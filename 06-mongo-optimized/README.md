# 06: MongoDB optimized (AOT + deferred init)

**Intent:** take the 05 app and apply everything that shortens startup: AOT, Mongo work moved off
the startup path (deferred), and Vault login/fetch moved out of the JVM. Each of the three delivery
options from 03 and 04 is used, with both KV and dynamic creds. That gives 6 deployments from 2
images:

| Delivery | KV creds | Dynamic creds | Image |
|---|---|---|---|
| Vault Secrets Operator → files (as in 03) | `opt-vso-kv` | `opt-vso-dyn` | `files/` (no Vault client) |
| Vault Agent init container → files (as in 03) | `opt-agentinit-kv` | `opt-agentinit-dyn` | `files/` |
| Vault Agent sidecar, Spring Cloud Vault reads through it (as in 04) | `opt-agent-kv` | `opt-agent-dyn` | `agent/` |

All run with `-Dspring.aot.enabled=true` and `MONGO_INIT=deferred`. See
[05](../05-mongo-baseline/README.md#what-each-mode-does-at-startup) for what the modes do.

## How it gets the secrets

| Deployment | db.password | Mongo creds | Vault calls per pod start |
|---|---|---|---|
| `opt-vso-kv` | 03's VSO Secret at `/vault/secrets` | `VaultStaticSecret` → Secret `vault-startup-demo-mongo-kv` at `/vault/mongo` | 0 (VSO syncs ahead of time) |
| `opt-vso-dyn` | same | `VaultDynamicSecret` → Secret `vault-startup-demo-mongo-dyn` at `/vault/mongo`. **One** lease and Mongo user, held and renewed by VSO and shared by every pod | 0 |
| `opt-agentinit-kv` | agent template → `/vault/secrets/db.password` | 2 more templates → `/vault/secrets/spring.mongodb.username` / `.password` | login + reads, in the init container |
| `opt-agentinit-dyn` | same | same templates on `database/creds/...`. The agent reads it once for both files, so every pod gets its own Mongo user | login + reads + user creation, in the init container |
| `opt-agent-kv` | Spring Cloud Vault via the sidecar | KV path, as in 05 | through the sidecar, during `env_prepare` |
| `opt-agent-dyn` | same | database engine, as in 05 (`SPRING_CLOUD_VAULT_MONGODB_ENABLED=true`) | same |

- **File names are the property names.** The files app reads both directories with
  `optional:configtree:`, so `/vault/mongo/spring.mongodb.username` becomes
  `spring.mongodb.username`.
- **VSO renames the database engine's keys.** It returns `username` / `password`, and
  `transformation.templates` in [`k8s/vso/vso.yaml`](k8s/vso/vso.yaml) renames them.
- **Trade-off of `opt-vso-dyn`:** pods start with no Vault call, but they all share one dynamic
  user. When VSO rotates it, pods must restart to pick up the new creds (`rolloutRestartTargets`;
  left out here so a rotation can't land mid-benchmark).

## Spring Data AOT repositories: already on

Spring Data 2025.1 generates repository implementations during `processAot`
(`ReferenceItemRepositoryImpl__AotRepository` in the jar), so derived queries like `countByCategory`
aren't parsed at startup. `spring.aot.repositories.enabled` **defaults to true**, so every
AOT-processed jar gets them, 05's included. They only take effect when the app runs with
`-Dspring.aot.enabled=true`.

**Gotcha:** the repository lives in the plain `mongo-common` library, which the Spring Boot plugin
doesn't configure. Without `-parameters` on its compiler, `processAot` fails with
`MethodParameter.getParameterName() must not be null` (see
[`mongo-common/build.gradle`](../mongo-common/build.gradle)).

## Results

Same setup as 05: 25 ms per round trip to Vault and MongoDB, 1 CPU per pod. Full tables are in
[startup-comparison](../startup-comparison/README.md#05-06-mongodb).

| k3d pod, AOT on, median of 5 | JVM total | Vault on the startup path | Vault requests | Scale-up → Ready |
|---|---|---|---|---|
| 05 `mongo-kv-blocking`, **AOT off** (the usual setup) | 6.6 s | 1.2 s (in the JVM) | 7 | 8.1 s |
| `opt-vso-kv` / `opt-vso-dyn` | **4.1 s** | 0 | 0 | **5.3 s** |
| `opt-agentinit-kv` / `-dyn` | 4.1 s | ~90 / ~105 ms (init container) | 6 / 7 | 5.8–6.3 s |
| `opt-agent-kv` / `-dyn` | 4.8 s | ~1.2 s (JVM via agent + agent wait) | 8 / 9 | 6.7–7.1 s |

- **VSO + AOT + deferred is the fastest: 2.5 s less JVM time (−38%) and ~2.8 s sooner to Ready
  than the usual setup.** It matches 03 without Mongo (4.1 s JVM, 5.3 s Ready in a separate
  `make compare` run), because nothing Vault- or Mongo-related is left on the startup path.
- **Dynamic creds cost nothing extra with VSO**, since VSO holds the lease. With the agent init
  container they add one request and ~15 ms, and every pod gets its own Mongo user.
- **The agent sidecar is still the slowest of the three.** Spring Cloud Vault still spends ~1.05 s
  in the JVM, and the pod waits for the sidecar, the same pattern as 04.
- **The Mongo warm-up still runs after Ready** (~0.7–0.9 s, `mongo_bg`); first requests took
  50–210 ms.

## Run it

k3d only. From the repo root:

```sh
make 06                 # 6 deployments x AOT off/on; RUNS=3 for a quicker pass
make compare-mongo      # 05 and 06 side by side
```
