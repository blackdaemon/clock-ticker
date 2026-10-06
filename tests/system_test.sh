#!/bin/bash

set -o errexit -o nounset -o pipefail

readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

SYSTEM_PROC_ROOT="$TEST_DIR/proc"
readonly RAM_DISK="$TEST_DIR"
readonly FIXTURE_PID=855898
readonly MDATP_SCRIPT="/opt/microsoft/mdatp/conf/scripts/get_jar_data_list_v2.py"

mkdir -p "$SYSTEM_PROC_ROOT/$FIXTURE_PID"

# Regression fixture captured from a hot Mdatp worker on 2026-09-14. The live
# process had PPID 1 and cgroup '/', so neither ancestry nor systemd ownership
# identified it. Only the invocation fields needed for identity are retained;
# the remaining arguments are deliberately represented by one harmless option.
printf '%s\0' \
  /bin/python3 \
  "$MDATP_SCRIPT" \
  --ScriptName \
  get_jar_data_list_v2.py >"$SYSTEM_PROC_ROOT/$FIXTURE_PID/cmdline"
printf '0::/\n' >"$SYSTEM_PROC_ROOT/$FIXTURE_PID/cgroup"

# shellcheck source=../modules/system.sh
source "$(dirname "${BASH_SOURCE[0]}")/../modules/system.sh"

rpm() {
  [[ "$*" == *"$MDATP_SCRIPT"* ]] || return 1
  printf 'mdatp\n'
}

ps() {
  printf '99.4 %d python3\n' "$FIXTURE_PID"
}

workload="$(python_workload_label "$FIXTURE_PID")"
[[ "$workload" == "mdatp/get_jar_data_list_v2" ]] || {
  printf 'Unexpected Mdatp workload label: %s\n' "$workload" >&2
  exit 1
}

top_process="$(top_cpu_process)"
[[ "$top_process" == "top:mdatp/get_jar_data_list_v2 99.4%" ]] || {
  printf 'Unexpected Mdatp top-CPU label: %s\n' "$top_process" >&2
  exit 1
}
