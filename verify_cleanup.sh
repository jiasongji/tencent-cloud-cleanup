#!/bin/bash
# ================================================================
# 腾讯云全家桶一键清理脚本 v3.4 - 快速验证模式
# ================================================================
# 用途：在已执行清理脚本的服务器上快速验证清理结果
# 使用：bash verify_cleanup.sh
# ================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

detect_boot_mode() {
    if [ -d /sys/firmware/efi ]; then
        echo "uefi"
    else
        echo "bios"
    fi
}

first_grub_cfg() {
    for cfg in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        if [ -f "$cfg" ]; then
            echo "$cfg"
            return 0
        fi
    done
    return 1
}

find_installer_entry() {
    local cfg="$1"
    awk -F"'" '
        /^menuentry / {
            if (title != "") {
                low=tolower(body)
                if (low ~ /\/boot\/debian-|preseed|debi|installer|auto.*install/) { print title; exit }
            }
            title=$2
            body=$0
            next
        }
        title != "" { body=body "\n" $0 }
        END {
            if (title != "") {
                low=tolower(body)
                if (low ~ /\/boot\/debian-|preseed|debi|installer|auto.*install/) print title
            }
        }
    ' "$cfg" | head -n1
}

has_installer_files() {
    for dir in /boot/debian-* /boot/debian; do
        [ -d "$dir" ] || continue
        if find "$dir" -maxdepth 1 -type f \( -name 'linux' -o -name 'vmlinuz*' \) | grep -q . \
           && find "$dir" -maxdepth 1 -type f \( -name 'initrd.gz' -o -name 'initrd*' \) | grep -q .; then
            return 0
        fi
    done
    return 1
}

check() {
    local desc="$1"
    local result="$2"  # pass/fail/warn
    local detail="${3:-}"
    
    case "$result" in
        pass)
            echo -e "${GREEN}[PASS]${NC} $desc"
            PASS=$((PASS + 1))
            ;;
        fail)
            echo -e "${RED}[FAIL]${NC} $desc"
            [ -n "$detail" ] && echo "       $detail"
            FAIL=$((FAIL + 1))
            ;;
        warn)
            echo -e "${YELLOW}[WARN]${NC} $desc"
            [ -n "$detail" ] && echo "       $detail"
            WARN=$((WARN + 1))
            ;;
    esac
}

echo "============================================================"
echo "     腾讯云清理结果验证"
echo "============================================================"
echo ""

# 1. 进程
echo "【进程】"
if ps aux | grep -iE "YDService|YDLive|sgagent|tat_agent|barad_agent|sgdaemon|sleep.100" | grep -v grep >/dev/null 2>&1; then
    check "腾讯相关进程" "fail" "$(ps aux | grep -iE 'YDService|YDLive|sgagent|tat_agent|barad_agent|sgdaemon' | grep -v grep | tr '\n' ' ')"
else
    check "无腾讯相关进程" "pass"
fi

# 2. 目录
echo ""
echo "【目录】"
for d in /usr/local/qcloud /etc/qcloudzone /qcloud_init /var/lib/qcloud /opt/qcloud; do
    if [ -e "$d" ]; then
        check "$d 不存在" "fail" "目录仍存在"
    else
        check "$d 已清除" "pass"
    fi
done

# 3. 定时任务
echo ""
echo "【定时任务】"
if crontab -l 2>/dev/null | grep -qi "qcloud\|stargate\|YunJing\|sgagent"; then
    check "root crontab" "fail" "仍有腾讯相关任务"
else
    check "root crontab 干净" "pass"
fi

for f in /etc/cron.d/sgagenttask /etc/cron.d/yunjing /etc/cron.d/hosteye; do
    if [ -f "$f" ]; then
        check "$f 已删除" "fail" "文件仍存在"
    else
        check "$f 已删除" "pass"
    fi
done

# 4. systemd
echo ""
echo "【systemd 服务】"
if systemctl list-unit-files --state=enabled 2>/dev/null | grep -qi "tat_agent\|tat_install"; then
    check "systemd 自启服务" "fail" "仍有腾讯自启服务"
else
    check "无腾讯自启服务" "pass"
fi

# 5. networking.service
echo ""
echo "【networking.service】"
if grep -qi "tencentcloud" /lib/systemd/system/networking.service 2>/dev/null; then
    check "networking.service 干净" "fail" "仍包含 tencentcloud 脚本"
else
    check "无腾讯 IPv6 脚本" "pass"
fi

# 6. rc.local
echo ""
echo "【rc.local】"
if grep -qi "qcloud\|YunJing\|tat_agent\|sgagent\|barad\|stargate\|tencentcloud" /etc/rc.local 2>/dev/null; then
    check "rc.local 干净" "fail" "仍包含腾讯内容"
else
    check "rc.local 已清空" "pass"
fi

# 7. cloud-init
echo ""
echo "【cloud-init】"
if [ -f /var/lib/cloud/scripts/per-boot/cloudRun.sh ]; then
    check "per-boot 脚本" "fail" "cloudRun.sh 仍存在"
else
    check "per-boot 脚本已清除" "pass"
fi

runcmd_clean=true
for runcmd in /var/lib/cloud/instances/*/scripts/runcmd; do
    if [ -f "$runcmd" ] && grep -qi "qcloud\|tencent\|cvm_init" "$runcmd"; then
        check "runcmd 干净" "fail" "仍包含安装脚本"
        runcmd_clean=false
    fi
done
$runcmd_clean && check "runcmd 已清空" "pass"

if [ -f /etc/cloud/cloud-init.disabled ]; then
    check "cloud-init 已禁用" "pass"
else
    check "cloud-init 已禁用" "fail" "/etc/cloud/cloud-init.disabled 不存在，config-drive 可能自恢复！"
fi

# 8. LD_PRELOAD
echo ""
echo "【安全检查】"
if [ -f /etc/ld.so.preload ] && grep -qi "qcloud\|YunJing\|yddaemon" /etc/ld.so.preload; then
    check "LD_PRELOAD" "fail" "存在腾讯注入"
else
    check "无 LD_PRELOAD 注入" "pass"
fi

# 9. 配置文件
echo ""
echo "【配置文件】"
if [ -f /etc/environment ] && grep -qi "tencentyun\|mirrors.tencent" /etc/environment; then
    check "/etc/environment" "fail" "仍包含腾讯代理"
else
    check "/etc/environment 干净" "pass"
fi

profile_ok=true
for f in /etc/profile.d/*.sh; do
    if [ -f "$f" ] && grep -qi "tencentyun\|mirrors.tencent" "$f"; then
        check "$f" "fail" "仍包含腾讯代理"
        profile_ok=false
    fi
done
$profile_ok && check "profile.d 干净" "pass"

for ntpfile in /etc/ntp.conf /etc/ntpsec/ntp.conf; do
    if [ -f "$ntpfile" ] && grep -qi "tencentyun\|tencent" "$ntpfile"; then
        check "$ntpfile" "pass" "保留腾讯云 NTP"
    fi
done

# 10. apt 源
echo ""
echo "【apt 源】"
if [ -f /etc/apt/sources.list ] && grep -qi "tencentyun\|tencent" /etc/apt/sources.list; then
    check "apt 源" "pass" "保留腾讯云内网镜像"
else
    check "apt 源" "warn" "未指向腾讯云镜像；中国大陆服务器可能无法访问海外源"
fi

# 11. config-drive 阻断
echo ""
echo "【config-drive 阻断】"
if [ -f /etc/cloud/cloud-init.disabled ]; then
    check "cloud-init 禁用标记" "pass"
else
    check "cloud-init 禁用标记" "fail" "/etc/cloud/cloud-init.disabled 不存在"
fi
if [ -f /etc/udev/rules.d/99-ignore-config-drive.rules ]; then
    check "udev 忽略 config-drive" "pass"
else
    check "udev 忽略 config-drive" "warn" "未配置 udev 规则"
fi
if [ -f /etc/modprobe.d/blacklist-cdrom.conf ]; then
    check "sr_mod 内核模块黑名单" "pass"
else
    check "sr_mod 内核模块黑名单" "warn" "未黑名单 sr_mod"
fi
if mount | grep -q "/dev/sr0"; then
    check "config-drive 未挂载" "warn" "config-drive 当前已挂载"
else
    check "config-drive 未挂载" "pass"
fi
if grep -q "sr0" /etc/fstab 2>/dev/null; then
    check "fstab 无 sr0" "fail" "fstab 中仍有 sr0 挂载"
else
    check "fstab 无 sr0" "pass"
fi

# 12. GRUB / DD 启动链
# VNC 直接进旧系统通常说明当前系统的 GRUB/启动链没有把控制权交给 DD 脚本。
echo ""
echo "【GRUB / DD 启动链】"
echo "启动模式: $(detect_boot_mode)"
root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
root_disk_name=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1 || true)
if [ -n "$root_disk_name" ] && [ -b "/dev/$root_disk_name" ]; then
    check "系统盘识别" "pass" "/dev/$root_disk_name"
else
    check "系统盘识别" "warn" "无法从根分区 $root_src 反查系统盘，请人工确认 DD 目标盘"
fi

cfg=$(first_grub_cfg 2>/dev/null || true)
if [ -n "$cfg" ]; then
    check "GRUB 配置存在" "pass" "$cfg"
    entry=$(find_installer_entry "$cfg" || true)
    if has_installer_files; then
        if [ -n "$entry" ]; then
            check "DD Installer 菜单项" "pass" "$entry"
        else
            check "DD Installer 菜单项" "fail" "发现 /boot/debian-* 安装文件，但 grub.cfg 没有对应菜单项；重启会回旧系统"
        fi
    else
        check "DD Installer 文件" "warn" "未发现 /boot/debian-*；仅运行清理脚本时这是正常的"
    fi
else
    check "GRUB 配置存在" "fail" "未找到 /boot/grub/grub.cfg 或 /boot/grub2/grub.cfg"
fi

if [ -f /etc/default/grub.d/99-tencent-dd-safe.cfg ]; then
    if grep -q "cloud-init=disabled" /etc/default/grub.d/99-tencent-dd-safe.cfg \
       && grep -q "modprobe.blacklist=sr_mod,cdrom" /etc/default/grub.d/99-tencent-dd-safe.cfg; then
        check "通用 DD GRUB 参数" "pass" "/etc/default/grub.d/99-tencent-dd-safe.cfg"
    else
        check "通用 DD GRUB 参数" "warn" "99-tencent-dd-safe.cfg 存在但参数不完整"
    fi
else
    check "通用 DD GRUB 参数" "warn" "未运行新版 remove_tencent_cloud.sh，或未写入通用 DD 前置参数"
fi

cmdline=$(tr '\n' ' ' </proc/cmdline 2>/dev/null || true)
if [ -f /etc/default/grub.d/99-tencent-dd-safe.cfg ] \
   && { ! echo "$cmdline" | grep -q "cloud-init=disabled" || ! echo "$cmdline" | grep -q "modprobe.blacklist=sr_mod,cdrom"; }; then
    check "当前启动链消费 GRUB 参数" "warn" "当前 /proc/cmdline 未包含通用 DD 参数；若重启后仍回旧系统，请用 kexec_debi_installer.sh 直跳安装器"
else
    check "当前启动链消费 GRUB 参数" "pass"
fi

if command -v grub-editenv >/dev/null 2>&1; then
    grubenv=$(grub-editenv list 2>/dev/null || true)
    if echo "$grubenv" | grep -q '^recordfail=1'; then
        check "grubenv recordfail" "warn" "recordfail=1 可能导致 GRUB 忽略下一次启动项"
    else
        check "grubenv recordfail" "pass"
    fi
    if has_installer_files \
       && ! echo "$grubenv" | grep -qiE 'next_entry=.*(debi|installer|install)|saved_entry=.*(debi|installer|install)' \
       && ! grep -qiE 'set default="?(debi|installer|install)' "$cfg" 2>/dev/null; then
        check "grubenv 安装器启动项" "warn" "已发现安装器文件，但 grubenv/default 均未指向安装器；请检查 DD 脚本是否已写入 grub-reboot 或 GRUB_DEFAULT"
    fi
else
    check "grubenv 工具" "warn" "未找到 grub-editenv，无法确认下一次启动项"
fi

# 13. 全盘扫描
echo ""
echo "【全盘扫描】"
residual=$(find / -maxdepth 5 \
    \( -name "*qcloud*" -o -name "*YunJing*" -o -name "*sgagent*" -o -name "*barad_agent*" \
       -o -name "*tat_agent*" -o -name "*stargate*" -o -name "*tencentcloud*" -o -name "*ydeyes*" \) \
    -not -path "/proc/*" -not -path "/sys/*" -not -path "*.bak*" 2>/dev/null || true)
if [ -n "$residual" ]; then
    check "全盘无残留" "fail" "发现: $residual"
else
    check "全盘无残留" "pass"
fi

# 13. 内存
echo ""
echo "【内存占用】"
free -h | head -2

# 汇总
echo ""
echo "============================================================"
TOTAL=$((PASS + FAIL + WARN))
echo -e "  通过: ${GREEN}${PASS}${NC}/${TOTAL}  失败: ${RED}${FAIL}${NC}  警告: ${YELLOW}${WARN}${NC}"
if [ $FAIL -eq 0 ]; then
    echo -e "  ${GREEN}✅ 验证通过，腾讯云组件已彻底清除${NC}"
else
    echo -e "  ${RED}❌ 存在未清理的项目，请检查上方输出${NC}"
fi
echo "============================================================"
