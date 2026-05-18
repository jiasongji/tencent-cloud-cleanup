# 变更日志

## v3.1 (2026-05-18)

### 新增
- **config-drive 阻断（DD 重装关键！）**：彻底解决 vendor_data.json 导致的 DD 后系统自恢复问题
  - 卸载 `/dev/sr0` 并从 fstab 中删除
  - 创建 udev 规则忽略 label=config-2 设备（`99-ignore-config-drive.rules`）
  - 黑名单 `sr_mod`/`cdrom` 内核模块（`/etc/modprobe.d/blacklist-cdrom.conf`）
  - 禁用 cloud-init：创建 `/etc/cloud/cloud-init.disabled`
  - 停止并禁用所有 cloud-init 服务（cloud-init-local、cloud-init、cloud-config、cloud-final）
  - 清除 `/var/lib/cloud/*` 缓存
  - 创建 `/etc/cloud/cloud.cfg.d/99-disable.cfg` 配置覆盖
- 验证检查从 12 项扩展到 17 项，新增 config-drive 阻断验证
- `dd-reinstall.sh` 升级到 v2.0，采用三重阻断策略：
  - 第一重：安装前禁用 cloud-init 和 config-drive
  - 第二重：preseed late_command 彻底阻断
  - 第三重：新系统首次启动 systemd 清理服务
- `dd-reinstall.sh` 新增多重备选下载源（ghfast.top → gh-proxy.com → ghps.cc → gh-proxy.org）
- `dd-reinstall.sh` 使用腾讯内网镜像源（无需代理）
- `dd-reinstall.sh` 新增 IPv6 配置支持

### 改进
- README 完整重写，详细说明 config-drive 自恢复机制和解决方案
- 修复 `dd-reinstall.sh` 中 gh-proxy.org 在中国大陆不可用的问题
- 修复 `dd-reinstall.sh` 中 preseed late_command 可能的转义问题

## v3.0 (2026-05-18)

### 新增
- 清理 `networking.service` 中嵌入的腾讯 IPv6 脚本调用
- 清理 `/etc/environment` 中的腾讯 Go 代理
- 清理 `/etc/profile.d/go_conf.sh` 腾讯代理脚本
- 自动替换 NTP 服务器为 `pool.ntp.org`
- 自动替换 apt 源为 Debian/Ubuntu 官方源
- 清理 cloud-init 模块执行标记（sem 文件），防止重启后恢复配置
- 清理 cloud-init part-001（lighthouse 用户创建脚本）
- 检查并清理 at 定时任务
- 扫描 init.d / rc*.d 中的腾讯启动脚本
- 扫描 systemd tmpfiles 中的注入
- 卸载通过 dpkg/rpm 包管理器安装的腾讯组件
- 全面验证从 6 项扩展到 12 项
- 新增独立验证脚本 `verify_cleanup.sh`
- 新增远程清理脚本 `remote_cleanup.sh`
- 新增 DD 重装脚本 `dd-reinstall.sh`，解决 config-drive vendor_data.json 导致 DD 后系统自恢复问题

### 改进
- sgdaemon 检测改为 fd 匹配 `sgdaemon.log`，避免误杀正常 sleep 进程
- 完善自恢复链分析，覆盖 cloud-init 定制模块导致的配置恢复问题
- 所有关键文件修改前自动创建 `.bak.tencleanup` 备份

## v2.0 (2026-05-18)

### 新增
- 首个公开发布版本
- 一键清理腾讯云云盾、Stargate、TAT、Barad 全部组件
- 杀死 sgdaemon 自恢复守护进程
- 阻断 crontab、cron.d、systemd、rc.local、cloud-init 等 7 层启动链
- 12 项自动验证检查
