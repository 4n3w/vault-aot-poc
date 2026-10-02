# 02: Baseline (no AOT)

**Intent:** the usual Spring Cloud Vault setup, with no AOT, no sidecar and no secret injection.
It's what 03 and 04 are measured against.

## How it gets the secret

On every start, Spring Cloud Vault logs in to Vault and reads the secrets itself:

- **Login:** `KUBERNETES` auth with role `vault-startup-demo` in a cluster; AppRole in the local run
  (`VAULT_AUTH=APPROLE`).
- **Paths read:** Spring's default KV paths, so both `secret/vault-startup-demo` **and**
  `secret/application`.
- **Requests per start:** 5 (login + 2 × (mount lookup + read)).

| File | What to look at |
|---|---|
| [`src/main/resources/application.yml`](src/main/resources/application.yml) | Vault client settings, untuned KV paths |
| [`k8s/deployment.yaml`](k8s/deployment.yaml) | Plain Deployment: `VAULT_ADDR`, `SPRING_CONFIG_IMPORT=vault://`, no AOT flag |

## Why the import comes from the environment

The `vault://` import is supplied at runtime (`SPRING_CONFIG_IMPORT=vault://`), not in
`application.yml`. That's only so the jar can also be AOT-processed: the startup comparison runs this
app with AOT on as well, to show what AOT alone buys. With the import in `application.yml`,
`processAot` would contact Vault at build time (see [01](../01-aot-breakage/README.md)). The Vault
fetch at startup is the same either way. In a cluster this app runs without AOT (no
`-Dspring.aot.enabled`).

## Results

25 ms latency per Vault round trip; full tables in [startup-comparison](../startup-comparison/README.md#results).

| | AOT off | AOT on |
|---|---|---|
| **Overall Vault time**, local | **449 ms** | 453 ms |
| **Overall Vault time**, k3d pod (1 CPU) | **856 ms** | 856 ms |
| JVM total, local | **1650 ms** | 1423 ms |
| JVM total, k3d pod | **3708 ms** | 3175 ms |
| Pod scale-up → Ready, k3d | ~4.4 s | ~4.5 s |

All of 02's Vault time is inside the JVM (the `vault` field in `STARTUP_TIMING`): setting up the
client, logging in, and 2 paths × (mount lookup + read). Only ~125 ms of it is network wait; the rest
is loading and starting the Vault client.

## Run it

```sh
../gradlew :02-baseline-no-aot:bootJar
SPRING_CONFIG_IMPORT=vault:// VAULT_ADDR=… VAULT_AUTH=APPROLE VAULT_ROLE_ID=… VAULT_SECRET_ID=… \
  java -jar build/libs/startup-baseline-0.0.1.jar
```

Measured, from the repo root: `make 02` runs it with AOT off and on, and asks (fzf) whether to run
`local` (Vault dev server + latency proxy) or on `k3d` (pods; the cluster is created on first use).
`WHERE=local|k3d` skips the question. `make compare` puts it next to 03 and 04. Both use the scripts
in [`startup-comparison`](../startup-comparison/README.md).
