#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:
#
# clock.sh
# Copyright (C) 2020 Pavel Vitis <pavelvitis@gmail.com>
#
# Distributed under terms of the MIT license.
#

# saner programming env: these switches turn some bugs into errors
#set -o errexit -o pipefail -o noclobber -o nounset


readonly DISK_STATUS_CACHE="$RAM_DISK/.disk_space.txt"

readonly LOG_DISK_USAGE_ALARM_GB=10
readonly DISK_USAGE_ALARM_PERCENT=95


help__filesystem() {
  cat <<EOF
Usage:
    clock_ticker update filesystem

Refreshes the cached available space and usage percentage of the root filesystem.

The result is stored in:
    $DISK_STATUS_CACHE
EOF
}


# Special update function called from main module clock_ticker update <module_name>
update__filesystem() {
    local available disk_used log_disk_used_b temporary

    read -r available disk_used < <(
        df -h --output=avail,pcent / | awk 'NR == 2 { print $1, $2 }'
    ) || return 1

    read -r log_disk_used_b < <(
        sudo du -sb /var/log | awk '{print $1}'
    ) || return 1

    disk_used=${disk_used%\%}

    temporary=$(mktemp "${DISK_STATUS_CACHE}.XXXXXX") || return 1

    printf '%s|%s|%s\n' "$available" "$disk_used" "$log_disk_used_b" | tee "$temporary"
    mv -f "$temporary" "$DISK_STATUS_CACHE"
}


disk_space_status() {
  # Disk space
  local symbol=""
  local color
  local available
  local disk_used
  local log_disk_used_b log_disk_used_hr

  if ! IFS='|' read -r available disk_used log_disk_used_b <"$DISK_STATUS_CACHE"; then
      printf '<span foreground="#ff5f5f">⚠ D:unknown</span>'
      return 1
  fi

  # Test with: disk_space red
  if [[ "${1:-}" == "red" ]]; then
      disk_used=96
  fi

  if (( disk_used < DISK_USAGE_ALARM_PERCENT && log_disk_used_b < LOG_DISK_USAGE_ALARM_GB * 1024 * 1034 * 1024 )); then
      color="3cb371"
  else
      color="ff5f5f"
      symbol="⚠ "
  fi

  read -r log_disk_used_hr < <(
      numfmt --to=iec --suffix=B "$log_disk_used_b"
  ) || return 1

  printf '<span foreground="#%s">%sD:%s avail·%s%% used·%s logs</span>' \
      "$color" "$symbol" "$available" "$disk_used" "$log_disk_used_hr"
}


readonly_filesystem_status() {
    local mountpoint options
    local -a readonly_mounts=()

    for mountpoint in / /home; do
        options=$(findmnt -no OPTIONS --target "$mountpoint" 2>/dev/null) ||
            continue

        if [[ ",$options," == *,ro,* ]]; then
            readonly_mounts+=("$mountpoint")
        fi
    done

    ((${#readonly_mounts[@]} > 0)) || return 0

    printf '<span foreground="#ff5f5f">‼ RO:%s</span>' \
        "$(IFS=,; printf '%s' "${readonly_mounts[*]}")"
}
