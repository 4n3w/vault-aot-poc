# Vault Agent as an init container: what the k8s injector does with
# vault.hashicorp.com/agent-pre-populate-only: "true". Log in, render one file per key, exit.
# Vault Secrets Operator produces the same files (a synced Secret mounted as a volume).
# Used by startup-comparison/run.sh, which starts the agent from startup-comparison/ - paths are relative to it.

exit_after_auth = true

vault {
  address = "http://127.0.0.1:18200" # Vault through the latency proxy
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "build/local/role_id"
      secret_id_file_path                 = "build/local/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  exit_on_retry_failure = true
}

template {
  destination = "build/local/secrets/db.password"
  contents    = "{{ with secret \"secret/data/vault-startup-demo\" }}{{ index .Data.data \"db.password\" }}{{ end }}"
}
