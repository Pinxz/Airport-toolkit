#!/bin/sh
set -eu

# ===== 只需修改这三个变量 =====
LOCAL_PORT="53333"
TARGET_ADDR="85.149.218.32"
TARGET_PORT="35690"
# =============================

fail() {
    echo "错误：$*" >&2
    exit 1
}

check_port() {
    case "$1" in
        ""|*[!0-9]*|0*)
            fail "端口必须是 1～65535 的整数，不能有前导零"
            ;;
    esac
    [ "${#1}" -le 5 ] || fail "端口超出范围"
    [ "$1" -le 65535 ] || fail "端口超出范围"
}

[ "$(id -u)" -eq 0 ] || fail "请使用 root 执行"
[ -f /etc/alpine-release ] || fail "仅支持 Alpine Linux"

case "$(cat /etc/alpine-release)" in
    3.23.*) ;;
    *) fail "此脚本适用于 Alpine 3.23" ;;
esac

command -v rc-service >/dev/null 2>&1 ||
    fail "需要使用 OpenRC 的 Alpine 系统"

check_port "$LOCAL_PORT"
check_port "$TARGET_PORT"

case "$TARGET_ADDR" in
    ""|*[!a-zA-Z0-9.:-]*)
        fail "目标地址应为 IP 或域名，不要包含协议、路径或方括号"
        ;;
esac

# 以下是脚本内部变量，无需修改。
case "$TARGET_ADDR" in
    *:*) endpoint="[$TARGET_ADDR]:$TARGET_PORT" ;;
    *)   endpoint="$TARGET_ADDR:$TARGET_PORT" ;;
esac

echo "安装 HAProxy..."
apk add --no-cache haproxy haproxy-openrc

mkdir -p /etc/haproxy
tmp_config="$(mktemp /etc/haproxy/haproxy.cfg.XXXXXX)"
trap 'rm -f "$tmp_config"' EXIT
trap 'exit 1' HUP INT TERM

cat > "$tmp_config" <<EOF
global
    user haproxy
    group haproxy
    daemon

defaults
    mode tcp
    timeout connect 10s
    timeout client 1h
    timeout server 1h

resolvers system_dns
    parse-resolv-conf
    resolve_retries 3
    timeout resolve 2s
    timeout retry 1s
    hold valid 10s

frontend port_forward
    bind 0.0.0.0:${LOCAL_PORT}
    default_backend forward_target

backend forward_target
    server target ${endpoint} resolvers system_dns init-addr libc
EOF

echo "校验配置..."
haproxy -c -f "$tmp_config" || fail "配置校验失败，旧配置未替换"

if [ -f /etc/haproxy/haproxy.cfg ]; then
    backup="$(mktemp /etc/haproxy/haproxy.cfg.backup.XXXXXX)"
    cp -p /etc/haproxy/haproxy.cfg "$backup"
    echo "旧配置已备份：$backup"
fi

chmod 644 "$tmp_config"
mv -f "$tmp_config" /etc/haproxy/haproxy.cfg

echo "启动服务并设置开机自启..."
rc-update add haproxy default

if rc-service haproxy status >/dev/null 2>&1; then
    rc-service haproxy restart
else
    rc-service haproxy start
fi

rc-service haproxy status
printf '\n已配置 TCP 转发：0.0.0.0:%s -> %s\n' \
    "$LOCAL_PORT" "$endpoint"