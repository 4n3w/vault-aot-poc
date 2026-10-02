#!/usr/bin/env bash
# Local startup comparison of apps 02-04, each with AOT off and on, against a Vault dev server that
# sits behind a latency proxy (toxiproxy), so each round trip to "remote" Vault costs what it would
# in a cluster.
#
#   02-baseline-no-aot                  Spring Cloud Vault -> Vault (AppRole login here, KUBERNETES in k8s)
#   03-vault-with-file-secrets-and-aot  secrets rendered to files before start (Agent init container / VSO)
#   04-vault-agent-and-aot              Spring Cloud Vault -> local Vault Agent (sidecar) -> Vault
#
# Env: RUNS (default 5), VAULT_LATENCY_MS (default 25), AOT=off|on|both (default both),
#      APPS="baseline file-secrets vault-agent" (default all three; any subset).
set -uo pipefail
cd "$(dirname "$0")"

GRADLE=$([ -x ../gradlew ] && echo ../gradlew || echo gradle)
RUNS=${RUNS:-5}
LATENCY_MS=${VAULT_LATENCY_MS:-25}
ALL_APPS=(baseline file-secrets vault-agent)
APPS=(${APPS:-${ALL_APPS[*]}})
for a in "${APPS[@]}"; do
  [[ " ${ALL_APPS[*]} " == *" $a "* ]] || { echo "unknown app '$a'; choose from: ${ALL_APPS[*]}" >&2; exit 2; }
done
selected() { [[ " ${APPS[*]} " == *" $1 "* ]]; }
case ${AOT:-both} in
  off) AOT_MODES=no ;; on) AOT_MODES=yes ;; both) AOT_MODES="no yes" ;;
  *) echo "AOT must be off, on or both" >&2; exit 2 ;;
esac
WORK=build/local
LOGS=build/logs
AUDIT=$PWD/$LOGS/vault-audit.log
VAULT=http://127.0.0.1:8200         # the real server
REMOTE_VAULT=http://127.0.0.1:18200 # the same server through the latency proxy
AGENT=http://127.0.0.1:8100
ROOT_TOKEN=poc-root-token

for tool in vault toxiproxy-server toxiproxy-cli jq perl curl; do
  command -v $tool >/dev/null || { echo "missing: $tool (brew install ${tool%-*})" >&2; exit 1; }
done
JAVA_MAJOR=$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.specification.version/ {print $2}')
if ! [ "${JAVA_MAJOR%%.*}" -ge 25 ] 2>/dev/null; then
  echo "java on PATH is ${JAVA_MAJOR:-unknown}; need 25+ (e.g. sdk use java 25.0.x-amzn)" >&2
  exit 1
fi

rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK/secrets" "$LOGS"
PIDS=()
trap 'kill ${PIDS[@]+"${PIDS[@]}"} 2>/dev/null' EXIT
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
v() { VAULT_ADDR=$VAULT VAULT_TOKEN=$ROOT_TOKEN vault "$@"; }
wait_for() { local i; for i in $(seq 1 100); do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done; return 1; }

# --- Vault dev server -------------------------------------------------------
if ! curl -sf -m1 "$VAULT/v1/sys/health" >/dev/null; then
  echo ">> starting vault dev server on $VAULT"
  vault server -dev -dev-root-token-id=$ROOT_TOKEN -dev-listen-address=127.0.0.1:8200 >"$LOGS/vault.log" 2>&1 &
  PIDS+=($!)
  wait_for curl -sf -m1 "$VAULT/v1/sys/health" || { echo "vault did not start" >&2; exit 1; }
fi
v kv put secret/vault-startup-demo db.password=s3cr3t-from-vault >/dev/null
v policy write vault-startup-demo local/policy.hcl >/dev/null
v auth enable approle >/dev/null 2>&1 || true
v write auth/approle/role/vault-startup-demo token_policies=vault-startup-demo token_ttl=1h \
  secret_id_num_uses=0 secret_id_ttl=0 >/dev/null
v read -field=role_id auth/approle/role/vault-startup-demo/role-id >"$WORK/role_id"
v write -f -field=secret_id auth/approle/role/vault-startup-demo/secret-id >"$WORK/secret_id"
v audit enable -path=startup-local file file_path="$AUDIT" >/dev/null 2>&1 || true
touch "$AUDIT"

# --- Latency proxy ----------------------------------------------------------
if ! curl -sf -m1 http://127.0.0.1:8474/version >/dev/null; then
  toxiproxy-server >"$LOGS/toxiproxy.log" 2>&1 &
  PIDS+=($!)
  wait_for curl -sf -m1 http://127.0.0.1:8474/version || { echo "toxiproxy did not start" >&2; exit 1; }
fi
toxiproxy-cli delete vault >/dev/null 2>&1 || true
toxiproxy-cli create --listen 127.0.0.1:18200 --upstream 127.0.0.1:8200 vault >/dev/null
toxiproxy-cli toxic add --type latency --attribute latency="$LATENCY_MS" vault >/dev/null

app_dir() {
  case $1 in
    baseline) echo ../02-baseline-no-aot ;;
    file-secrets) echo ../03-vault-with-file-secrets-and-aot ;;
    vault-agent) echo ../04-vault-agent-and-aot ;;
  esac
}
app_label() { echo "$(basename "$(app_dir "$1")" | cut -c1-2)-$1"; }
app_jar() { echo "$(app_dir "$1")/build/libs/startup-$1-0.0.1.jar"; }

# --- Build (Vault unreachable, like CI) -------------------------------------
echo ">> building ${APPS[*]}"
TASKS=(); for a in "${APPS[@]}"; do TASKS+=(":$(basename "$(app_dir "$a")"):bootJar"); done
if ! VAULT_ADDR=http://127.0.0.1:1 $GRADLE -p .. "${TASKS[@]}" >"$LOGS/build.log" 2>&1; then
  echo "build failed, see $LOGS/build.log" >&2; exit 1
fi

# --- 04: Vault Agent sidecar (proxy mode), already up and logged in ---------
if selected vault-agent; then
  vault agent -config=../04-vault-agent-and-aot/local/agent-proxy.hcl >"$LOGS/agent-proxy.log" 2>&1 &
  PIDS+=($!)
  wait_for curl -sf -m1 "$AGENT/v1/auth/token/lookup-self" || { echo "vault agent did not authenticate" >&2; exit 1; }
fi

# --- 03: Vault Agent init container (render files, exit) --------------------
if selected file-secrets; then
  t0=$(now_ms)
  vault agent -config=../03-vault-with-file-secrets-and-aot/local/agent-render.hcl >"$LOGS/agent-render.log" 2>&1 \
    || { echo "agent render failed, see $LOGS/agent-render.log" >&2; exit 1; }
  RENDER_MS=$(( $(now_ms) - t0 ))
fi

# --- Runs -------------------------------------------------------------------
median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
field() { sed -E "s/.* $1=([0-9]+)ms.*/\1/"; }

ROWS=()
COLS='%-16s %-4s %9s %7s %12s %9s %10s %8s %8s %8s %10s'
bench() { # <app> <aot: yes|no> [env assignments...]
  local app=$1 aot=$2; shift 2
  local label=$app-$([ "$aot" = yes ] && echo aot || echo noaot)
  local flags="-Dstartup-timing.exit-after-ready=true -Dspring.aot.enabled=$([ "$aot" = yes ] && echo true || echo false)"
  local i log before timing init lines=() inits=() reqs=()
  for i in $(seq 1 "$RUNS"); do
    log="$LOGS/$label-$i.log"
    before=$(wc -l <"$AUDIT")
    env ${1+"$@"} java $flags -jar "$(app_jar "$app")" --server.port=0 >"$log" 2>&1
    timing=$(grep -o 'STARTUP_TIMING .*' "$log"); init=$(grep -o 'SPRING_INIT .*' "$log")
    if [ -z "$timing" ] || [ -z "$init" ] || ! grep -q 'db.password loaded=true' "$log"; then
      echo "!! $label run $i failed, see $log" >&2; tail -5 "$log" | sed 's/^/   /' >&2; return
    fi
    lines+=("$timing"); inits+=("$init")
    reqs+=("$(tail -n +$((before + 1)) "$AUDIT" | jq -r 'select(.type=="request" and .request.path != "auth/token/revoke-self") | .request.path' | grep -c .)")
  done
  med() { printf '%s\n' "$@" | field "$FIELD" | median; }
  ROWS+=("$(printf "$COLS" "$(app_label "$app")" "$aot" \
    "$(FIELD=env_prepare med "${lines[@]}")" "$(FIELD=vault med "${lines[@]}")" "$(FIELD=spring_init med "${lines[@]}")" \
    "$(FIELD=context_prepare med "${inits[@]}")" "$(FIELD=bean_definitions med "${inits[@]}")" \
    "$(FIELD=web_server med "${inits[@]}")" "$(FIELD=bean_creation med "${inits[@]}")" \
    "$(FIELD=total med "${lines[@]}")" "$(printf '%s\n' "${reqs[@]}" | median)")")
  printf '.'
}

echo ">> $RUNS runs per app, AOT ${AOT:-both}, Vault latency ${LATENCY_MS} ms per round trip"
for aot in $AOT_MODES; do
  selected baseline && bench baseline $aot SPRING_CONFIG_IMPORT=vault:// VAULT_ADDR=$REMOTE_VAULT VAULT_AUTH=APPROLE \
    VAULT_ROLE_ID="$(cat $WORK/role_id)" VAULT_SECRET_ID="$(cat $WORK/secret_id)"
  selected file-secrets && bench file-secrets $aot SECRETS_DIR="$PWD/$WORK/secrets"
  selected vault-agent && bench vault-agent $aot SPRING_CONFIG_IMPORT=vault:// VAULT_AGENT_ADDR=$AGENT
done
echo

echo
echo "Median of $RUNS runs (ms). env_prep = config loading; vault = the part of it spent on the vault:// import"
echo "(client setup, login, reads). spring_init = Spring initialization:"
echo "ctx_prep (create context, register sources) + bean_defs (config parsing, scanning, conditions - what AOT replaces)"
echo "+ web_srv (create Tomcat) + beans (instantiate singletons, start lifecycle). vault_req = requests Vault saw per start."
printf "$COLS\n" app aot env_prep vault spring_init ctx_prep bean_defs web_srv beans total vault_req
printf '%s\n' ${ROWS[@]+"${ROWS[@]}"}
echo
if selected file-secrets; then
  echo "03 file-secrets pre-start: Vault Agent init container (login + render) took ${RENDER_MS} ms before the JVM started."
fi
if selected vault-agent; then
  echo "04 vault-agent: the agent sidecar was already up and logged in (best case); in a pod it starts alongside the app."
fi
echo "Logs: $LOGS/"
