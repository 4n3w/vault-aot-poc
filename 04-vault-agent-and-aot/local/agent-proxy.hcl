# Vault Agent as a local API proxy: what the k8s injector's sidecar does with
# vault.hashicorp.com/agent-cache-enable + agent-cache-use-auto-auth-token: "force".
# The agent logs in once and adds its token to every request the app sends it.
# Used by startup-comparison/run.sh, which starts the agent from startup-comparison/ - paths are relative to it.

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

api_proxy {
  use_auto_auth_token = "force"
}

cache {}

listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}
