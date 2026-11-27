#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

unit=nonapicloud.service
unit_path=/etc/systemd/system/$unit
app_dir=/opt/nonapicloud

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

(( $# == 0 )) || fail "Run sudo bash nonapicloud_uninstall.sh without arguments."
[[ $(uname -s) == Linux ]] || fail "This uninstaller requires Linux."
[[ $EUID == 0 ]] || fail "Run this uninstaller with sudo or as root."
for tool in systemctl pgrep ps rm; do
    command -v "$tool" >/dev/null || fail "Required command $tool is missing."
done
[[ -d /run/systemd/system ]] && systemctl show --property=Version >/dev/null ||
    fail "A running systemd system manager is required."
[[ ! -L $app_dir ]] || fail "Installation directory $app_dir is a symbolic link."
[[ ! -e $app_dir || -d $app_dir ]] || fail "Installation path $app_dir must be a directory."

running_pids() {
    local matches pid state result
    if matches=$(pgrep -x nonapicloud); then
        for pid in $matches; do
            if state=$(ps -o state= -p "$pid" 2>/dev/null) && [[ $state != *Z* && $state != *X* ]]; then
                printf '%s\n' "$pid"
            fi
        done
    else
        result=$?
        [[ $result == 1 ]] || return "$result"
    fi
}

unit_running() {
    local state
    state=$(systemctl show --property=ActiveState "$unit" 2>/dev/null) || return 1
    case $state in
        ActiveState=active|ActiveState=activating|ActiveState=deactivating|ActiveState=reloading) return 0 ;;
        *) return 1 ;;
    esac
}

pids=$(running_pids) || fail "Could not inspect running copier processes."
if [[ -n $pids ]] || unit_running; then
    printf 'Stop the current running instance...\n'
    stop_deadline=$((SECONDS + 15))
    if unit_running; then
        systemctl stop --no-block "$unit" || fail "Could not stop $unit."
    fi
    for pid in $pids; do
        if [[ -r /proc/$pid/comm ]] && [[ $(cat "/proc/$pid/comm" 2>/dev/null) == nonapicloud ]]; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    while true; do
        pids=$(running_pids) || fail "Could not inspect running copier processes."
        if [[ -z $pids ]] && ! unit_running; then
            break
        fi
        (( SECONDS < stop_deadline )) || fail "The copier is still running after 15 seconds. Uninstall aborted."
        sleep 1
    done
fi

if [[ -e $unit_path || -L $unit_path ]]; then
    systemctl disable "$unit" || fail "Could not disable $unit."
    rm -f -- "$unit_path"
    systemctl daemon-reload
fi

rm -rf -- "$app_dir" || fail "Could not remove $app_dir."
printf 'Uninstalled Nonapi Cloud Copier.\n'
