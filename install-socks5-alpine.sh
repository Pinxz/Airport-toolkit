#!/bin/sh
# Dante SOCKS5 installer for Alpine Linux 3.21 / 3.22 / 3.23 (OpenRC).
# IPv4, username/password authentication, TCP CONNECT + UDP ASSOCIATE.
# First-install only: existing accounts and service configurations are preserved.
# No firewall changes, remote scripts, edge repositories or system upgrades.
# Docs: https://www.inet.no/dante/doc/1.4.x/sockd.conf.5.html

set +x
set -eu
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

S5_PORT=
S5_USER=
S5_PASS=
S5_ALLOW=
S5_LISTEN=0.0.0.0
S5_INTERFACE=
S5_UDP=40000-40100
S5_DIR=/etc/socks5-dante
S5_SERVICE=/etc/init.d/socks5-dante
S5_WORK=
S5_LOCKED=0
S5_TTY=

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
cleanup() {
    if [ -n "$S5_TTY" ]; then stty "$S5_TTY" 2>/dev/null || :; fi
    if [ -n "$S5_WORK" ]; then
        rm -f "$S5_WORK/sockd.conf" "$S5_WORK/service" "$S5_WORK/repositories"
        rmdir "$S5_WORK" 2>/dev/null || :
    fi
    if [ "$S5_LOCKED" = 1 ]; then rmdir /run/socks5-dante-install.lock 2>/dev/null || :; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'HELP'
Alpine 3.21-3.23 Dante SOCKS5 installer (run as root)

Interactive:
  sh install-socks5-alpine.sh

Recommended (password prompted, hidden):
  sh install-socks5-alpine.sh --port 1080 --user socksuser --allow 203.0.113.10/32

Noninteractive (password is exposed in shell history / process arguments):
  sh install-socks5-alpine.sh --port 1080 --user socksuser --password 'STRONG_PASSWORD' --allow 203.0.113.10/32

Options:
  --port N             TCP control port, 1-65535 (interactive default: 1080)
  --user NAME          NEW dedicated local account (default: socksuser)
  --password TEXT      Password, 12-255 bytes; otherwise prompted twice
  --allow IPv4/CIDR    Client source address/range; /32 is added for a bare IP
  --allow-any          Explicitly allow all IPv4 sources (NOT recommended)
  --listen IPv4       Local bind address (default: 0.0.0.0)
  --interface NAME    IPv4 egress interface (default: detected from routing)
  --udp-range A-B     UDP client relay ports (default: 40000-40100)
  -h, --help          Show this help

The script installs dante-server and iproute2 from the matching Alpine branch,
creates a non-login account, validates the config and enables socks5-dante.
It does NOT modify firewall rules, disable other services, or overwrite an
existing installation. Passwords are set through chpasswd's stdin, not config.

Allow TCP control port + UDP relay range in your firewall/security group,
preferably from the same --allow source only. Allow stateful return traffic.
SOCKS5 does NOT encrypt authentication or traffic. Prefer a VPN/private link.
UDP needs a client implementing UDP ASSOCIATE and a reachable relay address;
NAT/port-mapped VPS may require additional networking setup.

Manage:
  rc-service socks5-dante status
  rc-service socks5-dante restart
  tail -n 80 /var/log/socks5-dante.log
  passwd socksuser                 # change your chosen account's password
  rc-service socks5-dante stop
  rc-update del socks5-dante default

Config: /etc/socks5-dante/sockd.conf
Backups of a modified repository list: /etc/socks5-dante/repositories.before
Diskless Alpine: use your normal lbu commit / persistent APK-cache workflow.
HELP
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --allow-any) S5_ALLOW=0.0.0.0/0; shift ;;
        --port|--user|--password|--allow|--listen|--interface|--udp-range)
            [ "$#" -ge 2 ] || die "Missing value for $1"
            case "$1" in
                --port) S5_PORT=$2 ;;
                --user) S5_USER=$2 ;;
                --password) S5_PASS=$2 ;;
                --allow) S5_ALLOW=$2 ;;
                --listen) S5_LISTEN=$2 ;;
                --interface) S5_INTERFACE=$2 ;;
                --udp-range) S5_UDP=$2 ;;
            esac
            shift 2 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

# Accept canonical decimal values only; reject configuration injection.
valid_port() {
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
valid_ipv4() {
    case "$1" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s\n' "$1" | awk -F. '
      NF != 4 {exit 1}
      {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 ||
        ($i ~ /^0/ && length($i)>1) || $i+0>255) exit 1}'
}

if [ -z "$S5_PORT" ]; then
    [ -t 0 ] || die 'Specify --port for noninteractive input.'
    printf 'TCP control port [1080]: '; IFS= read -r S5_PORT
    S5_PORT=${S5_PORT:-1080}
fi
valid_port "$S5_PORT" || die 'Invalid port (use 1-65535 without leading zeroes).'
if [ -z "$S5_USER" ]; then
    if [ -t 0 ]; then printf 'New proxy username [socksuser]: '; IFS= read -r S5_USER; fi
    S5_USER=${S5_USER:-socksuser}
fi
case "$S5_USER" in ''|[!a-z_]*|*[!a-z0-9_-]*) die 'Invalid username; use lowercase letters, digits, _ or -.' ;; esac
[ "${#S5_USER}" -le 32 ] || die 'Username is too long.'
valid_ipv4 "$S5_LISTEN" || die '--listen must be a local IPv4 address.'

if [ -z "$S5_ALLOW" ]; then
    [ -t 0 ] || die 'Specify --allow CLIENT_IP/CIDR or explicitly --allow-any.'
    printf 'Allowed client IPv4/CIDR (required; 0.0.0.0/0 permits everyone): '
    IFS= read -r S5_ALLOW
fi
case "$S5_ALLOW" in */*) ;; *) S5_ALLOW=$S5_ALLOW/32 ;; esac
S5_SOURCE=${S5_ALLOW%/*}
S5_PREFIX=${S5_ALLOW##*/}
valid_ipv4 "$S5_SOURCE" || die 'Invalid client IPv4 address.'
case "$S5_PREFIX" in ''|*[!0-9]*) die 'Invalid CIDR prefix.' ;; esac
[ "${#S5_PREFIX}" -le 2 ] && [ "$S5_PREFIX" -le 32 ] || die 'CIDR prefix must be 0-32.'
[ "$S5_PREFIX" = 0 ] || [ "${S5_PREFIX#0}" = "$S5_PREFIX" ] || die 'No leading zeroes in CIDR prefix.'
[ "$S5_PREFIX" != 0 ] || [ "$S5_SOURCE" = 0.0.0.0 ] || die 'Use 0.0.0.0/0 for all sources.'
if [ "$S5_ALLOW" = 0.0.0.0/0 ]; then
    info 'WARNING: all IPv4 sources can attempt login. SOCKS5 passwords are not encrypted.'
fi
case "$S5_UDP" in *-*) ;; *) die 'UDP range must be START-END.' ;; esac
S5_UDP_MIN=${S5_UDP%-*}
S5_UDP_MAX=${S5_UDP#*-}
valid_port "$S5_UDP_MIN" && valid_port "$S5_UDP_MAX" || die 'Invalid UDP range.'
[ "$S5_UDP_MIN" -ge 1024 ] && [ "$S5_UDP_MIN" -le "$S5_UDP_MAX" ] || die 'UDP range must be ordered, between 1024 and 65535.'

[ "$(id -u)" = 0 ] || die 'Run as root.'
[ -f /etc/alpine-release ] || die 'This installer only supports Alpine Linux.'
S5_VERSION=$(cut -d. -f1,2 /etc/alpine-release)
case "$S5_VERSION" in 3.21|3.22|3.23) ;; *) die "Unsupported Alpine version: $S5_VERSION" ;; esac
[ -x /sbin/openrc-run ] && command -v rc-service >/dev/null 2>&1 || die 'OpenRC is required (not a plain Docker container).'
[ -d /run/openrc ] || die 'OpenRC must be running; use a normal Alpine VM/server.'
for S5_CMD in apk chpasswd adduser; do
    command -v "$S5_CMD" >/dev/null 2>&1 || die "Missing prerequisite: $S5_CMD"
done

mkdir /run/socks5-dante-install.lock 2>/dev/null || die 'Another installer is running, or /run/socks5-dante-install.lock needs inspection.'
S5_LOCKED=1
[ ! -e "$S5_DIR" ] && [ ! -L "$S5_DIR" ] || die "$S5_DIR exists; refusing to overwrite. Inspect it before reinstalling."
[ ! -e "$S5_SERVICE" ] && [ ! -L "$S5_SERVICE" ] || die "$S5_SERVICE exists; refusing to overwrite."
[ ! -e /etc/conf.d/socks5-dante ] && [ ! -L /etc/conf.d/socks5-dante ] || die '/etc/conf.d/socks5-dante exists; inspect it first.'
if id "$S5_USER" >/dev/null 2>&1; then die "Account $S5_USER already exists. Choose a NEW username; existing passwords will not be changed."; fi

if [ -z "$S5_PASS" ]; then
    [ -t 0 ] || die 'Use an interactive terminal for the password, or specify --password.'
    S5_TTY=$(stty -g)
    printf 'Proxy password (12-255 bytes, hidden): '; stty -echo
    IFS= read -r S5_PASS
    stty "$S5_TTY"; S5_TTY=; printf '\n'
    S5_TTY=$(stty -g)
    printf 'Confirm password: '; stty -echo
    IFS= read -r S5_CONFIRM
    stty "$S5_TTY"; S5_TTY=; printf '\n'
    [ "$S5_PASS" = "$S5_CONFIRM" ] || die 'Passwords do not match.'
    unset S5_CONFIRM
fi
[ "${#S5_PASS}" -ge 12 ] && [ "${#S5_PASS}" -le 255 ] || die 'Password must be 12-255 bytes.'
case "$S5_PASS" in *'
'*|*"$(printf '\r')"*) die 'Password must not contain CR/LF.' ;; esac

S5_WORK=$(mktemp -d /etc/socks5-install.XXXXXX)
S5_REPO_CHANGED=0
# Refuse pre-existing mixed branches rather than silently installing from edge.
if ! awk -v branch="v$S5_VERSION" '
    /^[[:space:]]*#/ {next}
    {for(i=1;i<=NF;i++) {
        n=split($i,a,"/")
        for(j=1;j<n;j++) {
            if(a[j]=="edge") exit 1
            if(a[j] ~ /^v[0-9]+\.[0-9]+$/ && a[j]!=branch) exit 1
        }
    }}' /etc/apk/repositories; then
    die 'Mixed Alpine branches/edge found in repositories; resolve them before installing.'
fi
# Only a matching, untagged repository may be added. Never add edge.
if ! awk -v branch="v$S5_VERSION" '
    /^[[:space:]]*#/ {next}
    NF==1 && $1 ~ ("/" branch "/community/?$") {found=1}
    END {exit !found}' /etc/apk/repositories; then
    S5_REPO=$(awk -v branch="v$S5_VERSION" '
        /^[[:space:]]*#/ {next}
        NF==1 && $1 ~ ("/" branch "/main/?$") {
            sub(/\/main\/?$/, "/community", $1); print $1; exit
        }' /etc/apk/repositories)
    [ -n "$S5_REPO" ] || die "No matching v$S5_VERSION/main repository; fix /etc/apk/repositories first."
    cp -p /etc/apk/repositories "$S5_WORK/repositories"
    printf '\n%s\n' "$S5_REPO" >> /etc/apk/repositories
    S5_REPO_CHANGED=1
    info "Enabled matching repository: $S5_REPO"
fi
if ! apk update || ! apk add --no-cache dante-server iproute2; then
    if [ "$S5_REPO_CHANGED" = 1 ]; then cp -p "$S5_WORK/repositories" /etc/apk/repositories; fi
    die 'Package installation failed; no proxy configuration or account was created.'
fi
[ -x /usr/sbin/sockd ] || die 'dante-server did not provide /usr/sbin/sockd.'

if [ -z "$S5_INTERFACE" ]; then
    S5_INTERFACE=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
fi
case "$S5_INTERFACE" in ''|*[!a-zA-Z0-9_.:-]*) die 'Cannot detect a safe interface name; specify --interface.' ;; esac
ip link show dev "$S5_INTERFACE" >/dev/null 2>&1 || die 'The egress interface does not exist.'
ip -o -4 addr show dev "$S5_INTERFACE" | grep -q ' inet ' || die 'The egress interface has no IPv4 address.'
if [ "$S5_LISTEN" != 0.0.0.0 ]; then
    ip -o -4 addr show | awk -v addr="$S5_LISTEN" '{split($4,a,"/"); if(a[1]==addr) found=1} END {exit !found}' || die '--listen is not assigned locally.'
fi
if ss -H -lnt | awk -v port="$S5_PORT" '$4 ~ (":" port "$") {found=1} END {exit !found}'; then
    die "TCP port $S5_PORT is already in use; existing services were not stopped."
fi
if ss -H -lnu | awk -v lo="$S5_UDP_MIN" -v hi="$S5_UDP_MAX" '{n=split($4,a,":"); if(a[n]+0>=lo && a[n]+0<=hi) found=1} END {exit !found}'; then
    die 'The UDP range overlaps a current listener; select another --udp-range.'
fi

# No shell expansion/eval of passwords; they never enter sockd.conf.
adduser -D -H -s /sbin/nologin -g 'Dedicated SOCKS5 proxy account' "$S5_USER"
if ! printf '%s:%s\n' "$S5_USER" "$S5_PASS" | chpasswd; then
    die "Password setup failed. Account $S5_USER was created; inspect it before retrying."
fi
unset S5_PASS

cat > "$S5_WORK/sockd.conf" <<EOF
# Managed by install-socks5-alpine.sh; IPv4-only SOCKS5.
logoutput: /var/log/socks5-dante.log
internal: $S5_LISTEN port = $S5_PORT
external: $S5_INTERFACE
internal.protocol: ipv4
external.protocol: ipv4
user.privileged: root
user.unprivileged: nobody
clientmethod: none
socksmethod: username
udp.connectdst: no

client pass {
    from: $S5_ALLOW to: 0.0.0.0/0
    log: error
}
socks pass {
    from: $S5_ALLOW to: 0.0.0.0/0
    command: connect udpassociate
    protocol: tcp udp
    proxyprotocol: socks_v5
    socksmethod: username
    user: $S5_USER
    udp.portrange: $S5_UDP_MIN - $S5_UDP_MAX
    log: error
}
# Only replies belonging to existing UDP associations; no new TCP sessions.
socks pass {
    from: 0.0.0.0/0 to: $S5_ALLOW
    command: udpreply
    protocol: udp
    log: error
}
EOF

# Check the actual installed Dante parser, not assumptions about package splits.
if ! /usr/sbin/sockd -V -f "$S5_WORK/sockd.conf"; then
    die "Dante rejected the configuration. No service was enabled; account $S5_USER remains."
fi
cat > "$S5_WORK/service" <<'OPENRC'
#!/sbin/openrc-run
description="Authenticated Dante SOCKS5 TCP/UDP proxy"
command="/usr/sbin/sockd"
pidfile="/run/socks5-dante.pid"
command_args="-D -f /etc/socks5-dante/sockd.conf -p /run/socks5-dante.pid"
depend() {
    need net
    after firewall
}
start_pre() {
    checkpath --file --mode 0600 --owner root:root /var/log/socks5-dante.log || return 1
    /usr/sbin/sockd -V -f /etc/socks5-dante/sockd.conf
}
OPENRC

mkdir -m 0700 "$S5_DIR"
cp "$S5_WORK/sockd.conf" "$S5_DIR/sockd.conf"
chmod 0600 "$S5_DIR/sockd.conf"
if [ "$S5_REPO_CHANGED" = 1 ]; then cp -p "$S5_WORK/repositories" "$S5_DIR/repositories.before"; fi
cp "$S5_WORK/service" "$S5_SERVICE"
chmod 0755 "$S5_SERVICE"

if ! rc-service socks5-dante start; then
    die 'Start failed; see /var/log/socks5-dante.log. Boot autostart has NOT been enabled.'
fi
sleep 2
rc-service socks5-dante status || die 'Service exited; inspect /var/log/socks5-dante.log.'
ss -H -lntp | awk -v port="$S5_PORT" '$4 ~ (":" port "$") && /sockd/ {found=1} END {exit !found}' || die 'Dante TCP listener was not found.'
rc-update add socks5-dante default

cat <<EOF

Installed: Dante SOCKS5 on Alpine $S5_VERSION
Service:   socks5-dante (enabled at boot)
Listen:    $S5_LISTEN:$S5_PORT (IPv4)
Username:  $S5_USER
Sources:   $S5_ALLOW
Egress:    $S5_INTERFACE
UDP relay: $S5_UDP_MIN-$S5_UDP_MAX
Config:    /etc/socks5-dante/sockd.conf
Log:       /var/log/socks5-dante.log

Firewall/security group: permit TCP $S5_PORT and UDP $S5_UDP_MIN-$S5_UDP_MAX
from $S5_ALLOW. This script did NOT modify any firewall rules.
UDP sockets appear only when clients establish UDP ASSOCIATE sessions.
Local service/listening checks passed; remote authentication, TCP forwarding
and UDP forwarding have NOT been tested by this installer.

SOCKS5 is NOT encrypted. Use a trusted network or VPN wherever possible.
NAT VPS: the UDP relay address returned to clients must be reachable.
Diskless Alpine: persist changes with your normal lbu/APK-cache workflow.
EOF
