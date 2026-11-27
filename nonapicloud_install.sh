#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

service_user=nonapicloud
unit=nonapicloud.service
app_dir=/opt/nonapicloud
unit_dir=/etc/systemd/system
user_agent=Mozilla/5.0

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail "This installer requires Linux x86-64."
[[ $EUID == 0 ]] || fail "Run this installer with sudo or as root."
for tool in curl head stat od grep systemctl pgrep ps getent groupadd useradd runuser install chown mktemp mv nologin; do
    command -v "$tool" >/dev/null || fail "Required command $tool is missing."
done
[[ -d /run/systemd/system ]] && systemctl show --property=Version >/dev/null ||
    fail "A running systemd system manager is required."

read -r _ systemd_version _ < <(systemctl --version)
unit_type=simple
if [[ $systemd_version =~ ^[0-9]+$ ]] && (( systemd_version >= 240 )); then
    unit_type=exec
fi

ambient_setting=
minimum_port=1
default_port=443
if grep -q '^CapAmb:' /proc/self/status &&
    [[ $(systemctl show --all --property=AmbientCapabilities systemd-journald.service 2>/dev/null) == AmbientCapabilities=* ]]; then
    ambient_setting=AmbientCapabilities=CAP_NET_BIND_SERVICE
else
    minimum_port=1024
    if [[ -r /proc/sys/net/ipv4/ip_unprivileged_port_start ]]; then
        read -r first_unprivileged_port < /proc/sys/net/ipv4/ip_unprivileged_port_start
        minimum_port=$first_unprivileged_port
    fi
    (( minimum_port <= 65535 )) || fail "This system has no HTTPS port available to the service account."
fi

download_file=
cleanup_download() {
    trap '' HUP INT TERM
    local status=$1
    if [[ -n $download_file ]] && ! rm -f -- "$download_file"; then
        (( status != 0 )) || status=1
    fi
    exit "$status"
}
trap 'cleanup_download "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

read_text() {
    printf '%s' "$1" >&2
    if [[ -t 0 && $# == 2 ]]; then
        IFS= read -er -i "$2" input || fail "Input ended."
    else
        IFS= read -r input || fail "Input ended."
    fi
    input=${input#"${input%%[![:space:]]*}"}
    input=${input%"${input##*[![:space:]]}"}
}

printf '=== Nonapi Cloud Copier setup ===\n'
printf '# You can find the license key in your license email.\n'
read_text '> Input license key: '
license_key=$input
[[ $license_key =~ [^[:space:]] && $license_key != *$'\r'* ]] || fail "Enter a license key."

printf '# Set the HTTPS port for the copier.\n# The default port is %s.\n' "$default_port"
if (( minimum_port > default_port )); then
    printf 'This system requires port %s or higher for the unprivileged copier.\n' "$minimum_port"
fi
printf '# Choose an HTTPS port that is free on this server.\n'
while true; do
    read_text 'Input HTTPS port: ' "$default_port"
    port=${input:-$default_port}
    if [[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port >= minimum_port && 10#$port <= 65535 )); then
        port=$((10#$port))
        break
    fi
    printf 'Enter a port from %s to 65535.\n' "$((minimum_port > 1 ? minimum_port : 1))" >&2
done

printf '# Set up admin account for this site.\n'
read_text '> Input admin account ID: '
admin_id=$input
[[ $admin_id =~ [^[:space:]] && $admin_id != *$'\r'* ]] || fail "Enter an admin account ID."
while true; do
    read_text '> Input admin account password: '
    admin_password=$input
    read_text '> Confirm admin account password: '
    if [[ $admin_password != "$input" ]]; then
        printf 'Passwords do not match. Enter both passwords again.\n' >&2
    elif [[ $admin_password =~ [^[:space:]] && $admin_password != *$'\r'* ]]; then
        break
    else
        printf 'Enter a nonblank password on one line.\n' >&2
    fi
done
unset input

request_download_link() {
    local response
    local status_pattern='^[[:space:]]*\{[[:space:]]*"status"[[:space:]]*:[[:space:]]*"(invalid|expired)"[[:space:]]*\}[[:space:]]*$'
    local url_pattern='^[[:space:]]*\{[[:space:]]*"status"[[:space:]]*:[[:space:]]*"ok"[[:space:]]*,[[:space:]]*"url"[[:space:]]*:[[:space:]]*"(https://nonapicopier\.com/\?dl=[A-Za-z0-9_-]+)"[[:space:]]*\}[[:space:]]*$'

    printf 'Requesting an installer download link...\n'
    if ! response=$(printf '%s' "$license_key" |
        curl -q --silent --fail --get --globoff --proto '=https' \
            --connect-timeout 15 --max-time 20 --max-filesize 4096 \
            --user-agent "$user_agent" --data-urlencode 'lic@-' \
            'https://nonapicopier.com/cld/?cmd=dl&prod=nonapicloud'); then
        fail "Could not request an installer download link. Please try again."
    fi

    if [[ $response =~ $url_pattern ]]; then
        download_link=${BASH_REMATCH[1]}
    elif [[ $response =~ $status_pattern ]]; then
        case ${BASH_REMATCH[1]} in
            invalid) fail "The license key is invalid." ;;
            expired) fail "The license has expired." ;;
        esac
    else
        fail "The download server returned an invalid response."
    fi
}

save_linux_download() {
    local destination=$1
    local protocol status reason line key value filename disposition length received
    local limit=$((256 * 1024 * 1024))
    local extended_pattern="(^|;)[[:space:]]*filename\\*[[:space:]]*=[[:space:]]*[^';]*'[^';]*'([^;[:space:]]+)"
    local filename_pattern='(^|;)[[:space:]]*filename[[:space:]]*=[[:space:]]*("([^"]*)"|([^;[:space:]]+))'
    local -a header

    while true; do
        IFS=' ' read -r protocol status reason ||
            fail "Could not read a response from the download server."
        status=${status%$'\r'}
        reason=${reason%$'\r'}
        [[ $protocol == HTTP/* && $status =~ ^[0-9]{3}$ ]] ||
            fail "The download server returned an invalid response."
        disposition=
        length=
        while true; do
            IFS= read -r line || fail "The server sent incomplete response headers."
            line=${line%$'\r'}
            [[ -n $line ]] || break
            key=${line%%:*}
            value=${line#*:}
            case ${key,,} in
                content-disposition) disposition=$value ;;
                content-length) length=$value ;;
            esac
        done
        case $status in
            1??|3??) continue ;;
            200)
                [[ ${reason,,} == 'connection established' ]] && continue
                break
                ;;
            *) fail "Download server returned HTTP $status." ;;
        esac
    done

    if [[ ${disposition,,} =~ $extended_pattern ]]; then
        filename=${BASH_REMATCH[2]}
    elif [[ ${disposition,,} =~ $filename_pattern ]]; then
        filename=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    else
        fail "The server did not return a release filename."
    fi
    [[ $filename != *.exe* ]] ||
        fail "The download server returned a Windows installer. A Linux release is required."
    [[ $filename =~ ^nonapi(cloud|copier)-v[0-9]+\.[0-9]{2}$ ]] ||
        fail "The server did not return a Nonapi Cloud Copier Linux release filename."

    if [[ -n $length ]]; then
        [[ $length =~ ^[[:space:]]*([0-9]{1,9})[[:space:]]*$ ]] ||
            fail "The server reported an invalid download size."
        length=$((10#${BASH_REMATCH[1]}))
        (( length >= 20 && length <= limit )) || fail "The server reported an invalid download size."
    fi

    printf 'Downloading...\n'
    head -c "$((limit + 1))" > "$destination" || fail "Could not save the download."
    received=$(stat -c %s -- "$destination") || fail "Could not verify the download size."
    (( received <= limit )) || fail "The download exceeds the release size limit."
    (( received >= 20 )) || fail "The download is not a Linux x86-64 executable."
    if [[ -n $length && $received != "$length" ]]; then
        fail "The download ended before the full binary was received."
    fi

    IFS=' ' read -r -a header <<< "$(od -An -v -t u1 -N20 -w20 -- "$destination")" ||
        fail "Could not read the downloaded executable."
    [[ ${#header[@]} == 20 && "${header[*]:0:7}" == '127 69 76 70 2 1 1' &&
        ( ${header[16]} == 2 || ${header[16]} == 3 ) && "${header[*]:17:3}" == '0 62 0' ]] ||
        fail "The download is not a Linux x86-64 executable."
}

request_download_link
download_file=$(mktemp -- /tmp/nonapicloud-install.XXXXXXXX)
if ! printf 'url = "%s"\n' "$download_link" |
    curl -q --silent --no-buffer --location --include --globoff --max-redirs 5 \
        --proto '=https' --proto-redir '=https' --connect-timeout 30 --max-time 300 \
        --user-agent "$user_agent" --config - 2>/dev/null |
    save_linux_download "$download_file"; then
    fail "Download aborted."
fi
unset download_link

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
        (( SECONDS < stop_deadline )) || fail "The copier is still running after 15 seconds. Installation aborted."
        sleep 1
    done
fi

printf 'Processing\n'
if ! getent group "$service_user" >/dev/null; then
    groupadd --system "$service_user"
fi
if ! getent passwd "$service_user" >/dev/null; then
    useradd --system --gid "$service_user" --home-dir "$app_dir" --no-create-home \
        --shell "$(command -v nologin)" "$service_user"
fi
[[ $(id -u "$service_user") != 0 ]] || fail "The service account must be unprivileged."

[[ ! -L $app_dir ]] || fail "Installation directory $app_dir is a symbolic link."
if [[ ! -e $app_dir ]]; then
    install -d -m 0750 -o "$service_user" -g "$service_user" -- "$app_dir"
fi
[[ -d $app_dir ]] || fail "Installation path $app_dir must be a directory."
chown -hR -P -- "$service_user:$service_user" "$app_dir"
chmod 0750 -- "$app_dir"

runuser -u "$service_user" -g "$service_user" -- bash -eu -c '
    umask 077
    cd "$1"
    for directory in logs data update; do
        if [[ ! -e $directory && ! -L $directory ]]; then
            mkdir -m 0700 -- "$directory"
        fi
        [[ -d $directory && ! -L $directory ]] ||
            { printf "%s must be a directory inside the copier installation.\n" "$directory" >&2; exit 1; }
        chmod u+rwx -- "$directory"
        [[ -r $directory && -w $directory && -x $directory ]] ||
            { printf "The service account needs read and write access to %s.\n" "$directory" >&2; exit 1; }
    done
    if [[ ! -e act.ini && ! -L act.ini ]]; then
        (set -o noclobber; printf "[USER_ACCOUNT]\r\n\r\n" > act.ini)
    fi
    [[ -f act.ini && ! -L act.ini && -r act.ini ]]
' install-state "$app_dir" || fail "Could not prepare the copier state directory."

app_temp_dir=$(runuser -u "$service_user" -g "$service_user" -- \
    mktemp -d -- "$app_dir/.nonapicloud-install.XXXXXXXX")
write_as_service() {
    local target=$1 mode=$2
    runuser -u "$service_user" -g "$service_user" -- bash -eu -c '
        umask 077
        cat > "$1"
        chmod "$3" "$1"
        mv -fT -- "$1" "$2"
    ' install-file "$app_temp_dir/${target##*/}" "$target" "$mode"
}

csv_field() {
    local field=$1
    if [[ $field == *,* || $field == *\"* ]]; then
        printf '"%s"' "${field//\"/\"\"}"
    else
        printf '%s' "$field"
    fi
}

write_as_service "$app_dir/nonapicloud" 0750 < "$download_file"
{
    printf '[LICENSE]\n\nlicense_key=%s\n\n[SERVER]\n\nport=%s\n\n[ADMIN_ACCOUNT]\n\nadmin_account=' "$license_key" "$port"
    csv_field "$admin_id"
    printf ','
    csv_field "$admin_password"
    printf ',inp\n'
} | write_as_service "$app_dir/app.ini" 0600
unset license_key admin_password
runuser -u "$service_user" -g "$service_user" -- rmdir -- "$app_temp_dir" || true

configure_firewalld() {
    if ! command -v firewall-cmd >/dev/null || ! firewall-cmd --state >/dev/null 2>&1; then
        return 0
    fi

    local https_port=$1 routes zone=
    if command -v ip >/dev/null; then
        routes=$(ip -o -4 route show default 2>/dev/null) || routes=
        if [[ -z $routes ]]; then
            routes=$(ip -o -6 route show default 2>/dev/null) || routes=
        fi
        if [[ $routes =~ [[:space:]]dev[[:space:]]+([^[:space:]]+) ]]; then
            zone=$(firewall-cmd --get-zone-of-interface="${BASH_REMATCH[1]}" 2>/dev/null) || zone=
        fi
    fi
    if [[ ! $zone =~ ^[[:alnum:]_-]+$ ]]; then
        zone=$(firewall-cmd --get-default-zone) || return 1
    fi
    [[ $zone =~ ^[[:alnum:]_-]+$ ]] || return 1

    printf 'Allowing TCP port %s in firewalld zone %s.\n' "$https_port" "$zone"
    firewall-cmd --zone="$zone" --add-port="$https_port/tcp" &&
        firewall-cmd --permanent --zone="$zone" --add-port="$https_port/tcp"
}

unit_temp=$(mktemp -- "$unit_dir/.nonapicloud.XXXXXXXX")
cat > "$unit_temp" <<SYSTEMD
[Unit]
Description=Nonapi Cloud Copier
Wants=network-online.target
After=network-online.target

[Service]
Type=$unit_type
User=nonapicloud
Group=nonapicloud
WorkingDirectory=$app_dir
ExecStartPre=$app_dir/nonapicloud --apply-staged-update
ExecStart=$app_dir/nonapicloud
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
$ambient_setting
NoNewPrivileges=yes
UMask=0077
Restart=no
TimeoutStartSec=6min
TimeoutStopSec=16s
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
SYSTEMD
chmod 0644 "$unit_temp"
mv -fT -- "$unit_temp" "$unit_dir/$unit"
systemctl daemon-reload
systemctl enable "$unit"
previous_pre_start=$(systemctl show --property=ExecStartPre "$unit" 2>/dev/null) || previous_pre_start=
if ! systemctl start "$unit"; then
    pre_start_command="{ path=$app_dir/nonapicloud ; argv[]=$app_dir/nonapicloud --apply-staged-update ; "
    activation_exit='[^}]* ; code=exited ; status=42 \}'
    if pre_start=$(systemctl show --property=ExecStartPre "$unit" 2>/dev/null) &&
        [[ $pre_start != "$previous_pre_start" && $pre_start =~ "$pre_start_command"$activation_exit ]]; then
        fail "Out of activations. Your license is valid but has no remaining activation slots for this VPS."
    fi
    fail "Nonapi Cloud Copier was installed, but the service failed to start. Check systemctl status $unit."
fi
configure_firewalld "$port" || fail "Nonapi Cloud Copier started. Could not configure firewalld for TCP port $port."
printf 'Installed and started Nonapi Cloud Copier. It will also start at boot.\n'
