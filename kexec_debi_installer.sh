#!/usr/bin/env bash
# ================================================================
# 强制通过 kexec 进入 debi/Debian Installer
# ================================================================
# 用途：当腾讯云轻量服务器重启后仍回旧系统，说明平台启动链可能没有消费
#       /boot/grub/grubenv 或 GRUB_DEFAULT。此脚本绕过 GRUB，直接从当前
#       内核运行 Debian Installer。
#
# 使用：
#   1. 先运行 debi.sh，让它生成 /boot/debian-* 安装器文件
#   2. bash kexec_debi_installer.sh
#
# 非交互：
#   KEXEC_CONFIRM=1 bash kexec_debi_installer.sh
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

KEXEC_CMDLINE="${KEXEC_CMDLINE:-auto=true priority=critical net.ifnames=0 biosdevname=0 lowmem/low=1 console=ttyS0,115200 console=tty0}"
INSTALL_KEXEC_TOOLS="${INSTALL_KEXEC_TOOLS:-1}"
KEXEC_CONFIRM="${KEXEC_CONFIRM:-0}"
APPEND_PRESEED="${APPEND_PRESEED:-1}"

if [ "$(id -u)" -ne 0 ]; then
    log_fail "请使用 root 用户运行此脚本"
    exit 1
fi

find_installer() {
    local dir kernel initrd
    for dir in /boot/debian-* /boot/debian; do
        [ -d "$dir" ] || continue
        kernel=""
        initrd=""
        for k in "$dir"/linux "$dir"/vmlinuz*; do
            [ -f "$k" ] && kernel="$k" && break
        done
        for i in "$dir"/initrd.gz "$dir"/initrd*; do
            [ -f "$i" ] && initrd="$i" && break
        done
        if [ -n "$kernel" ] && [ -n "$initrd" ]; then
            INSTALLER_DIR="$dir"
            INSTALLER_KERNEL="$kernel"
            INSTALLER_INITRD="$initrd"
            INSTALLER_PRESEED="$dir/preseed.cfg"
            return 0
        fi
    done
    return 1
}

ensure_kexec() {
    command -v kexec >/dev/null 2>&1 && return 0

    if [ "$INSTALL_KEXEC_TOOLS" != "1" ]; then
        return 1
    fi

    log_warn "未找到 kexec，尝试安装 kexec-tools"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y kexec-tools >/dev/null 2>&1 || {
            DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y kexec-tools >/dev/null 2>&1
        }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y kexec-tools >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y kexec-tools >/dev/null 2>&1
    fi

    command -v kexec >/dev/null 2>&1
}

append_preseed_to_initrd() {
    local preseed="$1"
    local initrd="$2"
    local tmp backup

    [ "$APPEND_PRESEED" = "1" ] || return 0
    [ -f "$preseed" ] || {
        log_warn "未找到 $preseed；将使用 initrd 内已有 preseed"
        return 0
    }
    command -v cpio >/dev/null 2>&1 || {
        log_warn "未找到 cpio，无法重新嵌入 preseed.cfg"
        return 0
    }

    backup="${initrd}.bak.kexec.$(date +%s)"
    cp "$initrd" "$backup"
    tmp=$(mktemp -d)
    cp "$preseed" "$tmp/preseed.cfg"
    (cd "$tmp" && find preseed.cfg | cpio -H newc -o 2>/dev/null | gzip -c >> "$initrd")
    rm -rf "$tmp"
    log_info "已将当前 preseed.cfg 追加嵌入 initrd，原 initrd 备份为 $backup"
}

log_step "检查 Debian Installer 文件"
if ! find_installer; then
    log_fail "未找到 /boot/debian-* 安装器文件；请先运行 debi.sh 生成安装器"
    exit 1
fi

log_info "安装器目录: $INSTALLER_DIR"
log_info "内核: $INSTALLER_KERNEL"
log_info "initrd: $INSTALLER_INITRD"
[ -f "$INSTALLER_PRESEED" ] && log_info "preseed: $INSTALLER_PRESEED" || log_warn "preseed.cfg 不存在"

log_step "准备 kexec"
if ! ensure_kexec; then
    log_fail "kexec 不可用；无法绕过 GRUB 直接进入安装器"
    exit 1
fi

append_preseed_to_initrd "$INSTALLER_PRESEED" "$INSTALLER_INITRD"

cat <<EOF

即将通过 kexec 直接进入 Debian Installer。
这会断开当前 SSH，并按 preseed 配置重装系统；目标磁盘通常会被覆盖。

命令行参数：
  $KEXEC_CMDLINE
EOF

if [ "$KEXEC_CONFIRM" != "1" ]; then
    if [ -t 0 ]; then
        read -r -p "确认执行？输入 KEXEC ：" confirm
        [ "$confirm" = "KEXEC" ] || {
            echo "已取消。"
            exit 0
        }
    else
        log_fail "非交互环境请设置 KEXEC_CONFIRM=1"
        exit 1
    fi
fi

log_info "加载安装器内核"
kexec -l "$INSTALLER_KERNEL" --initrd="$INSTALLER_INITRD" --command-line="$KEXEC_CMDLINE"

log_info "同步磁盘并进入 Debian Installer"
sync
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl kexec
else
    kexec -e
fi
