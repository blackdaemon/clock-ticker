#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:
#
# clock.sh
# Copyright (C) 2026 Pavel Vitis <pavelvitis@gmail.com>
#
# Distributed under terms of the MIT license.
#

# This live module reports the highest readable CPU package temperature as
# trusted Pango markup. It reads millidegrees Celsius from matching thermal
# zones under /sys/class/thermal and remains silent when no matching sensor is
# available or the temperature is below 75 °C.
#
# Display thresholds:
#   75–79 °C: green; 80–89 °C: yellow; 90 °C and above: red.
# Call cpu_temperature_status with "yellow" or "red" to exercise those states.

# saner programming env: these switches turn some bugs into errors
#set -o errexit -o pipefail -o noclobber -o nounset


cpu_temperature_status() {
    local zone type temperature
    local highest=0
    local color symbol=""

    for zone in /sys/class/thermal/thermal_zone*; do
        [[ -r "$zone/type" && -r "$zone/temp" ]] || continue

        read -r type <"$zone/type"
        read -r temperature <"$zone/temp"

        [[ "$temperature" =~ ^[0-9]+$ ]] || continue

        case "$type" in
            x86_pkg_temp | cpu-thermal | cpu_thermal | package-*)
                (( temperature > highest )) && highest=$temperature
                ;;
        esac
    done

    # For testing the yellow and red output, call this with 'red' or 'yellow' parameter
    case "${1:-}" in
      yellow)
        highest=85000
        ;;
      red)
        highest=95000
        ;;
    esac

    (( highest > 0 )) || return 0

    local degrees=$((highest / 1000))

    # Remain invisible under 75 °C.
    (( degrees >= 75 )) || return 0

    if (( degrees >= 90 )); then
        color="#ff5f5f"
        symbol="‼ "
        symbol="⚠ "
    elif (( degrees >= 80 )); then
        color="#ffd75f"
        symbol="⚠ "
    else
        color="#3cb371"
    fi

    printf '<span foreground="%s">%sT:%d°</span>' \
        "$color" "$symbol" "$degrees"
}
