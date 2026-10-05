# Spring Boot + HashiCorp Vault: AOT and startup time

Spring Boot 4.1.1, Spring Cloud 2025.1.3 (Spring Cloud Vault 5.0.2), Java 25. One folder per
question:

| Folder | Intent |
|---|---|
| [`01-aot-breakage`](01-aot-breakage/README.md) | How `spring.config.import=vault://` breaks with Spring AOT (`processAot`), and which fixes actually work |
| [`02-baseline-no-aot`](02-baseline-no-aot/README.md) | The usual setup, no AOT: Spring Cloud Vault logs in and reads Vault on every start. The yardstick for 03 and 04 |
| [`03-vault-with-file-secrets-and-aot`](03-vault-with-file-secrets-and-aot/README.md) | Secrets as files (Vault Secrets Operator or a Vault Agent init container) + AOT: no Vault client, no Vault call at startup |
| [`04-vault-agent-and-aot`](04-vault-agent-and-aot/README.md) | A Vault Agent sidecar handles login; Spring Cloud Vault reads through it + AOT |
| [`05-mongo-baseline`](05-mongo-baseline/README.md) | 02 plus MongoDB: Mongo creds from Vault (KV or the database engine), and Mongo startup work done blocking, deferred or reactive |
| [`06-mongo-optimized`](06-mongo-optimized/README.md) | 05 with AOT + deferred Mongo init, through each of 03's and 04's delivery options |
| [`startup-comparison`](startup-comparison/README.md) | Runs 02–06 side by side (02–04 locally or on a k3d cluster, 05–06 on k3d) and has the results |

**Short version:** [`SUMMARY.md`](SUMMARY.md) has the fastest setups, their numbers, and why each one wins.

02–06 build on 01. Their AOT builds use the approach 01 recommends: no `vault://` import in the
packaged config.

## Layout

```
Makefile                             make targets for everything below
01-aot-breakage/                     one app, five build scenarios, run.sh, pick-scenarios.sh (fzf)
02-baseline-no-aot/                  app + k8s/ manifest
03-vault-with-file-secrets-and-aot/  app + k8s/vso/, k8s/agent-init/ + local agent (render) config
04-vault-agent-and-aot/              app + k8s/ manifest + local agent (proxy) config
05-mongo-baseline/                   sync/ and reactive/ apps + k8s/ (6 deployments)
06-mongo-optimized/                  files/ and agent/ apps + k8s/vso/, k8s/agent-init/, k8s/agent/
mongo-common/                        shared library for 05/06: entity, repository, startup warm-up, /items
startup-comparison/                  run.sh (local), k3d.sh (cluster), Dockerfile, k8s/apps, k8s/infra, results
startup-timing/                      shared library: logs STARTUP_TIMING + SPRING_INIT lines per app start
```

## Running

Everything runs from the repo root through `make` (`make` alone lists the targets):

| Command | What it does |
|---|---|
| `make 01` | 01: pick AOT scenarios with fzf, build them with Vault unreachable, run the jars against Vault |
| `make 01-jar` | 01: pick one scenario and only build it, to see `processAot` fail or succeed |
| `make 02`, `make 03`, `make 04` | One app, AOT off and on. fzf asks **where** to run: `local` (Vault dev server + latency proxy on this machine) or `k3d` (pods on the local cluster, which is created on first use) |
| `make compare` | 02, 03 and 04 side by side, local or k3d |
| `make 05`, `make 06` | MongoDB baseline / optimized, AOT off and on, on k3d |
| `make compare-mongo` | 05 and 06 side by side (12 deployments; ~30 min at `RUNS=5`) |
| `make k3d-up` / `make k3d-down` | Create the k3d cluster (or rebuild + redeploy the apps after code changes) / delete it |
| `make build`, `make clean`, `make prereqs` | Build everything, clean up, check which tools are installed |

Settings you can pass:
- **01:** `SCENARIOS="naive runtime-import"`, `SCENARIOS=all` or `SCENARIO=naive` skip the fzf picker.
- **02–04:** `WHERE=local|k3d` skips the fzf picker. `RUNS=3`, `VAULT_LATENCY_MS=50` and
  `AOT=off|on|both` tune the run.
- **05–06:** k3d only. The same settings, plus `MONGO_LATENCY_MS` (default: `VAULT_LATENCY_MS`) and
  `MONGO_SEED_DOCS` (default 5000; applied by `make k3d-up`).

Without fzf or a terminal, 01 runs all scenarios and 02–04 run locally.

`make` uses Java 25: the `java` on your PATH if it is 25, otherwise the first SDKMAN
`~/.sdkman/candidates/java/25*` install.

It's one Gradle build. Versions live in `build.gradle` (plugins) and `gradle.properties` (Spring
Cloud). Plain Gradle works too, e.g. `./gradlew :03-vault-with-file-secrets-and-aot:bootJar`.

## Prerequisites

| For | Needs |
|---|---|
| Everything | Java 25 (on `PATH`, or installed with SDKMAN for `make`) |
| 01, local comparison | `vault` CLI (`brew install hashicorp/tap/vault`) |
| 01 scenario picker | `fzf` (`brew install fzf`); without it, `make 01` runs all scenarios |
| Local comparison | `toxiproxy`, `jq` (`brew install toxiproxy jq`) |
| k3d comparison (02–06) | Docker, `k3d`, `helm`, `kubectl`, `jq` |

## Startup timing lines

Apps 02–06 log two lines when they're ready (05/06 add a `MONGO_INIT` line, see
[05](05-mongo-baseline/README.md#what-each-mode-does-at-startup)). They come from `startup-timing`, which is
registered through `META-INF/spring.factories`, so the apps need no code for it:

```
STARTUP_TIMING app=startup-baseline aot=false jvm_init=248ms env_prepare=634ms vault=477ms spring_init=845ms runners=1ms total=1729ms
SPRING_INIT app=startup-baseline aot=false spring_init=845ms context_prepare=56ms refresh=757ms bean_definitions=333ms config_classes=293ms web_server=180ms bean_creation=244ms
```

`STARTUP_TIMING` covers the whole start:

| Field | Covers |
|---|---|
| `jvm_init` | JVM start → `SpringApplication` starting |
| `env_prepare` | Loading config, **including the whole Vault fetch** |
| `vault` | **Overall Vault time**: the part of `env_prepare` spent on the `vault://` import (setting up the Vault client, logging in, reading secrets). 0 when the app doesn't use Spring Cloud Vault |
| `spring_init` | **Spring initialization:** creating the context and beans, and starting the embedded web server |
| `runners` | `ApplicationRunner`s / `CommandLineRunner`s |
| `total` | JVM start → application ready |

`SPRING_INIT` breaks `spring_init` down. This is where Spring AOT makes its difference:

| Field | Covers | With AOT |
|---|---|---|
| `context_prepare` | Creating the context and registering its sources | A little slower: loads the generated initializer |
| `refresh` | `ApplicationContext.refresh()`, which is the next three rows | |
| `bean_definitions` | Bean factory post-processing: `@Configuration` parsing, component scanning, `@Conditional` evaluation, BeanPostProcessor registration | **Mostly gone**: bean definitions are generated at build time |
| `config_classes` | The `@Configuration` parsing and CGLIB enhancement within `bean_definitions` | **0** |
| `web_server` | Creating the embedded Tomcat and initializing the servlet context | Unchanged |
| `bean_creation` | The rest of refresh: instantiating singletons, starting lifecycle beans | Roughly unchanged |

How `vault` is measured: the library registers a config-data resolver and loader that run ahead of
Spring Cloud Vault's own. They pass every `vault://` location straight to Vault's resolver and loader,
and time them. Nothing changes about how Vault is called.

Vault time *outside* the JVM (a Vault Agent init container, or waiting for the agent sidecar) can't
show up here. The k3d comparison adds it to get each pod's `vault_total`.

How the breakdown is measured: Spring Framework and Boot record named steps during startup
(`spring.context.refresh`, `spring.context.beans.post-process`, `spring.context.config-classes.parse`,
`spring.boot.webserver.create`). The library installs a small `ApplicationStartup` that times only
those steps. If an app sets its own `ApplicationStartup`, the library leaves it alone and skips the
`SPRING_INIT` line.

Use `grep -E 'STARTUP_TIMING|SPRING_INIT'` on any app log, or
`kubectl logs deploy/<app> -c app | grep -E 'STARTUP_TIMING|SPRING_INIT'` in a cluster.
