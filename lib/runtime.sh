#!/bin/bash

# Expand the supported home-directory and environment-variable references in a
# configured path without evaluating it as shell code.
expand_config_path() {
  local remaining="$1"
  local expanded=""
  local prefix variable

  case "$remaining" in
    '~') remaining="$HOME" ;;
    '~/'*) remaining="$HOME/${remaining#\~/}" ;;
    '~'*)
      printf 'Unsupported home-directory expansion: %s\n' "$remaining" >&2
      return 1
      ;;
  esac

  while [[ "$remaining" == *'$'* ]]; do
    prefix="${remaining%%\$*}"
    expanded+="$prefix"
    remaining="${remaining#*\$}"

    if [[ "$remaining" =~ ^\{([a-zA-Z_][a-zA-Z0-9_]*)\}(.*)$ ]]; then
      variable="${BASH_REMATCH[1]}"
      remaining="${BASH_REMATCH[2]}"
    elif [[ "$remaining" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)(.*)$ ]]; then
      variable="${BASH_REMATCH[1]}"
      remaining="${BASH_REMATCH[2]}"
    else
      printf 'Invalid environment-variable expansion in path: %s\n' "$1" >&2
      return 1
    fi

    [[ -v "$variable" ]] || {
      printf 'Environment variable is not set: %s\n' "$variable" >&2
      return 1
    }
    expanded+="${!variable}"
  done

  printf '%s%s\n' "$expanded" "$remaining"
}


# Load configuration and establish the readonly runtime paths used by the main
# process and sourced modules.
initialize_runtime_paths() {
  local command="${1:-}"
  local command_argument="${2:-}"
  local command_format="${3:-}"
  local command_target=""
  local config_line configured_ticker_directory="" configured_ticker_format="pango"
  local enabled_modules_value=""
  local enabled_module
  local -a enabled_module_names

  readonly USER_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  readonly RAM_DISK="$USER_RUNTIME_DIR/clock-ticker"
  readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/clock-ticker"
  readonly CONFIG_FILE="$CONFIG_DIR/config"
  readonly PERSONAL_MODULES_DIR="$CONFIG_DIR/modules"
  ENABLED_MODULES_CONFIGURED=false
  TICKER_FORMAT_CONFIGURED=false
  declare -gA ENABLED_MODULES=()

  if [[ -e "$CONFIG_FILE" ]]; then
    while IFS= read -r config_line || [[ -n "$config_line" ]]; do
      case "$config_line" in
        ''|'#'*) ;;
        ticker_directory=*)
          configured_ticker_directory="${config_line#ticker_directory=}"
          ;;
        ticker_format=*)
          configured_ticker_format="${config_line#ticker_format=}"
          TICKER_FORMAT_CONFIGURED=true
          ;;
        enabled_modules=*)
          enabled_modules_value="${config_line#enabled_modules=}"
          ENABLED_MODULES_CONFIGURED=true
          ;;
        *)
          printf 'Invalid clock ticker configuration: %s\n' "$config_line" >&2
          return 2
          ;;
      esac
    done <"$CONFIG_FILE"
  fi

  if [[ "$command" == run ]]; then
    case "$command_argument" in
      pango|plain)
        [[ -z "$command_format" ]] || {
          printf 'Output format was provided twice.\n' >&2
          return 2
        }
        command_format="$command_argument"
        ;;
      *) command_target="$command_argument" ;;
    esac
  fi

  [[ "$configured_ticker_format" == pango || "$configured_ticker_format" == plain ]] || {
    printf 'Invalid ticker_format in %s: %s\n' \
      "$CONFIG_FILE" "$configured_ticker_format" >&2
    return 2
  }
  [[ -z "$command_format" || "$command_format" == pango || "$command_format" == plain ]] || {
    printf 'Invalid ticker output format: %s\n' "$command_format" >&2
    return 2
  }

  if [[ -n "$command_format" ]]; then
    readonly TICKER_FORMAT="$command_format"
  else
    readonly TICKER_FORMAT="$configured_ticker_format"
  fi
  readonly TICKER_FORMAT_CONFIGURED

  if [[ "$ENABLED_MODULES_CONFIGURED" == true ]]; then
    IFS=',' read -r -a enabled_module_names <<<"$enabled_modules_value"
    for enabled_module in "${enabled_module_names[@]}"; do
      enabled_module="${enabled_module#"${enabled_module%%[![:space:]]*}"}"
      enabled_module="${enabled_module%"${enabled_module##*[![:space:]]}"}"
      [[ -n "$enabled_module" ]] || continue
      [[ "$enabled_module" =~ ^[a-zA-Z0-9_-]+$ ]] || {
        printf 'Invalid enabled module name: %s\n' "$enabled_module" >&2
        return 2
      }
      ENABLED_MODULES["$enabled_module"]=1
    done
  fi
  readonly ENABLED_MODULES_CONFIGURED ENABLED_MODULES

  if [[ "$command" == run && -n "$command_target" ]]; then
    readonly TICKER_DIRECTORY="$command_target"
  elif [[ -n "$configured_ticker_directory" ]]; then
    TICKER_DIRECTORY="$(expand_config_path "$configured_ticker_directory")" || return 2
    readonly TICKER_DIRECTORY
  else
    readonly TICKER_DIRECTORY="$RAM_DISK"
  fi

  [[ "$TICKER_DIRECTORY" == /* ]] || {
    printf 'Ticker target directory must be an absolute path: %s\n' \
      "$TICKER_DIRECTORY" >&2
    return 2
  }

  readonly TICKER_FILE="$TICKER_DIRECTORY/ticker.txt"
  readonly INITIALIZATION_MARKER="$RAM_DISK/.clock_ticker_initialized"
  readonly INITIALIZATION_LOCK_FILE="$RAM_DISK/.clock_ticker_initialization.lock"
}


# Return success when MODULE_NAME is enabled by configuration, or when module
# selection is unrestricted.
# Arguments: module name
# Output: none
module_is_enabled() {
  local module_name="$1"

  [[ "$ENABLED_MODULES_CONFIGURED" == false ]] ||
    [[ -n "${ENABLED_MODULES[$module_name]:-}" ]]
}


# Print configured module names as a sorted, comma-separated configuration
# value. Arguments: none. Output: one line. Returns failure when unrestricted.
configured_enabled_modules_value() {
  local module_name separator=""
  local -a module_names

  [[ "$ENABLED_MODULES_CONFIGURED" == true ]] || return 1
  mapfile -t module_names < <(printf '%s\n' "${!ENABLED_MODULES[@]}" | sort)
  for module_name in "${module_names[@]}"; do
    printf '%s%s' "$separator" "$module_name"
    separator=','
  done
  printf '\n'
}


# Return success when path, or its nearest existing parent, is mounted on
# tmpfs.
# Arguments: path to inspect
# Output: none
directory_is_on_tmpfs() {
  local existing_parent="$1"

  while [[ ! -e "$existing_parent" ]]; do
    existing_parent="$(dirname -- "$existing_parent")" || return 1
  done

  [[ "$(findmnt -no FSTYPE --target "$existing_parent")" == tmpfs ]]
}


# Create and validate the runtime and output directories.
# Arguments: none
# Output: diagnostics on stderr
# Returns: failure if tmpfs or write checks fail
prepare_runtime_directories() {
  directory_is_on_tmpfs "$RAM_DISK" || {
    printf 'Ticker runtime directory is not backed by tmpfs: %s\n' \
      "$RAM_DISK" >&2
    return 1
  }

  command mkdir -p -- "$RAM_DISK" || {
    printf 'Cannot create ticker runtime directory: %s\n' "$RAM_DISK" >&2
    return 1
  }

  [[ -w "$RAM_DISK" ]] || {
    printf 'Ticker runtime directory is not writable: %s\n' "$RAM_DISK" >&2
    return 1
  }

  [[ "$TICKER_DIRECTORY" == "$RAM_DISK" ]] && return 0

  command mkdir -p -- "$TICKER_DIRECTORY" || {
    printf 'Cannot create ticker output directory: %s\n' \
      "$TICKER_DIRECTORY" >&2
    return 1
  }

  [[ -w "$TICKER_DIRECTORY" ]] || {
    printf 'Ticker output directory is not writable: %s\n' \
      "$TICKER_DIRECTORY" >&2
    return 1
  }
}


# Atomically publish the rendered ticker on the target filesystem.
publish_ticker() {
  local ticker="$1"
  local published_ticker="$ticker"
  local temporary_file

  if [[ "$TICKER_FORMAT" == plain ]]; then
    published_ticker="$(strip_pango_markup "$ticker")" || return 1
  fi

  temporary_file="$(mktemp --tmpdir="$TICKER_DIRECTORY" 'ticker.txt.tmp.XXXXXX')" || return 1

  if ! printf '%s' "$published_ticker" >"$temporary_file"; then
    rm -f -- "$temporary_file"
    return 1
  fi

  if cmp -s -- "$temporary_file" "$TICKER_FILE"; then
    rm -f -- "$temporary_file"
  elif ! mv -f -- "$temporary_file" "$TICKER_FILE"; then
    rm -f -- "$temporary_file"
    return 1
  fi
}


# Remove Pango-style tags from TEXT.
# Arguments: text
# Output: plain text on stdout.
# Returns: success after all matching tags have been removed.
strip_pango_markup() {
  local text="$1"

  while [[ "$text" =~ \<[^\>]*\> ]]; do
    text="${text/"${BASH_REMATCH[0]}"/}"
  done
  printf '%s\n' "$text"
}
