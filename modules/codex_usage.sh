#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:

readonly CODEX_USAGE_CACHE="$RAM_DISK/.codex_usage.txt"


help__codex_usage() {
  cat <<EOF
Usage:
    clock_ticker update codex_usage

Refreshes the cached Codex account usage from the authenticated Codex CLI.
EOF
}

update__codex_usage() {
  local script_path script_dir temporary

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

  mv -f -- "$temporary" "$CODEX_USAGE_CACHE" || {
    rm -f -- "$temporary"
    return 1
  }
}

codex_usage_status() {
  local short_window short_remaining short_reset
  local long_window long_remaining long_reset extra
  local short_color="#7fc97f" long_color="#7fc97f"

  [[ -r "$CODEX_USAGE_CACHE" ]] || return 0
  IFS=$'\t' read -r short_window short_remaining short_reset \
    long_window long_remaining long_reset extra <"$CODEX_USAGE_CACHE" || return 1
  [[ -z "$extra" ]] || return 1
  [[ "$short_window" =~ ^[0-9]+[mhd]$ ]] || return 1
  [[ "$long_window" =~ ^[0-9]+[mhd]$ ]] || return 1
  [[ "$short_remaining" =~ ^[0-9]+$ ]] || return 1
  [[ "$long_remaining" =~ ^[0-9]+$ ]] || return 1
  ((short_remaining <= 100 && long_remaining <= 100)) || return 1
  [[ -n "$short_reset" && -n "$long_reset" ]] || return 1

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

  printf 'CX:<span foreground="%s">%s %d%% rst %s</span>·<span foreground="%s">%s %d%% rst %s</span>' \
    "$short_color" "$short_window" "$short_remaining" "$short_reset" \
    "$long_color" "$long_window" "$long_remaining" "$long_reset"
}
