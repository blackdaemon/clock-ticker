#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:
#
# clock.sh
# Copyright (C) 2026 Pavel Vitis <pavelvitis@gmail.com>
#
# Distributed under terms of the MIT license.


#
# Shows recent swap input and output activity. Normal activity is highlighted;
# very heavy swapping is shown as critical.
#

# Saner programming env: these switches turn some bugs into errors
#set -o errexit -o pipefail -o noclobber -o nounset


swap_io_status() {
    local cache="$RAM_DISK/.swap_io.txt"
    local hold_cache="$RAM_DISK/.swap_io_hold.txt"
    local hold_seconds=4

    local timestamp pages_in pages_out
    local previous_timestamp previous_in previous_out
    local elapsed page_kib
    local in_kib out_kib
    local in_text out_text
    local color="#ffd75f"

    local hold_until held_value

    timestamp="${EPOCHREALTIME/./}"
    timestamp="${timestamp:0:13}"

    read -r pages_in pages_out < <(
        awk '
            /^pswpin /  { pages_in = $2 }
            /^pswpout / { pages_out = $2 }
            END { print pages_in, pages_out }
        ' /proc/vmstat
    )

    # First sample: just initialize the sampling cache.
    if [[ ! -r "$cache" ]] ||
       ! read -r previous_timestamp previous_in previous_out <"$cache"; then

        printf '%s %s %s\n' \
            "$timestamp" "$pages_in" "$pages_out" >"$cache"

        # Still show an existing held value, if one exists.
        if [[ -r "$hold_cache" ]] &&
           IFS='|' read -r hold_until held_value <"$hold_cache" &&
           (( timestamp < hold_until )); then
            printf '%s' "$held_value"
        fi

        return 0
    fi

    # Save current counters for the next call.
    printf '%s %s %s\n' \
        "$timestamp" "$pages_in" "$pages_out" >"$cache"

    elapsed=$((timestamp - previous_timestamp))

    if (( elapsed > 0 &&
          pages_in >= previous_in &&
          pages_out >= previous_out )); then

        page_kib=$(($(getconf PAGESIZE) / 1024))

        in_kib=$(((pages_in - previous_in) * page_kib / elapsed))
        out_kib=$(((pages_out - previous_out) * page_kib / elapsed))

        if (( in_kib >= 256 || out_kib >= 256 )); then

            if (( in_kib >= 10240 || out_kib >= 10240 )); then
                color="#ff5f5f"
            fi

            if (( in_kib >= 1024 )); then
                printf -v in_text '%d.%dM/s' \
                    $((in_kib / 1024)) \
                    $(((in_kib % 1024) * 10 / 1024))
            else
                printf -v in_text '%dK/s' "$in_kib"
            fi

            if (( out_kib >= 1024 )); then
                printf -v out_text '%d.%dM/s' \
                    $((out_kib / 1024)) \
                    $(((out_kib % 1024) * 10 / 1024))
            else
                printf -v out_text '%dK/s' "$out_kib"
            fi

            printf -v held_value \
                '<span foreground="%s">↓SI:%s ↑SO:%s</span>' \
                "$color" "$in_text" "$out_text"

            hold_until=$((timestamp + hold_seconds))

            printf '%s|%s\n' \
                "$hold_until" "$held_value" >"$hold_cache"

            printf '%s' "$held_value"
            return 0
        fi
    fi

    # No new swap activity, but keep showing the last value
    # until its hold period expires.
    if [[ -r "$hold_cache" ]] &&
       IFS='|' read -r hold_until held_value <"$hold_cache"; then

        if (( timestamp < hold_until )); then
            printf '%s' "$held_value"
        else
            rm -f "$hold_cache"
        fi
    fi
}
