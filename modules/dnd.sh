#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:
#
# clock.sh
# Copyright (C) 2026 Pavel Vitis <pavelvitis@gmail.com>
#
# Distributed under terms of the MIT license.
#

# saner programming env: these switches turn some bugs into errors
#set -o errexit -o pipefail -o noclobber -o nounset


DND_MONITOR_PID=""
DND_MONITOR_FD=""
DND_SHOW_BANNERS="true"

start_dnd_monitor() {
  local initial_value

  initial_value="$(
    gsettings get \
      org.gnome.desktop.notifications \
      show-banners
  )" || return 1

  case "$initial_value" in
    true|false)
      DND_SHOW_BANNERS="$initial_value"
      ;;
    *)
      return 1
      ;;
  esac

  coproc DND_MONITOR {
    exec gsettings monitor \
      org.gnome.desktop.notifications \
      show-banners
  }

  DND_MONITOR_PID=$COPROC_PID
  DND_MONITOR_FD=${DND_MONITOR[0]}
}


stop_dnd_monitor() {
  if [[ -n "$DND_MONITOR_PID" ]]; then
    kill "$DND_MONITOR_PID" 2>/dev/null || true
    wait "$DND_MONITOR_PID" 2>/dev/null || true
  fi

  if [[ -n "$DND_MONITOR_FD" ]]; then
    exec {DND_MONITOR_FD}<&-
  fi

  DND_MONITOR_PID=""
  DND_MONITOR_FD=""
}


update_dnd_status() {
  local line value

  [[ -n "$DND_MONITOR_FD" ]] || return 0

  # A zero timeout can repeatedly report pending bytes without consuming a
  # complete line. Use a very small finite timeout to consume complete events
  # without delaying the ticker noticeably.
  while IFS= read -r -t 0.001 -u "$DND_MONITOR_FD" line; do
    value="${line##*: }"

    case "$value" in
      true|false)
        DND_SHOW_BANNERS="$value"
        ;;
    esac
  done
}


dnd_status() {
  if [[ "$DND_SHOW_BANNERS" == false ]]; then
    printf '●  '
  fi
}
