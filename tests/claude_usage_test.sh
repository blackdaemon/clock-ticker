#!/bin/bash

set -o errexit -o nounset -o pipefail

readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

readonly RAM_DISK="$TEST_DIR"
readonly PYTHON=/bin/false
HOME="$TEST_DIR"

# shellcheck source=../modules/claude_usage.sh
source "$(dirname "${BASH_SOURCE[0]}")/../modules/claude_usage.sh"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# A missing cache renders nothing and is not an error.
status="$(claude_usage_status)" || fail 'Missing Claude cache was rejected.'
[[ -z "$status" ]] || fail "Missing Claude cache rendered: $status"

printf '5h\t31\t15m (03:39)\t7d\t89\t4d3h\t12.5\tfalse\n' >"$CLAUDE_USAGE_CACHE"
status="$(claude_usage_status)"
[[ "$status" == 'CL:'* && "$status" == *'5h 31% rst 15m (03:39)'* &&
   "$status" == *'7d 89% rst 4d3h'* && "$status" == *'·Cr:12.5' &&
   "$status" != *$'⌁'* ]] || fail "Valid Claude cache rendered incorrectly: $status"

printf '5h\t31\t15m\t7d\t89\t7d\tunlimited\tfalse\n' >"$CLAUDE_USAGE_CACHE"
status="$(claude_usage_status)"
[[ "$status" == *'·Cr:∞' ]] || fail "Unlimited balance missing from Claude status: $status"

printf '5h\t31\t15m\t7d\t89\t7d\tnone\ttrue\n' >"$CLAUDE_USAGE_CACHE"
status="$(claude_usage_status)"
[[ "$status" == *$'⌁ '* && "$status" != *'·Cr:'* ]] ||
  fail "Active Claude cache rendered incorrectly: $status"

printf '5h\t5\t15m\t7d\t20\t7d\tnone\tfalse\n' >"$CLAUDE_USAGE_CACHE"
status="$(claude_usage_status)"
[[ "$status" == *'#ff5f5f">5h 5%'* && "$status" == *'#ffd75f">7d 20%'* ]] ||
  fail "Claude thresholds rendered incorrectly: $status"

for malformed in \
  '5h\t31\t15m\t7d\t89\t7d\tbogus\tfalse\n' \
  '5h\t101\t15m\t7d\t89\t7d\tnone\tfalse\n' \
  '5h\t31\t15m\t7d\t89\t7d\tnone\tmaybe\n' \
  '5h\t31\t15m\t7d\t89\t7d\tnone\tfalse\textra\n' \
  'garbage\n'; do
  # shellcheck disable=SC2059
  printf "$malformed" >"$CLAUDE_USAGE_CACHE"
  if claude_usage_status >/dev/null; then
    fail "Malformed Claude cache was accepted: $malformed"
  fi
done

# A failed update keeps the previous cache and leaves no temporary files.
printf 'previous\n' >"$CLAUDE_USAGE_CACHE"
if update_claude_usage false 2>/dev/null; then
  fail 'Claude update with unusable Python succeeded.'
fi
[[ "$(<"$CLAUDE_USAGE_CACHE")" == previous ]] || fail 'Failed update replaced the cache.'
leftovers=("$CLAUDE_USAGE_CACHE".*)
[[ ! -e "${leftovers[0]}" ]] || fail 'Failed update left a temporary file.'

# A failing updater waits for the refresh interval before it runs again.
rm -f -- "$CLAUDE_USAGE_CACHE"
readonly ATTEMPTS="$TEST_DIR/attempts"
update_claude_usage() {
  printf 'x\n' >>"$ATTEMPTS"
  return 1
}
maybe_update_claude_usage
wait "$CLAUDE_USAGE_UPDATE_PID" || true
maybe_update_claude_usage
[[ -z "$CLAUDE_USAGE_UPDATE_PID" ]] || wait "$CLAUDE_USAGE_UPDATE_PID" || true
[[ "$(wc -l <"$ATTEMPTS")" -eq 1 ]] || fail 'Failed Claude update was retried immediately.'

# New session-log activity refreshes immediately and is flagged to the updater.
mkdir -p "$HOME/.claude/projects/project"
touch "$HOME/.claude/projects/project/session.jsonl"
maybe_update_claude_usage
[[ "$CLAUDE_WORK_IN_PROGRESS" == true ]] || fail 'Claude activity was not detected.'
wait "$CLAUDE_USAGE_UPDATE_PID" || true
[[ "$(wc -l <"$ATTEMPTS")" -eq 2 ]] || fail 'Claude activity did not trigger a refresh.'
