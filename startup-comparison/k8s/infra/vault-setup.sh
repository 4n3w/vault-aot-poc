#!/usr/bin/env bash
# Vault-side setup for the startup comparison (02-06). Runs against the k3d dev Vault (vault-0, root token "root");
# on a real cluster, have your Vault admins create the equivalent policy and kubernetes auth role.
set -euo pipefail
CTX=${KUBE_CONTEXT:-k3d-vault-startup}
vexec() { kubectl --context "$CTX" -n vault exec -i vault-0 -- env VAULT_TOKEN=root "$@"; }

vexec vault kv put secret/vault-startup-demo db.password=s3cr3t-from-vault >/dev/null

# 05/06 MongoDB credentials, two ways. Static: a KV path holding the user mongo-seed.js creates.
vexec vault kv put secret/vault-startup-demo-mongo spring.mongodb.username=startup-static \
  spring.mongodb.password="${MONGO_STATIC_PASSWORD:-static-s3cr3t}" >/dev/null
# Dynamic: the database engine creates a Mongo user per lease (talking to Mongo directly, not via the proxy).
vexec vault secrets enable database >/dev/null 2>&1 || true
vexec vault write database/config/mongo plugin_name=mongodb-database-plugin allowed_roles=vault-startup-demo-mongo \
  connection_url='mongodb://{{username}}:{{password}}@mongo.mongo.svc:27017/admin' \
  username=root password="${MONGO_ROOT_PASSWORD:-root-s3cr3t}" >/dev/null
vexec vault write database/roles/vault-startup-demo-mongo db_name=mongo default_ttl=1h max_ttl=24h \
  creation_statements='{ "db": "admin", "roles": [{ "role": "readWrite", "db": "startup" }] }' >/dev/null

# Read access to the paths the apps ask for (Spring Cloud Vault's defaults include secret/application).
vexec vault policy write vault-startup-demo - >/dev/null <<'POLICY'
path "secret/data/vault-startup-demo"   { capabilities = ["read"] }
path "secret/data/vault-startup-demo/*" { capabilities = ["read"] }
path "secret/data/application"          { capabilities = ["read"] }
path "secret/data/application/*"        { capabilities = ["read"] }
path "secret/data/vault-startup-demo-mongo"     { capabilities = ["read"] }
path "database/creds/vault-startup-demo-mongo"  { capabilities = ["read"] }
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
