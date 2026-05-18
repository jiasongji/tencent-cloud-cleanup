#!/usr/bin/env bash
# ================================================================
# 腾讯云 DD 重装 Debian 12 脚本（解决 config-drive 自恢复问题）
# ================================================================
# 适用：腾讯云 CVM、轻量应用服务器（Lighthouse）
# 要求：root 权限、Debian 系列系统（用于运行此脚本）
# 原理：
#   1. 使用 debi.sh 创建 Debian Installer GRUB 引导项
#   2. 通过 preseed.cfg 自动化安装
#   3. 在 preseed/late_command 中禁用 cloud-init 并阻断 config-drive
#   4. 安装完成后重启进入纯净 Debian
#
# 问题根源：
#   腾讯云的 config-drive (/dev/sr0, label=config-2) 包含 vendor_data.json，
#   其中嵌入了完整的 cloud-init 配置，会在每次启动时：
#   - 从 config-drive 复制 cloudRun.sh 到 per-boot 目录
#   - 复制 /qcloud_init/ 并执行 cvm_init.sh（安装所有腾讯组件）
#   - 设置 root 密码、hostname、ntp 等
#   无论你 DD 什么新系统，cloud-init 检测到 config-drive 后都会重新安装腾讯组件
#
# 解决方案：
#   在 preseed 的 late_command 中：
#   1. 完全卸载 cloud-init
#   2. 创建 /etc/cloud/cloud-init.disabled 禁用文件
#   3. 写入自定义网络配置（防止 cloud-init 被卸载后网络丢失）
#   4. 创建 udev 规则忽略 config-drive
# ================================================================

set -euo pipefail

DEBI_URL="https://gh-proxy.org/https://raw.githubusercontent.com/bohanwood/debi/master/debi.sh"
DEBI_SH="/root/debi.sh"

echo "==> 1. 检查当前系统信息"
echo "当前主机名: $(hostname)"
echo "当前系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2- | tr -d '"')"
echo

echo "==> 2. 检查网卡"
ip -br addr show
echo

echo "==> 3. 检查磁盘"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE,MODEL
echo

ROOT_SRC="$(findmnt -n -o SOURCE /)"
ROOT_DISK_NAME="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"

if [ -z "${ROOT_DISK_NAME}" ]; then
  ROOT_DISK="$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')"
else
  ROOT_DISK="/dev/${ROOT_DISK_NAME}"
fi

if [ -z "${ROOT_DISK}" ] || [ ! -b "${ROOT_DISK}" ]; then
  echo "错误：无法自动识别系统盘，请手动执行 lsblk 后指定 --disk /dev/xxx"
  exit 1
fi

echo "自动识别到当前系统盘为: ${ROOT_DISK}"
echo

echo "==> 4. 获取当前网络配置（用于新系统）"
# 获取 IP/网关/DNS 信息
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
IP_ADDR=$(ip -4 addr show "$IFACE" | grep inet | awk '{print $2}' | head -1)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
DNS_SERVERS=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
echo "接口: $IFACE"
echo "IP: $IP_ADDR"
echo "网关: $GATEWAY"
echo "DNS: $DNS_SERVERS"
echo

echo "警告：即将通过 debi.sh 重装 Debian 12，目标磁盘 ${ROOT_DISK} 上的数据会被覆盖。"
echo -e "\033[31m警告：新系统将完全禁用 cloud-init，腾讯云控制台功能将全部失效！\033[0m"
echo -e "\033[31m警告：新系统 SSH 端口为 8622，用户名 debian，密码 Tadminn..\033[0m"
echo
read -r -p "确认继续请输入 REINSTALL ：" CONFIRM

if [ "${CONFIRM}" != "REINSTALL" ]; then
  echo "已取消。"
  exit 1
fi

echo
echo "==> 5. 下载 debi.sh"
curl -fL --retry 5 --connect-timeout 15 -o "${DEBI_SH}" "${DEBI_URL}"
chmod +x "${DEBI_SH}"

echo
echo "==> 6. 检查 debi.sh 是否可执行"
bash "${DEBI_SH}" --help >/tmp/debi-help.txt 2>&1 || true
head -n 40 /tmp/debi-help.txt || true

echo
echo "==> 7. 清理旧的 debi GRUB 注入配置，避免上次残留影响"
rm -rf /etc/default/grub.d/zz-debi.cfg /boot/debian-* || true
update-grub || grub2-mkconfig -o /boot/grub2/grub.cfg || true

echo
echo "==> 8. 执行 Debian 12 网络重装配置"
bash "${DEBI_SH}" \
  --version 12 \
  --user debian \
  --password 'Tadminn..' \
  --hostname 'TX-BJ' \
  --ssh-port 8622 \
  --ethx \
  --bbr \
  --cloud-kernel \
  --timezone 'Asia/Shanghai' \
  --ntp 'ntp.tencent.com' \
  --dns '183.60.83.19 183.60.82.98' \
  --mirror-protocol http \
  --mirror-host 'mirrors.tencentyun.com' \
  --mirror-directory '/debian' \
  --security-repository 'http://mirrors.tencentyun.com/debian-security/' \
  --apt-contrib \
  --apt-non-free \
  --apt-non-free-firmware \
  --no-apt-backports \
  --no-install-recommends \
  --no-apt-src \
  --grub-timeout 1 \
  2>&1 | tee /root/debi-run.log

echo
echo "==> 9. 修补 preseed.cfg —— 阻断 config-drive 自恢复"
# 找到 debi.sh 生成的 preseed.cfg
PRESEED_FILE=""
for f in /boot/debian-*/preseed.cfg /boot/debian-bookworm/preseed.cfg; do
    if [ -f "$f" ]; then
        PRESEED_FILE="$f"
        break
    fi
done

if [ -z "$PRESEED_FILE" ]; then
    echo "错误：找不到 preseed.cfg，debi.sh 可能未成功执行"
    exit 1
fi

echo "找到 preseed.cfg: $PRESEED_FILE"

# 备份原始 preseed
cp "$PRESEED_FILE" "${PRESEED_FILE}.bak"

# 构造 late_command 的补充内容
# 关键操作：
# 1. 完全卸载 cloud-init（防止它处理 config-drive 的 vendor_data）
# 2. 创建 /etc/cloud/cloud-init.disabled（双重保险）
# 3. 禁用 config-drive 的自动挂载
# 4. 写入静态网络配置（因为 cloud-init 不再管理网络）
# 5. 清理 fstab 中的 sr0 挂载
# 6. 确保 SSH 配置正确
LATE_CMD='true; in-target sh -c '\''
echo "=== 禁用 cloud-init ===";
mkdir -p /etc/cloud/;
touch /etc/cloud/cloud-init.disabled;
echo "cloud-init disabled by DD script" > /etc/cloud/cloud-init.disabled;
apt-get purge -y cloud-init 2>/dev/null || true;
apt-get autoremove -y 2>/dev/null || true;
rm -rf /etc/cloud /var/lib/cloud;

echo "=== 阻断 config-drive ===";
# 从 fstab 中删除 sr0 挂载
sed -i "/sr0/d" /etc/fstab;
# 创建 udev 规则忽略 config-drive
mkdir -p /etc/udev/rules.d;
echo "SUBSYSTEM==\"block\", ENV{ID_FS_LABEL}==\"config-2\", OPTIONS=\"ignore_device\"" > /etc/udev/rules.d/99-ignore-config-drive.rules;
# 禁用自动挂载
echo "blacklist sr_mod" > /etc/modprobe.d/blacklist-cdrom.conf;

echo "=== 写入静态网络配置 ===";
mkdir -p /etc/network;
cat > /etc/network/interfaces << "NETEOF";
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug eth0
NETEOF

# 使用 DHCP（腾讯云 DHCP 会分配正确的 IP）
echo "iface eth0 inet dhcp" >> /etc/network/interfaces;
echo "auto eth0" >> /etc/network/interfaces;

echo "=== 配置 DNS ===";
rm -f /etc/resolv.conf;
cat > /etc/resolv.conf << "DNSEOF";
nameserver 183.60.83.19
nameserver 183.60.82.98
DNSEOF
chattr +i /etc/resolv.conf 2>/dev/null || true;

echo "=== 清理残留 ===";
rm -rf /qcloud_init /usr/local/qcloud /etc/qcloudzone;
rm -f /etc/profile.d/go_conf.sh;
rm -f /etc/tencentcloud_ipv6_base.sh;

echo "=== SSH 配置 ===";
if [ ! -e "/etc/ssh/sshd_config.backup" ]; then cp "/etc/ssh/sshd_config" "/etc/ssh/sshd_config.backup"; fi;
sed -Ei "s/^#?PermitRootLogin .+/PermitRootLogin yes/" /etc/ssh/sshd_config;
sed -Ei "s/^#?Port .+/Port 8622/" /etc/ssh/sshd_config;
echo "debian ALL=(ALL:ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-user-debian";

echo "=== BBR ===";
{ echo "net.core.default_qdisc=fq"; echo "net.ipv4.tcp_congestion_control=bbr"; } > /etc/sysctl.d/bbr.conf;

echo "=== 完成 ==="
'\'''

# 替换 preseed 中的 late_command
# 在原 late_command 后追加我们的内容
# 先删除原来的 late_command 行，然后追加新的
sed -i '/^d-i preseed\/late_command/d' "$PRESEED_FILE"
echo "" >> "$PRESEED_FILE"
echo "# 阻断 config-drive 自恢复并禁用 cloud-init" >> "$PRESEED_FILE"
echo "d-i preseed/late_command string $LATE_CMD" >> "$PRESEED_FILE"

echo "preseed.cfg 已修补"
echo ""

# 同时也在 preseed 的 pkgsel 中排除 cloud-init
if ! grep -q "cloud-init" "$PRESEED_FILE"; then
    # 在 pkgsel/include 行后添加排除
    sed -i '/pkgsel\/include/a d-i pkgsel/exclude string cloud-init cloud-init-local' "$PRESEED_FILE"
    echo "已在 pkgsel 中排除 cloud-init"
fi

echo
echo "==> 10. 验证修补后的 preseed.cfg"
echo "late_command 内容:"
grep "late_command" "$PRESEED_FILE"
echo ""
echo "cloud-init 排除:"
grep "cloud-init\|cloud.init\|pkgsel/exclude" "$PRESEED_FILE" || echo "未找到排除配置"

echo
echo "==> 11. 验证 GRUB"
echo "检查 /boot/debian-*："
ls -lah /boot/debian-*/ 2>/dev/null || true
echo ""
echo "检查 zz-debi.cfg："
cat /etc/default/grub.d/zz-debi.cfg 2>/dev/null || true
echo ""
echo "检查 grub.cfg 中的 debi/debian installer 启动项："
grep -Ei -n "debi|debian.*install|installer" /boot/grub/grub.cfg 2>/dev/null || true

echo
echo "============================================================"
echo "  配置阶段完成！"
echo ""
echo "  新系统配置："
echo "    用户名：debian"
echo "    密码：Tadminn.."
echo "    SSH 端口：8622"
echo "    主机名：TX-BJ"
echo "    cloud-init：已禁用（阻断 config-drive 自恢复）"
echo "    BBR：已启用"
echo "    时区：Asia/Shanghai"
echo "============================================================"
echo
read -r -p "现在重启进入 Debian Installer 并开始重装？输入 REBOOT ：" REBOOT_CONFIRM

if [ "${REBOOT_CONFIRM}" = "REBOOT" ]; then
    echo "3 秒后重启..."
    sleep 3
    reboot
else
    echo "未重启。你稍后可以手动执行：reboot"
    echo ""
    echo "重装完成后，请用以下命令连接新系统："
    echo "  ssh -p 8622 debian@$(hostname -I | awk '{print $1}')"
fi
