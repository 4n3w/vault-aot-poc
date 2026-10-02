#!/usr/bin/env bash
# Startup comparison of apps 02-04 on a local k3d cluster: Vault (dev) + Agent Injector + Vault Secrets
# Operator, a latency proxy in front of Vault, and the apps' own manifests (via k8s/apps).
#
#   ./k3d.sh up     create the cluster, install everything, build + import images, deploy the apps
#   ./k3d.sh run    start each deployment RUNS times with AOT off and on (one at a time), print medians
#   ./k3d.sh down   delete the cluster
#
# Env: RUNS (default 5), VAULT_LATENCY_MS (default 25); for run: AOT=off|on|both (default both),
#      ONLY="baseline file-secrets file-secrets-agent-init vault-agent" (default all; any subset).
# Uses its own cluster and passes --context everywhere; your current kube context is not changed.
set -uo pipefail
cd "$(dirname "$0")"

CLUSTER=vault-startup
CTX=k3d-$CLUSTER
NS=vault-startup
RUNS=${RUNS:-5}
LATENCY_MS=${VAULT_LATENCY_MS:-25}
DEPLOYMENTS=(baseline file-secrets file-secrets-agent-init vault-agent)
APPS=(baseline file-secrets vault-agent)
GRADLE=$([ -x ../gradlew ] && echo ../gradlew || echo gradle)

k() { kubectl --context "$CTX" "$@"; }
app_dir() {
  case $1 in
    baseline) echo ../02-baseline-no-aot ;;
    file-secrets*) echo ../03-vault-with-file-secrets-and-aot ;;
    vault-agent) echo ../04-vault-agent-and-aot ;;
  esac
}
label() { echo "$(basename "$(app_dir "$1")" | cut -c1-2)-$1"; }   # deployment name, prefixed with its folder number
die() { echo "$*" >&2; exit 1; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

up() {
  for tool in k3d helm kubectl docker jq perl; do command -v $tool >/dev/null || die "missing: $tool"; done

  if ! k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
    echo ">> creating k3d cluster $CLUSTER (current kube context stays as is)"
    k3d cluster create "$CLUSTER" --kubeconfig-update-default --kubeconfig-switch-context=false \
      --k3s-arg "--disable=traefik@server:0" --wait || die "cluster create failed"
  fi

  echo ">> installing Vault (dev + injector) and Vault Secrets Operator"
  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo update hashicorp >/dev/null
  helm --kube-context "$CTX" upgrade --install vault hashicorp/vault --version 0.34.1 \
    -n vault --create-namespace -f k8s/infra/vault-values.yaml --wait --timeout 5m >/dev/null || die "vault install failed"
  helm --kube-context "$CTX" upgrade --install vso hashicorp/vault-secrets-operator --version 1.6.0 \
    -n vault-secrets-operator-system --create-namespace -f k8s/infra/vso-values.yaml --wait --timeout 5m >/dev/null \
    || die "vso install failed"
  k -n vault wait --for=condition=Ready pod/vault-0 --timeout=180s >/dev/null || die "vault-0 not ready"
  KUBE_CONTEXT=$CTX k8s/infra/vault-setup.sh || die "vault setup failed"

  echo ">> latency proxy: ${LATENCY_MS} ms per round trip to Vault"
  k apply -f k8s/infra/toxiproxy.yaml >/dev/null
  k -n vault rollout status deploy/toxiproxy --timeout=120s >/dev/null || die "toxiproxy not ready"
  k -n vault exec deploy/toxiproxy -- /toxiproxy-cli toxic remove --toxicName latency vault >/dev/null 2>&1 || true
  k -n vault exec deploy/toxiproxy -- /toxiproxy-cli toxic add --toxicName latency --type latency \
    --attribute latency="$LATENCY_MS" vault >/dev/null || die "could not add latency toxic"

  echo ">> building jars and images"
  VAULT_ADDR=http://127.0.0.1:1 $GRADLE -p .. :02-baseline-no-aot:bootJar :03-vault-with-file-secrets-and-aot:bootJar \
    :04-vault-agent-and-aot:bootJar -q || die "gradle build failed"
  local app images=()
  for app in "${APPS[@]}"; do
    docker build -q -f Dockerfile --build-arg JAR="build/libs/startup-$app-0.0.1.jar" -t "vault-startup-$app:local" \
      "$(app_dir "$app")" >/dev/null \
      || die "docker build $app failed"
    images+=("vault-startup-$app:local")
  done
  k3d image import -c "$CLUSTER" "${images[@]}" >/dev/null 2>&1 || die "image import failed"

  echo ">> deploying apps"
  k apply -k k8s/apps >/dev/null || die "apply failed"
  local d
  for d in "${DEPLOYMENTS[@]}"; do
    k -n "$NS" rollout restart deploy/"$d" >/dev/null   # pick up rebuilt :local images
  done
  for d in "${DEPLOYMENTS[@]}"; do
    if k -n "$NS" rollout status deploy/"$d" --timeout=240s >/dev/null; then
      printf '   %-30s ready  %s\n' "$(label "$d")" "$(k -n "$NS" logs deploy/"$d" -c app 2>/dev/null | grep -o 'db.password loaded=.*')"
    else
      printf '   %-30s NOT READY (kubectl --context %s -n %s describe deploy/%s)\n' "$(label "$d")" "$CTX" "$NS" "$d"
    fi
  done
  echo "Done. Next: ./k3d.sh run"
}

audit_lines() { k -n vault exec vault-0 -- sh -c 'wc -l < /tmp/vault-audit.log' | tr -d ' '; }

# Requests that came through the latency proxy = requests made on behalf of the starting pod
# (VSO talks to Vault directly). The shutdown token revoke of the previous pod is excluded.
audit_requests_since() {
  local from=$1 proxy_ip
  proxy_ip=$(k -n vault get pod -l app=toxiproxy -o jsonpath='{.items[0].status.podIP}')
  k -n vault exec vault-0 -- tail -n +"$((from + 1))" /tmp/vault-audit.log \
    | jq -r --arg ip "$proxy_ip" 'select(.type=="request" and .request.remote_address==$ip
        and .request.path != "auth/token/revoke-self") | .request.path' | grep -c .
}

median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
field() { sed -E "s/.* $1=([0-9]+)ms.*/\1/"; }
# ms between the first and last log line of the pod's Vault Agent init container (0 if it has none).
agent_init_ms() {
  k -n "$NS" logs "$1" -c vault-agent-init 2>/dev/null \
    | perl -MTime::Local=timegm -ne '/^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)(\.\d+)?Z/ and push @t, timegm($6,$5,$4,$3,$2-1,$1) + ($7 || 0);
        END { printf "%d\n", @t ? ($t[-1] - $t[0]) * 1000 : 0 }'
}

# The deployments' normal AOT setting (restored after a run): only baseline runs without AOT.
aot_default() { [ "$1" = baseline ] && echo false || echo true; }

SPRING_ROWS=(); POD_ROWS=()
SPRING_COLS='%-30s %-5s %9s %7s %12s %9s %10s %8s %8s %10s'
POD_COLS='%-30s %-5s %10s %7s %11s %11s %12s %10s %10s'

bench_deployment() { # <deployment> <aot: true|false>
  local d=$1 aot=$2 i
  k -n "$NS" set env deploy/"$d" -c app JAVA_TOOL_OPTIONS="-Dspring.aot.enabled=$aot" >/dev/null
  k -n "$NS" wait --for=delete pod -l app="$d" --timeout=120s >/dev/null 2>&1
  local timings=() inits=() readys=() agent_inits=() waits=() totals=() reqs=()
  for i in $(seq 1 "$RUNS"); do
    local before t0 pod ready_ms log jvm_vault agent_init agent_wait
    before=$(audit_lines)
    t0=$(now_ms)
    k -n "$NS" scale deploy/"$d" --replicas=1 >/dev/null
    pod=""   # the new pod, not one still terminating
    while [ -z "$pod" ]; do
      sleep 0.1
      pod=$(k -n "$NS" get pod -l app="$d" -o json 2>/dev/null \
        | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | "pod/" + .metadata.name' | head -1)
    done
    if ! k -n "$NS" wait --for=condition=Ready "$pod" --timeout=240s >/dev/null; then
      echo "!! $d (aot=$aot) run $i: pod not ready (kubectl --context $CTX -n $NS describe $pod)" >&2; break
    fi
    ready_ms=$(( $(now_ms) - t0 ))
    log=$(k -n "$NS" logs "$pod" -c app)
    timings+=("$(grep -o 'STARTUP_TIMING .*' <<<"$log")")
    inits+=("$(grep -o 'SPRING_INIT .*' <<<"$log")")
    jvm_vault=$(grep -o 'STARTUP_TIMING .*' <<<"$log" | field vault)
    agent_init=$(agent_init_ms "$pod")
    agent_wait=$(grep -oE 'AGENT_WAIT ms=[0-9]+' <<<"$log" | grep -oE '[0-9]+$' || echo 0)
    agent_inits+=("$agent_init"); waits+=("$agent_wait")
    totals+=("$(( ${jvm_vault:-0} + agent_init + agent_wait ))")
    readys+=("$ready_ms")
    reqs+=("$(audit_requests_since "$before")")
    k -n "$NS" scale deploy/"$d" --replicas=0 >/dev/null
    k -n "$NS" wait --for=delete "$pod" --timeout=120s >/dev/null 2>&1
    printf '.'
  done
  med() { printf '%s\n' "$@" | field "$FIELD" | median; }
  SPRING_ROWS+=("$(printf "$SPRING_COLS" "$(label "$d")" "$aot" \
    "$(FIELD=env_prepare med "${timings[@]}")" "$(FIELD=vault med "${timings[@]}")" "$(FIELD=spring_init med "${timings[@]}")" \
    "$(FIELD=context_prepare med "${inits[@]}")" "$(FIELD=bean_definitions med "${inits[@]}")" \
    "$(FIELD=web_server med "${inits[@]}")" "$(FIELD=bean_creation med "${inits[@]}")" \
    "$(FIELD=total med "${timings[@]}")")")
  POD_ROWS+=("$(printf "$POD_COLS" "$(label "$d")" "$aot" "$(FIELD=total med "${timings[@]}")" \
    "$(FIELD=vault med "${timings[@]}")" "$(printf '%s\n' "${agent_inits[@]}" | median)" \
    "$(printf '%s\n' "${waits[@]}" | median)" "$(printf '%s\n' "${totals[@]}" | median)" \
    "$(printf '%s\n' "${readys[@]}" | median)" "$(printf '%s\n' "${reqs[@]}" | median)")")
}

run() {
  k get ns "$NS" >/dev/null 2>&1 || die "not set up; run ./k3d.sh up first"
  local d aot only=(${ONLY:-${DEPLOYMENTS[*]}}) modes
  for d in "${only[@]}"; do
    [[ " ${DEPLOYMENTS[*]} " == *" $d "* ]] || die "unknown deployment '$d'; choose from: ${DEPLOYMENTS[*]}"
  done
  case ${AOT:-both} in
    off) modes=false ;; on) modes=true ;; both) modes="false true" ;;
    *) die "AOT must be off, on or both" ;;
  esac
  echo ">> $RUNS pod starts per deployment (${only[*]}), AOT ${AOT:-both}, one deployment at a time"
  # Everything is scaled down while measuring, so the pod being measured has the node to itself.
  for d in "${DEPLOYMENTS[@]}"; do k -n "$NS" scale deploy/"$d" --replicas=0 >/dev/null; done
  for d in "${DEPLOYMENTS[@]}"; do
    [[ " ${only[*]} " == *" $d "* ]] || continue
    for aot in $modes; do bench_deployment "$d" "$aot"; done
  done
  for d in "${DEPLOYMENTS[@]}"; do   # back to each deployment's normal setting
    if [ "$(aot_default "$d")" = true ]; then
      k -n "$NS" set env deploy/"$d" -c app JAVA_TOOL_OPTIONS=-Dspring.aot.enabled=true >/dev/null 2>&1
    else
      k -n "$NS" set env deploy/"$d" -c app JAVA_TOOL_OPTIONS- >/dev/null 2>&1
    fi
    k -n "$NS" scale deploy/"$d" --replicas=1 >/dev/null
  done
  echo; echo
  echo "Median of $RUNS pod starts, Vault latency ${LATENCY_MS} ms per round trip, 1 CPU per app container."
  echo
  echo "JVM (ms): env_prep = config loading; vault = the part of it spent on the vault:// import (client setup,"
  echo "login, reads). spring_init = Spring initialization:"
  echo "ctx_prep (create context, register sources) + bean_defs (config parsing, scanning, conditions - what AOT"
  echo "replaces) + web_srv (create Tomcat) + beans (instantiate singletons, start lifecycle)."
  printf "$SPRING_COLS\n" deployment aot env_prep vault spring_init ctx_prep bean_defs web_srv beans jvm_total
  printf '%s\n' "${SPRING_ROWS[@]}"
  echo
  echo "Pod (ms): vault_total = all Vault time on the pod's startup path = vault (in the JVM) + agent_init (Vault"
  echo "Agent init container, first to last log line) + agent_wait (app waiting for the agent sidecar)."
  echo "pod_ready = scale-up -> Ready (incl. 1 s probe period). vault_req = Vault requests per pod start."
  printf "$POD_COLS\n" deployment aot jvm_total vault agent_init agent_wait vault_total pod_ready vault_req
  printf '%s\n' "${POD_ROWS[@]}"
}

down() { k3d cluster delete "$CLUSTER"; }

case "${1:-}" in
  up) up ;;
  run) run ;;
  down) down ;;
  *) echo "usage: $0 up|run|down" >&2; exit 2 ;;
esac
