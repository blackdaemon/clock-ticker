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
  local remaining reset_time color="#7fc97f"

  [[ -r "$CODEX_USAGE_CACHE" ]] || return 0
  IFS=$'\t' read -r remaining reset_time <"$CODEX_USAGE_CACHE" || return 1
  [[ "$remaining" =~ ^[0-9]+$ ]] || return 1

  if ((remaining <= 10)); then
    color="#ff5f5f"
  elif ((remaining <= 25)); then
    color="#ffd75f"
  fi

  printf '<span foreground="%s">CX:%d%% reset:%s</span>' \
    "$color" "$remaining" "${reset_time:-unknown}"
}
