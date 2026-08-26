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


battery_status() {
    local bat status capacity now rate
    local total_minutes hours minutes
    local color="#3cb371" symbol=""

    for bat in /sys/class/power_supply/BAT*; do
        [[ -r "$bat/status" ]] || continue

        read -r status <"$bat/status"
        [[ "$status" == "Discharging" ]] || return 0

        read -r capacity <"$bat/capacity"

        if (( capacity < 10 )); then
            color="#ff5f5f"
            symbol="‼ "
        elif (( capacity < 25 )); then
            color="#ffd75f"
            symbol="⚠ "
        fi

        if [[ -r "$bat/energy_now" && -r "$bat/power_now" ]]; then
            read -r now <"$bat/energy_now"
            read -r rate <"$bat/power_now"
        elif [[ -r "$bat/charge_now" && -r "$bat/current_now" ]]; then
            read -r now <"$bat/charge_now"
            read -r rate <"$bat/current_now"
        fi

        if [[ "$now" =~ ^[0-9]+$ &&
              "$rate" =~ ^[0-9]+$ ]] &&
           (( rate > 0 )); then
            total_minutes=$((now * 60 / rate))
            hours=$((total_minutes / 60))
            minutes=$((total_minutes % 60))

            printf '<span foreground="%s">%sBAT:%d%% %d:%02d</span>' \
                "$color" "$symbol" "$capacity" "$hours" "$minutes"
        else
            printf '<span foreground="%s">%sBAT:%d%%</span>' \
                "$color" "$symbol" "$capacity"
        fi

        return
    done
}
