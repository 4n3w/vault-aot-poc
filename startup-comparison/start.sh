#!/usr/bin/env bash
# Run one app (02, 03, 04) or all three, locally or on the k3d cluster - picked with fzf.
# 05/06 (MongoDB) run on k3d only.
#
#   start.sh 02|03|04|all          pick "local" or "k3d" with fzf
#   start.sh 05|06|mongo           k3d (mongo = 05 and 06 side by side)
#   WHERE=local|k3d start.sh 03    no prompt (also: no fzf or no terminal -> local)
#
# k3d: if the cluster isn't up yet, it is created first (./k3d.sh up, a few minutes).
set -uo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  02)  label="02 baseline";        apps=baseline;     only=baseline ;;
  03)  label="03 file secrets";    apps=file-secrets; only="file-secrets file-secrets-agent-init" ;;
  04)  label="04 Vault Agent";     apps=vault-agent;  only=vault-agent ;;
  all) label="02-04 side by side"; apps="baseline file-secrets vault-agent"
       only="baseline file-secrets file-secrets-agent-init vault-agent" ;;
  05)  label="05 MongoDB baseline"
       only="mongo-kv-blocking mongo-kv-deferred mongo-kv-reactive mongo-dyn-blocking mongo-dyn-deferred mongo-dyn-reactive" ;;
  06)  label="06 MongoDB optimized"
       only="opt-vso-kv opt-vso-dyn opt-agentinit-kv opt-agentinit-dyn opt-agent-kv opt-agent-dyn" ;;
  mongo) label="05-06 side by side"
       only="mongo-kv-blocking mongo-kv-deferred mongo-kv-reactive mongo-dyn-blocking mongo-dyn-deferred mongo-dyn-reactive
             opt-vso-kv opt-vso-dyn opt-agentinit-kv opt-agentinit-dyn opt-agent-kv opt-agent-dyn" ;;
  *)   echo "usage: $0 02|03|04|all|05|06|mongo" >&2; exit 2 ;;
esac

# The first deployment of the selection exists = the cluster is up and has this version of the manifests.
k3d_ready() { kubectl --context k3d-vault-startup -n vault-startup get deploy "${only%% *}" >/dev/null 2>&1; }

case $1 in
  05|06|mongo)   # MongoDB is only set up on k3d (run.sh has no local MongoDB)
    if [ "${WHERE:-k3d}" != k3d ]; then echo ">> $label runs on k3d only (no local MongoDB); using k3d" >&2; fi
    WHERE=k3d ;;
esac

where=${WHERE:-}
if [ -z "$where" ]; then
  if command -v fzf >/dev/null && [ -t 0 ]; then
    if k3d_ready; then state="up"; else state="not running - creates it first, a few minutes"; fi
    where=$(printf '%s\t%s\t%s\n' \
        local "processes on this machine: Vault dev server + latency proxy" "APPS=\"$apps\" startup-comparison/run.sh" \
        k3d   "pods on k3d cluster vault-startup ($state)"                      "ONLY=\"$only\" startup-comparison/k3d.sh run" \
      | fzf --delimiter '\t' --with-nth 1,2 --nth 1 --height 30% --reverse --prompt "$label> " \
          --header "Where should $label run?   ENTER: pick   ESC: cancel" \
          --preview 'echo {3}' --preview-window down:3:wrap \
      | cut -f1) || true
    [ -n "$where" ] || { echo "nothing selected" >&2; exit 1; }
  else
    where=local
  fi
fi

case $where in
  local)
    APPS="$apps" exec ./run.sh ;;
  k3d)
    if ! k3d_ready; then
      echo ">> k3d cluster vault-startup isn't up yet; creating it first (./k3d.sh up)"
      ./k3d.sh up || exit 1
    fi
    ONLY="$only" exec ./k3d.sh run ;;
  *)
    echo "WHERE must be local or k3d" >&2; exit 2 ;;
esac
