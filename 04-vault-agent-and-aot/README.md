# 04: Vault Agent and AOT

**Intent:** keep Spring Cloud Vault in the app (for `VaultTemplate`, dynamic secrets or lease
renewal at runtime), but move login, TLS and DNS into a **Vault Agent sidecar**. The app runs with
Spring AOT.

## How it gets the secret

- **The agent's job:** the Agent Injector adds a sidecar that logs in to Vault and listens on
  `127.0.0.1:8200`. It adds its own token to every request (`agent-cache-use-auto-auth-token: force`).
- **The app's job:** Spring Cloud Vault talks only to that sidecar, with `authentication: NONE`.
- **Paths read:** only the app's own KV path (`kv.default-context: ""`, `kv.profiles: ""`). That's 2
  requests per start (mount lookup + read), which the agent forwards to Vault.
- **Where the import comes from:** the runtime environment (`SPRING_CONFIG_IMPORT=vault://`), not
  `application.yml`. So `processAot` never contacts Vault; see [01](../01-aot-breakage/README.md).

| File | What to look at |
|---|---|
| [`src/main/resources/application.yml`](src/main/resources/application.yml) | `uri` = the sidecar, `authentication: NONE`, trimmed KV paths, no import |
| [`k8s/deployment.yaml`](k8s/deployment.yaml) | Injector annotations, and the `command` that waits for the agent's listener before `exec java` (the injector has no native-sidecar option, so the app can start first) |
| [`local/agent-proxy.hcl`](local/agent-proxy.hcl) | The same agent as a local process (AppRole auto-auth, API proxy on `127.0.0.1:8100`), used by the comparison script |

## Results

25 ms latency per Vault round trip; full tables in [startup-comparison](../startup-comparison/README.md#results).

| | AOT off | AOT on | vs 02 baseline (no AOT) |
|---|---|---|---|
| **Overall Vault time**, local (agent already running) | 355 ms | **353 ms** | 449 ms |
| **Overall Vault time**, k3d pod (1 CPU) | 866 ms | **903 ms** | 856 ms |
| – of which in the JVM | 730 ms | 766 ms | 856 ms |
| – of which agent init container + waiting for the sidecar | 29 + 107 ms | 31 + 107 ms | — |
| JVM total, local | 1520 ms | **1312 ms** | 1650 ms |
| JVM total, k3d pod | 3583 ms | **2966 ms** | 3708 ms |
| Pod scale-up → Ready, k3d | ~5.5 s | **~4.5 s** | ~4.4 s |

- **The JVM is ~740 ms faster than 02**, but that's mostly AOT. The Vault time in the JVM drops only
  ~90–125 ms (no login, fewer requests). Loading and starting the Vault client is most of it.
- **The pod's overall Vault time is no lower than 02's,** once the agent's init container and the
  wait for the sidecar are counted. The pod isn't ready any sooner either.
- **When to pick this:** for runtime Vault access, not for startup speed.

## Run it

```sh
../gradlew :04-vault-agent-and-aot:bootJar
SPRING_CONFIG_IMPORT=vault:// VAULT_AGENT_ADDR=http://127.0.0.1:8100 \
  java -Dspring.aot.enabled=true -jar build/libs/startup-vault-agent-0.0.1.jar   # needs a running agent
```

Measured, from the repo root: `make 04` runs it with AOT off and on, and asks (fzf) whether to run
`local` (Vault dev server + latency proxy) or on `k3d` (pods; the cluster is created on first use).
`WHERE=local|k3d` skips the question. `make compare` puts it next to 02 and 03. Both use the scripts
in [`startup-comparison`](../startup-comparison/README.md).
