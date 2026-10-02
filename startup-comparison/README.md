# Startup comparison: 02 vs 03 vs 04

How much startup time does fetching secrets from Vault cost, and what do secrets-from-files or a
Vault Agent sidecar (both with Spring AOT) save over a plain Spring Cloud Vault app? This folder
holds the tooling that runs the three apps side by side, and the results.

| Folder | Intent | Secrets via | AOT by default |
|---|---|---|---|
| [`02-baseline-no-aot`](../02-baseline-no-aot/README.md) | The usual setup, to measure against | Spring Cloud Vault logs in and reads Vault itself | off |
| [`03-vault-with-file-secrets-and-aot`](../03-vault-with-file-secrets-and-aot/README.md) | Take Vault off the startup path entirely | Files rendered before start, by VSO or a Vault Agent init container; no Vault client | on |
| [`04-vault-agent-and-aot`](../04-vault-agent-and-aot/README.md) | Keep Spring Cloud Vault, move login into a sidecar | Spring Cloud Vault reads through a Vault Agent sidecar on localhost | on |

- **Why AOT doesn't help with the fetch itself:** it happens while Spring Boot prepares the
  environment, a phase AOT doesn't change (see
  [01](../01-aot-breakage/README.md#aot-freezes-beans-not-configuration)). Whatever Vault costs, you
  pay it on every start, with or without AOT.
- **What the tuned apps do instead:** they take Vault work off that path, and AOT shortens Spring
  initialization on top.
- **Both settings are measured:** all three jars are AOT-processed, so every app is run with AOT
  off and on.
- **The timing lines:** every app logs `STARTUP_TIMING` (including the overall Vault time, `vault`)
  and `SPRING_INIT`; see the [root README](../README.md#startup-timing-lines).

## What's here

```
run.sh                 local comparison: Vault dev server + toxiproxy + processes
k3d.sh                 cluster comparison: up | run | down on a local k3d cluster
Dockerfile             one image per app (+ Dockerfile.dockerignore: only the jar is sent)
k8s/apps/              kustomization that deploys the apps' own manifests (02, 03 x2, 04, 05 x6, 06 x6) together
k8s/infra/             k3d only: Vault + VSO Helm values, toxiproxy, vault-setup.sh, mongo.yaml + mongo-seed.js
local/policy.hcl       Vault policy for the local run
```

Each app keeps what belongs to it in its own folder:
- its Kubernetes manifests: `k8s/` in each folder (03 has `vso/` and `agent-init/`);
- its local Vault Agent config: [`03 …/local/agent-render.hcl`](../03-vault-with-file-secrets-and-aot/local/agent-render.hcl)
  and [`04 …/local/agent-proxy.hcl`](../04-vault-agent-and-aot/local/agent-proxy.hcl).

## Results

Both runs put **25 ms of latency on every round trip to Vault** (toxiproxy), and both use Java 25.
Times are medians of 5 starts, in ms.

- `env_prepare` is config loading.
- **`vault` is the overall Vault time inside the JVM:** the part of `env_prepare` spent on the
  `vault://` import (setting up the client, logging in, reading). On k3d, `vault_total` adds the
  Vault time outside the JVM (agent init container + waiting for the agent sidecar).
- `spring_init` is Spring initialization, broken down as:
  - `ctx_prep`: create the context, register sources;
  - `bean_defs`: config parsing, scanning, conditions (what AOT replaces);
  - `web_server`: create Tomcat;
  - `beans`: instantiate singletons, start lifecycle beans.

### Local processes (`run.sh`; 12 CPUs, no limits)

| App | AOT | `env_prepare` | **`vault`** | `spring_init` | `ctx_prep` | `bean_defs` | `web_server` | `beans` | `total` | Vault requests |
|---|---|---|---|---|---|---|---|---|---|---|
| 02 baseline | off | 600 | **449** | 823 | 53 | 333 | 173 | 219 | **1650** | 5 |
| 02 baseline | on | 605 | **453** | 576 | 99 | 37 | 196 | 215 | **1423** | 5 |
| 03 file-secrets | off | 137 | **0** | 755 | 52 | 303 | 161 | 207 | **1088** | 0 |
| 03 file-secrets | on | 141 | **0** | 547 | 97 | 29 | 194 | 190 | **885** | 0 |
| 04 vault-agent | off | 510 | **355** | 784 | 55 | 319 | 163 | 218 | **1520** | 2 |
| 04 vault-agent | on | 509 | **353** | 557 | 102 | 38 | 178 | 200 | **1312** | 2 |

- **03's files have to be written first.** For 03, the Vault Agent init container (login + render)
  took **183 ms** before the JVM started.
- **04's agent was already running.** The local sidecar was up and logged in, so 04's local `vault`
  doesn't include starting it.

### k3d pods (`k3d.sh`; 1 CPU / 768Mi per app container)

| Deployment | AOT | `env_prepare` | **`vault`** | `spring_init` | `ctx_prep` | `bean_defs` | `web_server` | `beans` | JVM `total` |
|---|---|---|---|---|---|---|---|---|---|
| 02 baseline | off | 1169 | **856** | 1960 | 108 | 822 | 419 | 511 | **3708** |
| 02 baseline | on | 1208 | **856** | 1434 | 244 | 94 | 489 | 530 | **3175** |
| 03 file-secrets (VSO) | off | 336 | **0** | 2114 | 154 | 797 | 535 | 532 | **2942** |
| 03 file-secrets (VSO) | on | 388 | **0** | 1599 | 274 | 89 | 682 | 492 | **2412** |
| 03 file-secrets (Agent init) | off | 359 | **0** | 2029 | 111 | 794 | 520 | 523 | **2861** |
| 03 file-secrets (Agent init) | on | 343 | **0** | 1592 | 218 | 88 | 679 | 514 | **2413** |
| 04 vault-agent | off | 1079 | **730** | 1914 | 105 | 817 | 398 | 506 | **3583** |
| 04 vault-agent | on | 1093 | **766** | 1382 | 267 | 95 | 490 | 441 | **2966** |

| Deployment | AOT | JVM `total` | `vault` (JVM) | Agent init container | App waits for agent | **`vault_total`** | Scale-up → Ready | Vault requests |
|---|---|---|---|---|---|---|---|---|
| 02 baseline | off | 3708 | 856 | — | — | **856** | 4443 | 5 |
| 02 baseline | on | 3175 | 856 | — | — | **856** | 4503 | 5 |
| 03 file-secrets (VSO) | off | 2942 | 0 | — | — | **0** | 3576 | 0 |
| 03 file-secrets (VSO) | on | 2412 | 0 | — | — | **0** | 3554 | 0 |
| 03 file-secrets (Agent init) | off | 2861 | 0 | 84 | — | **84** | 4531 | 4 |
| 03 file-secrets (Agent init) | on | 2413 | 0 | 85 | — | **85** | 3566 | 4 |
| 04 vault-agent | off | 3583 | 730 | 29 | 107 | **866** | 5467 | 6 |
| 04 vault-agent | on | 2966 | 766 | 31 | 107 | **903** | 4456 | 6 |

- **`vault_total`** is the sum of `vault` (JVM), the agent init container (first to last log line),
  and the app's wait for the agent sidecar.
- **Precision:** "Scale-up → Ready" is only accurate to about a second, because readiness is probed
  every second. The other columns are in exact ms.
- **What the request counts include:**
  - 04: the agent's own login (init container) and its token renew/lookup calls, plus the app's two
    forwarded requests.
  - 03 Agent init: login, renew, mount lookup, read.

### What the numbers show

- **Overall Vault time:**
  - 02: ~450 ms locally, ~860 ms on k3d.
  - 04: about the same as 02 once its agent is counted (~870–900 ms on k3d).
  - 03: 0 with VSO, and ~85 ms with an Agent init container (all outside the JVM).
- **The Vault client costs more than the network.**
  - With 25 ms per round trip, 02's 5 requests are ~125 ms of waiting, yet its `vault` is 449 ms
    locally and 856 ms on 1 CPU.
  - Most of it is loading and starting Spring Cloud Vault, its HTTP client and Jackson. That's why
    04's `vault` stays high (730–766 ms on k3d) even without a login in the app.
- **Spring AOT works the same way in all three apps.**
  - It nearly removes `bean_defs`: ~300–330 → ~30–40 ms locally, ~790–820 → ~90 ms on 1 CPU.
  - `ctx_prep` grows a little (+45 ms locally, +105–165 ms on 1 CPU) to load the generated initializer.
  - Net, `spring_init` is 210–250 ms faster locally and 440–530 ms faster on 1 CPU. JVM `total` is
    200–230 ms and 450–620 ms faster.
  - AOT doesn't change `vault`: the Vault fetch costs the same with or without it.
- **Compare totals, not individual phases.** Classes are loaded the first time they're used, so that
  cost moves between phases. It shows most on k3d (1 CPU): there, `web_server` is slower with AOT,
  and 03's `web_server` is slower than the Vault apps' (no Vault client loaded those classes earlier).
- **03 (secrets from files + AOT) is the fastest combination.**
  - JVM `total`: 1650 → 885 ms locally (−46%), and 3708 → 2412 ms on k3d (−35%).
  - The VSO-fed pod is Ready about 0.9 s sooner than 02's pod.
  - An Agent init container gives the same JVM time. But it adds ~85 ms of Vault calls to every pod
    start (it grows with Vault latency), and it waits out any network stall before the app
    container even starts.
- **04 (Agent sidecar) speeds up the JVM but not the pod.**
  - With AOT, its JVM `total` is ~740 ms lower than 02 without AOT.
  - But its overall Vault time is no lower, and the init container, the sidecar's start, and the
    app waiting for its listener mean the pod is Ready no sooner than 02.
  - It's worth it when the app needs Spring Cloud Vault at runtime, not for startup alone.
- **None of this explains an 8–9 s startup.** That points to a network stall (see below).

## 05-06 MongoDB

05 and 06 add MongoDB, with its credentials from Vault (static KV, or the database engine), and the
startup work Mongo apps usually do (index check plus loading 5,000 reference documents).
- **05** keeps 02's Vault setup and compares doing that work **blocking**, **deferred** or
  **reactive**.
- **06** is the optimized version: AOT plus deferred init, through each of 03's and 04's delivery
  options.

The design is in the [05](../05-mongo-baseline/README.md) and [06](../06-mongo-optimized/README.md)
READMEs. They run on k3d only (`make 05`, `make 06`, `make compare-mongo`).

| Folder | Deployments | Secrets via | Mongo init | AOT by default |
|---|---|---|---|---|
| [`05-mongo-baseline`](../05-mongo-baseline/README.md) | `mongo-{kv,dyn}-{blocking,deferred,reactive}` | Spring Cloud Vault → Vault (as 02) | blocking / deferred / reactive | off |
| [`06-mongo-optimized`](../06-mongo-optimized/README.md) | `opt-{vso,agentinit,agent}-{kv,dyn}` | VSO files / agent init files (as 03) / agent sidecar (as 04) | deferred | on |

### k3d pods (`k3d.sh`; 1 CPU / 768Mi per app container, 25 ms to Vault and to MongoDB)

`make compare-mongo`, median of 5 pod starts:

```
JVM (ms): env_prep = config loading; vault = the part of it spent on the vault:// import (client setup,
login, reads). spring_init = Spring initialization:
ctx_prep (create context, register sources) + bean_defs (config parsing, scanning, conditions - what AOT
replaces) + web_srv (create Tomcat) + beans (instantiate singletons, start lifecycle).
deployment                     aot    env_prep   vault  spring_init  ctx_prep  bean_defs  web_srv    beans  jvm_total
05-mongo-kv-blocking           false      1698    1207         4206       134       1396      586     1937       6636
05-mongo-kv-blocking           true       1791    1234         3212       392        124      709     1892       5752
05-mongo-kv-deferred           false      1732    1238         3505       167       1389      568     1278       6035
05-mongo-kv-deferred           true       1797    1259         2504       336        141      642     1270       5063
05-mongo-kv-reactive           false      1736    1212         3533       137       1371      587     1358       6316
05-mongo-kv-reactive           true       1700    1214         2515       402        138      659     1156       5121
05-mongo-dyn-blocking          false      1701    1223         4101       151       1318      565     1960       6555
05-mongo-dyn-blocking          true       1692    1213         3095       327        169      683     1811       5582
05-mongo-dyn-deferred          false      1711    1257         3394       116       1362      568     1230       5882
05-mongo-dyn-deferred          true       1770    1214         2443       340        174      672     1154       5017
05-mongo-dyn-reactive          false      1861    1357         3420       124       1316      571     1295       6249
05-mongo-dyn-reactive          true       1796    1338         2424       384        124      703     1165       5123
06-opt-vso-kv                  false       499       0         3725       190       1323      710     1344       4902
06-opt-vso-kv                  true        507       0         2914       406        181      899     1287       4136
06-opt-vso-dyn                 false       500       0         3683       187       1374      770     1310       4819
06-opt-vso-dyn                 true        503       0         2893       401        168      919     1282       4121
06-opt-agentinit-kv            false       499       0         3777       191       1382      763     1316       4923
06-opt-agentinit-kv            true        522       0         2928       402        135      968     1296       4119
06-opt-agentinit-dyn           false       543       0         3730       188       1364      716     1368       4906
06-opt-agentinit-dyn           true        590       0         2850       396        155      951     1257       4081
06-opt-agent-kv                false      1578    1070         3466       127       1369      577     1287       5741
06-opt-agent-kv                true       1575    1063         2497       333        176      701     1184       4808
06-opt-agent-dyn               false      1528    1083         3333       123       1299      514     1274       5639
06-opt-agent-dyn               true       1594    1101         2422       332        171      705     1119       4779

Pod (ms): vault_total = all Vault time on the pod's startup path = vault (in the JVM) + agent_init (Vault
Agent init container, first to last log line) + agent_wait (app waiting for the agent sidecar).
pod_ready = scale-up -> Ready (incl. 1 s probe period). vault_req = Vault requests per pod start.
deployment                     aot    jvm_total   vault  agent_init  agent_wait  vault_total  pod_ready  vault_req
05-mongo-kv-blocking           false       6636    1207           0           0         1207       8095          7
05-mongo-kv-blocking           true        5752    1234           0           0         1234       7091          7
05-mongo-kv-deferred           false       6035    1238           0           0         1238       7176          7
05-mongo-kv-deferred           true        5063    1259           0           0         1259       7012          7
05-mongo-kv-reactive           false       6316    1212           0           0         1212       7950          7
05-mongo-kv-reactive           true        5121    1214           0           0         1214       7015          7
05-mongo-dyn-blocking          false       6555    1223           0           0         1223       8051          7
05-mongo-dyn-blocking          true        5582    1213           0           0         1213       7059          7
05-mongo-dyn-deferred          false       5882    1257           0           0         1257       7139          7
05-mongo-dyn-deferred          true        5017    1214           0           0         1214       6145          7
05-mongo-dyn-reactive          false       6249    1357           0           0         1357       7552          7
05-mongo-dyn-reactive          true        5123    1338           0           0         1338       6109          7
06-opt-vso-kv                  false       4902       0           0           0            0       6187          0
06-opt-vso-kv                  true        4136       0           0           0            0       5277          0
06-opt-vso-dyn                 false       4819       0           0           0            0       6175          0
06-opt-vso-dyn                 true        4121       0           0           0            0       5292          0
06-opt-agentinit-kv            false       4923       0          89           0           89       6304          6
06-opt-agentinit-kv            true        4119       0          88           0           88       5842          6
06-opt-agentinit-dyn           false       4906       0         104           0          104       7206          7
06-opt-agentinit-dyn           true        4081       0         109           0          109       6266          7
06-opt-agent-kv                false       5741    1070          31         161         1268       8178          8
06-opt-agent-kv                true        4808    1063          31         109         1223       7140          8
06-opt-agent-dyn               false       5639    1083          31         160         1274       8139          9
06-opt-agent-dyn               true        4779    1101          30         109         1241       6661          9

MongoDB (ms): mongo_block = index check + cache load on the startup path (blocking mode; part of beans).
mongo_bg = the same work after Ready (deferred/reactive). first_req = GET /items right after Ready
(always queries Mongo; pays any connection/auth setup the warm-up hasn't done yet).
deployment                     aot          beans mongo_block   mongo_bg  first_req
05-mongo-kv-blocking           false         1937        613          0         50
05-mongo-kv-blocking           true          1892        604          0         50
05-mongo-kv-deferred           false         1278          0        834        100
05-mongo-kv-deferred           true          1270          0        782        130
05-mongo-kv-reactive           false         1358          0       1362        160
05-mongo-kv-reactive           true          1156          0       1336        180
05-mongo-dyn-blocking          false         1960        683          0         50
05-mongo-dyn-blocking          true          1811        611          0         50
05-mongo-dyn-deferred          false         1230          0        731         60
05-mongo-dyn-deferred          true          1154          0        696         70
05-mongo-dyn-reactive          false         1295          0       1301        150
05-mongo-dyn-reactive          true          1165          0       1359        210
06-opt-vso-kv                  false         1344          0        690         50
06-opt-vso-kv                  true          1287          0        810        190
06-opt-vso-dyn                 false         1310          0        726        100
06-opt-vso-dyn                 true          1282          0        794        190
06-opt-agentinit-kv            false         1316          0        811        200
06-opt-agentinit-kv            true          1296          0        800        150
06-opt-agentinit-dyn           false         1368          0        887        160
06-opt-agentinit-dyn           true          1257          0        792         50
06-opt-agent-kv                false         1287          0        689        110
06-opt-agent-kv                true          1184          0        715        210
06-opt-agent-dyn               false         1274          0        716        110
06-opt-agent-dyn               true          1119          0        872        200
```

### What the numbers show

- **Blocking Mongo init costs ~0.6–0.7 s per start** (`mongo_block`, inside `beans`), and holds
  readiness until Mongo answers. Deferring it moves all of that after Ready. The first request then
  takes 60–130 ms instead of 50 ms, because the warm-up has already opened the connection pool.
- **The reactive driver doesn't start faster than deferred sync.** Its warm-up (~1.3 s) and first
  request (150–210 ms) are slower. What helps is deferring the work.
- **Static KV vs dynamic creds makes no difference in the JVM.** Both cost 7 Vault requests and
  ~1.2–1.35 s of `vault` in 05. With VSO, dynamic creds cost nothing at startup, since VSO holds the
  lease, but all pods share one Mongo user.
- **AOT matters more with a bigger app.** `bean_defs` falls 1.3–1.4 s → 0.12–0.17 s, so the JVM
  total drops ~0.9–1.2 s (02: ~0.45–0.6 s).
- **All together** (06 VSO: AOT + files + deferred) vs the usual setup (05 KV, blocking, no AOT):
  JVM 6.6 → 4.1 s (−38%), Ready 8.1 → 5.3 s.
- **The ranking is the same as 02–04:** VSO ≈ agent init < agent sidecar ≈ 05.

## Run it

From the repo root, `make 02`, `make 03`, `make 04` (one app) or `make compare` (all three) runs
[`start.sh`](start.sh). (05/06: `make 05`, `make 06`, `make compare-mongo`, always on k3d.) It asks with fzf where to run:

| Pick | Runs | Same as |
|---|---|---|
| `local` | processes on this machine (below) | `APPS="…" ./run.sh` |
| `k3d` | pods on the k3d cluster (below); creates the cluster first if it isn't up | `ONLY="…" ./k3d.sh run` |

```sh
make 03                        # pick local or k3d
make 03 WHERE=k3d              # no prompt
make compare WHERE=local AOT=on RUNS=3   # settings: RUNS (5), VAULT_LATENCY_MS (25), AOT=off|on|both (both)
```

### Locally (`run.sh`)

- **Setup:** the script starts a Vault dev server with AppRole and an audit log, and puts
  **toxiproxy** in front of it (`127.0.0.1:18200`). Everything that talks to "remote" Vault pays
  `VAULT_LATENCY_MS` per round trip: 02 and both agents.
- **The two agent roles:**
  - 04's sidecar: a Vault Agent in API-proxy mode
    ([`agent-proxy.hcl`](../04-vault-agent-and-aot/local/agent-proxy.hcl)).
  - 03's init container: a Vault Agent run once in render-and-exit mode
    ([`agent-render.hcl`](../03-vault-with-file-secrets-and-aot/local/agent-render.hcl)), which
    writes the secret files.
- **Measuring:** it starts each app `RUNS` times with AOT off and `RUNS` times with AOT on, using
  `startup-timing.exit-after-ready=true`. It reports median `STARTUP_TIMING` and `SPRING_INIT`
  values, and the Vault requests each start made (from the audit log).

The local agent sidecar is already running and logged in, which is the best case. In a pod it
starts alongside the app; the k3d run shows that cost.

### On a local k3d cluster (`k3d.sh`)

```sh
make compare WHERE=k3d   # all deployments; creates the cluster on first use   (= ./k3d.sh up, then ./k3d.sh run)
make 03 WHERE=k3d        # one app's deployment(s) only                          (= ONLY="..." ./k3d.sh run)
make k3d-up              # create the cluster, or rebuild images + redeploy after code changes
make k3d-down            # delete the cluster
```

- **Your kube context isn't touched.** `up` creates its own cluster with
  `--kubeconfig-switch-context=false` and passes `--context k3d-vault-startup` everywhere.
- **What `up` installs:**
  - the `hashicorp/vault` chart (dev server + Agent Injector) and the `hashicorp/vault-secrets-operator` chart;
  - MongoDB for 05/06 ([`k8s/infra/mongo.yaml`](k8s/infra/mongo.yaml), namespace `mongo`), seeded
    by [`mongo-seed.js`](k8s/infra/mongo-seed.js) with `MONGO_SEED_DOCS` reference items and the
    static user `startup-static`;
  - a toxiproxy Deployment in front of Vault (`vault-latency.vault.svc:8200`) and MongoDB
    (`mongo-latency.vault.svc:27017`, `MONGO_LATENCY_MS`);
  - the Vault setup in [`k8s/infra/vault-setup.sh`](k8s/infra/vault-setup.sh): KV seed (including
    the static Mongo creds at `secret/vault-startup-demo-mongo`), the database engine with role
    `vault-startup-demo-mongo`, policy, and Kubernetes auth role `vault-startup-demo` bound to the
    `vault-startup-demo` service account.
- **What `up` deploys** through [`k8s/apps`](k8s/apps): the four 02–04 deployments below, plus
  the twelve 05/06 deployments (see [05-06 MongoDB](#05-06-mongodb)). Those sit at 0 replicas: `up`
  starts each one once as a smoke test, and `run` starts them only while it measures them.

  | Deployment | Folder | Secrets via |
  |---|---|---|
  | `baseline` | [02 `k8s/`](../02-baseline-no-aot/k8s) | Spring Cloud Vault → Vault, through the latency proxy |
  | `file-secrets` | [03 `k8s/vso/`](../03-vault-with-file-secrets-and-aot/k8s/vso) | **VSO**: `VaultStaticSecret` → k8s Secret → volume at `/vault/secrets` |
  | `file-secrets-agent-init` | [03 `k8s/agent-init/`](../03-vault-with-file-secrets-and-aot/k8s/agent-init) | **Injector init container only** (`agent-pre-populate-only`), templates into `/vault/secrets` |
  | `vault-agent` | [04 `k8s/`](../04-vault-agent-and-aot/k8s) | Injector sidecar (`agent-cache-enable`, `agent-cache-use-auto-auth-token: force`); the agent goes through the latency proxy |

- **What `run` does:** it scales each deployment 0 → 1, `RUNS` times with AOT off and `RUNS` times
  with AOT on, one deployment at a time, with the same 1 CPU / 768Mi on every app container. It
  switches AOT with `JAVA_TOOL_OPTIONS`, and afterwards restores each deployment's own setting. For
  each start it records:
  - `STARTUP_TIMING` (incl. `vault`) and `SPRING_INIT`;
  - the app's wait for the agent sidecar (`AGENT_WAIT`, 04 only);
  - the Vault Agent init container's duration (from its log timestamps);
  - wall time from scale-up to Ready;
  - the Vault requests that came through the latency proxy;
  - for 05/06: the `MONGO_INIT` line, and the time of the first `GET /items` right after Ready.
- **VSO talks to Vault directly.** It syncs in the background and is never on a pod's startup path.

### On your own cluster

Use [`k8s/apps`](k8s/apps) (`kubectl apply -k startup-comparison/k8s/apps`) after pointing it at
your environment:

- **Images:** the `images:` entries in `k8s/apps/kustomization.yaml`. Build them with the
  [`Dockerfile`](Dockerfile), from the repo root:
  ```sh
  docker build -f startup-comparison/Dockerfile --build-arg JAR=build/libs/startup-baseline-0.0.1.jar \
    -t <registry>/vault-startup-baseline:<tag> 02-baseline-no-aot
  ```
- **Vault address:** `VAULT_ADDR` in 02, `vault.hashicorp.com/service` in the two injector
  deployments (or drop it to use the injector's default), and VSO's `VaultConnection`.
- **Vault side:** a policy and a Kubernetes auth role equivalent to
  [`vault-setup.sh`](k8s/infra/vault-setup.sh).

Then compare:

```sh
kubectl logs deploy/<app> -c app | grep -E 'STARTUP_TIMING|SPRING_INIT|AGENT_WAIT'
# pod-level phases (1 s resolution): scheduled -> initialized -> ready
kubectl get pod -l app=<app> -o json | jq -r '.items[0].status.conditions[] | "\(.type)\t\(.lastTransitionTime)"'
```

The JVM line can't see init containers or the wait for the agent. The pod conditions can.

## Finding a slow Vault fetch in your cluster

Spring Cloud Vault 5 has no retry, and `spring.cloud.vault.connection-timeout` defaults to 5000 ms.
A Vault fetch of several seconds is most likely **one ~5 s timeout** plus normal work. Spring Boot
mutes logging while config loads, so look at `env_prepare` in the `STARTUP_TIMING` line, then run
these from a pod in the same namespace:

```sh
curl -so /dev/null -w 'dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} total=%{time_total}\n' \
  "$VAULT_ADDR/v1/sys/health"
cat /etc/resolv.conf     # ndots:5 and a long search list?
time vault write auth/kubernetes/login role=<role> jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
```

| Symptom | Likely cause | Fix |
|---|---|---|
| `dns` ≈ 5 s | Search-list expansion from `ndots:5`, or a kernel (conntrack) race that drops parallel IPv4/IPv6 lookups | Use an FQDN with a trailing dot in `VAULT_ADDR`, or set pod `dnsConfig` options (`ndots: "1"`, `single-request-reopen`), or run NodeLocal DNSCache |
| `connect` ≈ 5 s, then it works | IPv6 address tried first and not reachable | `-Djava.net.preferIPv4Stack=true`, or fix the AAAA record or the pod's IPv6 routing |
| `curl` is fast, but the app is slow right at pod start | Service-mesh proxy not ready when the JVM makes its first call | Istio `holdApplicationUntilProxyStarts: true`, or your mesh's equivalent |
| Login is slow | Vault's TokenReview call to the kube-apiserver | On the Vault side: check the k8s auth config and Vault's network path to the apiserver |

Fixing a stall like that helps every option below, and may be all you need.

## Choosing an approach

- **Keep Spring Cloud Vault, but read fewer paths.** Each KV path costs two round trips (mount
  lookup + read). Paths read = {`kv.application-name`, each `kv.default-context`} × (no profile +
  each active profile). With Spring's defaults and two profiles, that's 6 paths and 12 requests.
  - `kv.default-context: ""` and `kv.profiles: ""` cut it to one path (04 does this).
- **Secrets from files ([03](../03-vault-with-file-secrets-and-aot/README.md))** is the fastest. It
  needs no Vault client and makes no Vault call at start. VSO keeps the pod independent of Vault
  entirely.
- **Agent sidecar ([04](../04-vault-agent-and-aot/README.md))** suits apps that need Spring Cloud
  Vault at runtime (`VaultTemplate`, dynamic secrets, lease renewal).
- **Java's AOT cache on top.** Java 25 can cache loaded and linked classes, plus method profiles,
  from a training run (`-XX:AOTCacheOutput=app.aot`, then `-XX:AOTCache=app.aot`). Spring Boot's
  `-Dspring.context.exit=onRefresh` stops that training run after context refresh.
  - The training run goes through config loading, so it must not need Vault. 03 and 04 (runtime-only
    import) both qualify. This isn't measured here.
  - Avoid CRaC (checkpoint/restore) here: a checkpoint contains the secrets and the Vault token.
