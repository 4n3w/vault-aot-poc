# Read access to the paths the apps ask for (Spring Cloud Vault's defaults include secret/application).
path "secret/data/vault-startup-demo"   { capabilities = ["read"] }
path "secret/data/vault-startup-demo/*" { capabilities = ["read"] }
path "secret/data/application"          { capabilities = ["read"] }
path "secret/data/application/*"        { capabilities = ["read"] }
