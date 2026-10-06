#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:

# Constants
readonly CODEX_USAGE_CACHE="$RAM_DISK/.codex_usage.txt"
readonly CODEX_ACTIVE_INTERVAL=30
readonly CODEX_IDLE_INTERVAL=600
readonly CODEX_ACTIVITY_AGE=60

# Globals
WORK_IN_PROGRESS=false
CODEX_USAGE_UPDATE_PID=""


# Refresh the usage cache when its activity-dependent interval has elapsed.
#
# Recent Codex session-log activity selects the shorter refresh interval. A
# change in activity state also triggers an immediate refresh so the status
# icon stays current.
#
# Arguments: none.
# Reaps a completed updater before checking whether another refresh is due.
# Only one updater may run at a time.
#
# Output: none, except diagnostics inherited from a background
# update_codex_usage process.
# Side effects: updates WORK_IN_PROGRESS and CODEX_USAGE_UPDATE_PID, and may
# start a background process that replaces CODEX_USAGE_CACHE.
# Returns: zero.
maybe_update_codex_usage() {
  local now cache_mtime age interval work_in_progress
  work_in_progress=false
  now=$(date +%s)

  # If PID already exists for running update...
  if [[ -n "$CODEX_USAGE_UPDATE_PID" ]]; then
    # ...check if its process is still alive...
    if kill -0 "$CODEX_USAGE_UPDATE_PID" 2>/dev/null; then
      # ...and exit if it is.
      return 0
    fi
    # Reap the completed updater process otherwise.
    wait "$CODEX_USAGE_UPDATE_PID" 2>/dev/null || true
    CODEX_USAGE_UPDATE_PID=""
  fi

  # Is any current Codex logs WAL younger than CODEX_ACTIVITY_AGE?
  if fd -d 4 -t f '^rollout-.*\.jsonl$' "$HOME/.codex/sessions" \
      --changed-within "${CODEX_ACTIVITY_AGE}s" \
      --max-results 1 | grep -q .; then
    interval=$CODEX_ACTIVE_INTERVAL
    work_in_progress=true
  else
    interval=$CODEX_IDLE_INTERVAL
  fi

  if [[ -r "$CODEX_USAGE_CACHE" ]]; then
    cache_mtime=$(stat -c %Y "$CODEX_USAGE_CACHE") || cache_mtime=0
  else
    cache_mtime=0
  fi

  age=$((now - cache_mtime))

  ((age >= interval)) ||
    [[ "$work_in_progress" != "$WORK_IN_PROGRESS" ]] ||
    return 0
  WORK_IN_PROGRESS=$work_in_progress

  # Run the updater in background and remember its PID
  update_codex_usage "$work_in_progress" &
  CODEX_USAGE_UPDATE_PID=$!
}


# Generate and atomically replace the Codex usage cache.
#
# Arguments:
#   $1 - Optional work-in-progress flag written to the cache; defaults to
#        "false".
# Output: none. Diagnostics are written to standard error.
# Side effects: runs codex_usage.py, creates a temporary file beside the cache,
# and replaces CODEX_USAGE_CACHE on success.
# Returns: zero after replacing the cache; nonzero when path resolution, cache
# setup, Python execution, or publication fails.
update_codex_usage() {
  local script_path script_dir temporary work_in_progress

  work_in_progress="${1:-false}"

  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")" || return 1
  script_dir="$(dirname -- "$script_path")" || return 1

  if [[ -z "${RAM_DISK:-}" || ! -d "$RAM_DISK" || ! -w "$RAM_DISK" ]]; then
    printf 'RAM disk is not a writable directory: %s\n' \
      "${RAM_DISK:-<unset>}" >&2
    return 1
  fi

  temporary="$(mktemp "${CODEX_USAGE_CACHE}.XXXXXX")" || return 1

  if [[ ! -x "$PYTHON" ]]; then
    printf 'Virtual environment Python is not executable: %s\n' "$PYTHON" >&2
    rm -f -- "$temporary"
    return 1
  fi

  if ! "$PYTHON" "$script_dir/codex_usage.py" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi

  printf '\t%s\n' "$work_in_progress" >> $temporary

  mv -f -- "$temporary" "$CODEX_USAGE_CACHE" || {
    rm -f -- "$temporary"
    return 1
  }
}


# Stop and reap the background Codex usage updater, if one is running.
#
# Arguments: none.
# Output: none.
# Side effects: sends SIGTERM to CODEX_USAGE_UPDATE_PID, waits for it, and
# clears the stored PID. Intended for the ticker process's EXIT trap.
# Returns: zero, including when no updater exists.
stop_codex_usage_update() {
  [[ -n "$CODEX_USAGE_UPDATE_PID" ]] || return 0
  kill "$CODEX_USAGE_UPDATE_PID" 2>/dev/null || true
  wait "$CODEX_USAGE_UPDATE_PID" 2>/dev/null || true
  CODEX_USAGE_UPDATE_PID=""
}


# Render the cached Codex usage as trusted Pango markup.
#
# Remaining percentages at or below 25 and 10 use warning and critical colors,
# respectively. A work-in-progress cache flag adds the activity icon. A
# purchased-credit balance, when present, is appended after both usage windows.
#
# Arguments: none.
# Output: one status fragment on standard output, or nothing when the cache is
# absent.
# Returns: zero for a missing or valid cache; nonzero when the cache cannot be
# read completely or contains malformed fields.
codex_usage_status() {
  local short_window short_remaining short_reset
  local long_window long_remaining long_reset credits extra
  local wip_color="#ffd75f" short_color="#7fc97f" long_color="#7fc97f"
  local work_in_progress work_in_progress_icon

  work_in_progress_icon=""

  [[ -r "$CODEX_USAGE_CACHE" ]] || return 0
  IFS=$'\t' read -r short_window short_remaining short_reset \
    long_window long_remaining long_reset credits work_in_progress extra \
    <"$CODEX_USAGE_CACHE" || return 1

  # Accept the previous cache format until the background updater replaces it.
  if [[ "$credits" == true || "$credits" == false ]]; then
    [[ -z "$work_in_progress" ]] || return 1
    work_in_progress="$credits"
    credits=none
  fi

  [[ -z "$extra" ]] || return 1
  [[ "$short_window" =~ ^[0-9]+[mhd]$ ]] || return 1
  [[ "$long_window" =~ ^[0-9]+[mhd]$ ]] || return 1
  [[ "$short_remaining" =~ ^[0-9]+$ ]] || return 1
  [[ "$long_remaining" =~ ^[0-9]+$ ]] || return 1
  ((short_remaining <= 100 && long_remaining <= 100)) || return 1
  [[ -n "$short_reset" && -n "$long_reset" ]] || return 1
  [[ "$credits" == none || "$credits" == unlimited ||
     "$credits" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || return 1

  if ((short_remaining <= 10)); then
    short_color="#ff5f5f"
  elif ((short_remaining <= 25)); then
    short_color="#ffd75f"
  fi

  if ((long_remaining <= 10)); then
    long_color="#ff5f5f"
  elif ((long_remaining <= 25)); then
    long_color="#ffd75f"
  fi

  if [ "$work_in_progress" == "true" ]; then
    work_in_progress_icon=""$'\u2301'" "
  fi

  printf 'CX:<span foreground="%s">%s</span><span foreground="%s">%s %d%% rst %s</span>·<span foreground="%s">%s %d%% rst %s</span>' \
    "$wip_color" "$work_in_progress_icon" \
    "$short_color" "$short_window" "$short_remaining" "$short_reset" \
    "$long_color" "$long_window" "$long_remaining" "$long_reset"

  case "$credits" in
    unlimited)
      printf '·Cr:∞'
      ;;
    none)
      ;;
    *)
      printf '·Cr:%s' "$credits"
      ;;
  esac
}
