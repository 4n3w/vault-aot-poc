# 03: Vault with file secrets and AOT

**Intent:** take Vault off the app's startup path entirely. Secrets are written to files before the
JVM starts, and the app reads them like any other config. The app has **no Vault client**, and it
runs with Spring AOT.

## How it gets the secret

```yaml
spring.config.import: optional:configtree:${SECRETS_DIR:/vault/secrets}/
```

Each file becomes a property (`/vault/secrets/db.password` → `db.password`). It works with AOT
as-is: `processAot` finds no directory, so it makes no call and needs no flags (`optional:`). The
app still fails at startup if `db.password` is missing, because it has no default.

Two ways to produce the files, both under [`k8s/`](k8s):

| | [`k8s/vso/`](k8s/vso) (Vault Secrets Operator) | [`k8s/agent-init/`](k8s/agent-init) (Vault Agent init container) |
|---|---|---|
| How | `VaultStaticSecret` syncs `secret/vault-startup-demo` into a k8s Secret, mounted at `/vault/secrets` | Injector with `agent-pre-populate-only`: logs in, renders one file per key into an in-memory volume, exits |
| Vault calls at pod start | **0**: VSO syncs in the background | 4 (login, renew, mount lookup, read), before the app container starts |
| Pod starts if Vault is slow or down | Yes, with the last synced values | No, it waits for Vault or fails |
| Secrets stored in | etcd (needs encryption at rest + RBAC on Secrets) | Pod memory only |
| Rotation | Rolling restart (`rolloutRestartTargets`) | Restart |

Locally, [`local/agent-render.hcl`](local/agent-render.hcl) plays the init container (render once,
exit). The comparison script uses it.

## Results

25 ms latency per Vault round trip; full tables in [startup-comparison](../startup-comparison/README.md#results).

| | AOT off | AOT on | vs 02 baseline (no AOT) |
|---|---|---|---|
| **Overall Vault time**, k3d, VSO | **0** | **0** | 856 ms |
| **Overall Vault time**, k3d, Agent init container | 84 ms | 85 ms | 856 ms |
| JVM total, local | 1088 ms | **885 ms** | 1650 ms (−46%) |
| JVM total, k3d pod (1 CPU), VSO | 2942 ms | **2412 ms** | 3708 ms (−35%) |
| `env_prepare` (config loading), k3d, VSO | 336 ms | 388 ms | 1169 ms |
| Pod scale-up → Ready, k3d, VSO | ~3.6 s | **~3.6 s** | ~4.4 s |

- **This is the fastest of the three.** The app never touches Vault, so its `vault` time is 0.
- **The Agent init container variant** spends ~85 ms on Vault before the app container starts
  (login + read; it grows with Vault latency). VSO spends none on the pod's startup path.
- **The time saved is mostly not network.** It comes from not having to load and start a Vault
  client at all.

## Run it

```sh
../gradlew :03-vault-with-file-secrets-and-aot:bootJar
SECRETS_DIR=/path/to/secret/files java -Dspring.aot.enabled=true -jar build/libs/startup-file-secrets-0.0.1.jar
```

Measured, from the repo root: `make 03` runs it with AOT off and on, and asks (fzf) whether to run
`local` (Vault dev server + latency proxy) or on `k3d` (pods; the cluster is created on first use).
`WHERE=local|k3d` skips the question. `make compare` puts it next to 02 and 04. Both use the scripts
in [`startup-comparison`](../startup-comparison/README.md).
