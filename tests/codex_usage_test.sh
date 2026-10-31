#!/bin/bash

set -o errexit -o nounset -o pipefail

readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

readonly RAM_DISK="$TEST_DIR"
readonly PYTHON=/bin/false

# shellcheck source=../modules/codex_usage.sh
source "$(dirname "${BASH_SOURCE[0]}")/../modules/codex_usage.sh"

printf '5h\t31\t15m\t7d\t89\t7d\t2489.1\tfalse\n' >"$CODEX_USAGE_CACHE"
status="$(codex_usage_status)"
[[ "$status" == *'·Cr:2489.1' ]] || {
  printf 'Credit balance missing from Codex status: %s\n' "$status" >&2
  exit 1
}

printf '5h\t31\t15m\t7d\t89\t7d\tunlimited\tfalse\n' \
  >"$CODEX_USAGE_CACHE"
status="$(codex_usage_status)"
[[ "$status" == *'·Cr:∞' ]] || {
  printf 'Unlimited balance missing from Codex status: %s\n' "$status" >&2
  exit 1
}

# The pre-credit cache format remains readable during a rolling restart.
printf '5h\t31\t15m\t7d\t89\t7d\ttrue\n' >"$CODEX_USAGE_CACHE"
status="$(codex_usage_status)"
[[ "$status" == *'⌁ '* && "$status" != *'·Cr:'* ]] || {
  printf 'Legacy Codex cache rendered incorrectly: %s\n' "$status" >&2
  exit 1
}

printf '5h\t31\t15m\t7d\t89\t7d\tbogus\tfalse\n' >"$CODEX_USAGE_CACHE"
if codex_usage_status >/dev/null; then
  printf 'Malformed credit balance was accepted.\n' >&2
  exit 1
fi

# The Free plan has a single usage window.
printf '30d\t80\t29d23h\tnone\tnone\tnone\tnone\tfalse\n' \
  >"$CODEX_USAGE_CACHE"
status="$(codex_usage_status)"
[[ "$status" == *'30d 80% rst 29d23h</span>' ]] || {
  printf 'Single Codex window rendered incorrectly: %s\n' "$status" >&2
  exit 1
}

printf '30d\t80\t29d23h\tnone\tnone\tnone\t12.5\ttrue\n' \
  >"$CODEX_USAGE_CACHE"
status="$(codex_usage_status)"
[[ "$status" == *'⌁ '*'30d 80% rst 29d23h</span>·Cr:12.5' ]] || {
  printf 'Single Codex window with credits rendered incorrectly: %s\n' \
    "$status" >&2
  exit 1
}

printf '30d\t80\t29d23h\tnone\t89\t7d\tnone\tfalse\n' >"$CODEX_USAGE_CACHE"
if codex_usage_status >/dev/null; then
  printf 'Partially absent Codex window was accepted.\n' >&2
  exit 1
fi

printf 'none\tnone\tnone\tnone\tnone\tnone\tnone\tfalse\n' \
  >"$CODEX_USAGE_CACHE"
if codex_usage_status >/dev/null; then
  printf 'Codex cache without usage windows was accepted.\n' >&2
  exit 1
fi

rm -f -- "$CODEX_USAGE_CACHE"
status="$(codex_usage_status)"
[[ -z "$status" ]] || {
  printf 'Missing Codex cache rendered output: %s\n' "$status" >&2
  exit 1
}
