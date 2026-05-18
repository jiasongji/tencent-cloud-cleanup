# 变更日志

## v3.4 (2026-05-18)

### 新增
- 新增 `kexec_debi_installer.sh`：debi.sh 已生成 `/boot/debian-*` 后，可绕过 GRUB 直接进入 Debian Installer。
- `dd-reinstall.sh` 升级到 v2.1，默认优先使用 kexec 进入安装器，避免腾讯云轻量实例重启后仍回旧系统。

### 修复
- `dd-reinstall.sh` 修补 preseed 后会重新追加嵌入 initrd，确保 late_command 在安装器中生效。
- `verify_cleanup.sh` 新增当前 `/proc/cmdline` 检查，识别实际启动链未消费当前 GRUB 参数的情况。

## v3.3 (2026-05-18)

### 修复
- 修正 `grub-editenv` 清理语法，确保 Debian 上真正清除 `recordfail`/`next_entry`。
- BIOS 模式下自动将 GRUB 重新安装到根分区所在系统盘，避免实际启动链绕过当前 `/boot/grub/grub.cfg`。
- `verify_cleanup.sh` 同时识别 `grubenv` 和 `GRUB_DEFAULT` 指向安装器，减少误报。

## v3.2 (2026-05-18)

### 新增
- 将 DD 修复方向调整为“通用系统前置修复”，不依赖修改某一个 DD 脚本。
- `remove_tencent_cloud.sh` 写入 `/etc/default/grub.d/99-tencent-dd-safe.cfg`，追加 `cloud-init=disabled`、`ds=nocloud`、`modprobe.blacklist=sr_mod,cdrom`。
- 刷新 initramfs/dracut 与 GRUB，清理 `grubenv` 中的 `recordfail`/`next_entry`，降低重启直接回旧系统的概率。
- `verify_cleanup.sh` 增加通用 DD GRUB 参数验证。

### 改进
- 保留腾讯云 DNS、NTP 和腾讯云内网 apt 源，适配中国大陆服务器网络环境。
- 文档明确区分“VNC 直接进旧系统”和“新系统启动后组件复生”两类问题。
- 移除公开脚本中的硬编码密码和默认 IPv6，改为环境变量或交互输入。

## v3.1 (2026-05-18)

### 新增
- **config-drive 阻断（DD 重装关键！）**：降低 vendor_data.json 在新系统首次启动后重新安装腾讯组件的风险
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
- 旧版曾自动替换 NTP 服务器为 `pool.ntp.org`（v3.2 起默认保留腾讯云 NTP）
- 旧版曾将 apt 源切到 Debian/Ubuntu 官方源（v3.2 起默认保留腾讯云内网源）
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
