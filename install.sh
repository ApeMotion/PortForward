#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [--audio-only] [--bind LISTEN_IPV4] [MAC_IPV4]

Forward TCP 9876 (remote control) and TCP 9879 (computer audio and microphone)
to the same ports on a Mac. Run this on the Linux proxy host.

  --audio-only       Install only the TCP 9879 proxy.
  --bind LISTEN_IPV4  Listen on this Linux address (default: 0.0.0.0).
  -h, --help         Show this help.

If MAC_IPV4 is omitted, the installer asks for it interactively.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

valid_ipv4() {
    local octet part
    local -a octets
    part='(0|[1-9][0-9]{0,2})'
    [[ $1 =~ ^$part\.$part\.$part\.$part$ ]] || return 1
    IFS=. read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
        (( octet <= 255 )) || return 1
    done
}

ports=(9876 9879)
bind_ip=0.0.0.0
mac_ip=
while (( $# )); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --audio-only) ports=(9879) ;;
        --bind)
            (( $# >= 2 )) || die '--bind requires an IPv4 address.'
            bind_ip=$2
            shift
            ;;
        -*) die "Unknown option: $1. See --help." ;;
        *)
            [[ -z $mac_ip ]] || die 'Specify a single Mac IPv4 address.'
            mac_ip=$1
            ;;
    esac
    shift
done

[[ $OSTYPE == linux* ]] || die 'Run this installer on the Linux proxy host.'
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) ||
    die 'Bash 4.4 or newer is required.'
(( EUID == 0 )) || die 'Run this installer with sudo.'
if [[ -z $mac_ip ]]; then
    [[ -t 0 ]] || die 'Pass the Mac IPv4 address when running without a terminal.'
    read -r -p 'Controlled Mac IPv4 address: ' mac_ip || die 'No Mac address was provided.'
fi
valid_ipv4 "$mac_ip" || die "Invalid Mac IPv4 address: $mac_ip"
valid_ipv4 "$bind_ip" || die "Invalid listen IPv4 address: $bind_ip"

for command in systemctl flock; do
    command -v "$command" >/dev/null || die "Required command is missing: $command"
done
systemd_version=$(systemctl show --property=Version --value) || die 'A running systemd system manager is required.'
[[ $systemd_version =~ ^([0-9]+) ]] && (( 10#${BASH_REMATCH[1]} >= 232 )) ||
    die 'systemd 232 or newer is required to run the proxy without root privileges.'

exec 9>/run/vibedesk-proxy-install.lock
flock -n 9 || die 'Another VibeDesk proxy installation is in progress.'

install_dependencies() {
    if command -v socat >/dev/null && command -v ip >/dev/null && command -v ss >/dev/null; then
        return
    fi
    printf 'Installing socat and IP networking tools…\n'
    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y socat iproute2
    elif command -v dnf >/dev/null; then
        dnf -y install socat iproute
    elif command -v pacman >/dev/null; then
        pacman -S --needed --noconfirm socat iproute2
    elif command -v zypper >/dev/null; then
        zypper --non-interactive install socat iproute2
    else
        die 'Install socat and the package providing ip and ss, then run the installer again.'
    fi
}

install_dependencies
socat_bin=$(command -v socat) || die 'Could not find socat after dependency installation.'
[[ $socat_bin =~ ^/[-A-Za-z0-9_./]+$ && -x $socat_bin ]] || die "Unsupported socat executable path: $socat_bin"
route=$(ip -4 route get "$mac_ip") || die "Linux has no IPv4 route to $mac_ip."
case $route in
    'local '*|'broadcast '*|'multicast '*) die 'Specify the IPv4 address of the remote Mac.' ;;
esac

unit_dir=/etc/systemd/system
staging=$(mktemp -d "$unit_dir/.vibedesk-proxy.XXXXXX")
started=()
enabled=()
units_to_create=()
units_to_start=()
units_to_enable=()

cleanup() {
    local status=$? unit path removed=0
    if (( status != 0 )); then
        if (( ${#started[@]} )); then
            systemctl stop "${started[@]}" || printf 'Could not stop all newly started proxies.\n' >&2
        fi
        if (( ${#enabled[@]} )); then
            systemctl disable "${enabled[@]}" || printf 'Could not disable all newly enabled proxies.\n' >&2
        fi
        # The staged inode identifies files created by this invocation, even if
        # a signal arrived immediately after ln wrote the link.
        for unit in "${units_to_create[@]}"; do
            path=$unit_dir/$unit
            if [[ ! -L $path && $path -ef $staging/$unit ]]; then
                if rm -f -- "$path"; then
                    removed=1
                else
                    printf 'Could not remove new unit file %s.\n' "$path" >&2
                fi
            fi
        done
        if (( removed )); then
            systemctl daemon-reload || printf 'Could not reload systemd after rollback.\n' >&2
        fi
    fi
    rm -rf -- "$staging"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

is_listening() {
    local unit=$1 port=$2 pid listeners
    pid=$(systemctl show --property=MainPID --value "$unit") || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    listeners=$(ss -4 -H -ltnp "sport = :$port") || return 1
    [[ $listeners == *"pid=$pid,"* ]]
}

check_port_available() {
    local port=$1 listeners address
    listeners=$(ss -4 -H -ltn "sport = :$port") || die "Could not check TCP $port."
    while read -r _ _ _ address _; do
        [[ -n $address ]] || continue
        if [[ $bind_ip == 0.0.0.0 || $address == "0.0.0.0:$port" ||
              $address == "*:$port" || $address == "$bind_ip:$port" ]]; then
            die "TCP $bind_ip:$port is already in use. If 9876 is already forwarded, use --audio-only."
        fi
    done <<< "$listeners"
    # A dual-stack IPv6 socket can also occupy the IPv4 address. The listener
    # check after start handles any such conflicts and rolls back this install.
}

check_loaded_unit() {
    local unit=$1 fragment drop_ins
    fragment=$(systemctl show --property=FragmentPath --value "$unit")
    [[ $fragment == "$unit_dir/$unit" ]] || die "$unit is loaded from ${fragment:-an unknown path}."
    drop_ins=$(systemctl show --property=DropInPaths --value "$unit")
    [[ -z $drop_ins ]] || die "$unit has existing systemd overrides: $drop_ins"
}

for port in "${ports[@]}"; do
    unit=vibedesk-proxy-$port.service
    path=$unit_dir/$unit
    cat > "$staging/$unit" <<EOF
# Managed by the VibeDesk Linux proxy installer.
[Unit]
Description=VibeDesk TCP $port proxy to $mac_ip
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
ExecStart=$socat_bin TCP4-LISTEN:$port,bind=$bind_ip,reuseaddr,fork TCP4:$mac_ip:$port
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$staging/$unit"

    load_state=$(systemctl show --property=LoadState --value "$unit" || :)
    if [[ -e $path || -L $path ]]; then
        [[ -f $path && ! -L $path ]] && cmp -s "$path" "$staging/$unit" ||
            die "$path already exists with a different configuration. It was left in place."
        if [[ $load_state == loaded ]]; then
            check_loaded_unit "$unit"
        elif [[ $load_state != not-found ]]; then
            die "Cannot use $unit (systemd load state: ${load_state:-unknown})."
        fi
    else
        [[ $load_state == not-found ]] || die "Cannot create $unit (systemd load state: ${load_state:-unknown})."
        units_to_create+=("$unit")
    fi

    active_state=$(systemctl show --property=ActiveState --value "$unit" || :)
    case $active_state in
        active)
            [[ $load_state == loaded && -f $path ]] || die "$unit is active without a matching unit file."
            reload_needed=$(systemctl show --property=NeedDaemonReload --value "$unit")
            [[ $reload_needed == no ]] || die "$unit's configuration changed on disk. Review it before restarting."
            is_listening "$unit" "$port" || die "$unit is active but does not own a TCP $port listener."
            ;;
        inactive|failed)
            check_port_available "$port"
            units_to_start+=("$unit")
            ;;
        *) die "Cannot use $unit (systemd active state: ${active_state:-unknown})." ;;
    esac

    enable_state=$(systemctl is-enabled "$unit" 2>/dev/null || :)
    case $enable_state in
        enabled) ;;
        disabled|not-found|'') units_to_enable+=("$unit") ;;
        *) die "Cannot enable $unit (systemd enable state: $enable_state)." ;;
    esac
done

for unit in "${units_to_create[@]}"; do
    path=$unit_dir/$unit
    ln -T -- "$staging/$unit" "$path" || die "Could not create $path without overwriting an existing file."
done

if (( ${#units_to_create[@]} || ${#units_to_start[@]} )); then
    systemctl daemon-reload
fi
for port in "${ports[@]}"; do
    check_loaded_unit "vibedesk-proxy-$port.service"
done
for unit in "${units_to_start[@]}"; do
    started+=("$unit")
    systemctl start "$unit" || die "Could not start $unit. Check: journalctl -u $unit -b"
done

for port in "${ports[@]}"; do
    unit=vibedesk-proxy-$port.service
    for (( attempt = 0; attempt < 25; attempt++ )); do
        is_listening "$unit" "$port" && break
        sleep 0.2
    done
    is_listening "$unit" "$port" || die "$unit did not start listening. Check: journalctl -u $unit -b"
done

for unit in "${units_to_enable[@]}"; do
    enabled+=("$unit")
    systemctl enable "$unit" || die "Could not enable $unit at boot."
done

for port in "${ports[@]}"; do
    printf 'TCP %s:%s -> %s:%s is active and enabled at boot.\n' "$bind_ip" "$port" "$mac_ip" "$port"
done
