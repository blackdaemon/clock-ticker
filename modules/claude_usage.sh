#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:

# Constants
readonly CLAUDE_USAGE_CACHE="$RAM_DISK/.claude_usage.txt"
readonly CLAUDE_ACTIVE_INTERVAL=30
readonly CLAUDE_IDLE_INTERVAL=600
readonly CLAUDE_ACTIVITY_AGE=60

# Globals
CLAUDE_WORK_IN_PROGRESS=false
CLAUDE_USAGE_UPDATE_PID=""
CLAUDE_USAGE_LAST_ATTEMPT=0


# Refresh the usage cache when its activity-dependent interval has elapsed.
#
# Recent Claude session-log activity selects the shorter refresh interval. A
# change in activity state also triggers an immediate refresh so the status
# icon stays current. The interval also applies after a failed refresh, so an
# unavailable usage endpoint is not queried again every few seconds.
#
# Arguments: none.
# Reaps a completed updater before checking whether another refresh is due.
# Only one updater may run at a time.
#
# Output: none, except diagnostics inherited from a background
# update_claude_usage process.
# Side effects: updates CLAUDE_WORK_IN_PROGRESS, CLAUDE_USAGE_UPDATE_PID and
# CLAUDE_USAGE_LAST_ATTEMPT, and may start a background process that replaces
# CLAUDE_USAGE_CACHE.
# Returns: zero.
maybe_update_claude_usage() {
  local now cache_mtime age interval work_in_progress
  work_in_progress=false
  now=$(date +%s)

  # If PID already exists for running update...
  if [[ -n "$CLAUDE_USAGE_UPDATE_PID" ]]; then
    # ...check if its process is still alive...
    if kill -0 "$CLAUDE_USAGE_UPDATE_PID" 2>/dev/null; then
      # ...and exit if it is.
      return 0
    fi
    # Reap the completed updater process otherwise.
    wait "$CLAUDE_USAGE_UPDATE_PID" 2>/dev/null || true
    CLAUDE_USAGE_UPDATE_PID=""
  fi

  # Is any current Claude session log younger than CLAUDE_ACTIVITY_AGE?
  if [[ -n "$(fd -d 4 -t f '\.jsonl$' "$HOME/.claude/projects" \
      --changed-within "${CLAUDE_ACTIVITY_AGE}s" \
      --max-results 1 2>/dev/null)" ]]; then
    interval=$CLAUDE_ACTIVE_INTERVAL
    work_in_progress=true
  else
    interval=$CLAUDE_IDLE_INTERVAL
  fi

  if [[ -r "$CLAUDE_USAGE_CACHE" ]]; then
    cache_mtime=$(stat -c %Y "$CLAUDE_USAGE_CACHE") || cache_mtime=0
  else
    cache_mtime=0
  fi

  if ((CLAUDE_USAGE_LAST_ATTEMPT > cache_mtime)); then
    age=$((now - CLAUDE_USAGE_LAST_ATTEMPT))
  else
    age=$((now - cache_mtime))
  fi

  ((age >= interval)) ||
    [[ "$work_in_progress" != "$CLAUDE_WORK_IN_PROGRESS" ]] ||
    return 0
  CLAUDE_WORK_IN_PROGRESS=$work_in_progress
  CLAUDE_USAGE_LAST_ATTEMPT=$now

  # Run the updater in background and remember its PID
  update_claude_usage "$work_in_progress" &
  CLAUDE_USAGE_UPDATE_PID=$!
}


# Generate and atomically replace the Claude usage cache.
#
# Arguments:
#   $1 - Optional work-in-progress flag written to the cache; defaults to
#        "false".
# Output: none. Diagnostics are written to standard error.
# Side effects: runs claude_usage.py, creates a temporary file beside the cache,
# and replaces CLAUDE_USAGE_CACHE on success.
# Returns: zero after replacing the cache; nonzero when path resolution, cache
# setup, Python execution, or publication fails.
update_claude_usage() {
  local script_path script_dir temporary work_in_progress

  work_in_progress="${1:-false}"

  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")" || return 1
  script_dir="$(dirname -- "$script_path")" || return 1

  if [[ -z "${RAM_DISK:-}" || ! -d "$RAM_DISK" || ! -w "$RAM_DISK" ]]; then
    printf 'RAM disk is not a writable directory: %s\n' \
      "${RAM_DISK:-<unset>}" >&2
    return 1
  fi

  temporary="$(mktemp "${CLAUDE_USAGE_CACHE}.XXXXXX")" || return 1

  if [[ ! -x "$PYTHON" ]]; then
    printf 'Virtual environment Python is not executable: %s\n' "$PYTHON" >&2
    rm -f -- "$temporary"
    return 1
  fi

  if ! "$PYTHON" "$script_dir/claude_usage.py" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi

  printf '\t%s\n' "$work_in_progress" >>"$temporary"

  mv -f -- "$temporary" "$CLAUDE_USAGE_CACHE" || {
    rm -f -- "$temporary"
    return 1
  }
}


# Stop and reap the background Claude usage updater, if one is running.
#
# Arguments: none.
# Output: none.
# Side effects: sends SIGTERM to CLAUDE_USAGE_UPDATE_PID, waits for it, and
# clears the stored PID. Intended for the ticker process's EXIT trap.
# Returns: zero, including when no updater exists.
stop_claude_usage_update() {
  [[ -n "$CLAUDE_USAGE_UPDATE_PID" ]] || return 0
  kill "$CLAUDE_USAGE_UPDATE_PID" 2>/dev/null || true
  wait "$CLAUDE_USAGE_UPDATE_PID" 2>/dev/null || true
  CLAUDE_USAGE_UPDATE_PID=""
}


# Render the cached Claude usage as trusted Pango markup.
#
# Remaining percentages at or below 25 and 10 use warning and critical colors,
# respectively. A work-in-progress cache flag adds the activity icon. The
# remaining usage-credit allowance, when present, is appended after both usage
# windows.
#
# Arguments: none.
# Output: one status fragment on standard output, or nothing when the cache is
# absent.
# Returns: zero for a missing or valid cache; nonzero when the cache cannot be
# read completely or contains malformed fields.
claude_usage_status() {
  local short_window short_remaining short_reset
  local long_window long_remaining long_reset credits extra
  local wip_color="#ffd75f" short_color="#7fc97f" long_color="#7fc97f"
  local work_in_progress work_in_progress_icon

  work_in_progress_icon=""

  [[ -r "$CLAUDE_USAGE_CACHE" ]] || return 0
  IFS=$'\t' read -r short_window short_remaining short_reset \
    long_window long_remaining long_reset credits work_in_progress extra \
    <"$CLAUDE_USAGE_CACHE" || return 1

  [[ -z "$extra" ]] || return 1
  [[ "$short_window" =~ ^[0-9]+[mhd]$ ]] || return 1
  [[ "$long_window" =~ ^[0-9]+[mhd]$ ]] || return 1
  [[ "$short_remaining" =~ ^[0-9]+$ ]] || return 1
  [[ "$long_remaining" =~ ^[0-9]+$ ]] || return 1
  ((short_remaining <= 100 && long_remaining <= 100)) || return 1
  [[ -n "$short_reset" && -n "$long_reset" ]] || return 1
  [[ "$credits" == none || "$credits" == unlimited ||
     "$credits" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || return 1
  [[ "$work_in_progress" == true || "$work_in_progress" == false ]] || return 1

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

  if [[ "$work_in_progress" == true ]]; then
    work_in_progress_icon=$'⌁ '
  fi

  printf 'CL:<span foreground="%s">%s</span><span foreground="%s">%s %d%% rst %s</span>·<span foreground="%s">%s %d%% rst %s</span>' \
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
