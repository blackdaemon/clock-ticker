#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:
#
# Copyright (C) 2026 Pavel Vitis <pavelvitis@gmail.com>
#
# Distributed under terms of the MIT license.

readonly SYNCTHING_STATUS_CACHE="$RAM_DISK/.syncthing_status.txt"
SYNCTHING_MONITOR_PID=""
# Seconds between background updates while remote sync work is pending.
SYNCTHING_MONITOR_INTERVAL="${SYNCTHING_MONITOR_INTERVAL:-4}"


# Print command-line help for the Syncthing cache updater.
#
# Arguments: none.
# Output: usage text on standard output.
# Returns: zero when the text is written successfully.
help__syncthing() {
  cat <<EOF
Usage:
    clock_ticker update syncthing

Refreshes cached Syncthing connectivity, completion, error, and activity
information.

The result is stored in:
    $SYNCTHING_STATUS_CACHE
EOF
}


# Query Syncthing's authenticated REST API and atomically refresh the cache.
#
# Collects local and aggregate remote completion, connectivity, folder errors,
# recent activity, and connection byte counters. Transfer rates are calculated
# from the preceding cache sample. The API key is kept in a private temporary
# curl configuration and is never written to the status cache.
#
# Arguments: none.
# Output: none on success; curl diagnostics may be written to standard error.
# Side effects: replaces SYNCTHING_STATUS_CACHE and creates temporary files in
# RAM_DISK. An unreachable daemon writes an offline cache entry.
# Returns: zero after a successful online refresh; nonzero on API, parsing, or
# filesystem failure (including after recording an offline daemon).
update__syncthing() {
  local config_dir config_file gui_config api_key gui_address scheme base_url
  local curl_config temporary
  local connections completion folders statistics folder errors_json device
  local connected total paused completion_pct need_bytes need_items error_count=0
  local remote_global_bytes=0 remote_need_bytes=0 remote_need_items=0
  local remote_completion_pct=100.0 in_bytes out_bytes sample_epoch
  local completion_global completion_bytes completion_items completion_deletes
  local previous_state previous_in previous_out previous_epoch
  local download_rate=0 upload_rate=0 elapsed
  local last_scan last_file_time last_folder_id last_folder
  local last_scan_epoch=0 last_file_epoch=0

  config_dir="${STCONFDIR:-${XDG_STATE_HOME:-$HOME/.local/state}/syncthing}"
  config_file="$config_dir/config.xml"
  [[ -r "$config_file" ]] || config_file="$HOME/.config/syncthing/config.xml"
  [[ -r "$config_file" ]] || return 1

  gui_config="$(
    awk '
      /<gui[ >]/ { inside = 1 }
      inside { print }
      /<\/gui>/ { exit }
    ' "$config_file"
  )" || return 1

  [[ "$gui_config" =~ \<address\>([^\<]+)\</address\> ]] || return 1
  gui_address="${BASH_REMATCH[1]}"
  [[ "$gui_config" =~ \<apikey\>([^\<]+)\</apikey\> ]] || return 1
  api_key="${BASH_REMATCH[1]}"

  scheme=http
  [[ "$gui_config" == *'tls="true"'* ]] && scheme=https
  base_url="$scheme://$gui_address"

  temporary="$(mktemp --tmpdir="$RAM_DISK" '.syncthing_status.tmp.XXXXXX')" ||
    return 1
  curl_config="$(mktemp --tmpdir="$RAM_DISK" '.syncthing_curl.tmp.XXXXXX')" || {
    rm -f -- "$temporary"
    return 1
  }
  chmod 600 "$curl_config" || {
    rm -f -- "$temporary" "$curl_config"
    return 1
  }
  printf 'header = "X-API-Key: %s"\n' "$api_key" >"$curl_config"
  [[ "$scheme" == https ]] && printf 'insecure\n' >>"$curl_config"

  if ! connections="$(curl -fsS --config "$curl_config" \
      "$base_url/rest/system/connections")"; then
    rm -f -- "$curl_config"
    printf 'offline|0|0|0|0|0|0|0|0|0|\n' >"$temporary" &&
      mv -f -- "$temporary" "$SYNCTHING_STATUS_CACHE"
    return 1
  fi

  folders="$(curl -fsS --config "$curl_config" \
    "$base_url/rest/config/folders")" || {
    rm -f -- "$temporary" "$curl_config"
    return 1
  }
  statistics="$(curl -fsS --config "$curl_config" \
    "$base_url/rest/stats/folder")" || {
    rm -f -- "$temporary" "$curl_config"
    return 1
  }

  read -r connected total paused < <(
    jq -r '
      [.connections[]] as $devices |
      [
        ($devices | map(select(.connected == true)) | length),
        ($devices | length),
        ($devices | map(select(.paused == true)) | length)
      ] | @tsv
    ' <<<"$connections"
  ) || {
    rm -f -- "$temporary" "$curl_config"
    return 1
  }

  # Preserve the original local-device completion status.
  completion="$(curl -fsS --config "$curl_config" \
    "$base_url/rest/db/completion")" || {
    rm -f -- "$temporary" "$curl_config"
    return 1
  }
  read -r completion_pct need_bytes need_items < <(
    jq -r '[.completion, .needBytes, .needItems] | @tsv' <<<"$completion"
  ) || {
    rm -f -- "$temporary" "$curl_config"
    return 1
  }

  # Separately aggregate the connected remote-device view used by Syncthing's
  # device panel. Disconnected devices cannot be actively syncing, so their
  # pending items must not keep the activity monitor running indefinitely.
  while IFS= read -r device; do
    completion="$(curl -fsS --config "$curl_config" --get \
      --data-urlencode "device=$device" "$base_url/rest/db/completion")" || {
      rm -f -- "$temporary" "$curl_config"
      return 1
    }
    read -r completion_global completion_bytes completion_items completion_deletes < <(
      jq -r '[.globalBytes, .needBytes, .needItems, .needDeletes] | @tsv' \
        <<<"$completion"
    ) || {
      rm -f -- "$temporary" "$curl_config"
      return 1
    }
    [[ "$completion_global" =~ ^[0-9]+$ &&
       "$completion_bytes" =~ ^[0-9]+$ &&
       "$completion_items" =~ ^[0-9]+$ &&
       "$completion_deletes" =~ ^[0-9]+$ ]] || {
      rm -f -- "$temporary" "$curl_config"
      return 1
    }
    remote_global_bytes=$((remote_global_bytes + completion_global))
    remote_need_bytes=$((remote_need_bytes + completion_bytes))
    # Syncthing's GUI includes pending deletions in "Out of Sync Items".
    remote_need_items=$((remote_need_items + completion_items + completion_deletes))
  done < <(
    jq -r +      '.connections | to_entries[] | select(.value.connected == true) | .key' +      <<<"$connections"
  )

  if ((remote_global_bytes > 0)); then
    remote_completion_pct="$(awk -v total="$remote_global_bytes" \
      -v need="$remote_need_bytes" \
      'BEGIN { printf "%.1f", 100 * (total - need) / total }')"
  fi

  read -r in_bytes out_bytes < <(
    jq -r '[.total.inBytesTotal, .total.outBytesTotal] | @tsv' <<<"$connections"
  ) || {
    rm -f -- "$temporary" "$curl_config"
    return 1
  }
  [[ "$in_bytes" =~ ^[0-9]+$ && "$out_bytes" =~ ^[0-9]+$ ]] || {
    rm -f -- "$temporary" "$curl_config"
    return 1
  }
  sample_epoch="$EPOCHSECONDS"

  # Rates are deltas between updates. Counter resets (for example after a
  # Syncthing restart) deliberately produce a zero rate for one sample.
  if [[ -r "$SYNCTHING_STATUS_CACHE" ]]; then
    IFS='|' read -r previous_state _ _ _ _ _ _ _ _ _ _ \
      previous_epoch previous_in previous_out _ _ <"$SYNCTHING_STATUS_CACHE" || true
    if [[ "$previous_state" == online &&
          "$previous_epoch" =~ ^[0-9]+$ &&
          "$previous_in" =~ ^[0-9]+$ &&
          "$previous_out" =~ ^[0-9]+$ &&
          "$in_bytes" -ge "$previous_in" &&
          "$out_bytes" -ge "$previous_out" ]]; then
      elapsed=$((sample_epoch - previous_epoch))
      if ((elapsed > 0)); then
        download_rate=$(((in_bytes - previous_in) / elapsed))
        upload_rate=$(((out_bytes - previous_out) / elapsed))
      fi
    fi
  fi

  while IFS= read -r folder; do
    errors_json="$(curl -fsS --config "$curl_config" \
      "$base_url/rest/folder/errors?folder=$folder")" || {
      rm -f -- "$temporary" "$curl_config"
      return 1
    }
    error_count=$((error_count + $(jq '.errors | length' <<<"$errors_json")))
  done < <(jq -r '.[].id' <<<"$folders")

  last_scan="$(jq -r '[.[] | .lastScan // empty] | max // empty' \
    <<<"$statistics")"
  IFS=$'\t' read -r last_file_time last_folder_id < <(
    jq -r '
      [to_entries[] |
        select(.value.lastFile.at? != null) |
        {at: .value.lastFile.at, folder: .key}
      ] | sort_by(.at) | last // {} | [.at // "", .folder // ""] | @tsv
    ' <<<"$statistics"
  )

  [[ -z "$last_scan" ]] || last_scan_epoch="$(date -d "$last_scan" +%s)" ||
    last_scan_epoch=0
  [[ -z "$last_file_time" ]] || last_file_epoch="$(date -d "$last_file_time" +%s)" ||
    last_file_epoch=0
  last_folder="$(jq -r --arg id "$last_folder_id" \
    '.[] | select(.id == $id) | if (.label // "") == "" then .id else .label end' \
    <<<"$folders")"
  last_folder="${last_folder//$'\n'/ }"
  last_folder="${last_folder//|//}"
  last_folder="${last_folder:0:40}"
  last_folder="${last_folder//&/\&amp;}"
  last_folder="${last_folder//</\&lt;}"
  last_folder="${last_folder//>/\&gt;}"

  rm -f -- "$curl_config"

  [[ "$connected" =~ ^[0-9]+$ &&
     "$total" =~ ^[0-9]+$ &&
     "$paused" =~ ^[0-9]+$ &&
     "$completion_pct" =~ ^[0-9]+([.][0-9]+)?$ &&
     "$need_bytes" =~ ^[0-9]+$ &&
     "$need_items" =~ ^[0-9]+$ &&
     "$error_count" =~ ^[0-9]+$ ]] || {
    rm -f -- "$temporary"
    return 1
  }

  printf 'online|%d|%d|%d|%.1f|%d|%d|%d|%d|%d|%s|%d|%d|%d|%d|%d|%.1f|%d|%d\n' \
    "$connected" "$total" "$paused" "$completion_pct" "$need_bytes" \
    "$need_items" "$error_count" "$last_scan_epoch" "$last_file_epoch" \
    "$last_folder" "$sample_epoch" "$in_bytes" "$out_bytes" \
    "$download_rate" "$upload_rate" "$remote_completion_pct" \
    "$remote_need_bytes" "$remote_need_items" >"$temporary" &&
    mv -f -- "$temporary" "$SYNCTHING_STATUS_CACHE"
}


# Format a nonnegative byte count as a compact binary-unit value.
#
# Arguments:
#   $1 - Byte count as a nonnegative integer.
# Output: bytes, KiB, MiB, or GiB abbreviated as B, K, M, or G. MiB and GiB
# values include one decimal place; KiB values are whole numbers.
# Returns: the status of printf.
syncthing_format_bytes() {
  local bytes="$1"

  if ((bytes >= 1073741824)); then
    printf '%d.%dG' "$((bytes / 1073741824))" \
      "$((bytes % 1073741824 * 10 / 1073741824))"
  elif ((bytes >= 1048576)); then
    printf '%d.%dM' "$((bytes / 1048576))" \
      "$((bytes % 1048576 * 10 / 1048576))"
  elif ((bytes >= 1024)); then
    printf '%dK' "$((bytes / 1024))"
  else
    printf '%dB' "$bytes"
  fi
}


# Format an epoch timestamp as a compact age relative to the current time.
#
# Arguments:
#   $1 - Unix timestamp in seconds.
# Output: a nonnegative whole-number age suffixed with s, m, h, or d.
# Returns: the status of printf.
syncthing_format_age() {
  local timestamp="$1"
  local age=$((EPOCHSECONDS - timestamp))

  ((age < 0)) && age=0
  if ((age < 60)); then
    printf '%ds' "$age"
  elif ((age < 3600)); then
    printf '%dm' "$((age / 60))"
  elif ((age < 86400)); then
    printf '%dh' "$((age / 3600))"
  else
    printf '%dd' "$((age / 86400))"
  fi
}


# Test whether the cache reports outstanding work on any remote device.
#
# Arguments: none.
# Output: none.
# Returns: zero when aggregate remote out-of-sync items are positive; nonzero
# when the cache is absent, malformed, or reports no pending remote items.
syncthing_remote_work_pending() {
  local remote_need_items

  [[ -r "$SYNCTHING_STATUS_CACHE" ]] || return 1
  IFS='|' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ \
    remote_need_items <"$SYNCTHING_STATUS_CACHE" || return 1
  [[ "$remote_need_items" =~ ^[1-9][0-9]*$ ]]
}


# Ensure a periodic background updater runs while remote work is pending.
#
# Reaps a completed monitor, avoids starting duplicates, and starts a new
# subshell only when the current cache reports remote out-of-sync items. The
# monitor stops itself when the remote count reaches zero. Refresh frequency is
# controlled by SYNCTHING_MONITOR_INTERVAL and defaults to four seconds.
#
# Arguments: none.
# Output: none, except diagnostics inherited from update__syncthing.
# Side effects: may start a background process and set SYNCTHING_MONITOR_PID.
# Returns: zero.
maintain_syncthing_monitor() {
  [[ "$SYNCTHING_MONITOR_INTERVAL" =~ ^[1-9][0-9]*$ ]] || \
    SYNCTHING_MONITOR_INTERVAL=4

  if [[ -n "$SYNCTHING_MONITOR_PID" ]]; then
    if kill -0 "$SYNCTHING_MONITOR_PID" 2>/dev/null; then
      return 0
    fi
    wait "$SYNCTHING_MONITOR_PID" 2>/dev/null || true
    SYNCTHING_MONITOR_PID=""
  fi

  syncthing_remote_work_pending || return 0

  (
    while syncthing_remote_work_pending; do
      update__syncthing || true
      syncthing_remote_work_pending || break
      sleep "$SYNCTHING_MONITOR_INTERVAL"
    done
  ) &
  SYNCTHING_MONITOR_PID=$!
}


# Stop and reap the background Syncthing updater, if one is running.
#
# Arguments: none.
# Output: none.
# Side effects: sends SIGTERM to SYNCTHING_MONITOR_PID, waits for it, and clears
# the stored PID. Intended for the ticker process's EXIT trap.
# Returns: zero, including when no monitor exists.
stop_syncthing_monitor() {
  [[ -n "$SYNCTHING_MONITOR_PID" ]] || return 0
  kill "$SYNCTHING_MONITOR_PID" 2>/dev/null || true
  wait "$SYNCTHING_MONITOR_PID" 2>/dev/null || true
  SYNCTHING_MONITOR_PID=""
}


# Render the cached Syncthing state as compact Pango markup for the ticker.
#
# Shows device connectivity and conditionally adds paused devices, local or
# remote completion, human-readable remaining bytes/items, transfer rates,
# errors, and recent folder activity. Invalid optional rate/remote fields fall
# back safely, which keeps older cache records readable.
#
# Ticker format:
#   ST:<connected>/<total> [P:<paused>]
#     [<local-completion>% <remaining-bytes>/<remaining-items>]
#     [·remote <completion>% <remaining-bytes>/<out-of-sync-items>]
#     [↓<download-rate>/s ↑<upload-rate>/s] [E:<errors>]
#     [·last:<folder> <age>] [scan:<age>]
#
# Optional fields are omitted when inactive. The remote item count includes
# pending deletions to match Syncthing's GUI. Download and upload arrows denote
# aggregate connection traffic. The entire result is wrapped in a green,
# yellow, or red Pango span according to health.
#
# Example:
#   <span foreground="#ffd75f">ST:1/1·remote 38.6% 2.0G/4568
#   ↓1.0K/s ↑1.0M/s·last:Dropbox 3s scan:30s</span>
#
# Arguments: none.
# Output: one Pango span on standard output, or nothing when no cache exists.
# Returns: zero for a rendered/absent status; nonzero for malformed required
# cache fields.
syncthing_status() {
  local state connected total paused completion need_bytes need_items errors
  local last_scan_epoch last_file_epoch last_folder
  local sample_epoch in_bytes out_bytes download_rate upload_rate
  local remote_completion remote_need_bytes remote_need_items
  local color="#3cb371"
  local suffix=""

  [[ -r "$SYNCTHING_STATUS_CACHE" ]] || return 0
  IFS='|' read -r state connected total paused completion need_bytes need_items \
    errors last_scan_epoch last_file_epoch last_folder sample_epoch in_bytes \
    out_bytes download_rate upload_rate remote_completion remote_need_bytes \
    remote_need_items <"$SYNCTHING_STATUS_CACHE" || return 1

  if [[ "$state" == "offline" ]]; then
    printf '<span foreground="#ff5f5f">ST:offline</span>'
    return 0
  fi

  [[ "$connected" =~ ^[0-9]+$ &&
     "$total" =~ ^[0-9]+$ &&
     "$paused" =~ ^[0-9]+$ &&
     "$completion" =~ ^[0-9]+([.][0-9]+)?$ &&
     "$need_bytes" =~ ^[0-9]+$ &&
     "$need_items" =~ ^[0-9]+$ &&
     "$errors" =~ ^[0-9]+$ ]] || return 1

  [[ "$download_rate" =~ ^[0-9]+$ ]] || download_rate=0
  [[ "$upload_rate" =~ ^[0-9]+$ ]] || upload_rate=0
  [[ "$remote_completion" =~ ^[0-9]+([.][0-9]+)?$ ]] || remote_completion=100.0
  [[ "$remote_need_bytes" =~ ^[0-9]+$ ]] || remote_need_bytes=0
  [[ "$remote_need_items" =~ ^[0-9]+$ ]] || remote_need_items=0

  if ((errors > 0)); then
    color="#ff5f5f"
  elif ((connected < total || paused > 0 || need_items > 0 || remote_need_items > 0)); then
    color="#ffd75f"
  fi

  ((paused > 0)) && printf -v suffix ' P:%d' "$paused"
  if ((need_items > 0)); then
    suffix+=" ${completion}% $(syncthing_format_bytes "$need_bytes")/$need_items"
  fi
  if ((remote_need_items > 0)); then
    suffix+="·remote:${remote_completion}%"
    suffix+=" $(syncthing_format_bytes "$remote_need_bytes")/$remote_need_items"
  fi
  if ((download_rate > 0 || upload_rate > 0)); then
    suffix+=" ↓$(syncthing_format_bytes "$download_rate")/s"
    suffix+=" ↑$(syncthing_format_bytes "$upload_rate")/s"
  fi
  ((errors > 0)) && suffix+=" E:$errors"
  if [[ "$last_file_epoch" =~ ^[1-9][0-9]*$ && -n "$last_folder" ]]; then
    suffix+="·last:$last_folder $(syncthing_format_age "$last_file_epoch")"
  fi
  if [[ "$last_scan_epoch" =~ ^[1-9][0-9]*$ ]]; then
    suffix+=" scan:$(syncthing_format_age "$last_scan_epoch")"
  fi

  printf '<span foreground="%s">ST:%d/%d%s</span>' \
    "$color" "$connected" "$total" "$suffix"
}
