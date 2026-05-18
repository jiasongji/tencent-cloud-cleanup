#!/bin/bash
# ================================================================
# 腾讯云全家桶一键清理脚本 v3.0 - 快速验证模式
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
        check "$ntpfile" "warn" "仍包含腾讯 NTP 服务器"
    fi
done

# 10. apt 源
echo ""
echo "【apt 源】"
if [ -f /etc/apt/sources.list ] && grep -qi "tencentyun\|tencent" /etc/apt/sources.list; then
    check "apt 源" "warn" "仍指向腾讯镜像"
else
    check "apt 源已清理" "pass"
fi

# 11. 全盘扫描
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

# 12. 内存
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
