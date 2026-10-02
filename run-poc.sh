#!/usr/bin/env bash
# End-to-end PoC: build each scenario with Vault UNREACHABLE (like a CI runner),
# then run the jars that built in AOT mode against a local Vault dev server.
set -uo pipefail
cd "$(dirname "$0")"

GRADLE=$([ -x ./gradlew ] && echo ./gradlew || echo gradle)
LOGS=build/poc-logs
LIVE_VAULT=http://127.0.0.1:8200
DEAD_VAULT=http://127.0.0.1:1
TOKEN=poc-root-token
SCENARIOS=(naive blank-import optional-disabled runtime-import runtime-import-flags)

mkdir -p "$LOGS"

# --- Vault dev server -------------------------------------------------------
if ! curl -sf -m1 "$LIVE_VAULT/v1/sys/health" >/dev/null; then
  echo ">> starting vault dev server on $LIVE_VAULT"
  vault server -dev -dev-root-token-id="$TOKEN" -dev-listen-address=127.0.0.1:8200 >"$LOGS/vault.log" 2>&1 &
  VAULT_PID=$!
  trap 'kill $VAULT_PID 2>/dev/null' EXIT
  until curl -sf -m1 "$LIVE_VAULT/v1/sys/health" >/dev/null; do sleep 0.5; done
fi
VAULT_ADDR=$LIVE_VAULT VAULT_TOKEN=$TOKEN \
  vault kv put secret/vault-aot-poc db.password=s3cr3t-from-vault feature.audit.enabled=true >/dev/null

# --- Build phase: Vault unreachable ----------------------------------------
echo; echo "================ BUILD (processAot + bootJar, Vault unreachable) ================"
rm -rf build/libs
for s in "${SCENARIOS[@]}"; do
  if VAULT_ADDR=$DEAD_VAULT VAULT_TOKEN= $GRADLE bootJar -Paot="$s" >"$LOGS/build-$s.log" 2>&1; then
    printf '%-22s BUILD OK\n' "$s"
  else
    reason=$(grep -hoE "Connection refused|Config data location '[^']*' does not exist" "$LOGS/build-$s.log" | head -1)
    printf '%-22s BUILD FAILED  (%s)\n' "$s" "${reason:-see $LOGS/build-$s.log}"
  fi
done

# --- Run phase --------------------------------------------------------------
run() { # <label> <jar-scenario> [env assignments...] -- [extra java args...]
  local label=$1 s=$2; shift 2
  local jar=build/libs/vault-aot-poc-0.0.1-$s.jar
  echo; echo "--- $label"
  [ -f "$jar" ] || { echo "    (no jar - build failed)"; return; }
  local envs=() ; while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env VAULT_ADDR=$LIVE_VAULT VAULT_TOKEN=$TOKEN "${envs[@]}" java "$@" -jar "$jar" 2>&1 \
    | grep -E '^(AOT|db\.|feature|AuditService|Vault)|^Caused by: org.springframework.web' | sed 's/^/    /' | head -8 || true
}

echo; echo "================ RUN (Vault live) ================"
run "optional-disabled  | AOT"                              optional-disabled    -- -Dspring.aot.enabled=true
run "runtime-import     | AOT | import via env var"         runtime-import       SPRING_CONFIG_IMPORT=vault:// -- -Dspring.aot.enabled=true
run "runtime-import     | AOT | import forgotten"           runtime-import       -- -Dspring.aot.enabled=true
run "runtime-import     | NO AOT (baseline)"                runtime-import       SPRING_CONFIG_IMPORT=vault:// --
run "runtime-import-flags | AOT | import via env var"       runtime-import-flags SPRING_CONFIG_IMPORT=vault:// -- -Dspring.aot.enabled=true
run "runtime-import     | AOT | Vault down at runtime"      runtime-import       SPRING_CONFIG_IMPORT=vault:// VAULT_ADDR=$DEAD_VAULT -- -Dspring.aot.enabled=true
