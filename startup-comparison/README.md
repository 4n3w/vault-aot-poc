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
k8s/apps/              kustomization that deploys the apps' own manifests (02, 03 x2, 04) together
k8s/infra/             k3d only: Vault + VSO Helm values, toxiproxy, vault-setup.sh
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

## Run it

From the repo root, `make 02`, `make 03`, `make 04` (one app) or `make compare` (all three) runs
[`start.sh`](start.sh). It asks with fzf where to run:

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
  - a toxiproxy Deployment in front of Vault (`vault-latency.vault.svc:8200`);
  - the Vault setup in [`k8s/infra/vault-setup.sh`](k8s/infra/vault-setup.sh): KV seed, policy,
    and Kubernetes auth role `vault-startup-demo` bound to the `vault-startup-demo` service account.
- **What `up` deploys** through [`k8s/apps`](k8s/apps), as four deployments:

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
  - the Vault requests that came through the latency proxy.
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
