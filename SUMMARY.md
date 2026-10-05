# Fastest startup: Spring Boot + Vault (+ MongoDB)

**Setup:** local k3d cluster, 1 CPU / 768 Mi per app pod, 25 ms latency per round trip to Vault and to MongoDB, median of 5 pod starts. The 02–04 numbers come from a separate `make compare` run from the 05/06 numbers.

## Ranking (AOT on)

| Approach                                                              | JVM start  | Pod Ready | Vault time on startup path |
| --------------------------------------------------------------------- | ---------- | --------- | -------------------------- |
| **Files from VSO + AOT** (03 / 06 `opt-vso`)                          | **4.1 s**  | **5.3 s** | **0**                      |
| Files from Vault Agent init container + AOT (03 / 06 `opt-agentinit`) | 4.1 s      | 5.8–6.3 s | ~90–105 ms                 |
| Vault Agent sidecar + AOT (04 / 06 `opt-agent`)                       | 4.75–4.8 s | 6.7–7.2 s | ~1.2 s                     |
| Usual setup: Spring Cloud Vault → Vault, no AOT (02 / 05)             | 6.2–6.6 s  | 8.0–8.1 s | ~1.2–1.3 s                 |

**Best vs usual, with MongoDB:**
- **Usual:** 05 with KV creds, blocking Mongo startup, no AOT.
- **Best:** 06 VSO.
- **JVM start:** 6.6 → 4.1 s (−38%).
- **Ready:** 8.1 → 5.3 s (−2.8 s).

## Why each one wins or loses

**1. Secrets as files from VSO: fastest**
- **No Vault work at startup.** VSO syncs secrets into a Kubernetes Secret in the background, and the app reads them as files (`configtree:`). Vault requests per pod start: 0.
- **No Vault client in the JVM.** Config loading drops from ~1.7 s to ~0.5 s. Most of Vault's startup cost is loading and starting the Spring Cloud Vault client on 1 CPU, not the network: 02's 5 requests are only ~125 ms of latency, yet it spends ~1.3 s on Vault.
- **Dynamic Mongo creds cost nothing extra.** VSO holds the lease ahead of time. The trade-offs:
  - all pods share one Mongo user;
  - pods must restart when VSO rotates the creds;
  - the secrets are stored in etcd.

**2. Files from a Vault Agent init container: same JVM time, slower pod**
- **Same JVM time.** The app reads the same files, so it starts just as fast.
- **Slower pod.** The init container logs in and reads on every pod start (~90–105 ms, 6–7 requests), and the extra container adds scheduling time before the app starts.
- **Upside:** secrets never touch etcd, and with dynamic creds each pod gets its own Mongo user (+1 request, ~15 ms).

**3. Vault Agent sidecar: speeds up the JVM, but the pod isn't Ready sooner**
- **Login moves out of the app**, but Spring Cloud Vault still runs in the JVM and still reads through the agent: ~1.05–1.1 s.
- **The app also waits for the sidecar** to start listening (~110–160 ms).
- **Use it when the app needs Vault at runtime** (lease renewal, dynamic reads), not for startup speed.

**4. AOT: always worth it, and more so as the app grows**
- **What it removes:** bean definition work (config parsing, scanning, `@Conditional` evaluation). That's 1.3–1.4 s → ~0.15 s in the Mongo app, saving 0.9–1.2 s of JVM time (02: ~0.5 s).
- **What it doesn't touch:** the Vault fetch. That happens while config is loaded, before AOT's generated code runs, so the Vault cost is the same with or without AOT.

**5. Deferring Mongo startup work: saves ~0.6–0.7 s**
- **Blocking cost:** checking indexes and loading 5,000 reference documents during startup, plus readiness waiting on Mongo, costs ~0.6–0.7 s before the pod can be Ready.
- **Deferring is nearly free for users.** The first request after Ready takes 60–130 ms instead of 50 ms, because the background warm-up has already opened the connection pool.
- **Caveat:** the warm-up still uses the CPU for ~0.7–0.8 s after Ready.

## What didn't help

- **Reactive Mongo driver:** no faster to start than deferred with the normal driver. Its warm-up (~1.3 s vs ~0.75 s) and first request (150–210 ms) were both slower. What helps is deferring the work, not the driver.
- **KV vs dynamic creds:** no measurable difference to startup in any setup; both cost about the same number of Vault requests.

## Gotchas found along the way

- **Don't put `spring.config.import=vault://` in `application.yml` with AOT.** `processAot` then calls Vault at build time. Supply the import at runtime instead (`SPRING_CONFIG_IMPORT=vault://`). The commonly suggested `--spring.config.import=` fix doesn't work.
- **AOT fixes `@Profile` and `@ConditionalOnProperty` decisions at build time.** Choose behaviour at runtime, from environment variables read when the app starts.
- **Spring Cloud Vault 5.0.2 + Boot 4: set `username-property` / `password-property` to `spring.mongodb.*`.** By default the creds load but Boot never uses them.
- **Spring Data AOT repositories** need `-parameters` on any library module that holds repositories.
