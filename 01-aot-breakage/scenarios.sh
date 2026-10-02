#!/usr/bin/env bash
# What each 01 scenario is, in one place. Sourced by run.sh and pick-scenarios.sh; run it directly
# to print one scenario's configuration:  ./scenarios.sh show <scenario>
# Paths are relative to 01-aot-breakage/. processAot args mirror aotArgs in build.gradle.

ALL_SCENARIOS=(naive blank-import optional-disabled runtime-import runtime-import-flags)

scenario_summary() { # name -> what it tests, in one line
  case $1 in
    naive)                echo "packaged vault:// import -> processAot calls Vault; build FAILS without Vault" ;;
    blank-import)         echo "packaged vault:// + processAot --spring.config.import= (the usual 'fix') -> still FAILS" ;;
    optional-disabled)    echo "packaged optional:vault:// + processAot --spring.cloud.vault.enabled=false -> builds, Vault beans dropped" ;;
    runtime-import)       echo "no packaged import; SPRING_CONFIG_IMPORT=vault:// at runtime -> builds, Vault beans kept" ;;
    runtime-import-flags) echo "runtime-import + processAot --feature.audit.enabled=true -> bean-shaping flag set at build time" ;;
  esac
}

scenario_aot_args() { # name -> processAot args
  case $1 in
    blank-import)         echo "--spring.config.import=" ;;
    optional-disabled)    echo "--spring.cloud.vault.enabled=false" ;;
    runtime-import-flags) echo "--feature.audit.enabled=true" ;;
    *)                    echo "(none)" ;;
  esac
}

scenario_config() { # name -> the config file the scenario adds to the jar (runtime-import-flags reuses runtime-import's)
  echo "src/scenarios/${1%-flags}/config/application.yml"
}

# Print a YAML file without its comment lines, indented by $2 spaces.
print_yaml() {
  local pad; pad=$(printf '%*s' "$2" '')
  grep -vE '^\s*#' "$1" | sed "s/^/$pad/"
}

# Print the base config every scenario's jar contains.
show_base_config() {
  echo "Base config in every jar (src/main/resources/application.yml):"
  print_yaml src/main/resources/application.yml 4
}

# Print one scenario's configuration block.
show_scenario() {
  local name=$1 config
  config=$(scenario_config "$name")
  echo "$name: $(scenario_summary "$name")"
  echo "  build:            ../gradlew :01-aot-breakage:bootJar -Paot=$name"
  if [ -f "$config" ]; then
    echo "  adds config:      $config"
    print_yaml "$config" 20
  else
    echo "  adds config:      (nothing - no spring.config.import in the jar; it's supplied at runtime)"
  fi
  echo "  processAot args:  $(scenario_aot_args "$name")"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cd "$(dirname "$0")"
  case "${1:-}" in
    show) [ -n "${2:-}" ] && show_scenario "$2" || { echo "usage: $0 show <${ALL_SCENARIOS[*]}>" >&2; exit 2; } ;;
    base) show_base_config ;;
    *) echo "usage: $0 show <scenario> | base" >&2; exit 2 ;;
  esac
fi
