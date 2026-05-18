#!/bin/bash
# ================================================================
# 腾讯云全家桶一键清理脚本 v3.0
# ================================================================
# 适用系统：Debian / Ubuntu / CentOS 等 Linux 发行版
# 适用场景：腾讯云 CVM、轻量应用服务器（Lighthouse）
# 使用方法：
#   curl -sO <脚本地址> && bash remove_tencent_cloud.sh
#   或上传到服务器后直接 bash remove_tencent_cloud.sh
#
# 警告：执行后腾讯云控制台的监控、自动化助手、主机安全等功能
#       将全部失效，且无法通过控制台重装恢复。
#       apt 源将替换为官方源（仅 Debian/Ubuntu 自动替换）。
# ================================================================

set -uo pipefail

# ======================== 颜色定义 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ======================== 工具函数 ========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()    { echo -e "\n${CYAN}======== $* =======${NC}"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }
log_success() { echo -e "${GREEN}[  OK ]${NC}  $*"; }

# ======================== 检测操作系统 ========================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID}-${VERSION_ID}"
    elif [ -f /etc/redhat-release ]; then
        echo "centos-7"
    else
        echo "unknown"
    fi
}

OS_ID=$(detect_os)
log_info "检测到操作系统: $OS_ID"

# ======================== 确认提示 ========================
echo ""
echo "============================================================"
echo "     腾讯云全家桶一键清理脚本 v3.1"
echo "============================================================"
echo ""
echo "本脚本将执行以下操作："
echo ""
echo "  【进程清理】"
echo "    1. 杀死 sgdaemon 自恢复守护进程（伪装为 sleep 100）"
echo "    2. 杀死所有腾讯云相关进程（云镜、Stargate、TAT、Barad）"
echo ""
echo "  【启动链阻断】"
echo "    3. 清理 crontab / cron.d / at 定时任务"
echo "    4. 清理 systemd 自启服务（tat_agent、tat_install、nv_gpu）"
echo "    5. 清理 rc.local 启动脚本"
echo "    6. 清理 cloud-init（per-boot、runcmd、part-001）"
echo "    7. 清理 networking.service 中嵌入的腾讯 IPv6 脚本"
echo "    8. 清理 init.d / rc*.d 中的腾讯启动链接"
echo "    9. 清理 udev 规则、LD_PRELOAD、shell profile 注入"
echo ""
echo "  【config-drive 阻断（DD 重装关键！）】"
log_warn "   ⭐ 10. 卸载并禁用 config-drive（/dev/sr0，vendor_data.json 自恢复根源）"
log_warn "   ⭐ 11. 黑名单 sr_mod 内核模块 + udev 规则忽略 config-drive"
log_warn "   ⭐ 12. 禁用 cloud-init 并清除缓存（阻止读取 vendor_data）"
echo ""
echo "  【文件清理】"
echo "   13. 删除 /usr/local/qcloud、/qcloud_init 等全部目录"
echo "   14. 删除 /tmp 下所有安装包、脚本和守护程序"
echo "   15. 删除 tencentcloud_ipv6_base.sh 等"
echo "   16. 清理 cgroup、pid/lock 残留"
echo ""
echo "  【配置清理】"
echo "   17. 清理 /etc/environment、/etc/profile.d 中的腾讯代理"
echo "   18. 清理 cloud-init 模块执行标记（防止重启恢复）"
echo "   19. 替换 apt 源为官方源（仅 Debian/Ubuntu 自动替换）"
echo ""
echo -e "${RED}警告：执行后腾讯云控制台监控/安全/自动化功能将全部失效！${NC}"
echo -e "${RED}警告：apt 源将替换为公网官方源，内网机器可能需要手动改回！${NC}"
echo -e "${RED}警告：将禁用 cloud-init 并阻断 config-drive，DD 重装系统不再会被恢复！${NC}"
echo ""

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    log_fail "请使用 root 用户运行此脚本"
    exit 1
fi

read -p "确认执行？(yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "已取消。"
    exit 0
fi

# ================================================================
#  第一阶段：杀死进程（必须先杀 sgdaemon，否则会自动重装）
# ================================================================

log_step "阶段 1/4：杀死所有腾讯云相关进程"

# 1.1 杀死 sgdaemon 自恢复守护进程
# sgdaemon 伪装为 /bin/sh -c sleep 100，PPID=1
# 它会持续监控云盾组件，一旦被删除就自动从腾讯服务器下载重装
# fd 中会打开 sgdaemon.log，据此精确识别
log_info "搜索 sgdaemon 自恢复守护进程..."
found_sgdaemon=0
for pid in $(ps -eo pid,ppid,cmd 2>/dev/null | grep 'sleep' | grep -v grep | awk '{if($2==1) print $1}'); do
    if ls -la /proc/$pid/fd/ 2>/dev/null | grep -q "sgdaemon"; then
        log_info "发现 sgdaemon（伪装为 sleep），PID: $pid"
        kill -9 "$pid" 2>/dev/null && log_info "已杀死 sgdaemon PID $pid" || log_warn "杀死 PID $pid 失败"
        found_sgdaemon=1
    fi
done
if [ "$found_sgdaemon" -eq 0 ]; then
    log_info "未发现 sgdaemon 进程（可能已清理或不存在）"
fi

# 1.2 杀死所有已知腾讯云进程
log_info "杀死所有腾讯云相关进程..."
TENCENT_PROCS="YDService YDLive YDEyes sgagent tat_agent barad_agent sgdaemon hosteye"
for name in $TENCENT_PROCS; do
    pids=$(pgrep -x "$name" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        log_info "  杀死 $name: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
done

# 1.3 杀死正在进行的安装/重装进程
for pattern in "ydeyesinst" "self_cloud_install" "yunjing_install" "cvm_init.sh" "qcloud_init"; do
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        log_info "  杀死安装进程 ($pattern): $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
done

sleep 2

# 二次清理：强制杀死任何残留
remaining=$(ps aux 2>/dev/null | grep -i -E "YDService|YDLive|sgagent|tat_agent|barad_agent|sgdaemon" | grep -v grep || true)
if [ -n "$remaining" ]; then
    log_warn "仍有残留进程，强制清理..."
    echo "$remaining" | awk '{print $2}' | xargs kill -9 2>/dev/null || true
    sleep 2
fi

log_info "进程清理完成"

# ================================================================
#  第二阶段：阻断所有自恢复链
# ================================================================

log_step "阶段 2/4：阻断所有自恢复链"

# --------------------- 2.1 crontab ---------------------
log_info "清理 crontab 定时任务"
if crontab -l 2>/dev/null | grep -qi "stargate\|qcloud\|YunJing\|tat_agent\|sgagent\|barad"; then
    crontab -l 2>/dev/null | grep -vi "stargate\|qcloud\|YunJing\|tat_agent\|sgagent\|barad" | crontab - 2>/dev/null || true
    # 过滤后如果为空则直接删除
    cleft=$(crontab -l 2>/dev/null | grep -cv "^$" 2>/dev/null || echo "0")
    if [ "$cleft" -eq 0 ]; then
        crontab -r 2>/dev/null || true
    fi
    log_info "  已清理 root crontab"
else
    log_info "  root crontab 无腾讯相关内容"
fi

# /var/spool/cron/crontabs/root (部分系统)
if [ -f /var/spool/cron/crontabs/root ]; then
    if grep -qi "stargate\|qcloud\|YunJing\|sgagent\|barad" /var/spool/cron/crontabs/root 2>/dev/null; then
        sed -i '/stargate\|qcloud\|YunJing\|sgagent\|barad/d' /var/spool/cron/crontabs/root
        log_info "  已清理 /var/spool/cron/crontabs/root"
    fi
fi

# /var/spool/cron/root (CentOS 等)
if [ -f /var/spool/cron/root ]; then
    if grep -qi "stargate\|qcloud\|YunJing\|sgagent\|barad" /var/spool/cron/root 2>/dev/null; then
        sed -i '/stargate\|qcloud\|YunJing\|sgagent\|barad/d' /var/spool/cron/root
        log_info "  已清理 /var/spool/cron/root"
    fi
fi

# --------------------- 2.2 cron.d ---------------------
log_info "清理 /etc/cron.d"
for f in /etc/cron.d/sgagenttask /etc/cron.d/yunjing /etc/cron.d/hosteye; do
    if [ -f "$f" ]; then
        rm -f "$f"
        log_info "  已删除 $f"
    fi
done

# --------------------- 2.3 at 定时任务 ---------------------
if command -v atq >/dev/null 2>&1; then
    atq 2>/dev/null | awk '{print $1}' | while read job_id; do
        if [ -n "$job_id" ]; then
            job_content=$(at -c "$job_id" 2>/dev/null || true)
            if echo "$job_content" | grep -qi "qcloud\|YunJing\|tat_agent\|sgagent"; then
                atrm "$job_id" 2>/dev/null || true
                log_info "  已删除 at 任务 $job_id"
            fi
        fi
    done
fi

# --------------------- 2.4 systemd 服务 ---------------------
log_info "清理 systemd 自启服务"
for svc in tat_agent tat_install; do
    if systemctl is-enabled "$svc" 2>/dev/null | grep -q "enabled"; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        log_info "  已禁用 $svc"
    fi
done

# 删除 unit 文件
rm -f /etc/systemd/system/tat_agent.service
rm -f /etc/systemd/system/tat_install.service
rm -f /etc/systemd/system/multi-user.target.wants/tat_agent.service
rm -f /etc/systemd/system/multi-user.target.wants/tat_install.service

# 禁用 nv_gpu_shutdown_pm（腾讯 GPU 电源管理服务）
systemctl disable nv_gpu_shutdown_pm.service 2>/dev/null || true
rm -f /lib/systemd/system/nv_gpu_shutdown_pm.service 2>/dev/null || true
rm -f /usr/lib/systemd/system/nv_gpu_shutdown_pm.service 2>/dev/null || true

# 搜索其他可能遗漏的腾讯 systemd unit
for unit_dir in /etc/systemd /lib/systemd /usr/lib/systemd; do
    if [ -d "$unit_dir" ]; then
        for unit_file in $(grep -rl "qcloud\|YunJing\|tat_agent\|sgagent\|barad_agent\|stargate\|sgdaemon" "$unit_dir" 2>/dev/null || true); do
            # 跳过 cloud-init 默认服务和 networking（单独处理）
            echo "$unit_file" | grep -q "cloud-init\|cloud-config\|cloud-final\|networking" && continue
            log_info "  发现腾讯相关 unit: $unit_file"
            systemctl stop "$(basename "$unit_file")" 2>/dev/null || true
            systemctl disable "$(basename "$unit_file")" 2>/dev/null || true
            rm -f "$unit_file"
        done
    fi
done

systemctl daemon-reload

# --------------------- 2.5 rc.local ---------------------
log_info "清空 /etc/rc.local"
cat > /etc/rc.local << 'EOF'
#!/bin/bash
exit 0
EOF
chmod +x /etc/rc.local

# --------------------- 2.6 networking.service 中的腾讯 IPv6 脚本 ---------------------
log_info "清理 networking.service 中嵌入的腾讯脚本"
for net_svc in /lib/systemd/system/networking.service /usr/lib/systemd/system/networking.service /etc/systemd/system/networking.service; do
    if [ -f "$net_svc" ] && grep -q "tencentcloud" "$net_svc"; then
        # 备份原文件
        cp "$net_svc" "${net_svc}.bak.tencleanup"
        # 删除包含 tencentcloud 的 ExecStartPost 行
        sed -i '/tencentcloud/d' "$net_svc"
        log_info "  已从 $net_svc 中移除腾讯 IPv6 脚本调用"
    fi
done
systemctl daemon-reload

# --------------------- 2.7 cloud-init ---------------------
log_info "清理 cloud-init 自启脚本"

# per-boot（每次启动都会执行，腾讯用这个来重装云盾）
if [ -f /var/lib/cloud/scripts/per-boot/cloudRun.sh ]; then
    rm -f /var/lib/cloud/scripts/per-boot/cloudRun.sh
    log_info "  已删除 per-boot/cloudRun.sh"
fi

# runcmd（首次启动时执行，复制 /qcloud_init 并运行安装）
for runcmd in /var/lib/cloud/instances/*/scripts/runcmd; do
    if [ -f "$runcmd" ] && grep -qi "qcloud\|tencent\|cvm_init" "$runcmd"; then
        cp "$runcmd" "${runcmd}.bak.tencleanup"
        echo "#!/bin/sh" > "$runcmd"
        log_info "  已清空 $runcmd"
    fi
done

# part-001（创建 lighthouse 用户的脚本，这是腾讯轻量应用服务器的默认用户）
for part in /var/lib/cloud/instances/*/scripts/part-001; do
    if [ -f "$part" ] && grep -qi "lighthouse\|qcloud" "$part"; then
        cp "$part" "${part}.bak.tencleanup"
        echo "#!/bin/bash" > "$part"
        log_info "  已清空 $part（lighthouse 用户创建脚本）"
    fi
done

# 清除 cloud-init 模块执行标记，防止重启后重复执行
# 腾讯修改了 cloud-init 使用 /usr/local/qcloud/python 下的定制模块
# 这些 sem 文件标记了模块已执行（once-per-instance），删除后 cloud-init 会重新执行
# 但由于我们已经清空了 runcmd/part-001/per-boot，重新执行也是无害的
# 关键是确保不会重新安装腾讯组件
log_info "清理 cloud-init 模块执行标记"
for sem in /var/lib/cloud/instances/*/sem/*; do
    if [ -f "$sem" ]; then
        sem_name=$(basename "$sem")
        # 保留 consume_data 标记（防止 cloud-init 重新消费全部数据）
        # 删除其他标记以确保 cloud-init 不会用旧缓存重新写入
        case "$sem_name" in
            config_runcmd|config_write_files|config_scripts_per_instance|config_scripts_per_boot|config_scripts_per_once)
                rm -f "$sem"
                log_info "  已删除 sem/$sem_name"
                ;;
        esac
    fi
done

# --------------------- 2.8 init.d / rc*.d ---------------------
log_info "检查 init.d / rc*.d 启动链接"
for f in /etc/init.d/*; do
    if [ -f "$f" ] && grep -ql "qcloud\|YunJing\|tat_agent\|sgagent\|barad\|stargate" "$f" 2>/dev/null; then
        log_info "  发现腾讯 init.d 脚本: $f"
        # 查找并删除对应的 rc*.d 链接
        find /etc/rc*.d -type l -lname "*$(basename "$f")*" -delete 2>/dev/null || true
        rm -f "$f"
        log_info "  已删除 $f 及其 rc*.d 链接"
    fi
done

# --------------------- 2.9 udev 规则 ---------------------
log_info "清理 udev 规则"
rm -f /etc/udev/rules.d/80-qcloud-nic.rules

# --------------------- 2.10 LD_PRELOAD ---------------------
if [ -f /etc/ld.so.preload ]; then
    if grep -qi "qcloud\|YunJing\|yddaemon" /etc/ld.so.preload; then
        log_warn "检测到 /etc/ld.so.preload 中有腾讯注入，正在清理..."
        grep -vi "qcloud\|YunJing\|yddaemon" /etc/ld.so.preload > /tmp/.ld.so.preload.clean
        mv /tmp/.ld.so.preload.clean /etc/ld.so.preload
        log_info "  已清理 ld.so.preload"
    fi
fi

# --------------------- 2.11 systemd tmpfiles ---------------------
for tmpfile_dir in /etc/tmpfiles.d /usr/lib/tmpfiles.d /lib/tmpfiles.d; do
    for f in "${tmpfile_dir}"/*; do
        if [ -f "$f" ] && grep -qi "qcloud\|YunJing\|tat_agent\|sgagent\|barad\|stargate" "$f" 2>/dev/null; then
            log_info "  发现腾讯 tmpfiles 配置: $f"
            grep -vi "qcloud\|YunJing\|tat_agent\|sgagent\|barad\|stargate" "$f" > "${f}.clean"
            mv "${f}.clean" "$f"
        fi
    done
done

# ================================================================
#  2.12 config-drive 阻断（DD 重装系统的关键步骤！）
# ================================================================
# config-drive (/dev/sr0, label=config-2) 包含 vendor_data.json
# 其中嵌入了完整的 cloud-init 配置：
#   - bootcmd: 从 config-drive 复制 cloudRun.sh 到 per-boot
#   - bootcmd: 复制 action.sh 并执行 downsr_rollback
#   - runcmd: 挂载 config-drive, 复制 /qcloud_init/ 到根目录
#   - runcmd: 执行 cvm_init.sh（安装所有腾讯组件）
#   - runcmd: 设置 root 密码、hostname、ntp
#   - write_files: 写入 /etc/uuid
# 无论你 DD 什么新系统，cloud-init 检测到 config-drive 就会重新安装
# ================================================================

log_info "阻断 config-drive 自恢复机制"

# 卸载已挂载的 config-drive
if mount | grep -q "/dev/sr0"; then
    MOUNT_POINT=$(mount | grep "/dev/sr0" | awk '{print $3}')
    umount "$MOUNT_POINT" 2>/dev/null && log_info "  已卸载 config-drive ($MOUNT_POINT)" || log_warn "  卸载 config-drive 失败"
fi

# 从 fstab 中删除 sr0 挂载
if grep -q "sr0" /etc/fstab 2>/dev/null; then
    cp /etc/fstab /etc/fstab.bak.tencleanup
    sed -i '/sr0/d' /etc/fstab
    log_info "  已从 fstab 中移除 sr0 挂载"
fi

# 创建 udev 规则忽略 config-drive
# label=config-2 是腾讯云 config-drive 的固定标签
mkdir -p /etc/udev/rules.d
# 先删除旧规则（如果存在）
rm -f /etc/udev/rules.d/99-ignore-config-drive.rules
cat > /etc/udev/rules.d/99-ignore-config-drive.rules << 'UDEVEOF'
# 忽略腾讯云 config-drive（阻止 cloud-init 读取 vendor_data.json）
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="config-2", OPTIONS="ignore_device"
KERNEL=="sr0", OPTIONS="ignore_device"
UDEVEOF
log_info "  已创建 udev 规则忽略 config-drive"

# 黑名单 sr_mod 内核模块（阻止加载光驱驱动）
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/blacklist-cdrom.conf << 'MODPROBEEOF'
# 禁用光驱模块，阻止加载腾讯云 config-drive
blacklist sr_mod
blacklist cdrom
install sr_mod /bin/true
install cdrom /bin/true
MODPROBEEOF
log_info "  已黑名单 sr_mod/cdrom 内核模块"

# 禁用 cloud-init（这是最关键的一步）
# 即使 udev 和 modprobe 阻止了设备加载，cloud-init 可能通过其他方式检测到
mkdir -p /etc/cloud
echo "cloud-init disabled by tencent-cloud-cleanup script" > /etc/cloud/cloud-init.disabled
log_info "  已创建 /etc/cloud/cloud-init.disabled"

# 停止并禁用 cloud-init 服务
if command -v systemctl >/dev/null 2>&1; then
    for svc in cloud-init-local cloud-init cloud-config cloud-final; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    log_info "  已停止并禁用 cloud-init 服务"
fi

# 清除 cloud-init 缓存（包含已解析的 vendor_data）
rm -rf /var/lib/cloud/* 2>/dev/null || true
log_info "  已清除 cloud-init 缓存"

# 创建 cloud-init 配置覆盖（即使 cloud-init 被重新安装也不会执行）
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-disable.cfg << 'CLOUDCFGEOF'
# 完全禁用 cloud-init（由 tencent-cloud-cleanup 创建）
cloud-init:
  disabled: true
CLOUDCFGEOF
log_info "  已创建 cloud-init 禁用配置"

log_info "config-drive 阻断完成"

log_info "自恢复链阻断完成"

# ================================================================
#  第三阶段：删除所有文件
# ================================================================

log_step "阶段 3/4：删除所有腾讯云文件"

# 3.1 主目录
rm -rf /usr/local/qcloud
rm -rf /qcloud_init
rm -rf /etc/qcloudzone

# 3.2 符号链接
rm -f /usr/local/bin/tat_agent

# 3.3 腾讯 IPv6 脚本
rm -f /etc/tencentcloud_ipv6_base.sh

# 3.4 pid / lock 文件
rm -f /run/.barad_agent.pid
rm -f /run/barad_agent.lock
rm -f /run/stargate.tencentyun.pid
rm -f /tmp/stargate.lock

# 3.5 日志
rm -f /var/log/qcloud_action.log

# 3.6 /tmp 下所有腾讯相关文件（安装包、脚本、守护程序）
rm -f /tmp/ydeyesinst_linux64.tar.gz
rm -f /tmp/ydeyes_linux64_*.tar.gz
rm -f /tmp/yddaemon.so
rm -f /tmp/sgdaemon.log
rm -f /tmp/startYD.sh
rm -f /tmp/startYDCore.sh
rm -f /tmp/stopYDCore.sh
rm -f /tmp/YDService /tmp/YDService.service
rm -f /tmp/YDCoreService.service /tmp/YDGentooService
rm -f /tmp/YDAddCrontab.sh /tmp/YDCrontab.sh /tmp/YDDelCrontab.sh
rm -f /tmp/agent_tool.sh /tmp/busybox /tmp/clearRules.sh
rm -f /tmp/gpudirect_rdma_setup.sh /tmp/nvenc_ai_sdk_install.sh
rm -f /tmp/yunjing_eks.sh /tmp/yunjing_install /tmp/yunjing_install_nohup
rm -f /tmp/ydeye_install.log
rm -f /tmp/cpuidle_support.log /tmp/cvm_init.log
rm -f /tmp/disable_rt_runtime_share.log /tmp/gpudirect_rdma_setup.log
rm -f /tmp/net_affinity.log /tmp/nv_gpu_conf.log /tmp/nvenc_ai_sdk_install.log
rm -f /tmp/setRps.log /tmp/set_xps.log /tmp/tlinux_xps.log /tmp/virtio_blk_affinity.log
rm -rf /tmp/YDEyes /tmp/YDLive /tmp/conf

# 3.7 cgroup 残留
rmdir /sys/fs/cgroup/YunJing/YDEyes 2>/dev/null || true
rmdir /sys/fs/cgroup/YunJing 2>/dev/null || true

# 3.8 /var/lib 下的腾讯组件残留
rm -rf /var/lib/qcloud

# 3.9 /opt 下的腾讯组件（部分安装方式）
rm -rf /opt/qcloud /opt/tencent

# 3.10 清理 /etc/environment 中的腾讯代理
# basic_linux_install 的 add_npm_go_config 函数会写入 GOPROXY
if [ -f /etc/environment ] && grep -qi "tencentyun\|mirrors.tencent" /etc/environment; then
    cp /etc/environment /etc/environment.bak.tencleanup
    grep -vi "tencentyun\|mirrors.tencent\|GOPROXY.*tencent" /etc/environment > /tmp/.environment.clean
    mv /tmp/.environment.clean /etc/environment
    log_info "已清理 /etc/environment 中的腾讯代理设置"
fi

# 3.11 清理 /etc/profile.d/ 中的腾讯代理脚本
# basic_linux_install 的 add_npm_go_config 函数会创建 go_conf.sh
for f in /etc/profile.d/*.sh; do
    if [ -f "$f" ] && grep -qi "tencentyun\|mirrors.tencent" "$f"; then
        cp "$f" "${f}.bak.tencleanup"
        log_warn "发现腾讯代理脚本 $f，删除"
        rm -f "$f"
    fi
done

# 3.12 清理 /etc/ntp.conf 和 /etc/ntpsec/ntp.conf 中可能的腾讯 NTP 服务器
for ntpfile in /etc/ntp.conf /etc/ntpsec/ntp.conf; do
    if [ -f "$ntpfile" ] && grep -qi "tencentyun\|tencent" "$ntpfile"; then
        cp "$ntpfile" "${ntpfile}.bak.tencleanup"
        # 替换腾讯 NTP 为公共 NTP
        sed -i 's/time[1-5]\.tencentyun\.com/pool.ntp.org/g' "$ntpfile"
        sed -i 's/time[1-5]\.tencent\.com/pool.ntp.org/g' "$ntpfile"
        sed -i 's/ntp\.tencentyun\.com/pool.ntp.org/g' "$ntpfile"
        log_info "已替换 $ntpfile 中的腾讯 NTP 为 pool.ntp.org"
    fi
done

# 3.13 替换 apt 源（Debian / Ubuntu 自动替换为官方源）
log_info "检查 apt 源..."
if [ -f /etc/apt/sources.list ] && grep -qi "tencentyun\|tencent" /etc/apt/sources.list; then
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.tencleanup

    if echo "$OS_ID" | grep -q "^debian"; then
        # 获取 Debian 版本代号
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            codename="${VERSION_CODENAME:-bookworm}"
        else
            codename="bookworm"
        fi
        cat > /etc/apt/sources.list << EOF
# 替换为 Debian 官方源（原腾讯内网源已移除）
deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security/ ${codename}-security main contrib non-free-firmware
EOF
        log_info "已将 apt 源替换为 Debian 官方源（原文件备份: sources.list.bak.tencleanup）"
    elif echo "$OS_ID" | grep -q "^ubuntu"; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            codename="${VERSION_CODENAME:-jammy}"
        else
            codename="jammy"
        fi
        cat > /etc/apt/sources.list << EOF
# 替换为 Ubuntu 官方源（原腾讯内网源已移除）
deb http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse
EOF
        log_info "已将 apt 源替换为 Ubuntu 官方源（原文件备份: sources.list.bak.tencleanup）"
    else
        log_warn "检测到腾讯 apt 源但非 Debian/Ubuntu，请手动替换 /etc/apt/sources.list"
        log_warn "备份文件: /etc/apt/sources.list.bak.tencleanup"
    fi
fi

# 同样检查 sources.list.d 下的腾讯源
for f in /etc/apt/sources.list.d/*; do
    if [ -f "$f" ] && grep -qi "tencentyun\|tencent" "$f"; then
        cp "$f" "${f}.bak.tencleanup"
        log_warn "发现腾讯源 $f，已备份并删除"
        rm -f "$f"
    fi
done

# 3.14 卸载通过包管理器安装的腾讯组件
log_info "检查包管理器中的腾讯组件..."
if command -v dpkg >/dev/null 2>&1; then
    tencent_pkgs=$(dpkg -l 2>/dev/null | grep -i -E "tat-agent|qcloud|YunJing|sgagent|barad-agent|stargate|hosteye" | awk '{print $2}' || true)
    if [ -n "$tencent_pkgs" ]; then
        log_info "发现通过 dpkg 安装的腾讯包: $tencent_pkgs"
        echo "$tencent_pkgs" | xargs apt-get purge -y 2>/dev/null || true
    fi
fi
if command -v rpm >/dev/null 2>&1; then
    tencent_pkgs=$(rpm -qa 2>/dev/null | grep -i -E "tat-agent|qcloud|YunJing|sgagent|barad-agent|stargate|hosteye" || true)
    if [ -n "$tencent_pkgs" ]; then
        log_info "发现通过 rpm 安装的腾讯包: $tencent_pkgs"
        echo "$tencent_pkgs" | xargs yum remove -y 2>/dev/null || echo "$tencent_pkgs" | xargs rpm -e 2>/dev/null || true
    fi
fi

log_info "文件删除完成"

# ================================================================
#  第四阶段：全面验证
# ================================================================

log_step "阶段 4/4：全面验证"

ERRORS=0
WARNINGS=0

# --------------------- 4.1 进程检查 ---------------------
log_info "检查残留进程..."
if ps aux | grep -i -E "YDService|YDLive|sgagent|tat_agent|barad_agent|sgdaemon|hosteye|sleep.100" | grep -v grep >/dev/null 2>&1; then
    log_fail "❌ 仍有腾讯相关进程残留："
    ps aux | grep -i -E "YDService|YDLive|sgagent|tat_agent|barad_agent|sgdaemon|hosteye" | grep -v grep
    ERRORS=$((ERRORS + 1))
else
    log_success "✅ 无残留进程"
fi

# --------------------- 4.2 关键目录检查 ---------------------
log_info "检查关键目录..."
dir_ok=true
for d in /usr/local/qcloud /etc/qcloudzone /qcloud_init /var/lib/qcloud /opt/qcloud /opt/tencent; do
    if [ -e "$d" ]; then
        log_fail "❌ $d 仍存在"
        ERRORS=$((ERRORS + 1))
        dir_ok=false
    fi
done
$dir_ok && log_success "✅ 关键目录已全部清除"

# --------------------- 4.3 crontab 检查 ---------------------
log_info "检查定时任务..."
cron_ok=true
if crontab -l 2>/dev/null | grep -qi "qcloud\|stargate\|YunJing\|tat_agent\|sgagent\|barad"; then
    log_fail "❌ crontab 中仍有腾讯相关任务"
    ERRORS=$((ERRORS + 1))
    cron_ok=false
fi
for f in /etc/cron.d/sgagenttask /etc/cron.d/yunjing /etc/cron.d/hosteye; do
    if [ -f "$f" ]; then
        log_fail "❌ $f 仍存在"
        ERRORS=$((ERRORS + 1))
        cron_ok=false
    fi
done
$cron_ok && log_success "✅ 定时任务已清除"

# --------------------- 4.4 systemd 检查 ---------------------
log_info "检查 systemd 自启服务..."
if systemctl list-unit-files --state=enabled 2>/dev/null | grep -qi -E "tat_agent|tat_install"; then
    log_fail "❌ systemd 中仍有腾讯自启服务"
    ERRORS=$((ERRORS + 1))
else
    log_success "✅ systemd 无腾讯自启服务"
fi

# 检查 networking.service 是否还有腾讯脚本
for net_svc in /lib/systemd/system/networking.service /usr/lib/systemd/system/networking.service /etc/systemd/system/networking.service; do
    if [ -f "$net_svc" ] && grep -qi "tencentcloud" "$net_svc"; then
        log_fail "❌ $net_svc 中仍有腾讯 IPv6 脚本调用"
        ERRORS=$((ERRORS + 1))
    fi
done
[ $ERRORS -eq 0 ] && log_success "✅ networking.service 已清理"

# --------------------- 4.5 rc.local 检查 ---------------------
log_info "检查 rc.local..."
if grep -qi "qcloud\|YunJing\|tat_agent\|sgagent\|barad\|stargate\|tencentcloud" /etc/rc.local 2>/dev/null; then
    log_fail "❌ rc.local 中仍有腾讯相关内容"
    ERRORS=$((ERRORS + 1))
else
    log_success "✅ rc.local 已清空"
fi

# --------------------- 4.6 cloud-init 检查 ---------------------
log_info "检查 cloud-init..."
cloud_ok=true

if [ -f /var/lib/cloud/scripts/per-boot/cloudRun.sh ]; then
    log_fail "❌ per-boot/cloudRun.sh 仍存在"
    ERRORS=$((ERRORS + 1))
    cloud_ok=false
fi

for runcmd in /var/lib/cloud/instances/*/scripts/runcmd; do
    if [ -f "$runcmd" ] && grep -qi "qcloud\|tencent\|cvm_init" "$runcmd"; then
        log_fail "❌ $runcmd 中仍有腾讯安装脚本"
        ERRORS=$((ERRORS + 1))
        cloud_ok=false
    fi
done

# cloud-init 禁用检查
if [ ! -f /etc/cloud/cloud-init.disabled ]; then
    log_fail "❌ /etc/cloud/cloud-init.disabled 不存在"
    ERRORS=$((ERRORS + 1))
    cloud_ok=false
fi

$cloud_ok && log_success "✅ cloud-init 已禁用并清理"

# --------------------- 4.7 LD_PRELOAD 检查 ---------------------
log_info "检查 LD_PRELOAD..."
if [ -f /etc/ld.so.preload ] && grep -qi "qcloud\|YunJing\|yddaemon" /etc/ld.so.preload; then
    log_fail "❌ /etc/ld.so.preload 中仍有腾讯注入"
    ERRORS=$((ERRORS + 1))
else
    log_success "✅ 无 LD_PRELOAD 注入"
fi

# --------------------- 4.8 配置文件检查 ---------------------
log_info "检查配置文件（environment/profile.d/ntp）..."
config_ok=true

if [ -f /etc/environment ] && grep -qi "tencentyun\|mirrors.tencent" /etc/environment; then
    log_warn "⚠️  /etc/environment 中仍有腾讯相关设置"
    WARNINGS=$((WARNINGS + 1))
    config_ok=false
fi
for f in /etc/profile.d/*.sh; do
    if [ -f "$f" ] && grep -qi "tencentyun\|mirrors.tencent" "$f"; then
        log_warn "⚠️  $f 中仍有腾讯相关设置"
        WARNINGS=$((WARNINGS + 1))
        config_ok=false
    fi
done
for ntpfile in /etc/ntp.conf /etc/ntpsec/ntp.conf; do
    if [ -f "$ntpfile" ] && grep -qi "tencentyun\|tencent" "$ntpfile"; then
        log_warn "⚠️  $ntpfile 中仍有腾讯 NTP 服务器"
        WARNINGS=$((WARNINGS + 1))
        config_ok=false
    fi
done
$config_ok && log_success "✅ 配置文件已清理"

# --------------------- 4.10 config-drive 阻断检查 ---------------------
log_info "检查 config-drive 阻断..."
configdrive_ok=true

if [ -f /etc/cloud/cloud-init.disabled ]; then
    log_success "✅ cloud-init 已禁用（/etc/cloud/cloud-init.disabled）"
else
    log_fail "❌ cloud-init 未禁用！config-drive 自恢复可能生效"
    ERRORS=$((ERRORS + 1))
    configdrive_ok=false
fi

if [ -f /etc/udev/rules.d/99-ignore-config-drive.rules ]; then
    log_success "✅ udev 规则已配置（忽略 config-drive）"
else
    log_warn "⚠️  未找到 config-drive udev 忽略规则"
    WARNINGS=$((WARNINGS + 1))
    configdrive_ok=false
fi

if [ -f /etc/modprobe.d/blacklist-cdrom.conf ]; then
    log_success "✅ sr_mod 内核模块已黑名单"
else
    log_warn "⚠️  未找到 sr_mod 黑名单配置"
    WARNINGS=$((WARNINGS + 1))
    configdrive_ok=false
fi

if grep -q "sr0" /etc/fstab 2>/dev/null; then
    log_fail "❌ fstab 中仍有 sr0 挂载"
    ERRORS=$((ERRORS + 1))
    configdrive_ok=false
else
    log_success "✅ fstab 无 sr0 挂载"
fi

if mount | grep -q "/dev/sr0"; then
    log_warn "⚠️  config-drive 当前已挂载（重启后将被 udev/modprobe 阻止）"
    WARNINGS=$((WARNINGS + 1))
else
    log_success "✅ config-drive 未挂载"
fi

# --------------------- 4.9 apt 源检查 ---------------------
log_info "检查 apt 源..."
if [ -f /etc/apt/sources.list ] && grep -qi "tencentyun\|tencent" /etc/apt/sources.list; then
    log_warn "⚠️  apt 源仍指向腾讯镜像"
    WARNINGS=$((WARNINGS + 1))
else
    log_success "✅ apt 源已清理"
fi

# --------------------- 4.10 全盘扫描 ---------------------
log_info "全盘扫描残留文件..."
residual=$(find / -maxdepth 5 \
    \( -name "*qcloud*" -o -name "*YunJing*" -o -name "*sgagent*" -o -name "*barad_agent*" \
       -o -name "*tat_agent*" -o -name "*stargate*" -o -name "*yddaemon*" -o -name "*sgdaemon*" \
       -o -name "*ydeyes*" -o -name "*tencentcloud*" -o -name "*hosteye*" \) \
    -not -path "/proc/*" -not -path "/sys/*" -not -path "*.bak.tencleanup" 2>/dev/null || true)
if [ -n "$residual" ]; then
    log_warn "⚠️  发现以下可能相关的文件（请人工确认是否为腾讯组件）："
    echo "$residual"
    WARNINGS=$((WARNINGS + 1))
else
    log_success "✅ 全盘无残留"
fi

# ======================== 汇总 ========================
echo ""
echo "============================================================"
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}  ✅ 全部验证通过，腾讯云组件已彻底清除！${NC}"
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}  ⚠️  主要项目已通过，但有 $WARNINGS 个警告项，请检查上方输出${NC}"
else
    echo -e "${RED}  ❌ 有 $ERRORS 个错误项和 $WARNINGS 个警告项，请检查上方输出${NC}"
fi
echo "============================================================"
echo ""

# ======================== 重启提示 ========================
if [ $ERRORS -eq 0 ]; then
    echo "为确保重启后腾讯组件不会复生，建议立即重启服务器。"
    echo ""
    read -p "是否立即重启？(yes/no): " reboot_confirm
    if [ "$reboot_confirm" = "yes" ]; then
        log_info "将在 3 秒后重启..."
        sleep 3
        reboot
    else
        echo ""
        log_info "已跳过重启。请尽快手动重启并执行以下验证命令："
        echo ""
        echo "  # 1. 检查进程（应为空）"
        echo "  ps aux | grep -iE 'YDService|YDLive|sgagent|tat_agent|barad_agent|sgdaemon' | grep -v grep"
        echo ""
        echo "  # 2. 检查关键目录（应报不存在）"
        echo "  ls -d /usr/local/qcloud /qcloud_init /etc/qcloudzone 2>&1"
        echo ""
        echo "  # 3. 检查定时任务（应为空）"
        echo "  crontab -l 2>&1; ls /etc/cron.d/"
        echo ""
        echo "  # 4. 检查 networking.service（不应包含 tencentcloud）"
        echo "  grep tencentcloud /lib/systemd/system/networking.service 2>/dev/null"
        echo ""
        echo "  # 5. 检查 systemd 自启服务"
        echo "  systemctl list-unit-files --state=enabled | grep -iE 'tat|qcloud|barad|stargate'"
        echo ""
        echo "  # 6. 全盘扫描（应为空）"
        echo "  find / -maxdepth 5 \\( -name '*qcloud*' -o -name '*YunJing*' -o -name '*tat_agent*' \\) -not -path '/proc/*' -not -path '*.bak*' 2>/dev/null"
    fi
else
    log_warn "存在未清理的项目，建议检查后再重启。"
fi
