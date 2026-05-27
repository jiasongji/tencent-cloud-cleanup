#!/usr/bin/env bash
# ================================================================
# 腾讯云轻量 / CVM DD 后 IPv6 配置脚本
# ================================================================
# 使用：
#   TENCENT_IPV6='2402:xxxx:....:0' bash configure_ipv6.sh
#
# 可选：
#   IFACE=eth0
#   TENCENT_IPV6_PREFIX=64
#   TENCENT_IPV6_GW='fe80::feee:ffff:feff:ffff'
#   IPV6_DNS='2402:4e00:: 2400:3200::1'
# ================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
log_step() { echo -e "\n${CYAN}======== $* ========${NC}"; }

IPV6_ADDR_RAW="${TENCENT_IPV6:-${IPV6_ADDR:-}}"
IPV6_PREFIX="${TENCENT_IPV6_PREFIX:-64}"
IPV6_GW="${TENCENT_IPV6_GW:-fe80::feee:ffff:feff:ffff}"
IPV6_DNS="${IPV6_DNS:-2402:4e00:: 2400:3200::1}"
PERSIST="${PERSIST:-1}"
TEST_IPV6="${TEST_IPV6:-2400:3200::1}"

if [ "$(id -u)" -ne 0 ]; then
    log_fail "请使用 root 用户运行此脚本"
    exit 1
fi

if [ -z "$IPV6_ADDR_RAW" ]; then
    log_fail "未设置 TENCENT_IPV6。请从腾讯云控制台复制实例 IPv6 地址后重试"
    echo "示例：TENCENT_IPV6='2402:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:0' bash configure_ipv6.sh"
    exit 1
fi

if [[ "$IPV6_ADDR_RAW" == */* ]]; then
    IPV6_ADDR="$IPV6_ADDR_RAW"
else
    IPV6_ADDR="${IPV6_ADDR_RAW}/${IPV6_PREFIX}"
fi
IPV6_ADDR_NO_PREFIX="${IPV6_ADDR%%/*}"

IFACE="${IFACE:-}"
if [ -z "$IFACE" ]; then
    IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
fi
if [ -z "$IFACE" ]; then
    IFACE=$(ip -br link show | awk '$1 != "lo" {print $1; exit}' | cut -d@ -f1)
fi
if [ -z "$IFACE" ] || ! ip link show dev "$IFACE" >/dev/null 2>&1; then
    log_fail "无法识别网卡，请用 IFACE=eth0 指定"
    exit 1
fi

log_step "配置参数"
log_info "网卡: $IFACE"
log_info "IPv6 地址: $IPV6_ADDR"
log_info "IPv6 网关: $IPV6_GW"
log_info "IPv6 DNS: $IPV6_DNS"

log_step "启用 IPv6 内核开关"
sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.$IFACE.disable_ipv6=0" >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.$IFACE.accept_ra=0" >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.$IFACE.autoconf=0" >/dev/null 2>&1 || true
ip link set dev "$IFACE" up

log_step "应用运行时 IPv6 配置"
if ip -6 -o addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$IPV6_ADDR_NO_PREFIX"; then
    log_info "IPv6 地址已存在"
else
    ip -6 addr add "$IPV6_ADDR" dev "$IFACE"
    log_info "已添加 IPv6 地址"
fi

ip -6 route replace "$IPV6_GW" dev "$IFACE" 2>/dev/null || true
ip -6 route replace default via "$IPV6_GW" dev "$IFACE"
log_info "已配置 IPv6 默认路由"

if [ "$PERSIST" = "1" ]; then
    log_step "写入持久化配置"
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-tencent-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.$IFACE.disable_ipv6 = 0
net.ipv6.conf.$IFACE.accept_ra = 0
net.ipv6.conf.$IFACE.autoconf = 0
EOF
    log_info "已写入 /etc/sysctl.d/99-tencent-ipv6.conf"

    if [ -f /etc/network/interfaces ]; then
        backup="/etc/network/interfaces.bak.tencent-ipv6.$(date +%s)"
        cp /etc/network/interfaces "$backup"

        # 删除旧的 BEGIN/END 块（如果存在）
        MARKER_START="# BEGIN tencent-cloud-cleanup ipv6 ${IFACE}"
        MARKER_END="# END tencent-cloud-cleanup ipv6 ${IFACE}"
        if grep -qF "$MARKER_START" /etc/network/interfaces 2>/dev/null; then
            # 用 sed 删除标记块（兼容 BSD/GNU sed）
            sed -i "/${MARKER_START}/,/${MARKER_END}/d" /etc/network/interfaces 2>/dev/null || \
            sed -e "/${MARKER_START}/,/${MARKER_END}/d" -i '' /etc/network/interfaces 2>/dev/null || true
        fi

        # 追加 IPv6 静态配置
        cat >> /etc/network/interfaces <<EOF

${MARKER_START}
iface ${IFACE} inet6 static
    address ${IPV6_ADDR}
    accept_ra 0
    autoconf 0
    dns-nameservers ${IPV6_DNS}
    post-up ip -6 route replace ${IPV6_GW} dev ${IFACE} || true
    post-up ip -6 route replace default via ${IPV6_GW} dev ${IFACE} || true
    pre-down ip -6 route del default via ${IPV6_GW} dev ${IFACE} 2>/dev/null || true
${MARKER_END}
EOF
        log_info "已更新 /etc/network/interfaces（备份: $backup）"
    else
        log_warn "未找到 /etc/network/interfaces，已跳过 ifupdown 持久化配置"
    fi

    if [ -f /etc/resolv.conf ]; then
        for dns in $IPV6_DNS; do
            if ! grep -qi "^nameserver[[:space:]]\+$dns$" /etc/resolv.conf; then
                echo "nameserver $dns" >> /etc/resolv.conf || true
            fi
        done
        log_info "已确保 /etc/resolv.conf 包含 IPv6 DNS"
    fi
fi

log_step "验证 IPv6"
echo "--- ip -6 addr show dev $IFACE ---"
ip -6 addr show dev "$IFACE"
echo "--- ip -6 route show ---"
ip -6 route show

echo "--- route get $TEST_IPV6 ---"
ip -6 route get "$TEST_IPV6" || true

if ping -6 -c 3 -W 3 "$TEST_IPV6" >/dev/null 2>&1; then
    log_info "IPv6 ping 测试通过: $TEST_IPV6"
else
    log_warn "IPv6 ping 未通过，继续尝试 curl -6"
fi

if command -v curl >/dev/null 2>&1; then
    if curl -6 -fsS --connect-timeout 10 https://ifconfig.co >/tmp/tencent-ipv6-test.out 2>/dev/null; then
        log_info "IPv6 HTTPS 测试通过，出口地址: $(tr -d '\n' </tmp/tencent-ipv6-test.out)"
    else
        log_warn "curl -6 测试未通过；请结合安全组、防火墙和控制台 IPv6 开关检查"
    fi
fi

log_info "IPv6 配置完成"
