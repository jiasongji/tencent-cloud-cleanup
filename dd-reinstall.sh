#!/usr/bin/env bash
# ================================================================
# 腾讯云 DD 重装 Debian 12 脚本 v2.1（内置 config-drive 阻断 + kexec 直跳）
# ================================================================
# 适用：腾讯云 CVM、轻量应用服务器（Lighthouse）
# 要求：root 权限、Debian 系列系统（用于运行此脚本）
#
# 问题根源：
#   腾讯云的 config-drive (/dev/sr0, label=config-2) 包含 vendor_data.json，
#   其中嵌入了完整的 cloud-init 配置，会在每次启动时：
#   - bootcmd: 从 config-drive 复制 cloudRun.sh 到 per-boot 目录（每次启动执行）
#   - bootcmd: 复制 action.sh 并执行 downsr_rollback
#   - runcmd: 挂载 config-drive, 复制整个 /qcloud_init/ 到根目录
#   - runcmd: 执行 cvm_init.sh（安装 YunJing + Stargate + TAT + Barad 等全部组件）
#   - runcmd: 设置 root 密码、hostname、ntp 等
#   - write_files: 写入 /etc/uuid
#   新系统若启用 cloud-init 并读取 config-drive，腾讯组件可能被重新安装
#
# 解决方案：
#   第一重：安装前（当前系统）—— 卸载并禁用 config-drive，阻止 cloud-init 写入缓存
#   第二重：preseed 阶段 —— 在 late_command 中彻底禁用 cloud-init 和 sr_mod
#   第三重：新系统首次启动 —— 通过 systemd 服务做最终清理和验证
#   启动兜底：优先用 kexec 直接进入 Debian Installer，绕过不消费 grubenv 的平台启动链
#
# 使用方法：
#   scp dd-reinstall.sh root@<IP>:/root/
#   ssh root@<IP> 'bash /root/dd-reinstall.sh'
# ================================================================

set -euo pipefail

# ======================== 配置 ========================
# 新系统配置（可通过环境变量覆盖；不要把密码写入公开脚本）
NEW_USER="${NEW_USER:-debian}"
NEW_PASSWORD="${NEW_PASSWORD:-}"
NEW_SSH_PORT="${NEW_SSH_PORT:-8622}"
NEW_HOSTNAME="${NEW_HOSTNAME:-debian}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

# IPv6（腾讯云控制台分配的地址，留空则不配置 IPv6）
IPV6_ADDR="${TENCENT_IPV6:-}"
IPV6_GW="${TENCENT_IPV6_GW:-fe80::1}"

# debi.sh 下载地址（多重备选，适合中国网络环境）
DEBI_URLS=(
  "https://ghfast.top/https://raw.githubusercontent.com/bohanwood/debi/master/debi.sh"
  "https://gh-proxy.com/https://raw.githubusercontent.com/bohanwood/debi/master/debi.sh"
  "https://ghps.cc/https://raw.githubusercontent.com/bohanwood/debi/master/debi.sh"
  "https://gh-proxy.org/https://raw.githubusercontent.com/bohanwood/debi/master/debi.sh"
)

# Debian 安装镜像（使用腾讯内网加速源，无需代理）
MIRROR_HOST="mirrors.tencentyun.com"
MIRROR_DIR="/debian"
SECURITY_REPO="http://mirrors.tencentyun.com/debian-security/"

# DNS（腾讯内网 DNS）
DNS_SERVERS="183.60.83.19 183.60.82.98"

# 启动方式：默认 kexec，绕过部分腾讯云轻量实例不消费 grubenv/GRUB_DEFAULT 的问题
BOOT_METHOD="${BOOT_METHOD:-kexec}"
KEXEC_CMDLINE="${KEXEC_CMDLINE:-auto=true priority=critical net.ifnames=0 biosdevname=0 lowmem/low=1 console=ttyS0,115200 console=tty0}"
INSTALL_KEXEC_TOOLS="${INSTALL_KEXEC_TOOLS:-1}"

# ======================== 颜色 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()  { echo -e "\n${CYAN}======== $* =======${NC}"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

ensure_kexec() {
    command -v kexec >/dev/null 2>&1 && return 0
    [ "$INSTALL_KEXEC_TOOLS" = "1" ] || return 1

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
    local dir initrd tmp backup

    dir=$(dirname "$preseed")
    initrd=""
    for i in "$dir"/initrd.gz "$dir"/initrd*; do
        [ -f "$i" ] && initrd="$i" && break
    done

    if [ -z "$initrd" ]; then
        log_fail "找不到 Debian Installer initrd"
        exit 1
    fi
    if ! command -v cpio >/dev/null 2>&1; then
        log_fail "未找到 cpio，无法把修补后的 preseed.cfg 嵌入 initrd"
        exit 1
    fi

    backup="${initrd}.bak.preseed.$(date +%s)"
    cp "$initrd" "$backup"
    tmp=$(mktemp -d)
    cp "$preseed" "$tmp/preseed.cfg"
    (cd "$tmp" && find preseed.cfg | cpio -H newc -o 2>/dev/null | gzip -c >> "$initrd")
    rm -rf "$tmp"
    log_info "已将修补后的 preseed.cfg 追加嵌入 initrd，原 initrd 备份为 $backup"
}

boot_debian_installer() {
    local preseed="$1"
    local dir kernel initrd

    dir=$(dirname "$preseed")
    kernel=""
    initrd=""
    for k in "$dir"/linux "$dir"/vmlinuz*; do
        [ -f "$k" ] && kernel="$k" && break
    done
    for i in "$dir"/initrd.gz "$dir"/initrd*; do
        [ -f "$i" ] && initrd="$i" && break
    done

    if [ -z "$kernel" ] || [ -z "$initrd" ]; then
        log_fail "找不到 Debian Installer kernel/initrd"
        exit 1
    fi

    if [ "$BOOT_METHOD" != "reboot" ] && ensure_kexec; then
        log_info "使用 kexec 直接进入 Debian Installer，绕过 GRUB/grubenv"
        kexec -l "$kernel" --initrd="$initrd" --command-line="$KEXEC_CMDLINE"
        sync
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl kexec
        else
            kexec -e
        fi
    fi

    log_warn "kexec 不可用，回退为普通 reboot；若重启仍回旧系统，请运行 kexec_debi_installer.sh"
    reboot
}

# ======================== 检查 root ========================
if [ "$(id -u)" -ne 0 ]; then
    log_fail "请使用 root 用户运行此脚本"
    exit 1
fi

if [ -z "$NEW_PASSWORD" ]; then
    if [ -t 0 ]; then
        read -r -s -p "请输入新系统 ${NEW_USER} 的 SSH 密码: " NEW_PASSWORD
        echo ""
    else
        log_fail "未设置 NEW_PASSWORD，非交互环境请用环境变量传入"
        exit 1
    fi
fi

# ======================== 显示配置 ========================
echo ""
echo "============================================================"
echo "     腾讯云 DD 重装 Debian 12 脚本 v2.1"
echo "     （内置 config-drive 阻断 + kexec 直跳）"
echo "============================================================"
echo ""
echo "新系统配置："
echo "  用户名：${NEW_USER}"
echo "  密码：已设置（不回显）"
echo "  SSH 端口：${NEW_SSH_PORT}"
echo "  主机名：${NEW_HOSTNAME}"
echo "  时区：${TIMEZONE}"
echo "  镜像源：${MIRROR_HOST}（腾讯内网加速）"
echo "  IPv6：${IPV6_ADDR:-未配置}"
echo "  启动方式：${BOOT_METHOD}"
echo ""

# ======================== 阶段 0：系统信息收集 ========================
log_step "阶段 0：系统信息收集"

echo "当前主机名: $(hostname)"
echo "当前系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2- | tr -d '"')"
echo "内核: $(uname -r)"
echo "架构: $(uname -m)"

echo ""
echo "--- 网卡 ---"
ip -br addr show

echo ""
echo "--- 磁盘 ---"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE 2>/dev/null

echo ""
echo "--- config-drive ---"
if [ -b /dev/sr0 ]; then
    log_warn "检测到 config-drive 设备 /dev/sr0（这是自恢复的根源）"
    if mount | grep -q "/dev/sr0"; then
        log_info "  当前已挂载: $(mount | grep sr0 | awk '{print $3}')"
    else
        log_info "  当前未挂载"
    fi
else
    log_info "未检测到 /dev/sr0"
fi

# ======================== 识别系统盘 ========================
ROOT_SRC="$(findmnt -n -o SOURCE /)"
ROOT_DISK_NAME="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"

if [ -z "${ROOT_DISK_NAME}" ]; then
    ROOT_DISK="$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')"
else
    ROOT_DISK="/dev/${ROOT_DISK_NAME}"
fi

if [ -z "${ROOT_DISK}" ] || [ ! -b "${ROOT_DISK}" ]; then
    log_fail "无法自动识别系统盘，请手动指定"
    echo "用法：编辑脚本中的 ROOT_DISK 变量"
    exit 1
fi

log_info "系统盘: ${ROOT_DISK}"

# ======================== 获取网络信息 ========================
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$IFACE" ]; then
    # 回退：取第一个非 lo 的 UP 网卡
    IFACE=$(ip -br addr show | grep -v "^lo" | awk '$2=="UP" || $2=="UNKNOWN" {print $1; exit}')
fi

IP_ADDR=$(ip -4 addr show "$IFACE" | grep inet | awk '{print $2}' | head -1)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
MAC_ADDR=$(cat /sys/class/net/"$IFACE"/address 2>/dev/null || echo "unknown")

echo ""
echo "网络配置："
echo "  接口: $IFACE"
echo "  IP: $IP_ADDR"
echo "  网关: $GATEWAY"
echo "  MAC: $MAC_ADDR"
echo "  DNS: $DNS_SERVERS"

# ======================== 确认提示 ========================
echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}  ⚠️  警告：此操作将完全覆盖 ${ROOT_DISK} 上的数据！${NC}"
echo -e "${RED}  ⚠️  新系统将禁用 cloud-init，腾讯云控制台功能全部失效${NC}"
echo -e "${RED}  ⚠️  新系统 SSH 端口 ${NEW_SSH_PORT}，用户 ${NEW_USER}${NC}"
echo -e "${RED}============================================================${NC}"
echo ""
read -r -p "确认继续？输入 REINSTALL ：" CONFIRM

if [ "${CONFIRM}" != "REINSTALL" ]; then
    echo "已取消。"
    exit 0
fi

# ================================================================
#  第一重阻断：安装前禁用 config-drive（当前系统中）
#  这一步非常关键：阻止 cloud-init 在重启时读取 vendor_data.json
# ================================================================

log_step "第一重阻断：禁用当前系统的 config-drive"

# 1. 卸载已挂载的 config-drive
if mount | grep -q "/dev/sr0"; then
    MOUNT_POINT=$(mount | grep "/dev/sr0" | awk '{print $3}')
    umount "$MOUNT_POINT" 2>/dev/null && log_info "已卸载 config-drive ($MOUNT_POINT)" || log_warn "卸载 config-drive 失败"
fi

# 2. 禁用 cloud-init（防止重启后自动读取 config-drive）
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop cloud-init-local cloud-init cloud-config cloud-final 2>/dev/null || true
    systemctl disable cloud-init-local cloud-init cloud-config cloud-final 2>/dev/null || true
    log_info "已停止并禁用 cloud-init 服务"
fi

mkdir -p /etc/cloud
echo "disabled by DD reinstall script" > /etc/cloud/cloud-init.disabled
log_info "已创建 /etc/cloud/cloud-init.disabled"

# 3. 清除 cloud-init 缓存（防止使用旧的 vendor_data 缓存）
rm -rf /var/lib/cloud/* 2>/dev/null || true
log_info "已清除 cloud-init 缓存"

# 4. 从 fstab 中删除 sr0 挂载
if grep -q "sr0" /etc/fstab 2>/dev/null; then
    cp /etc/fstab /etc/fstab.bak.dd
    sed -i '/sr0/d' /etc/fstab
    log_info "已从 fstab 中移除 sr0 挂载"
fi

# 5. 清理 cloud-init 的 per-boot 脚本
rm -f /var/lib/cloud/scripts/per-boot/cloudRun.sh 2>/dev/null || true
rm -f /usr/local/qcloud/action/action.sh 2>/dev/null || true
rm -rf /qcloud_init 2>/dev/null || true
log_info "已清理 cloud-init per-boot 和安装脚本"

log_info "第一重阻断完成"

# ================================================================
#  下载 debi.sh（多重备选）
# ================================================================

log_step "下载 debi.sh"

DEBI_SH="/root/debi.sh"
DOWNLOADED=false

for url in "${DEBI_URLS[@]}"; do
    log_info "尝试: $url"
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "${DEBI_SH}" "$url" 2>/dev/null; then
        # 验证下载的文件是有效的 shell 脚本
        if head -1 "${DEBI_SH}" 2>/dev/null | grep -qE "^#!/"; then
            DOWNLOADED=true
            log_info "下载成功: $url"
            break
        else
            log_warn "下载的文件不是有效的 shell 脚本，尝试下一个地址"
            rm -f "${DEBI_SH}"
        fi
    fi
done

if [ "$DOWNLOADED" = false ]; then
    log_fail "所有下载地址均失败，请检查网络连接"
    echo "你可以手动下载 debi.sh 并上传到服务器："
    echo "  scp debi.sh root@$(hostname -I | awk '{print $1}'):${DEBI_SH}"
    exit 1
fi

chmod +x "${DEBI_SH}"
log_info "debi.sh 准备完成"

# ================================================================
#  执行 debi.sh 配置 Debian 安装
# ================================================================

log_step "配置 Debian 安装"

# 清理旧配置
rm -rf /etc/default/grub.d/zz-debi.cfg /boot/debian-* 2>/dev/null || true
update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true

# 注意：debi.sh 内部使用 stty -echo 读取密码，在非 PTY 环境会失败
# 即使已通过 --password 提供密码，stty 仍会报错
# 解决方案：patch debi.sh 跳过 stty 调用
sed -i 's/stty -echo/# stty -echo/g' "${DEBI_SH}"
sed -i "s/stty echo/# stty echo/g" "${DEBI_SH}"
sed -i "s/trap 'stty echo' EXIT/# trap 'stty echo' EXIT/g" "${DEBI_SH}"
log_info "已修补 debi.sh（跳过 stty 调用）"

# 执行 debi.sh
# 注意：--ethx 让网卡名使用 eth0 格式（而不是 ens5 等预测命名）
# 注意：使用腾讯内网镜像源，无需代理
bash "${DEBI_SH}" \
  --version 12 \
  --user "${NEW_USER}" \
  --password "${NEW_PASSWORD}" \
  --hostname "${NEW_HOSTNAME}" \
  --ssh-port "${NEW_SSH_PORT}" \
  --ethx \
  --bbr \
  --cloud-kernel \
  --timezone "${TIMEZONE}" \
  --ntp 'ntp.tencent.com' \
  --dns "${DNS_SERVERS}" \
  --mirror-protocol http \
  --mirror-host "${MIRROR_HOST}" \
  --mirror-directory "${MIRROR_DIR}" \
  --security-repository "${SECURITY_REPO}" \
  --apt-contrib \
  --apt-non-free \
  --apt-non-free-firmware \
  --no-apt-backports \
  --no-install-recommends \
  --no-apt-src \
  --grub-timeout 1 \
  2>&1 | tee /root/debi-run.log

# ================================================================
#  第二重阻断：修补 preseed.cfg
# ================================================================

log_step "第二重阻断：修补 preseed.cfg"

# 找到 debi.sh 生成的 preseed.cfg
PRESEED_FILE=""
for f in /boot/debian-*/preseed.cfg /boot/debian-bookworm/preseed.cfg; do
    if [ -f "$f" ]; then
        PRESEED_FILE="$f"
        break
    fi
done

if [ -z "$PRESEED_FILE" ]; then
    log_fail "找不到 preseed.cfg，debi.sh 可能未成功执行"
    exit 1
fi

log_info "找到 preseed.cfg: $PRESEED_FILE"
cp "$PRESEED_FILE" "${PRESEED_FILE}.bak"

# 构造 late_command 的方式：将脚本内容写入独立文件，在 preseed 中复制到目标系统并执行
# 这避免了多层引号嵌套的解析问题

# 找到 debi.sh 生成的安装文件目录
INSTALLER_DIR=$(dirname "$PRESEED_FILE")
LATE_SCRIPT_SRC="${INSTALLER_DIR}/late_command.sh"
LATE_SCRIPT_DST="/tmp/late_command.sh"

log_info "创建 late_command 脚本文件: $LATE_SCRIPT_SRC"

cat > "$LATE_SCRIPT_SRC" << 'LATEEOF'
#!/bin/sh
# ================================================================
#  preseed late_command 脚本（由 dd-reinstall.sh 生成）
#  功能：三重阻断 config-drive 自恢复机制
# ================================================================
set -x

echo "================================================"
echo "  第二重阻断：preseed late_command"
echo "================================================"

# [1/10] 完全卸载 cloud-init
echo "=== [1/10] 完全卸载 cloud-init ==="
apt-get purge -y cloud-init 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
rm -rf /etc/cloud /var/lib/cloud

# [2/10] 创建 cloud-init 禁用标记
echo "=== [2/10] 创建 cloud-init 禁用标记 ==="
mkdir -p /etc/cloud
echo "cloud-init permanently disabled by DD reinstall script" > /etc/cloud/cloud-init.disabled

# [3/10] 创建 udev 规则忽略 config-drive
echo "=== [3/10] 创建 udev 规则忽略 config-drive ==="
mkdir -p /etc/udev/rules.d
echo 'SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="config-2", OPTIONS="ignore_device"' > /etc/udev/rules.d/99-ignore-config-drive.rules
echo 'KERNEL=="sr0", OPTIONS="ignore_device"' >> /etc/udev/rules.d/99-ignore-config-drive.rules

# [4/10] 黑名单 sr_mod 内核模块
echo "=== [4/10] 黑名单 sr_mod 内核模块 ==="
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/blacklist-cdrom.conf << 'MEOF'
# 禁用光驱模块，阻止加载腾讯云 config-drive
blacklist sr_mod
blacklist cdrom
install sr_mod /bin/true
install cdrom /bin/true
MEOF

# [5/10] 清理 fstab
echo "=== [5/10] 清理 fstab ==="
sed -i '/sr0/d' /etc/fstab
sed -i '/config-2/d' /etc/fstab
sed -i '/cdrom/d' /etc/fstab

# [6/10] 写入静态网络配置
echo "=== [6/10] 写入静态网络配置 ==="
mkdir -p /etc/network
cat > /etc/network/interfaces << 'NETEOF'
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface（使用 DHCP 获取 IP）
allow-hotplug eth0
iface eth0 inet dhcp
auto eth0
NETEOF

# [7/10] 配置 DNS
echo "=== [7/10] 配置 DNS ==="
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'DNSEOF'
nameserver 183.60.83.19
nameserver 183.60.82.98
DNSEOF
chattr +i /etc/resolv.conf 2>/dev/null || true

# [8/10] 清理残留文件
echo "=== [8/10] 清理残留文件 ==="
rm -rf /qcloud_init /usr/local/qcloud /etc/qcloudzone
rm -rf /var/lib/cloud
rm -f /etc/profile.d/go_conf.sh
rm -f /etc/tencentcloud_ipv6_base.sh
rm -f /etc/ld.so.preload
rm -rf /opt/qcloud /opt/tencent

# [9/10] SSH 配置
echo "=== [9/10] SSH 配置 ==="
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup 2>/dev/null || true
sed -Ei 's/^#?PermitRootLogin .+/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
sed -Ei 's/^#?PasswordAuthentication .+/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true

# [10/10] BBR + 内核参数
echo "=== [10/10] BBR + 内核参数 ==="
mkdir -p /etc/sysctl.d
echo 'net.core.default_qdisc=fq' > /etc/sysctl.d/bbr.conf
echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.d/bbr.conf
echo 'net.ipv6.conf.all.autoconf=0' > /etc/sysctl.d/disable-ipv6-autoconf.conf
echo 'net.ipv6.conf.eth0.autoconf=0' >> /etc/sysctl.d/disable-ipv6-autoconf.conf
LATEEOF

# IPv6 配置（追加到 late_command 脚本）
if [ -n "${IPV6_ADDR}" ] && [ "${IPV6_ADDR}" != "none" ]; then
    IPV6_PREFIX="64"
    cat >> "$LATE_SCRIPT_SRC" << IPV6BLOCK

# IPv6 配置
echo '=== 配置 IPv6 ==='
ip -6 addr add ${IPV6_ADDR}/${IPV6_PREFIX} dev eth0 2>/dev/null || true
ip -6 route add default via ${IPV6_GW} dev eth0 2>/dev/null || true
cat >> /etc/network/interfaces << 'IPV6EOF'

# IPv6
iface eth0 inet6 static
    address ${IPV6_ADDR}
    netmask ${IPV6_PREFIX}
    gateway ${IPV6_GW}
IPV6EOF
echo 'IPv6 配置完成'
IPV6BLOCK
fi

# 第三重阻断：systemd 清理服务 + sudoer 配置（追加）
cat >> "$LATE_SCRIPT_SRC" << 'LATEEOF2'

# 第三重阻断 systemd 服务
echo '=== 创建第三重阻断 systemd 服务 ==='
cat > /etc/systemd/system/tencent-cleanup.service << 'SVCEOF'
[Unit]
Description=Tencent Cloud Config-Drive Cleanup (One-shot)
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe -r sr_mod 2>/dev/null; rm -rf /var/lib/cloud /qcloud_init /usr/local/qcloud /etc/qcloudzone 2>/dev/null; mkdir -p /etc/cloud; echo disabled > /etc/cloud/cloud-init.disabled'

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable tencent-cleanup.service 2>/dev/null || true

echo '=== 完成：三重阻断全部就绪 ==='
LATEEOF2

chmod +x "$LATE_SCRIPT_SRC"
log_info "late_command 脚本已创建 ($(wc -l < "$LATE_SCRIPT_SRC") 行)"

# 将 late_command 脚本写入 preseed 的 late_command
# 使用 base64 编码避免引号嵌套问题
# 在 preseed late_command 中：解码脚本到目标系统并执行

# 生成 base64 编码的 late_command 脚本
LATE_B64=$(base64 -w0 "$LATE_SCRIPT_SRC")
log_info "late_command 脚本已编码（$(echo "$LATE_B64" | wc -c) 字节）"

# 替换 preseed 中的 late_command
# 格式：in-target sh -c 'echo BASE64 | base64 -d | sh'
sed -i '/^d-i preseed\/late_command/d' "$PRESEED_FILE"
echo "" >> "$PRESEED_FILE"
echo "# 阻断 config-drive 自恢复（三重阻断：preseed late_command）" >> "$PRESEED_FILE"
echo "d-i preseed/late_command string in-target sh -c 'echo ${LATE_B64} | base64 -d | sh'" >> "$PRESEED_FILE"

# 在 pkgsel 中排除 cloud-init
if ! grep -q "cloud-init" "$PRESEED_FILE" 2>/dev/null; then
    sed -i '/pkgsel\/include/a d-i pkgsel/exclude string cloud-init cloud-init-local' "$PRESEED_FILE"
    log_info "已在 pkgsel 中排除 cloud-init"
fi

log_info "preseed.cfg 修补完成"
append_preseed_to_initrd "$PRESEED_FILE"

# ================================================================
#  验证
# ================================================================

log_step "验证配置"

echo "--- late_command 内容 ---"
grep "late_command" "$PRESEED_FILE" | head -1
echo ""
echo "--- cloud-init 排除 ---"
grep "cloud-init\|pkgsel/exclude" "$PRESEED_FILE" || echo "未找到排除配置"

echo ""
echo "--- GRUB 启动项 ---"
ls -lah /boot/debian-*/ 2>/dev/null || true
echo ""
cat /etc/default/grub.d/zz-debi.cfg 2>/dev/null || true

echo ""
echo "--- GRUB 配置验证 ---"
grep -Ei -n "debi|debian.*install|installer" /boot/grub/grub.cfg 2>/dev/null | head -10 || true

# ================================================================
#  最终确认和重启
# ================================================================

echo ""
echo "============================================================"
echo "  ✅ 三重阻断配置全部完成！"
echo ""
echo "  新系统配置："
echo "    用户名：${NEW_USER}"
echo "    密码：已设置（不回显）"
echo "    SSH 端口：${NEW_SSH_PORT}"
echo "    主机名：${NEW_HOSTNAME}"
echo "    镜像源：${MIRROR_HOST}（腾讯内网加速）"
echo "    BBR：已启用"
echo "    时区：${TIMEZONE}"
echo ""
echo "  三重阻断："
echo "    第一重：当前系统已禁用 cloud-init 和 config-drive ✅"
echo "    第二重：preseed late_command 已注入阻断逻辑 ✅"
echo "    第三重：新系统首次启动清理服务已创建 ✅"
echo ""
echo "  重装后连接命令："
echo "    ssh -p ${NEW_SSH_PORT} ${NEW_USER}@$(hostname -I | awk '{print $1}')"
echo ""
echo -e "  ${RED}注意：重装过程需要 10-20 分钟，请耐心等待${NC}"
echo "  ${RED}注意：如果 SSH 连不上，请等待几分钟后再试${NC}"
echo "  启动方式：${BOOT_METHOD}（默认优先 kexec，避免重启回旧系统）"
echo "============================================================"
echo ""

read -r -p "现在进入 Debian Installer？输入 BOOT ：" BOOT_CONFIRM

if [ "${BOOT_CONFIRM}" = "BOOT" ] || [ "${BOOT_CONFIRM}" = "REBOOT" ]; then
    log_info "3 秒后进入 Debian Installer..."
    sleep 3
    boot_debian_installer "$PRESEED_FILE"
else
    echo "未启动安装器。你稍后可以执行："
    echo "  KEXEC_CONFIRM=1 bash /root/kexec_debi_installer.sh"
    echo ""
    echo "重装完成后，请用以下命令连接新系统："
    echo "  ssh -p ${NEW_SSH_PORT} ${NEW_USER}@$(hostname -I | awk '{print $1}')"
fi
