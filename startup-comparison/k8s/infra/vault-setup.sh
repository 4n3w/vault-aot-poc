#!/usr/bin/env bash
# Vault-side setup for the startup comparison (02-04). Runs against the k3d dev Vault (vault-0, root token "root");
# on a real cluster, have your Vault admins create the equivalent policy and kubernetes auth role.
set -euo pipefail
CTX=${KUBE_CONTEXT:-k3d-vault-startup}
vexec() { kubectl --context "$CTX" -n vault exec -i vault-0 -- env VAULT_TOKEN=root "$@"; }

vexec vault kv put secret/vault-startup-demo db.password=s3cr3t-from-vault >/dev/null

# Read access to the paths the apps ask for (Spring Cloud Vault's defaults include secret/application).
vexec vault policy write vault-startup-demo - >/dev/null <<'POLICY'
path "secret/data/vault-startup-demo"   { capabilities = ["read"] }
path "secret/data/vault-startup-demo/*" { capabilities = ["read"] }
path "secret/data/application"          { capabilities = ["read"] }
path "secret/data/application/*"        { capabilities = ["read"] }
POLICY

# Kubernetes auth: pods (and VSO) log in with the vault-startup-demo service account.
vexec vault auth enable kubernetes >/dev/null 2>&1 || true
vexec vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
vexec vault write auth/kubernetes/role/vault-startup-demo \
  bound_service_account_names=vault-startup-demo bound_service_account_namespaces=vault-startup \
  token_policies=vault-startup-demo token_ttl=1h >/dev/null

# Audit log, so k3d.sh can count the requests each pod start makes.
vexec vault audit enable file file_path=/tmp/vault-audit.log >/dev/null 2>&1 || true
echo "vault configured"
