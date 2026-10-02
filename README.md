# Vault under Spring AOT — PoC

Checks how `spring.config.import=vault://` (Spring Cloud Vault) behaves with Spring Boot AOT
(`processAot` + `java -Dspring.aot.enabled=true`) on a plain JVM, and which fixes actually work.

Stack: Spring Boot 3.5.16, Spring Cloud 2025.0.3 (Spring Cloud Vault 4.3.x), Java 17, Gradle 8.13,
Vault 1.21 dev server.

## Run it

```sh
./run-poc.sh          # needs: java 17, gradle (or ./gradlew), vault CLI on PATH
```

The script starts a Vault dev server (or reuses one on `127.0.0.1:8200`) and seeds
`secret/vault-aot-poc` with `db.password` and `feature.audit.enabled=true`. It then builds every
scenario with **Vault unreachable** (like a CI runner) and runs the jars that built against the
live Vault. Logs go to `build/poc-logs/`.

Build a single scenario with `gradle bootJar -Paot=<scenario>`. Each scenario adds
`src/scenarios/<scenario>/` to the classpath and can pass args to `processAot` (see `build.gradle`).

| Scenario | Packaged config | `processAot` args |
|---|---|---|
| `naive` | `spring.config.import: vault://` | — |
| `blank-import` | `spring.config.import: vault://` | `--spring.config.import=` (the commonly suggested fix) |
| `optional-disabled` | `spring.config.import: optional:vault://` | `--spring.cloud.vault.enabled=false` |
| `runtime-import` | **no import** (supplied at runtime) | — |
| `runtime-import-flags` | **no import** | `--feature.audit.enabled=true` |

## Results

Build with Vault unreachable (`fail-fast: true`):

```
naive                  BUILD FAILED  (Connection refused)
blank-import           BUILD FAILED  (Connection refused)
optional-disabled      BUILD OK
runtime-import         BUILD OK
runtime-import-flags   BUILD OK
```

Run with Vault live:

| Run | AOT | `db.password` | `AuditService` bean | `VaultProperties` bean |
|---|---|---|---|---|
| `optional-disabled` | yes | loaded | **0** | **0** |
| `runtime-import` + `SPRING_CONFIG_IMPORT=vault://` | yes | loaded | **0** | 1 |
| `runtime-import`, import not supplied | yes | **not loaded (silent)** | 0 | 1 |
| `runtime-import` + import, no AOT (baseline) | no | loaded | 1 | 1 |
| `runtime-import-flags` + import | yes | loaded | 1 | 1 |
| `runtime-import` + import, Vault down | yes | startup fails (fail-fast) | — | — |

## Findings

1. **`processAot` does contact Vault.** AOT boots the app far enough to load config data, so the
   `vault://` import runs at build time.
   - With `fail-fast: true` the build fails when Vault is unreachable.
   - With the default `fail-fast: false` the build **succeeds** and only logs a `WARN`. That's
     arguably worse: whether the build could reach Vault decides which beans the AOT output keeps
     (see finding 4).

2. **`--spring.config.import=` on `processAot` does NOT work** when the import is declared in
   `application.yml`. Spring Boot reads each config file's `spring.config.import` from that file
   only, so a blank import on the command line doesn't cancel it. (It only helps if the import was
   itself passed on the command line or through an env var.)

3. **Two approaches work at build time:**
   - **Runtime-only import (recommended).** Leave `spring.config.import` out of the packaged
     config. Supply it at deploy time with `SPRING_CONFIG_IMPORT=vault://` or
     `-Dspring.config.import=vault://`. Vault auto-configuration stays enabled during AOT, so its
     beans (`VaultProperties` etc.) are kept. Nothing changes in the build. See
     [How the runtime-only import works](#how-the-runtime-only-import-works).
   - **`optional:vault://` + `--spring.cloud.vault.enabled=false` on `processAot`.** The build
     works, and secrets still load at runtime because config-data loading isn't frozen by AOT. But
     AOT **removes `VaultAutoConfiguration` and the `VaultProperties` bean** for good. Any code that
     injects `VaultProperties` or relies on that auto-config will break under AOT. Using
     `enabled=false` without `optional:` fails the build with
     `Config data location 'vault://' does not exist`.

4. **The real "frozen state" risk is `@Conditional` decisions, not secret values.** Secret
   *values* are resolved at runtime in every working scenario. But `@ConditionalOnProperty`,
   `@Profile`, etc. are evaluated **once, at build time**. `feature.audit.enabled=true` lives in
   Vault, so with AOT the `AuditService` bean is missing even though the property reads `true` at
   runtime. Without AOT the bean exists.
   Fix: don't let Vault values decide which beans exist. Pass any bean-shaping flags/profiles to
   `processAot` explicitly (`runtime-import-flags`), the same way `GUIDE.md` handles
   `--spring.profiles.active`.

5. **A forgotten runtime import fails silently** if the code has defaults (`${db.password:...}`).
   Avoid defaults for secrets, so startup fails if the deployment forgets `SPRING_CONFIG_IMPORT`.

## How the runtime-only import works

### AOT freezes beans, not configuration

Spring Boot startup has two phases, and AOT only changes the second one:

| Phase | What happens | With AOT (`-Dspring.aot.enabled=true`) |
|---|---|---|
| 1. Prepare the environment | Reads `application.yml`, environment variables and `-D` properties, and processes `spring.config.import`. The Vault fetch happens here. | **Still runs at runtime**, unchanged |
| 2. Refresh the context | Scans for beans, evaluates `@Conditional`/`@Profile`, registers bean definitions | **Replaced** by code generated at build time |

Vault config loading happens in phase 1, so AOT never freezes it. The secret is fetched each time
the app starts, whether it was built with AOT or not. That's why `db.password` loaded in every
scenario that built. AOT only fixes phase 2, which decides which beans exist.

### At build time (`processAot`)

With no import in `application.yml`:

- Phase 1 runs, but nothing asks for `vault://`, so **no network call is made**. It builds even
  with Vault unreachable.
- Phase 2 runs, and Spring Cloud Vault is on the classpath with `spring.cloud.vault.enabled` at its
  default of `true`. Vault's auto-configuration passes its conditions, so AOT **keeps** those beans
  (`VaultProperties` and the rest of `VaultAutoConfiguration`).
- AOT only *registers* bean definitions; it doesn't create the beans. So no token or connection is
  needed to keep them.

The generated jars confirm this. The `runtime-import` jar contains
`VaultAutoConfiguration__BeanDefinitions` and `VaultProperties__BeanDefinitions`. The
`optional-disabled` jar has neither, because Vault was turned off during AOT. To check:

```sh
unzip -l build/libs/vault-aot-poc-0.0.1-<scenario>.jar | grep -i 'vault.*__BeanDefinitions'
```

### At runtime

```sh
SPRING_CONFIG_IMPORT=vault:// java -Dspring.aot.enabled=true -jar app.jar
```

- Spring treats the `SPRING_CONFIG_IMPORT` environment variable the same as
  `spring.config.import`. Environment variables, `-D` properties and command-line args are checked
  for imports just like `application.yml`.
- Spring Cloud Vault's loader reads the `spring.cloud.vault.*` client settings from the packaged
  `application.yml` (uri, auth, kv path). It fetches `secret/vault-aot-poc` and adds those values as
  a property source.
- The pre-built context then starts and gets its values from that environment.

PoC output for that run:

```
AOT mode active        : true
db.password (Vault)    : s3cr3t-from-vault
VaultTemplate beans    : 1
VaultProperties beans  : 1
```

### Why this works and the `--spring.config.import=` fix doesn't

They look similar, but they're opposites:

- **Pasted fix:** the import stays in `application.yml`, and a blank `--spring.config.import=` is
  passed during the build. A config file's import is read from that file only, so the blank value
  can't override it.
- **This approach:** the import exists only in the runtime environment. During the build there is
  nothing to override because no import was ever declared.

### In practice

- **Packaged `application.yml`:** keep only the Vault client settings (`uri`, `authentication`,
  `kv.*`, `fail-fast: true`). They aren't secret and are safe to build in.
- **Deployment:** set `SPRING_CONFIG_IMPORT=vault://` wherever runtime environment variables are
  defined. With the `hcvault-ecs` profile, that's probably the ECS task definition.
- **Local dev:** export the same variable, or add it to your IDE run configuration.

### Caveats

- **A forgotten import fails silently** if code has defaults like `${db.password:...}`. The PoC
  showed `<NOT LOADED>` with no error. Don't give secrets defaults, so startup fails instead.
- **Vault outages:** with `fail-fast: true`, the app won't start if Vault is down (the last PoC
  run). That's normally what you want.
- **Bean-deciding properties still can't come from Vault.** This approach only solves secret
  loading. A Vault value that decides whether a bean exists is still decided at build time
  (finding 4), so pass those flags or profiles to `processAot` explicitly.
- **Don't move the import into a profile-specific file** that is also passed to `processAot`. See
  [Watch out with profiles](#watch-out-with-profiles).

## Watch out with profiles

If the import lives in a profile-specific file (e.g. `application-hcvault.yml`) **and** that
profile is passed to `processAot` (as `GUIDE.md` recommends for bean coverage), the build connects
to Vault again (this follows from finding 1; I did not test it separately). Either keep the import
out of packaged config (runtime-only import above), or make it `optional:` and pass
`--spring.cloud.vault.enabled=false` alongside the profiles, knowing the bean trade-off in
finding 3.

## Recommended setup

```yaml
# application.yml (packaged) — client settings only, no import
spring:
  cloud:
    vault:
      uri: ${VAULT_ADDR}
      fail-fast: true
      authentication: TOKEN   # or KUBERNETES / AWS_IAM / APPROLE …
      kv: { enabled: true, backend: secret, default-context: my-app }
```

```groovy
tasks.named('processAot') {
    // profiles/flags that decide which beans exist — never sourced from Vault
    args('--spring.profiles.active=dev,hcvault,hcvault-ecs,ecs')
}
```

```sh
SPRING_CONFIG_IMPORT=vault:// java -Dspring.aot.enabled=true -jar app.jar
```

Not covered: GraalVM native image (not installed here). The config-data behavior should be the
same, but native builds also need reachability hints for whatever auth method you use.
