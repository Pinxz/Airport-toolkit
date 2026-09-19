#!/bin/sh

# Install and configure shadowsocks-rust ssserver on Alpine Linux.
#
# Usage:
#   ./install-ssserver-rust.sh --port 8388 --password 'your-password'
#   ./install-ssserver-rust.sh 8388 'your-password'
#   ./install-ssserver-rust.sh              # interactive input
#   ./install-ssserver-rust.sh --uninstall # keep configuration and logs
#   ./install-ssserver-rust.sh --uninstall --purge # archive configuration/logs too

set -eu

PROGRAM_NAME=${0##*/}
CONFIG_DIR=/etc/shadowsocks-rust
CONFIG_FILE=$CONFIG_DIR/config.json
SERVICE_FILE=/etc/init.d/ssserver
METHOD=aes-256-gcm
PORT=
PASSWORD=
TEMP_DIR=
TTY_ECHO_DISABLED=0
UNINSTALL=0
PURGE=0
ASSUME_YES=0

say() {
    printf '%s\n' "$*"
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

restore_tty() {
    if [ "$TTY_ECHO_DISABLED" -eq 1 ]; then
        stty echo 2>/dev/null || true
        TTY_ECHO_DISABLED=0
        printf '\n' >&2
    fi
}

cleanup() {
    restore_tty
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<EOF
Usage:
  $PROGRAM_NAME --port PORT --password PASSWORD
  $PROGRAM_NAME PORT PASSWORD
  $PROGRAM_NAME
  $PROGRAM_NAME --uninstall [--purge] [--yes]

Options:
  -p, --port PORT          Shadowsocks server port (1024-65535)
  -k, --password PASSWORD  Shadowsocks password
  -h, --help               Show this help
  --uninstall             Stop/remove this installer's ssserver service;
                          remove the server program only when safe
  --purge                 With --uninstall, also archive config and logs
  -y, --yes               With --uninstall, skip the confirmation prompt

If PORT or PASSWORD is omitted, the script asks for it interactively.
The password is hidden during interactive input.
Uninstall needs no port/password and performs no installation or downloads.
By default, config and logs remain in place. Removed service/local binary
and --purge data are moved to /var/backups/ssserver-uninstall.* (root-only).
Shared packages, other running instances, helpers, repositories, firewall
rules, sslocal, ssservice and Dante services are not removed.

Examples:
  $PROGRAM_NAME --port 8388 --password 'replace-with-a-strong-password'
  $PROGRAM_NAME 8388 'replace-with-a-strong-password'
  $PROGRAM_NAME --port 8388
  $PROGRAM_NAME --uninstall
  $PROGRAM_NAME --uninstall --purge --yes
EOF
}

# Exact template used by both the original installer and this version.
# Compare the service rather than sourcing arbitrary shell text on uninstall.
render_service() {
    cat <<EOF
#!/sbin/openrc-run

name="Shadowsocks Rust Server"
description="Shadowsocks Rust encrypted proxy server"

command="$SSSERVER_BIN"
command_args="-c $CONFIG_FILE -a nobody"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/ssserver.log"
error_log="/var/log/ssserver.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --file --mode 0640 /var/log/ssserver.log
}
EOF
}

ssserver_is_running() {
    for ss_proc in /proc/[0-9]*/comm; do
        [ -r "$ss_proc" ] || continue
        ss_comm=$(cat "$ss_proc" 2>/dev/null) || continue
        [ "$ss_comm" != ssserver ] || return 0
    done
    return 1
}

ssserver_referenced_elsewhere() {
    for ss_ref in /etc/init.d/* /etc/conf.d/*; do
        [ -f "$ss_ref" ] || continue
        if grep -Fq 'ssserver' "$ss_ref"; then return 0; fi
    done
    return 1
}

uninstall_ssserver() {
    [ "$(id -u)" -eq 0 ] || die 'Run uninstall as root.'
    [ -f /etc/alpine-release ] || die 'Uninstall supports Alpine Linux only.'
    command -v rc-service >/dev/null 2>&1 || die 'OpenRC was not found.'
    command -v rc-update >/dev/null 2>&1 || die 'rc-update was not found.'
    command -v apk >/dev/null 2>&1 || die 'apk was not found.'
    [ -d /proc/1 ] || die '/proc is required to check for other ssserver instances.'

    if [ ! -e "$SERVICE_FILE" ] && [ ! -L "$SERVICE_FILE" ]; then
        say 'No /etc/init.d/ssserver service found. Nothing was removed.'
        say 'Any remaining programs/configuration are left untouched (ownership unknown).'
        return 0
    fi
    [ -f "$SERVICE_FILE" ] && [ ! -L "$SERVICE_FILE" ] || die 'Service is not a regular file; refusing uninstall.'
    [ ! -e /etc/conf.d/ssserver ] && [ ! -L /etc/conf.d/ssserver ] || \
        die '/etc/conf.d/ssserver overrides may exist. Inspect them before uninstalling.'
    SSSERVER_BIN=$(sed -n 's/^command="\([^"]*\)"$/\1/p' "$SERVICE_FILE")
    case "$SSSERVER_BIN" in
        /usr/bin/ssserver|/usr/local/bin/ssserver) ;;
        *) die 'Unrecognized ssserver binary path; no changes made.' ;;
    esac
    # Command substitution removes trailing newlines in both strings only.
    [ "$(sed '/^[[:space:]]*$/d' "$SERVICE_FILE")" = "$(render_service | sed '/^[[:space:]]*$/d')" ] || \
        die 'Service differs from this installer template; refusing to remove a custom service.'
    [ ! -L "$CONFIG_DIR" ] || die 'Configuration directory is a symlink; inspect it first.'

    say 'Uninstall target: /etc/init.d/ssserver'
    say "Server program: $SSSERVER_BIN (retained if shared or ownership is unclear)"
    if [ "$PURGE" -eq 1 ]; then
        say 'Current config, config backups and ssserver.log will also be archived.'
    else
        say 'Configuration and logs will stay in place.'
    fi
    say 'Firewall rules and Alpine repository settings will NOT be changed.'
    if [ "$ASSUME_YES" -ne 1 ]; then
        [ -t 0 ] || die 'Interactive confirmation required; use --yes for unattended uninstall.'
        printf 'Continue uninstall? [y/N]: '
        IFS= read -r uninstall_answer
        case "$uninstall_answer" in y|Y|yes|YES) ;; *) say 'Cancelled; no changes made.'; return 0 ;; esac
    fi

    # Stopping must succeed before changing the service registration or files.
    if rc-service ssserver status >/dev/null 2>&1; then
        rc-service ssserver stop || die 'Could not stop ssserver; service files retained.'
        if rc-service ssserver status >/dev/null 2>&1; then die 'ssserver is still running; aborting.'; fi
    elif [ -f /run/ssserver.pid ]; then
        uninstall_pid=$(cat /run/ssserver.pid)
        case "$uninstall_pid" in
            ''|*[!0-9]*) die 'Invalid ssserver PID file; inspect the service first.' ;;
            *) if kill -0 "$uninstall_pid" 2>/dev/null; then
                   die 'PID is alive but OpenRC does not report a running service; inspect it first.'
               fi ;;
        esac
    fi

    umask 077
    mkdir -p /var/backups
    UNINSTALL_BACKUP=$(mktemp -d /var/backups/ssserver-uninstall.XXXXXX)
    # Remove only ssserver links, in each actual OpenRC runlevel.
    for uninstall_level in /etc/runlevels/*; do
        [ -d "$uninstall_level" ] || continue
        if [ -L "$uninstall_level/ssserver" ]; then
            rc-update del ssserver "${uninstall_level##*/}" || die 'Could not disable autostart; service retained.'
        elif [ -e "$uninstall_level/ssserver" ]; then
            die 'Unexpected non-symlink runlevel entry; inspect it first.'
        fi
    done
    mv "$SERVICE_FILE" "$UNINSTALL_BACKUP/ssserver.init"
    say "Service removed. Recoverable backup: $UNINSTALL_BACKUP/ssserver.init"

    if ssserver_is_running || ssserver_referenced_elsewhere; then
        warn 'Another process or service references ssserver. Program, config and logs retained, including with --purge.'
    else
        if [ "$SSSERVER_BIN" = /usr/local/bin/ssserver ]; then
            if [ -f /usr/local/bin/ssserver ] && [ ! -L /usr/local/bin/ssserver ] && \
               ! apk info --who-owns /usr/local/bin/ssserver >/dev/null 2>&1; then
                mv /usr/local/bin/ssserver "$UNINSTALL_BACKUP/ssserver.bin"
                say "Local server binary archived: $UNINSTALL_BACKUP/ssserver.bin"
            else
                warn 'Local binary missing, linked, or package-owned; left untouched.'
            fi
        elif apk info -e shadowsocks-rust-ssserver >/dev/null 2>&1; then
            # Only delete an explicitly identified leaf package. Never remove
            # the full meta-package or use recursive reverse-dependency removal.
            uninstall_owner=$(apk info --who-owns /usr/bin/ssserver 2>/dev/null) || uninstall_owner=
            uninstall_rdeps=$(apk info --rdepends shadowsocks-rust-ssserver 2>/dev/null) || uninstall_rdeps=
            case "$uninstall_owner" in
                *' is owned by shadowsocks-rust-ssserver-'*)
                    if printf '%s\n' "$uninstall_rdeps" | awk '
                        NF {n++; if(n==1 && $0 ~ /^shadowsocks-rust-ssserver-.* is required by:$/) ok=1}
                        END {exit !(ok && n==1)}'; then
                        if apk del shadowsocks-rust-ssserver; then
                            say 'Removed package: shadowsocks-rust-ssserver (reinstall with apk if needed).'
                        else
                            warn 'Package removal failed; service is removed but the package may remain.'
                        fi
                    else
                        warn 'Server package has dependents or its dependency state is unclear; retained.'
                    fi ;;
                *) warn 'Cannot confirm package ownership; server binary retained.' ;;
            esac
        else
            warn 'Server program ownership is unclear; binary retained.'
        fi

        if [ "$PURGE" -eq 1 ]; then
            mkdir "$UNINSTALL_BACKUP/config"
            for uninstall_file in "$CONFIG_FILE" "$CONFIG_FILE".bak.*; do
                [ -f "$uninstall_file" ] || [ -L "$uninstall_file" ] || continue
                mv "$uninstall_file" "$UNINSTALL_BACKUP/config/"
            done
            if [ -f /var/log/ssserver.log ] || [ -L /var/log/ssserver.log ]; then
                mv /var/log/ssserver.log "$UNINSTALL_BACKUP/ssserver.log"
            fi
            # Never recursively remove the shared configuration directory.
            rmdir "$CONFIG_DIR" 2>/dev/null || :
            say "Config/logs removed from active paths and recoverable under $UNINSTALL_BACKUP"
            say 'Backup may contain passwords; it is root-only. Other config files and rotated logs are untouched.'
        fi
    fi
    say 'Uninstall finished. Shared helper packages, other services and firewall rules were not removed.'
    say "Backup directory: $UNINSTALL_BACKUP"
}

need_value() {
    [ "$#" -ge 2 ] || die "Option $1 requires a value."
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --uninstall|uninstall)
            UNINSTALL=1
            shift
            ;;
        --purge)
            PURGE=1
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        -p|--port)
            need_value "$@"
            PORT=$2
            shift 2
            ;;
        --port=*)
            PORT=${1#*=}
            shift
            ;;
        -k|--password)
            need_value "$@"
            PASSWORD=$2
            shift 2
            ;;
        --password=*)
            PASSWORD=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            if [ -z "$PORT" ]; then
                PORT=$1
            elif [ -z "$PASSWORD" ]; then
                PASSWORD=$1
            else
                die "Too many positional arguments."
            fi
            shift
            ;;
    esac
done

[ "$#" -eq 0 ] || die "Too many arguments."

if [ "$UNINSTALL" -eq 1 ]; then
    [ -z "$PORT" ] && [ -z "$PASSWORD" ] || die 'Do not combine uninstall with port/password options.'
    uninstall_ssserver
    exit 0
fi
[ "$PURGE" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] || die '--purge/--yes require --uninstall.'

if [ -z "$PORT" ]; then
    [ -t 0 ] || die "No port supplied. Use --port PORT."
    printf 'Server port [8388]: '
    IFS= read -r PORT
    PORT=${PORT:-8388}
fi

case "$PORT" in
    ''|*[!0-9]*) die "Port must be an integer from 1024 to 65535." ;;
esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || \
    die "Port must be between 1024 and 65535 so ssserver can run as nobody."

if [ -z "$PASSWORD" ]; then
    [ -t 0 ] || die "No password supplied. Use --password PASSWORD."

    printf 'Password: ' >&2
    stty -echo
    TTY_ECHO_DISABLED=1
    IFS= read -r PASSWORD
    restore_tty

    printf 'Confirm password: ' >&2
    stty -echo
    TTY_ECHO_DISABLED=1
    IFS= read -r PASSWORD_CONFIRM
    restore_tty

    [ "$PASSWORD" = "$PASSWORD_CONFIRM" ] || die "Passwords do not match."
    unset PASSWORD_CONFIRM
fi

[ -n "$PASSWORD" ] || die "Password cannot be empty."
if [ "${#PASSWORD}" -lt 16 ]; then
    warn "A password of at least 16 characters is recommended."
fi

[ "$(id -u)" -eq 0 ] || die "Run this script as root."
[ -f /etc/alpine-release ] || die "This script supports Alpine Linux only."
command -v apk >/dev/null 2>&1 || die "apk was not found."
command -v rc-service >/dev/null 2>&1 || die "OpenRC was not found."

enable_community_repository() {
    repositories=/etc/apk/repositories

    if awk '!/^[[:space:]]*#/ && /\/community([[:space:]]*)$/' "$repositories" | grep -q .; then
        return 0
    fi

    main_repository=$(awk '
        !/^[[:space:]]*#/ && /\/main([[:space:]]*)$/ {
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$repositories")
    if [ -n "$main_repository" ]; then
        community_repository=${main_repository%/main}/community
        say "Enabling the matching Alpine community repository: $community_repository"
        printf '%s\n' "$community_repository" >> "$repositories"
    else
        warn "No Alpine main repository was found; community was not added automatically."
    fi
}

install_from_official_release() {
    case "$(uname -m)" in
        x86_64) release_target=x86_64-unknown-linux-musl ;;
        aarch64|arm64) release_target=aarch64-unknown-linux-musl ;;
        armv7l|armv7) release_target=armv7-unknown-linux-musleabihf ;;
        i386|i486|i586|i686) release_target=i686-unknown-linux-musl ;;
        *) die "No supported official musl release for architecture: $(uname -m)" ;;
    esac

    say "Alpine package unavailable; downloading the official shadowsocks-rust release."
    TEMP_DIR=$(mktemp -d)
    release_json=$TEMP_DIR/release.json
    archive=$TEMP_DIR/shadowsocks-rust.tar.xz

    wget -q -O "$release_json" \
        https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest || \
        die "Could not query the official shadowsocks-rust release."

    download_url=$(jq -r --arg target "$release_target" '
        [.assets[]
         | select(.name | contains($target))
         | select(.name | endswith(".tar.xz"))
         | .browser_download_url][0] // empty
    ' "$release_json")

    [ -n "$download_url" ] || \
        die "No official release archive found for $release_target."

    wget -q -O "$archive" "$download_url" || \
        die "Could not download the official shadowsocks-rust release."
    tar -xJf "$archive" -C "$TEMP_DIR" || die "Could not extract the release archive."

    extracted_ssserver=$(find "$TEMP_DIR" -type f -name ssserver | head -n 1)
    [ -n "$extracted_ssserver" ] || die "ssserver was not found in the release archive."

    cp "$extracted_ssserver" /usr/local/bin/ssserver
    chmod 0755 /usr/local/bin/ssserver
}

enable_community_repository
say "Refreshing Alpine package indexes..."
apk update
apk add --no-cache ca-certificates jq iproute2 tar xz

if ! command -v ssserver >/dev/null 2>&1; then
    say "Installing shadowsocks-rust ssserver..."
    if apk add --no-cache shadowsocks-rust-ssserver; then
        :
    elif apk add --no-cache shadowsocks-rust; then
        :
    else
        install_from_official_release
    fi
fi

SSSERVER_BIN=$(command -v ssserver) || die "ssserver installation failed."
say "Using: $($SSSERVER_BIN --version 2>&1 | head -n 1)"

umask 077
mkdir -p "$CONFIG_DIR"
TEMP_CONFIG=$CONFIG_DIR/config.json.new
PASSWORD_FILE=$CONFIG_DIR/.password.new
printf '%s' "$PASSWORD" > "$PASSWORD_FILE"

jq -n \
    --arg server '0.0.0.0' \
    --argjson server_port "$PORT" \
    --rawfile password "$PASSWORD_FILE" \
    --arg method "$METHOD" \
    '{
        server: $server,
        server_port: $server_port,
        password: $password,
        method: $method,
        mode: "tcp_and_udp",
        timeout: 300
    }' > "$TEMP_CONFIG"
rm -f -- "$PASSWORD_FILE"
unset PASSWORD

BACKUP_STAMP=$(date +%Y%m%d-%H%M%S)
if [ -f "$CONFIG_FILE" ]; then
    cp -p "$CONFIG_FILE" "$CONFIG_FILE.bak.$BACKUP_STAMP"
fi
if [ -f "$SERVICE_FILE" ]; then
    cp -p "$SERVICE_FILE" "$SERVICE_FILE.bak.$BACKUP_STAMP"
fi

mv "$TEMP_CONFIG" "$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

render_service > "$SERVICE_FILE.new"
mv "$SERVICE_FILE.new" "$SERVICE_FILE"
chmod 0755 "$SERVICE_FILE"

rc-update add ssserver default >/dev/null

say "Starting ssserver..."
if rc-service ssserver status >/dev/null 2>&1; then
    if ! rc-service ssserver restart; then
        warn "Could not restart ssserver."
        warn "Check: rc-service ssserver status"
        warn "Log:   tail -n 100 /var/log/ssserver.log"
        exit 1
    fi
else
    if ! rc-service ssserver start; then
        warn "Could not start ssserver."
        warn "Check: rc-service ssserver status"
        warn "Log:   tail -n 100 /var/log/ssserver.log"
        exit 1
    fi
fi

sleep 1
TCP_OK=0
UDP_OK=0
if ss -H -lnt | awk -v port="$PORT" '$4 ~ (":" port "$" ) {found=1} END {exit !found}'; then
    TCP_OK=1
fi
if ss -H -lnu | awk -v port="$PORT" '$4 ~ (":" port "$" ) {found=1} END {exit !found}'; then
    UDP_OK=1
fi

if [ "$TCP_OK" -ne 1 ] || [ "$UDP_OK" -ne 1 ]; then
    warn "ssserver did not open both TCP and UDP port $PORT."
    warn "Check: rc-service ssserver status"
    warn "Log:   tail -n 100 /var/log/ssserver.log"
    exit 1
fi

say ""
say "Installation completed."
say "Server port : $PORT (TCP and UDP)"
say "Method      : $METHOD"
say "Config      : $CONFIG_FILE"
say "Service     : ssserver (enabled at boot)"
say ""
say "Remember to allow both TCP $PORT and UDP $PORT in the cloud security group/firewall."
say "Client settings must use the same server address, port, password, method, and UDP mode."
