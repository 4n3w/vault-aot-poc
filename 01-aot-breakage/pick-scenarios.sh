#!/usr/bin/env bash
# Pick 01 scenarios with fzf; prints the chosen names, one per line.
#
#   pick-scenarios.sh            multi-select (TAB to toggle, ctrl-a for all)
#   pick-scenarios.sh --single   pick exactly one
#
# Without fzf or a terminal: multi-select prints every scenario, --single fails.
set -uo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"

source ./scenarios.sh

if [ "${1:-}" = --preview ]; then
  show_scenario "$2"
  exit 0
fi

SCENARIOS=("${ALL_SCENARIOS[@]}")
single=false; [ "${1:-}" = --single ] && single=true

if ! command -v fzf >/dev/null || ! [ -t 0 ]; then
  if $single; then
    echo "no fzf/terminal to pick with; pass SCENARIO=<name> (${SCENARIOS[*]})" >&2; exit 1
  fi
  printf '%s\n' "${SCENARIOS[@]}"; exit 0
fi

if $single; then
  opts=(--header "ENTER: pick one scenario   ESC: cancel")
else
  opts=(--multi --bind ctrl-a:select-all --header "TAB: select   ctrl-a: all   ENTER: run selected   ESC: cancel")
fi
for s in "${SCENARIOS[@]}"; do printf '%s\t%s\n' "$s" "$(scenario_summary "$s")"; done \
  | fzf "${opts[@]}" --delimiter '\t' --height 60% --reverse --prompt "01 scenario> " \
      --preview "'$SELF' --preview {1}" --preview-window down:12:wrap \
  | cut -f1 | grep . || { echo "no scenario selected" >&2; exit 1; }
