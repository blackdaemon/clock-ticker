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

readonly FEDORA_STATUS_CACHE="$RAM_DISK/.fedora_updates.txt"


# Special help print function called from main module clock_ticker update <module_name> --help
help__fedora_status() {
  cat <<EOF
Usage:
    clock_ticker update fedora_status

Refreshes the cached number of available Fedora package updates.

The result is stored in:
    $RAM_DISK/.fedora_updates
EOF
}


# Special update function called from main module clock_ticker update <module_name>
update__fedora_status() {
    local cache=$FEDORA_STATUS_CACHE
    local dnf_command temporary packages update_count
    local reboot_required=0
    local result

    if command -v dnf5 >/dev/null 2>&1; then
        dnf_command=dnf5
    elif command -v dnf >/dev/null 2>&1; then
        dnf_command=dnf
    else
        printf 'Neither dnf5 nor dnf is available.\n' >&2
        return 1
    fi

    packages="$(
        "$dnf_command" --quiet --refresh repoquery \
            --upgrades \
            --queryformat '%{name}\n' 2>/dev/null
    )" || return 1

    printf '%s\n\n' "$packages" >&2

    update_count=$(
        printf '%s\n' "$packages" |
            sed '/^[[:space:]]*$/d' |
            sort -u |
            wc -l
    )

    printf '%d packages to update\n\n' "$update_count" >&2

    "$dnf_command" needs-restarting -r >/dev/null 2>&1
    result=$?

    case "$result" in
        0) ;;
        1) reboot_required=1 ;;
        *)
            printf '%s needs-restarting failed with exit status %d.\n' \
                "$dnf_command" "$result" >&2
            return 1
            ;;
    esac

    printf 'Reboot required: %d\n' "$reboot_required" >&2

    temporary=$(mktemp "${cache}.XXXXXX") || return 1

    printf '%d|%d\n' \
        "$update_count" "$reboot_required" | tee "$temporary"

    mv -f "$temporary" "$cache"
}


fedora_status() {
    local cache=$FEDORA_STATUS_CACHE
    local update_count reboot_required
    local output=""

    [[ -r "$cache" ]] || return 0

    IFS='|' read -r update_count reboot_required <"$cache" ||
        return 1

    if (( update_count > 0 )); then
        output='<span foreground="#ffd75f">UPD:'"$update_count"'</span>'
    fi

    if (( reboot_required == 1 )); then
        [[ -z "$output" ]] || output+=" "
        output+='<span foreground="#ff5f5f">↻reboot</span>'
    fi

    printf '%s' "$output"
}
