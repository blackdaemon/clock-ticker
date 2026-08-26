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

# Available-memory thresholds are percentages of total host RAM. On the
# maintainer's 32 GiB workstation, 25% leaves about 8 GiB and 12% leaves about
# 4 GiB, providing warning and critical headroom before heavy reclaim or
# out-of-memory conditions. These percentages scale automatically with host
# RAM. To target a specific amount on another system, use:
#
#   percentage = desired available GiB * 100 / total RAM GiB
#
# For example, thresholds of 25 and 12 on a 16 GiB host warn near 4 GiB and
# become critical near 2 GiB. Raise them for memory-hungry workloads that need
# more spare RAM; lower them when a small system normally operates with less.
readonly MEMORY_AVAILABLE_WARNING_PERCENT=25
readonly MEMORY_AVAILABLE_CRITICAL_PERCENT=12

# Swap use is a secondary warning rather than a critical condition by itself:
# Linux may keep inactive pages in swap after memory pressure has passed. A
# half-full swap area is highlighted only when available RAM is low or PSI
# reports pressure. Raise it if normal workloads retain substantial swapped
# data, or lower it when swap space is small.
readonly MEMORY_SWAP_WARNING_PERCENT=50

# PSI measures the recent percentage of time processes were stalled by memory
# pressure. A 2% avg10 value indicates noticeable contention; 10% indicates
# sustained pressure. These values describe workload impact rather than RAM
# capacity, so they normally do not need scaling for different memory sizes.
# Increase them to reduce alerts for intentionally memory-intensive workloads,
# or decrease them when short stalls matter.
readonly MEMORY_PRESSURE_WARNING_PERCENT=2
readonly MEMORY_PRESSURE_CRITICAL_PERCENT=10

# VM thresholds apply to the combined resident memory of all qemu-system
# processes. The 5 GiB warning and 6 GiB critical defaults allow overhead above
# one roughly 4 GiB guest. Set them above the expected aggregate guest memory
# plus QEMU overhead; increase them for more or larger guests and decrease them
# for a smaller VM setup.
readonly VM_MEMORY_WARNING_KIB=$((5 * 1024 * 1024))
readonly VM_MEMORY_CRITICAL_KIB=$((6 * 1024 * 1024))


top_memory_process() {
    local rss_kib process memory_gib

    read -r rss_kib process < <(
        ps -eo rss=,comm= --sort=-rss | head -n 1
    )

    memory_gib=$(awk -v kib="$rss_kib" \
        'BEGIN { printf "%.1f", kib / 1024 / 1024 }')

    printf 'top:%s %sG' "$process" "$memory_gib"
}


memory_status() {
  # The most useful indicators are:
  #
  # - Available RAM, not “used RAM.”
  # - Memory pressure (PSI), which detects actual stalls/thrashing.
  # - Swap usage, as a secondary warning.
  #
  # Healthy state:
  #
  #   M:18.2G  S:11%
  #
  # When pressure develops:
  #
  #   ⚠ M:5.1G S:34% P:8%
  #
  # Critical:
  #
  #   ‼ M:2.0G S:71% P:42%
  #
  #   Where:
  #
  #   M = genuinely available RAM
  #   S = total swap utilization
  #   P = percentage of recent time in which processes were stalled waiting for memory
  #
  #   Suggested thresholds for 32 GiB system:
  #     Status  Available RAM  Memory PSI (some avg10)
  #     Green   ≥ 8 GiB        < 2%
  #     Yellow  4–8 GiB        2–10%
  #     Red     < 4 GiB        ≥ 10%
  #
  #   PSI should override the RAM threshold. For example, 7 GiB available with 20% pressure should still be red.
  #
  #   Swap alone should not trigger red because Linux can leave old pages in swap after the pressure has ended.
  #
  #     below 50%: normal
  #     50–80%: yellow
  #     above 80%: red only if available RAM is also low or PSI is elevated

    local mem_total mem_available swap_total swap_free
    local mem_pct swap_pct psi mem_gib
    local color="#7fc97f"
    local symbol=""
    local status='green'

    mem_total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    mem_available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/ { print $2 }' /proc/meminfo)

    psi=$(awk '
        /^some / {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^avg10=/) {
                    sub(/^avg10=/, "", $i)
                    print $i
                    exit
                }
            }
        }
    ' /proc/pressure/memory)

    mem_pct=$((mem_available * 100 / mem_total))

    if (( swap_total > 0 )); then
        swap_pct=$(((swap_total - swap_free) * 100 / swap_total))
    else
        swap_pct=0
    fi

    mem_gib=$(awk -v kb="$mem_available" \
        'BEGIN { printf "%.1f", kb / 1024 / 1024 }')

    # For testing the yellow and red output, call this with 'red' or 'yellow' parameter
    case "${1:-}" in
      yellow)
        mem_pct=20
        mem_gib=6.4
        swap_pct=55
        psi=5.0
        ;;
      red)
        mem_pct=8
        mem_gib=2.6
        swap_pct=90
        psi=25.0
        ;;
    esac

    # High swap alone is normal after earlier pressure: Linux does not eagerly
    # move inactive pages back to RAM. Alert on it only while RAM is low or
    # there is current memory pressure.
    if (( mem_pct < MEMORY_AVAILABLE_WARNING_PERCENT )) ||
       awk -v value="$psi" -v threshold="$MEMORY_PRESSURE_WARNING_PERCENT" \
         'BEGIN { exit !(value >= threshold) }' ||
       (( swap_pct >= MEMORY_SWAP_WARNING_PERCENT )) &&
       { (( mem_pct < MEMORY_AVAILABLE_WARNING_PERCENT )) ||
         awk -v value="$psi" 'BEGIN { exit !(value > 0) }'; }
    then
        color="#ffd75f"
        symbol="⚠ "
        status='yellow'
    fi

    if (( mem_pct < MEMORY_AVAILABLE_CRITICAL_PERCENT )) ||
       awk -v value="$psi" -v threshold="$MEMORY_PRESSURE_CRITICAL_PERCENT" \
         'BEGIN { exit !(value >= threshold) }'
    then
        color="#ff5f5f"
        symbol="‼ "
        symbol="⚠ "
        status='red'
    fi

    printf '<span foreground="%s">%sM:%sG S:%d%%' \
        "$color" "$symbol" "$mem_gib" "$swap_pct"

    if awk -v value="$psi" -v threshold="$MEMORY_PRESSURE_WARNING_PERCENT" \
        'BEGIN { exit !(value >= threshold) }'; then
        printf ' P:%.1f%%' "$psi"
    fi

    if [[ "$status" != "green" ]]; then
      printf ' %s' "$(top_memory_process)"
    fi

    printf '</span>'
}


vm_status() {
    local rss_kib memory_gib
    local color="#3cb371"

    rss_kib=$(
        ps -eo comm=,rss= |
            awk '$1 ~ /^qemu-system/ { total += $2 }
                 END { print total + 0 }'
    )

    (( rss_kib > 0 )) || return 0

    memory_gib=$(awk -v kib="$rss_kib" \
        'BEGIN { printf "%.1f", kib / 1024 / 1024 }')

    if (( rss_kib >= VM_MEMORY_CRITICAL_KIB )); then
        color="#ff5f5f"
    elif (( rss_kib >= VM_MEMORY_WARNING_KIB )); then
        color="#ffd75f"
    fi

    printf '<span foreground="%s">VM:%sG</span>' \
        "$color" "$memory_gib"
}
