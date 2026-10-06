#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:
#
# clock_ticker.sh
# Copyright (C) 2026 Pavel Vitis <pavelvitis@gmail.com>
#
# Distributed under terms of the MIT license.
#

# Report failures from any command in a pipeline, not just the final command.
set -o pipefail

readonly -a SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")" || {
  printf 'Cannot determine script path.\n' >&2
  exit 1
}
readonly SCRIPT_PATH

readonly SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

readonly LIB_DIR="$SCRIPT_DIR/lib"
readonly MODULES_DIR="$SCRIPT_DIR/modules"
readonly TESTS_DIR="$SCRIPT_DIR/tests"
readonly PYTHON="$SCRIPT_DIR/.venv/bin/python"
readonly BIN_DIR="$HOME/.local/bin"

# shellcheck source=lib/runtime.sh
source "$LIB_DIR/runtime.sh" || exit 1

case "${1:-help}" in
  install|uninstall|status|restart|stop|test)
    # shellcheck source=lib/service.sh
    source "$LIB_DIR/service.sh" || exit 1
    ;;
esac

initialize_runtime_paths "${1:-}" "${2:-}" "${3:-}" || exit $?


# Resolve a module name to its personal or repository module file.
# Arguments: module name
# Output: selected module path on stdout
# Returns: 0 when a module file exists, 1 otherwise
module_file_for_name() {
  local module_name="$1"

  if [[ -f "$PERSONAL_MODULES_DIR/$module_name.sh" ]]; then
    printf '%s\n' "$PERSONAL_MODULES_DIR/$module_name.sh"
  elif [[ -f "$MODULES_DIR/$module_name.sh" ]]; then
    printf '%s\n' "$MODULES_DIR/$module_name.sh"
  else
    return 1
  fi
}


# List the unique module names available from personal and repository directories.
# Arguments: none
# Output: sorted module names, one per line, on stdout
# Returns: 0 unless sorting or output fails
list_module_names() {
  local module_file
  local -A names=()

  for module_file in "$MODULES_DIR"/*.sh "$PERSONAL_MODULES_DIR"/*.sh; do
    [[ -f "$module_file" ]] || continue
    names["$(basename "${module_file%.sh}")"]=1
  done

  ((${#names[@]} > 0)) || return 0
  printf '%s\n' "${!names[@]}" | sort
}


# Source every enabled module in sorted name order.
# Arguments: none
# Output: sourced module paths on stdout
# Returns: 0 when all enabled modules load, 1 when a module cannot be resolved or sourced
source_modules() {
  local module_file module_name
  local -a module_names

  mapfile -t module_names < <(list_module_names)
  for module_name in "${module_names[@]}"; do
    module_is_enabled "$module_name" || continue
    module_file="$(module_file_for_name "$module_name")" || return 1
    printf 'Sourcing module %s\n' "$module_file"
    source "$module_file" || return 1
  done
}


# Invoke CALLBACK for each module that provides an update function.
# Arguments: callback name, optional true to restrict to enabled modules
# Output: callback output
# Returns: 0 when every callback succeeds, 1 when any callback fails
for_each_update_module() {
  local callback="$1"
  local enabled_only="${2:-false}"
  local module_file module_name function_name
  local callback_failed=0
  local -a module_names

  mapfile -t module_names < <(list_module_names)
  for module_name in "${module_names[@]}"; do
    if [[ "$enabled_only" == true ]] && ! module_is_enabled "$module_name"; then
      continue
    fi
    module_file="$(module_file_for_name "$module_name")" || continue
    function_name="update__${module_name}"

    if declare -F "$function_name" >/dev/null || (
        source "$module_file"
        declare -F "$function_name" >/dev/null
      ); then
      "$callback" "$module_name" "$function_name" || callback_failed=1
    fi
  done

  return "$callback_failed"
}


# Run a module update while holding that module's non-blocking lock.
# Arguments: module name, update function name, lock-contention status, update arguments
# Output: update output and lock diagnostics
# Returns: update status, or the supplied contention status when already locked
run_locked_module_update() {
  local module_name="$1"
  local function_name="$2"
  local contention_status="$3"
  local module_lock_fd
  shift 3

  exec {module_lock_fd}>"$RAM_DISK/.clock_ticker_update.${module_name}.lock" ||
    return 1
  if ! flock -n "$module_lock_fd"; then
    printf 'Module update is already in progress; skipping update: %s\n' \
      "$module_name" >&2
    return "$contention_status"
  fi

  "$function_name" "$@"
}


# Perform the initial cache update for one module.
# Arguments: module name, update function name
# Output: progress and failure diagnostics on stderr
# Returns: 0 on a successful update, 1 otherwise
initialize_module_cache() {
  local module_name="$1"
  local function_name="$2"

  printf 'Running initial update: %s\n' "$module_name" >&2
  if ! run_locked_module_update "$module_name" "$function_name" 1; then
    printf 'Initial update failed: %s\n' "$module_name" >&2
    return 1
  fi
}


# Initialize every enabled module cache once per runtime directory.
# Arguments: none
# Output: progress and failure diagnostics on stderr
# Returns: 0 when initialized or already marked complete, 1 otherwise
initialize_module_caches() {
  local initialization_lock_fd

  if [[ ! -d "$RAM_DISK" || ! -w "$RAM_DISK" ]]; then
    printf 'Runtime directory is unavailable at %s; skipping initial updates.\n' \
      "$RAM_DISK" >&2
    return 1
  fi

  exec {initialization_lock_fd}>"$INITIALIZATION_LOCK_FILE" || return 1
  flock "$initialization_lock_fd" || return 1

  [[ ! -e "$INITIALIZATION_MARKER" ]] || return 0

  printf 'Initializing module caches...\n' >&2

  if ! for_each_update_module initialize_module_cache true; then
    printf 'Some initial updates failed; initialization marker was not created.\n' >&2
    return 1
  fi

  touch -- "$INITIALIZATION_MARKER"
}


# Print an update-capable module name with help-list indentation.
# Arguments: module name
# Output: indented module name on stdout
# Returns: status from printf
print_update_module() {
  printf '    %s\n' "$1"
}


# List all modules that provide an update function.
# Arguments: none
# Output: indented module names on stdout
# Returns: 0 when all names are listed, 1 when a callback fails
list_modules() {
  for_each_update_module print_update_module
}


# Dispatch an update module's help text or cache refresh.
# Arguments: module name followed by optional module arguments
# Output: module help, update output, and diagnostics
# Returns: the selected module operation status
run_module_update() {
  local module="${1:-}"
  local initialization_lock_fd
  shift || true

  [[ "$module" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    printf 'Invalid module: "%s"\n' "$module" >&2
    printf 'Available modules:\n' >&2
    list_modules
    return 1
  }

  local module_file
  local function_name="update__$module"
  local help_function="help__${module}"

  module_file="$(module_file_for_name "$module")" || {
    printf 'Unknown module: %s\n' "$module" >&2
    return 1
  }

  source "$module_file"

  declare -F "$function_name" >/dev/null || {
    printf "Module '%s' does not support update\n" "$module" >&2
    return 1
  }

  case "${1:-}" in
    help|-h|--help)
      if declare -F "$help_function" >/dev/null; then
        "$help_function"
      else
        printf 'Usage: %s update %s\n' "$(basename "$0")" "$module"
      fi
      ;;

    *)
      exec {initialization_lock_fd}>"$INITIALIZATION_LOCK_FILE" || return 1
      if ! flock -s -n "$initialization_lock_fd"; then
        printf 'Initial cache update is in progress; skipping update: %s\n' \
          "$module" >&2
        return 0
      fi

      run_locked_module_update "$module" "$function_name" 0 "$@"
      ;;
  esac
}


# Sleep until the next whole wall-clock second.
# Arguments: none
# Output: none
# Returns: status from sleep
sleep_until_next_second() {
    local frac="${EPOCHREALTIME#*.}"
    local remaining=$((1000000 - 10#$frac))

    printf -v remaining '0.%06d' "$remaining"
    sleep "$remaining"
}


# Render text as optional Pango foreground markup and optionally truncate it.
# Arguments: color, text or render_file path, optional maximum length
# Output: rendered text on stdout
# Returns: 0 when text is rendered, 1 when a requested file cannot be read
render_text() {
  local color="$1"
  local text="$2"
  local max_len="${3:-0}"
  local file_name len
  local -a lines

  [[ -n "$text" ]] || return

  # text beginning with 'render_file ' will read and render the contents of that file
  if [[ "$text" == 'render_file '* ]]; then
    file_name="${text#render_file }"
    [[ -f "$file_name" ]] || return 1

    # Replace line endings with spaces.
    local IFS=' '
    mapfile -t lines <"$file_name" || return 1
    text="${lines[*]}"
  fi

  # Optional shortening of long string
  if (( max_len > 3 && ${#text} > max_len )); then
    len=$((max_len - 3))
    text="${text:0:len}..."
  fi

  if [[ -n "$color" ]]; then
    printf "<span foreground='%s'>%s</span>" "$color" "$text"
  else
    printf '%s' "$text"
  fi
}

# Append text to a caller-owned ticker variable, adding a separator when needed.
# Arguments: target variable name, text, optional separator defaulting to " | "
# Output: none
# Returns: 0 after appending or when text is empty
append_ticker() {
  local -n target="$1"
  local text="$2"
  local separator="${3:- | }"

  [[ -n "$text" ]] || return

  if [[ -n "$target" ]]; then
    target+="$separator"
  fi

  target+="$text"
}


# Format the current system uptime for ticker display.
# Arguments: none
# Output: compact uptime text on stdout
# Returns: 0 when /proc/uptime is readable, 1 otherwise
compact_uptime() {
  local uptime_seconds unused days hours minutes tenths_of_days

  read -r uptime_seconds unused < /proc/uptime || return 1
  uptime_seconds="${uptime_seconds%.*}"

  days=$((uptime_seconds / 86400))
  hours=$((uptime_seconds % 86400 / 3600))
  minutes=$((uptime_seconds % 3600 / 60))

  if ((days > 0)); then
    tenths_of_days=$((uptime_seconds / 8640))
    printf 'up %d.%dd' "$((tenths_of_days / 10))" "$((tenths_of_days % 10))"
  else
    printf 'up %dh %dm' "$hours" "$minutes"
  fi
}


# Invoke a function only when it has been declared.
# Arguments: function name followed by function arguments
# Output: invoked function output
# Returns: 0 when unavailable, otherwise the invoked function status
call_if_available() {
  local function_name="$1"
  shift

  declare -F "$function_name" >/dev/null || return 0
  "$function_name" "$@"
}


# Run the one-second ticker rendering and publication loop.
# Arguments: none
# Output: progress and failure diagnostics on stderr
# Returns: 1 when runtime setup, module loading, or publication fails
ticker_loop() {
  prepare_runtime_directories || return 1

  printf 'Loading modules...\n' >&2
  source_modules >&2 || return 1

  initialize_module_caches &

  call_if_available start_dnd_monitor || {
    printf 'Unable to monitor GNOME DND state.\n' >&2
  }
  trap 'call_if_available stop_codex_usage_update; call_if_available stop_syncthing_monitor; call_if_available stop_dnd_monitor' EXIT
  trap 'exit 0' INT TERM

  printf 'Running main ticker loop...\n' >&2

  while true; do
    local ticker=""

    #append_ticker ticker "$(render_text "" "$(cat $RAM_DISK/.fuzzy_time)")"
    #append_ticker ticker "$(render_text "" "render_file $HOME/.countdown/christmas")"
    #append_ticker ticker "$(render_text "" "render_file $HOME/.upcoming_meetings" 70)" ""

    append_ticker ticker "$(render_text "" "$(call_if_available disk_space_status)")"
    append_ticker ticker "$(render_text "" "$(call_if_available readonly_filesystem_status)")"

    append_ticker ticker "$(render_text "" "$(call_if_available memory_status)")"
    append_ticker ticker "$(render_text "" "$(call_if_available swap_io_status)")" $' \u2022 '
    append_ticker ticker "$(render_text "" "$(call_if_available vm_status)")"

    append_ticker ticker "$(render_text "" "$(call_if_available cpu_temperature_status)")"

    append_ticker ticker "$(render_text "" "$(call_if_available battery_status)")"

    #echon "" "$(echo -n 'osmcv '; cat $RAM_DISK/.osmcv_disk_space)"  >> $TF

    append_ticker ticker "$(render_text "" "$(call_if_available backup_status)")"

    call_if_available maintain_syncthing_monitor
    append_ticker ticker "$(render_text "" "$(call_if_available syncthing_status)")"

    call_if_available maybe_update_codex_usage
    append_ticker ticker "$(render_text "" "$(call_if_available codex_usage_status)")"

    append_ticker ticker "$(render_text "" "$(call_if_available fedora_status)")"
#    append_ticker ticker "$(call_if_available configuration_drift_status)"

    #[ -s "$RAM_DISK/.pomodoro" ] && echon "Pomodoro elapsed: $(cat $RAM_DISK/.pomodoro)"  >> $TF
    song_title_status >/dev/null \
      && append_ticker ticker "$(call_if_available song_title_status)" \
      || append_ticker ticker "$(call_if_available cli_commands_status)"


    sleep_until_next_second

    call_if_available update_dnd_status

    local uptime_text spinner
    uptime_text="$(compact_uptime)" || return 1
    spinner="${SPINNER_FRAMES[EPOCHSECONDS % ${#SPINNER_FRAMES[@]}]}"

    clock_ticker="$({
      render_text "#ff5f5f" "$(call_if_available dnd_status)"
      call_if_available clock_status
      render_text "#48D1CC" " $spinner" " "
      render_text "#48D1CC" " $uptime_text" " "
    })"

    append_ticker clock_ticker "$ticker"

    publish_ticker "$clock_ticker" || {
      printf 'Failed to publish ticker output.\n' >&2
      return 1
    }
  done
}


# Print command-line usage and available update modules.
# Arguments: none
# Output: help text and update module names on stdout
# Returns: status from listing update modules
print_help() {
    cat <<EOF
Usage:
    $(basename "$0") COMMAND [ARGUMENT]

Commands:
    help
        Show this help.

    run [TARGET_DIRECTORY] [pango|plain]
        Start main ticker loop. Publish ticker.txt in TARGET_DIRECTORY when
        provided; the default is \$XDG_RUNTIME_DIR/clock-ticker. The output
        defaults to Pango markup; use plain to strip markup tags.

    install [TARGET_DIRECTORY]
        Install and enable the user service. Save TARGET_DIRECTORY in the
        configuration file when provided; otherwise preserve the current file.
        The service will maintain "clock_ticker run" process alive.

    uninstall
        Stop and remove the user service and command symlink.

    status
        Show the user service status.

    restart
        Restart the user service.
        Run this after modifying module scripts or main script.

    stop
        Stop the user service.

    test
        Run static checks and print the currently published ticker.

    update MODULE
        Run an update module from:
        $MODULES_DIR

        Use this in crontab to update ticker information on disk cache.

Available update modules:
EOF

    list_modules
}


case "${1:-help}" in
  help)
    print_help
    exit
    ;;
  install)
    if (( $# > 2 )); then
      printf 'Usage: %s install [TARGET_DIRECTORY]\n' "$(basename "$0")" >&2
      exit 2
    fi
    shift
    install_service "$@"
    exit $?
    ;;
  uninstall)
    uninstall_service
    exit $?
    ;;
  status)
    status_service
    exit $?
    ;;
  restart)
    restart_service
    exit $?
    ;;
  stop)
    stop_service
    exit $?
    ;;
  test)
    test_project
    exit $?
    ;;
  update)
    shift
    run_module_update "$@"
    exit $?
    ;;
  run)
    if (( $# > 3 )); then
      printf 'Usage: %s run [TARGET_DIRECTORY] [pango|plain]\n' \
        "$(basename "$0")" >&2
      exit 2
    fi
    ticker_loop
    ;;
  *)
    printf 'Unknown command: %q\n' "$1" >&2
    print_help >&2
    exit 2
    ;;    
esac
