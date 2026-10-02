#!/usr/bin/env bash
# End-to-end PoC: build each scenario with Vault UNREACHABLE (like a CI runner),
# then run the jars that built in AOT mode against a local Vault dev server.
# Prints each scenario's configuration and each run's command, so it's clear what is tested.
#
# Env: SCENARIOS="naive runtime-import ..." limits the run to those scenarios (default: all).
set -uo pipefail
cd "$(dirname "$0")"
source ./scenarios.sh

GRADLE=$([ -x ../gradlew ] && echo ../gradlew || echo gradle)
LOGS=build/poc-logs
LIVE_VAULT=http://127.0.0.1:8200
DEAD_VAULT=http://127.0.0.1:1
TOKEN=poc-root-token
SECRET='db.password=s3cr3t-from-vault feature.audit.enabled=true'
[ "${SCENARIOS:-all}" = all ] && SCENARIOS="${ALL_SCENARIOS[*]}"
SCENARIOS=($SCENARIOS)
selected() { local s; for s in "${SCENARIOS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
for s in "${SCENARIOS[@]}"; do
  [[ " ${ALL_SCENARIOS[*]} " == *" $s "* ]] || { echo "unknown scenario '$s'; choose from: ${ALL_SCENARIOS[*]}" >&2; exit 2; }
done

mkdir -p "$LOGS"

# The run phase uses `java` from PATH; an older JVM fails with an error the output filter hides.
JAVA_MAJOR=$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.specification.version/ {print $2}')
if ! [ "${JAVA_MAJOR%%.*}" -ge 25 ] 2>/dev/null; then
  echo "java on PATH is ${JAVA_MAJOR:-unknown}; need 25+ (e.g. sdk use java 25.0.x-amzn)" >&2
  exit 1
fi

# --- Vault dev server -------------------------------------------------------
if ! curl -sf -m1 "$LIVE_VAULT/v1/sys/health" >/dev/null; then
  echo ">> starting vault dev server on $LIVE_VAULT"
  vault server -dev -dev-root-token-id="$TOKEN" -dev-listen-address=127.0.0.1:8200 >"$LOGS/vault.log" 2>&1 &
  VAULT_PID=$!
  trap 'kill $VAULT_PID 2>/dev/null' EXIT
  until curl -sf -m1 "$LIVE_VAULT/v1/sys/health" >/dev/null; do sleep 0.5; done
fi
VAULT_ADDR=$LIVE_VAULT VAULT_TOKEN=$TOKEN vault kv put secret/vault-aot-poc $SECRET >/dev/null

# --- What is being tested ---------------------------------------------------
echo
echo "================ SETUP ================"
show_base_config
echo "Vault dev server ($LIVE_VAULT) holds secret/vault-aot-poc: $SECRET"
echo "  feature.audit.enabled decides whether the AuditService bean exists (@ConditionalOnProperty)."

# --- Build phase: Vault unreachable ----------------------------------------
echo
echo "================ BUILD: processAot + bootJar with Vault unreachable (VAULT_ADDR=$DEAD_VAULT) ================"
rm -rf build/libs
SUMMARY=()
for s in "${ALL_SCENARIOS[@]}"; do
  selected "$s" || continue
  echo
  show_scenario "$s"
  if VAULT_ADDR=$DEAD_VAULT VAULT_TOKEN= $GRADLE :01-aot-breakage:bootJar -Paot="$s" >"$LOGS/build-$s.log" 2>&1; then
    result="BUILD OK"
  else
    reason=$(grep -hoE "Connection refused|Config data location '[^']*' does not exist" "$LOGS/build-$s.log" | head -1)
    result="BUILD FAILED  (${reason:-see $LOGS/build-$s.log})"
  fi
  echo "  result:           $result"
  SUMMARY+=("$(printf '%-22s %s' "$s" "$result")")
done
echo
echo "Build summary:"
printf '  %s\n' "${SUMMARY[@]}"

# --- Run phase --------------------------------------------------------------
run() { # <label> <question> <jar-scenario> [env assignments...] -- [extra java args...]
  local label=$1 question=$2 s=$3; shift 3
  local jar=build/libs/vault-aot-poc-0.0.1-$s.jar
  selected "$s" || return 0
  RAN=$((RAN + 1))
  echo; echo "--- $label"
  echo "    checks: $question"
  [ -f "$jar" ] || { echo "    (no jar - build failed)"; return; }
  local envs=() ; while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  echo "    \$ ${envs[*]+${envs[*]} }java ${*+$* }-jar $jar"
  env VAULT_ADDR=$LIVE_VAULT VAULT_TOKEN=$TOKEN ${envs[@]+"${envs[@]}"} java "$@" -jar "$jar" 2>&1 \
    | grep -E '^(AOT|db\.|feature|AuditService|Vault)|^Caused by: org.springframework.web' | sed 's/^/    /' | head -8 || true
}

echo
echo "================ RUN: the jars that built, against the live Vault (VAULT_ADDR=$LIVE_VAULT) ================"
RAN=0
run "optional-disabled  | AOT" \
    "Vault was disabled during processAot: do secrets still load, and are the Vault beans still there?" \
    optional-disabled -- -Dspring.aot.enabled=true
run "runtime-import     | AOT | import via env var" \
    "The import exists only at runtime: do secrets load, and do the Vault beans survive AOT?" \
    runtime-import SPRING_CONFIG_IMPORT=vault:// -- -Dspring.aot.enabled=true
run "runtime-import     | AOT | import forgotten" \
    "Same jar without SPRING_CONFIG_IMPORT: does startup notice that the secrets are missing?" \
    runtime-import -- -Dspring.aot.enabled=true
run "runtime-import     | NO AOT (baseline)" \
    "Same jar without -Dspring.aot.enabled: the reference for which beans should exist" \
    runtime-import SPRING_CONFIG_IMPORT=vault:// --
run "runtime-import-flags | AOT | import via env var" \
    "feature.audit.enabled=true was passed to processAot: does AuditService exist under AOT?" \
    runtime-import-flags SPRING_CONFIG_IMPORT=vault:// -- -Dspring.aot.enabled=true
run "runtime-import     | AOT | Vault down at runtime" \
    "Vault unreachable at startup with fail-fast: true: does the app refuse to start?" \
    runtime-import SPRING_CONFIG_IMPORT=vault:// VAULT_ADDR=$DEAD_VAULT -- -Dspring.aot.enabled=true
[ "$RAN" -gt 0 ] || echo "    (nothing to run: naive and blank-import never produce a jar - their builds are the test)"
