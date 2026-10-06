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

readonly SYSTEM_PROC_ROOT="${SYSTEM_PROC_ROOT:-/proc}"


# Identify the script or module executed by a Python process.
#
# Only the Python invocation target is inspected; subsequent command-line
# arguments are ignored because they may contain secrets. Packaged scripts
# include their RPM package name; unpackaged scripts below /opt/OWNER or
# /var/opt/OWNER fall back to OWNER for application context.
#
# Arguments:
#   $1 - Process ID.
# Output: a compact workload label, or nothing when no safe target is found.
# Returns: zero when a label is printed; nonzero otherwise.
python_workload_label() {
    local pid="$1"
    local argument script owner workload index
    local -a arguments

    [[ -r "$SYSTEM_PROC_ROOT/$pid/cmdline" ]] || return 1
    mapfile -d '' -t arguments <"$SYSTEM_PROC_ROOT/$pid/cmdline" || return 1

    for ((index = 1; index < ${#arguments[@]}; index++)); do
        argument="${arguments[index]}"
        case "$argument" in
            -m)
                ((++index < ${#arguments[@]})) || return 1
                printf '%s' "${arguments[index]}"
                return 0
                ;;
            -c)
                return 1
                ;;
            -W | -X)
                ((index++))
                ;;
            --)
                ((++index < ${#arguments[@]})) || return 1
                script="${arguments[index]}"
                break
                ;;
            -*)
                ;;
            *)
                script="$argument"
                break
                ;;
        esac
    done

    [[ -n "$script" ]] || return 1
    workload="${script##*/}"
    workload="${workload%.py}"

    if command -v rpm >/dev/null; then
        owner="$(rpm -qf --qf '%{NAME}\n' -- "$script" 2>/dev/null)" ||
            owner=""
    fi

    if [[ -z "$owner" ]]; then
        case "$script" in
            /opt/*/*)
                owner="${script#/opt/}"
                owner="${owner%%/*}"
                ;;
            /var/opt/*/*)
                owner="${script#/var/opt/}"
                owner="${owner%%/*}"
                ;;
        esac
    fi

    if [[ -n "$owner" && "$owner" != "$workload" ]]; then
        printf '%s/%s' "$owner" "$workload"
    else
        printf '%s' "$workload"
    fi
}


# Print the process with the highest reported CPU utilization.
#
# Arguments: none.
# Output: a compact, Pango-safe process identity and CPU percentage, or nothing
# when process information is unavailable. The identity includes its systemd
# service or scope when available.
# Returns: zero when a process is printed; nonzero otherwise.
top_cpu_process() {
    local cpu_percent pid process cgroup_path component owner=""
    local -a cgroup_components

    read -r cpu_percent pid process < <(
        ps -eo pcpu=,pid=,comm= --sort=-pcpu | head -n 1
    ) || return 1
    [[ -n "$cpu_percent" && "$pid" =~ ^[0-9]+$ && -n "$process" ]] ||
        return 1

    # The executable name alone is often just an interpreter such as python3.
    # A systemd service or scope from the process cgroup identifies the owning
    # application without exposing its complete command line.
    if [[ -r "$SYSTEM_PROC_ROOT/$pid/cgroup" ]]; then
        while IFS=: read -r _ _ cgroup_path; do
            IFS=/ read -ra cgroup_components <<<"$cgroup_path"
            for component in "${cgroup_components[@]}"; do
                case "$component" in
                    *.service)
                        owner="${component%.service}"
                        ;;
                    *.scope)
                        owner="${component%.scope}"
                        ;;
                esac
            done
        done <"$SYSTEM_PROC_ROOT/$pid/cgroup"
    fi

    if [[ -n "$owner" && "$owner" != "$process" ]]; then
        process="$owner/$process"
    elif [[ "$process" == python || "$process" == python[0-9]* ]]; then
        process="$(python_workload_label "$pid")" || process="$process"
    fi

    process="${process//&/\&amp;}"
    process="${process//</\&lt;}"
    process="${process//>/\&gt;}"

    printf 'top:%s %s%%' "$process" "$cpu_percent"
}


cpu_temperature_status() {
    local zone type temperature
    local highest=0
    local color symbol=""
    local top_process=""

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
        top_process="$(top_cpu_process)" || true
    elif (( degrees >= 80 )); then
        color="#ffd75f"
        symbol="⚠ "
    else
        color="#3cb371"
    fi

    printf '<span foreground="%s">%sT:%d°' \
        "$color" "$symbol" "$degrees"
    [[ -z "$top_process" ]] || printf ' %s' "$top_process"
    printf '</span>'
}
