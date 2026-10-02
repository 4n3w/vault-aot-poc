# Run the examples:  make  (or make help) lists the targets.
# Works with the GNU Make 3.81 that ships with macOS.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Every recipe needs Java 25. Keep the java on PATH if it already is 25; otherwise use the first
# SDKMAN 25.x install found, so there's no need to `sdk use` first.
JAVA_SPEC := $(shell java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.specification.version/ {print $$2}')
SDKMAN_JDK25 := $(firstword $(wildcard $(HOME)/.sdkman/candidates/java/25*))
ifneq ($(JAVA_SPEC),25)
ifneq ($(SDKMAN_JDK25),)
export JAVA_HOME := $(SDKMAN_JDK25)
export PATH := $(SDKMAN_JDK25)/bin:$(PATH)
endif
endif

# Knobs, passed through to the scripts.
RUNS ?= 5
VAULT_LATENCY_MS ?= 25
AOT ?= both
WHERE ?=
export RUNS VAULT_LATENCY_MS AOT WHERE
SCENARIOS ?=
SCENARIO ?=
DEAD_VAULT := http://127.0.0.1:1

.PHONY: help build clean prereqs 01 01-jar 02 03 04 compare k3d-up k3d-down

##@ General
help: ## List targets and knobs
	@awk 'BEGIN {FS = ":.*## "} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} /^[0-9a-zA-Z_-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Knobs: 01:    SCENARIOS=\"naive runtime-import ...\"|all  SCENARIO=<one>   (no value = pick with fzf)"
	@echo "       02-04: WHERE=local|k3d (no value = pick with fzf)  RUNS=$(RUNS)  VAULT_LATENCY_MS=$(VAULT_LATENCY_MS)  AOT=$(AOT) (off|on|both)"

build: ## Build every project (processAot runs with Vault unreachable)
	VAULT_ADDR=$(DEAD_VAULT) VAULT_TOKEN= ./gradlew build

clean: ## Remove build output, logs and generated files
	./gradlew clean
	rm -rf startup-comparison/build

prereqs: ## Show which tools are installed, and what needs them
	@check() { if command -v $$1 >/dev/null; then s=ok; else s=MISSING; fi; printf '  %-8s %-17s %s\n' $$s $$1 "$$2"; }; \
	check java "everything - Java 25 (found: $$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.specification.version/ {print $$2}'))"; \
	check vault "01, 02-04 local (brew install hashicorp/tap/vault)"; \
	check fzf "01 scenario picker (brew install fzf)"; \
	check toxiproxy-server "02-04 local (brew install toxiproxy)"; \
	check jq "02-04 local and k3d (brew install jq)"; \
	check docker "k3d"; check k3d "k3d"; check helm "k3d"; check kubectl "k3d"

##@ 01 - Vault under Spring AOT
01: ## Pick scenarios (fzf), build them with Vault unreachable, run the jars against Vault
	@scenarios="$(SCENARIOS)"; \
	if [ -z "$$scenarios" ]; then scenarios="$$(01-aot-breakage/pick-scenarios.sh)" || exit 1; fi; \
	SCENARIOS="$$(echo $$scenarios)" 01-aot-breakage/run.sh

01-jar: ## Pick one scenario (fzf) and only build it: processAot + bootJar, Vault unreachable
	@scenario="$(SCENARIO)"; \
	if [ -z "$$scenario" ]; then scenario="$$(01-aot-breakage/pick-scenarios.sh --single)" || exit 1; fi; \
	log=01-aot-breakage/build/poc-logs/jar-$$scenario.log; jar=01-aot-breakage/build/libs/vault-aot-poc-0.0.1-$$scenario.jar; \
	mkdir -p $$(dirname $$log); \
	01-aot-breakage/scenarios.sh show $$scenario; \
	echo "  building with:    VAULT_ADDR=$(DEAD_VAULT) (unreachable, like CI)"; \
	if VAULT_ADDR=$(DEAD_VAULT) VAULT_TOKEN= ./gradlew :01-aot-breakage:bootJar -Paot=$$scenario >$$log 2>&1; then \
	  echo "  result:           BUILD OK - $$jar"; \
	  echo "                    $$(unzip -l $$jar | grep -c '__BeanDefinitions.class') AOT-generated bean definition classes; run with: java -Dspring.aot.enabled=true -jar $$jar"; \
	else \
	  echo "  result:           BUILD FAILED ($$(grep -hoE "Connection refused|Config data location '[^']*' does not exist" $$log | head -1)) - full log: $$log"; exit 1; \
	fi

##@ 02-04 - Startup with Vault (pick local or k3d with fzf, or WHERE=local|k3d)
02: ## 02 baseline: Spring Cloud Vault -> Vault, AOT off and on
	startup-comparison/start.sh 02

03: ## 03 file secrets: secrets rendered to files, AOT off and on
	startup-comparison/start.sh 03

04: ## 04 Vault Agent: Spring Cloud Vault -> agent sidecar -> Vault, AOT off and on
	startup-comparison/start.sh 04

compare: ## 02, 03 and 04 side by side
	startup-comparison/start.sh all

##@ k3d cluster (02-04 create it on first use; these are for managing it)
k3d-up: ## Create cluster vault-startup, or rebuild images + redeploy the apps after code changes
	startup-comparison/k3d.sh up

k3d-down: ## Delete the k3d cluster
	startup-comparison/k3d.sh down
