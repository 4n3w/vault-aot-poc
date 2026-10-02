# 05: MongoDB baseline (no AOT)

**Intent:** 02 plus a real database. The app reads its MongoDB credentials from Vault and does the
startup work Mongo-backed apps usually do: make sure its indexes exist, then load reference data
into memory. It's the yardstick for [06](../06-mongo-optimized/README.md).

Two things vary, giving 6 deployments from 2 images:

| | KV creds | Dynamic creds |
|---|---|---|
| **blocking** (sync driver) | `mongo-kv-blocking` | `mongo-dyn-blocking` |
| **deferred** (sync driver) | `mongo-kv-deferred` | `mongo-dyn-deferred` |
| **reactive** (reactive driver) | `mongo-kv-reactive` | `mongo-dyn-reactive` |

- **`sync/`** has the blocking driver (`spring-boot-starter-data-mongodb`) and serves the blocking
  and deferred deployments.
- **`reactive/`** has the reactive driver (`-reactive`).

## How it gets the secrets

As in 02, Spring Cloud Vault logs in (`KUBERNETES` auth) and reads Vault itself on every start, from
`SPRING_CONFIG_IMPORT=vault://`.

| Creds | Where | How the app asks for them |
|---|---|---|
| **KV** (static) | `secret/vault-startup-demo-mongo`: `spring.mongodb.username` / `.password` of the user `startup-static` | `SPRING_CLOUD_VAULT_KV_APPLICATION_NAME=vault-startup-demo,vault-startup-demo-mongo`. One more KV path: mount lookup + read |
| **Dynamic** | Vault's database engine: `database/creds/vault-startup-demo-mongo` creates a new Mongo user per pod (TTL 1 h), revoked when the app shuts down | `SPRING_CLOUD_VAULT_MONGODB_ENABLED=true` (needs `spring-cloud-vault-config-databases`) |

**Gotcha found while building this:** Spring Cloud Vault 5.0 still puts the dynamic credentials in
`spring.data.mongodb.username` / `.password`. Spring Boot 4 moved them to `spring.mongodb.*` and no
longer reads the old names. With the defaults, the creds load from Vault but are never used, and
Mongo fails with `Command ... requires authentication`. `application.yml` sets them explicitly:

```yaml
spring.cloud.vault.mongodb:
  username-property: spring.mongodb.username
  password-property: spring.mongodb.password
```

## What each mode does at startup

All modes do the same work: create the 3 `@Indexed` indexes of `ReferenceItem` (no-ops once they
exist, but still a round trip each) and load all `reference_items` (5,000 by default) into a map.
Only *when* they do it differs:

| Mode | When | Readiness |
|---|---|---|
| blocking | In `ReferenceDataCache.afterPropertiesSet()`, while the context starts: it adds to `SPRING_INIT bean_creation` and delays Ready | Includes Mongo (`MANAGEMENT_ENDPOINT_HEALTH_GROUP_READINESS_INCLUDE=readinessState,mongo`) |
| deferred | On a virtual thread after `ApplicationReadyEvent` | Doesn't wait for Mongo |
| reactive | A `Flux` pipeline subscribed after `ApplicationReadyEvent` | Doesn't wait for Mongo |

`spring.data.mongodb.auto-index-creation=true` is the other common way to create indexes at startup.
It blocks in the same way, but its time can't be separated out, so the app creates the indexes
itself.

The app logs one line when the work is done, which `k3d.sh` reads:

```
MONGO_INIT mode=blocking creds=kv items=5000 blocking=212ms background=0ms
```

Deferring doesn't make the work disappear. The k3d run also times the first `GET /items` right after
Ready (`first_req`). That request always queries Mongo, so it pays for any connection setup the
warm-up hasn't done yet.

### Why the mode is a runtime switch

`MONGO_INIT`, the readiness group, and which Vault creds to read are all **environment variables
read at runtime**, never `@Profile` or `@ConditionalOnProperty`. AOT evaluates conditions once, at
build time ([01, finding 4](../01-aot-breakage/README.md)), so a conditional bean would fix the mode
when the image is built. A runtime value lets one image serve every mode with AOT on or off.

## Results

25 ms latency per round trip to Vault **and** to MongoDB, 1 CPU per pod. Full tables are in
[startup-comparison](../startup-comparison/README.md#05-06-mongodb).

| k3d pod, median of 5 | blocking | deferred | reactive |
|---|---|---|---|
| Mongo work on the startup path (`mongo_block`) | **~610–680 ms** | 0 | 0 |
| Same work after Ready (`mongo_bg`) | 0 | 700–830 ms | 1300–1360 ms |
| `SPRING_INIT bean_creation` | ~1.8–1.95 s | ~1.15–1.3 s | ~1.15–1.35 s |
| JVM total, AOT off → on | 6.6 → 5.6–5.75 s | 5.9–6.0 → 5.0–5.06 s | 6.25–6.3 → 5.1 s |
| First `GET /items` after Ready | 50 ms | 60–130 ms | 150–210 ms |

- **Blocking costs ~0.6–0.7 s of JVM time** (the index check plus loading 5,000 documents in 25 ms
  round trips). It also holds readiness until Mongo answers. Deferring moves all of it after Ready.
- **Deferring is nearly free for users here.** The first request is only 10–80 ms slower than with a
  warm cache, because the background warm-up has already opened the connection pool. The warm-up
  still uses the pod's 1 CPU for ~0.7–0.8 s after Ready.
- **Reactive doesn't help startup.** It defers the same way, but its warm-up is ~0.5 s slower and
  so is its first request. Use the reactive driver because the app is reactive, not to start faster.
- **KV vs dynamic creds: no measurable difference to the app.** Both make 7 Vault requests per
  start (KV: one more path; dynamic: one `database/creds` read), and `vault` is ~1.2–1.35 s either
  way. Vault creates the Mongo user on its side, talking to Mongo directly.
- **AOT saves ~0.9–1.2 s of JVM time.** `bean_defs` drops 1.3–1.4 s → 0.12–0.17 s. That's more than
  in 02 because there are more beans to define (Mongo, Spring Data, repositories). Vault time is
  unchanged.
- `pod_ready` moves in ~1 s steps (1 s readiness probe period), so compare JVM totals for anything
  smaller than that.

## Run it

k3d only (the local `run.sh` has no MongoDB). From the repo root:

```sh
make 05                 # 6 deployments x AOT off/on; RUNS=3 for a quicker pass
make compare-mongo      # 05 and 06 side by side
```

`make k3d-up` (also run automatically on first use) installs MongoDB, seeds it (`MONGO_SEED_DOCS`,
default 5000) and sets up the Vault database engine. The 05/06 deployments sit at 0 replicas until
they're measured.
