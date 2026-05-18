# 腾讯云云盾全家桶一键清理脚本

一键卸载腾讯云服务器上的所有云盾、监控、自动化组件，恢复为纯净的 Linux 系统。**彻底阻断 config-drive 自恢复机制，DD 重装系统不再被还原。**

## 背景

腾讯云的 CVM 和轻量应用服务器（Lighthouse）默认预装了大量监控和安全组件，它们包括但不限于：

| 组件 | 说明 | 占用内存 |
|------|------|---------|
| **云镜（YunJing）** | 主机安全agent，包含 YDService、YDLive | ~80MB |
| **sgdaemon** | 云镜自恢复守护进程，伪装为 `sleep 100` | ~130MB |
| **Stargate（sgagent）** | 监控采集 agent | ~3MB |
| **TAT Agent（tat_agent）** | 自动化助手，远程执行命令 | ~14MB |
| **Barad（barad_agent）** | 监控上报 agent（3个进程） | ~27MB |
| **cloud-init 定制模块** | 腾讯修改版 cloud-init，开机自动安装以上组件 | - |
| **config-drive** | 只读虚拟光驱，包含 `vendor_data.json` 自恢复配置 | - |

这些组件合计占用约 **250-300MB 内存**（在 2G 内存的机器上约 15%），并且存在以下问题：

- **config-drive 自恢复（核弹级）**：`/dev/sr0`（label `config-2`）中的 `vendor_data.json` 包含完整的 cloud-init 配置，**无论你 DD 什么新系统，cloud-init 检测到 config-drive 后都会自动重新安装所有腾讯组件**
- **sgdaemon 自恢复**：伪装为 `sleep 100` 进程，一旦检测到云盾被卸载，会自动从腾讯服务器下载重装
- **多层启动链**：通过 crontab、cron.d、systemd、rc.local、cloud-init per-boot、cloud-init runcmd 等多达 **7 层** 启动链确保持久运行
- **深度嵌入系统**：在 `networking.service` 中嵌入腾讯 IPv6 脚本调用、修改 apt 源为腾讯内网镜像、注入 Go 代理等

本脚本就是为了彻底清除这些组件而编写的。

## 适用范围

- **云厂商**：腾讯云
- **产品**：CVM（云服务器）、Lighthouse（轻量应用服务器）
- **操作系统**：Debian、Ubuntu、CentOS、其他 Linux 发行版
- **要求**：root 权限

## 功能清单

### 进程清理
1. 精确识别并杀死 sgdaemon 自恢复守护进程（通过 fd 匹配 `sgdaemon.log`，避免误杀正常 sleep 进程）
2. 杀死所有腾讯云相关进程（YDService、YDLive、sgagent、tat_agent、barad_agent 等）
3. 杀死正在进行的安装/重装进程

### 启动链阻断（7 层全覆盖）
4. **crontab**：清理 root 用户的腾讯定时任务
5. **cron.d**：删除 `sgagenttask`、`yunjing`、`hosteye` 等文件
6. **at 定时任务**：检查并删除通过 at 命令注入的任务
7. **systemd 服务**：停止并禁用 `tat_agent.service`、`tat_install.service`、`nv_gpu_shutdown_pm.service`
8. **rc.local**：清空腾讯启动脚本
9. **networking.service**：移除嵌入的腾讯 IPv6 脚本调用（`tencentcloud_ipv6_base.sh`）
10. **cloud-init per-boot**：删除每次启动都会重装云盾的 `cloudRun.sh`
11. **cloud-init runcmd**：清空首次启动安装脚本（`cvm_init.sh`）
12. **cloud-init part-001**：清空 lighthouse 用户创建脚本
13. **cloud-init sem 标记**：清理模块执行标记，防止重启后用旧缓存恢复配置
14. **init.d / rc*.d**：扫描并删除腾讯启动脚本和链接
15. **udev 规则**：删除 `80-qcloud-nic.rules`

### config-drive 阻断（DD 重装关键！）
16. **卸载 config-drive**：卸载 `/dev/sr0` 并从 fstab 中删除
17. **udev 规则**：创建 `99-ignore-config-drive.rules`，忽略 label 为 `config-2` 的设备
18. **黑名单内核模块**：在 `/etc/modprobe.d/blacklist-cdrom.conf` 中禁用 `sr_mod` 和 `cdrom`
19. **禁用 cloud-init**：创建 `/etc/cloud/cloud-init.disabled` 并停止所有 cloud-init 服务
20. **清除缓存**：清除 `/var/lib/cloud/*` 中已解析的 vendor_data
21. **配置覆盖**：在 `/etc/cloud/cloud.cfg.d/99-disable.cfg` 中写入禁用配置

### 文件清理
22. 删除 `/usr/local/qcloud`（主安装目录）
23. 删除 `/qcloud_init`（安装源目录）
24. 删除 `/etc/qcloudzone`、`/var/lib/qcloud`、`/opt/qcloud` 等
25. 删除 `/usr/local/bin/tat_agent` 符号链接
26. 删除 `/etc/tencentcloud_ipv6_base.sh`
27. 清理 `/tmp` 下所有安装包、守护脚本（30+ 个文件）
28. 清理 pid/lock/cgroup 残留

### 配置清理
29. 清理 `/etc/environment` 中的腾讯 Go 代理（`GOPROXY`）
30. 清理 `/etc/profile.d/go_conf.sh` 腾讯代理脚本
31. 替换 NTP 服务器为 `pool.ntp.org`（替换 `time[1-5].tencentyun.com`）
32. 替换 apt 源为官方源（Debian → `deb.debian.org`，Ubuntu → `archive.ubuntu.com`）

### 安全检查
33. 检查 `/etc/ld.so.preload` 中的 LD_PRELOAD 注入
34. 检查 `/etc/profile.d/`、`/root/.bashrc` 等中的 shell 注入
35. 检查 systemd tmpfiles 中的注入
36. 卸载通过 dpkg/rpm 安装的腾讯软件包

### 全面验证（17 项检查）
脚本执行完成后会自动进行以下验证：

| # | 检查项 | 说明 |
|---|--------|------|
| 1 | 进程检查 | 扫描所有腾讯相关进程 |
| 2 | 关键目录 | 检查 6 个关键目录是否已删除 |
| 3 | 定时任务 | crontab + cron.d |
| 4 | systemd 自启 | enabled 服务列表 |
| 5 | networking.service | 是否包含 tencentcloud |
| 6 | rc.local | 是否包含腾讯内容 |
| 7 | cloud-init | per-boot + runcmd + 禁用状态 |
| 8 | LD_PRELOAD | 注入检查 |
| 9 | 配置文件 | environment + profile.d + ntp |
| 10 | apt 源 | 是否仍指向腾讯镜像 |
| 11 | config-drive | 禁用状态 + udev + modprobe + fstab + 挂载 |
| 12 | 全盘扫描 | 深度 5 层文件系统扫描 |

## 使用方法

### 方式一：直接上传运行

```bash
scp remove_tencent_cloud.sh root@<服务器IP>:/tmp/
ssh root@<服务器IP> 'bash /tmp/remove_tencent_cloud.sh'
```

### 方式二：curl 下载运行

```bash
curl -sL https://raw.githubusercontent.com/jiasongji/tencent-cloud-cleanup/main/remove_tencent_cloud.sh -o remove_tencent_cloud.sh
bash remove_tencent_cloud.sh
```

### 方式三：一键执行

```bash
curl -sL https://raw.githubusercontent.com/jiasongji/tencent-cloud-cleanup/main/remove_tencent_cloud.sh | bash
```

> 注意：方式三无法使用交互式确认，需要先修改脚本中的 `confirm` 变量或使用 `echo "yes" |` 管道输入。

## 执行流程

```
┌─────────────────────────────────────────────────────┐
│              阶段 1/4：杀死进程                       │
│                                                     │
│  sgdaemon(伪装sleep 100) ──kill──> YDService        │
│       │                          YDLive             │
│       │                          sgagent            │
│       └── kill ──> tat_agent  barad_agent           │
│                                                     │
├─────────────────────────────────────────────────────┤
│              阶段 2/4：阻断自恢复链                    │
│                                                     │
│  crontab ──清理──> cron.d ──删除──> systemd ──禁用   │
│  rc.local ──清空──> networking.service ──移除腾讯脚本 │
│  cloud-init per-boot ──删除──> runcmd ──清空         │
│  part-001 ──清空──> sem标记 ──清理──> init.d ──扫描   │
│  udev ──删除──> LD_PRELOAD ──检查──> tmpfiles ──检查  │
│                                                     │
│  ⭐ config-drive 阻断 ⭐                             │
│  卸载 sr0 ──udev 忽略──> 黑名单 sr_mod ──禁用         │
│  cloud-init ──disabled──> 清缓存 ──配置覆盖          │
│                                                     │
├─────────────────────────────────────────────────────┤
│              阶段 3/4：删除文件 + 配置清理             │
│                                                     │
│  /usr/local/qcloud ──rm──> /qcloud_init ──rm──>      │
│  /tmp/* ──rm──> /etc/environment ──清理──>            │
│  /etc/profile.d/go_conf.sh ──rm──>                   │
│  ntp.conf ──替换──> sources.list ──替换──>            │
│  dpkg/rpm 包 ──卸载                                  │
│                                                     │
├─────────────────────────────────────────────────────┤
│              阶段 4/4：全面验证（17 项）               │
│                                                     │
│  进程 ✓  目录 ✓  定时任务 ✓  systemd ✓               │
│  networking ✓  rc.local ✓  cloud-init ✓             │
│  LD_PRELOAD ✓  配置文件 ✓  apt源 ✓                   │
│  ⭐ config-drive 阻断 ✓ ⭐                           │
│  全盘 ✓                                             │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## 注意事项

1. **不可逆操作**：执行后腾讯云控制台的以下功能将永久失效：
   - 主机安全（云镜）防护
   - 自动化助手（TAT）远程命令执行
   - 云监控数据采集和展示
   - 安全基线检查

2. **config-drive 阻断**：脚本会禁用 cloud-init 并通过 udev/modprobe 阻止 config-drive 加载。这意味着 DD 重装任意系统后，新系统不会被腾讯组件"还原"。

3. **apt 源替换**：脚本会将腾讯内网镜像源替换为公网官方源。如果你的服务器需要通过内网访问 apt 源（例如没有公网带宽），请执行后手动改回。

4. **NTP 替换**：腾讯 NTP 服务器会被替换为 `pool.ntp.org`。

5. **重启验证**：强烈建议执行后重启服务器，确认所有组件不会复生。

6. **备份说明**：脚本修改关键文件前会自动创建 `.bak.tencleanup` 备份文件，如需恢复可以参考备份内容。

## 自恢复机制详解

### 第一层：config-drive（核弹级）

```
                    ┌──────────────────────────────────────┐
                    │   config-drive (/dev/sr0, label=config-2) │
                    │                                      │
                    │   vendor_data.json 内容：             │
                    │   {                                   │
                    │     "cloud-init": "#cloud-config     │
                    │       bootcmd:                        │
                    │         - 复制 cloudRun.sh 到 per-boot│  ← 每次启动执行
                    │         - 复制 action.sh 并执行       │
                    │       runcmd:                         │
                    │         - 挂载 config-drive           │
                    │         - 复制 /qcloud_init/ 到 /     │
                    │         - 执行 cvm_init.sh           │  ← 安装全部组件
                    │       write_files:                    │
                    │         - 写入 /etc/uuid              │
                    │       chpasswd:                       │
                    │         - 设置 root 密码              │
                    │     ..."                              │
                    │   }                                   │
                    └──────────┬───────────────────────────┘
                               │
              DD 新系统后，cloud-init 检测到 config-drive
                               │
                               ▼
                    ┌──────────────────────────────────────┐
                    │   vendor_data.json 中的配置全部执行    │
                    │   → 安装 YunJing + Stargate + TAT     │
                    │   → 安装 Barad + sgdaemon             │
                    │   → 设置 root 密码、hostname          │
                    │   → 系统完全回到腾讯云初始状态！       │
                    └──────────────────────────────────────┘
```

**这就是"DD 重装后总是回到原系统"的根本原因！**

### 第二层：sgdaemon 守护进程

```
                    ┌──────────────────┐
                    │  cloud-init      │
                    │  runcmd          │  ← 复制 /qcloud_init/ 并执行 cvm_init.sh
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
     ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
     │ tat_agent   │ │ stargate    │ │ YunJing     │
     │ (systemd)   │ │ (crontab)   │ │ (cron.d)    │
     └─────────────┘ └─────────────┘ └──────┬──────┘
                                            │ 启动
                                            ▼
                                   ┌──────────────────┐
                                   │ sgdaemon         │
                                   │ (伪装 sleep 100) │  ← 守护进程，监控云盾状态
                                   └────────┬─────────┘
                                            │ 检测到卸载
                                            ▼
                                   从腾讯服务器下载重装
```

本脚本的解决思路是 **先阻断 config-drive（断核弹），再杀 sgdaemon（断根），然后清理所有启动链（剪枝），最后删除所有文件（清场）**。

## DD 重装系统方案

### 问题

腾讯云的 config-drive (`/dev/sr0`, label `config-2`) 包含 `vendor_data.json`，其中嵌入了完整的 cloud-init 配置。**无论你 DD 什么新系统，cloud-init 检测到 config-drive 后都会自动重新安装所有腾讯组件。**

这就是"DD 重装后总是回到原系统"的根本原因。

### 解决方案

本项目提供了一键 DD 重装脚本 `dd-reinstall.sh`，采用 **三重阻断** 策略：

| 阶段 | 时机 | 措施 |
|------|------|------|
| **第一重** | 安装前（当前系统） | 停止 cloud-init、创建 disabled 标记、卸载 config-drive、清除缓存 |
| **第二重** | preseed late_command | 卸载 cloud-init 包、udev 忽略 config-drive、黑名单 sr_mod、静态网络、清理残留 |
| **第三重** | 新系统首次启动 | systemd one-shot 服务做最终清理和验证 |

### dd-reinstall.sh 特点

- **多重备选下载源**：`ghfast.top` → `gh-proxy.com` → `ghps.cc` → `gh-proxy.org`，适合中国网络环境
- **腾讯内网镜像源**：使用 `mirrors.tencentyun.com` 作为 Debian 安装源，无需代理
- **IPv6 支持**：自动配置腾讯云控制台分配的 IPv6 地址
- **静态网络**：写入 DHCP 网络配置，替代 cloud-init 的网络管理
- **BBR 加速**：自动启用 TCP BBR 拥塞控制

### 使用方法

```bash
# 方式一：先运行清理脚本（推荐）
scp remove_tencent_cloud.sh dd-reinstall.sh root@<服务器IP>:/root/
ssh root@<服务器IP>
bash /root/remove_tencent_cloud.sh   # 先清理
bash /root/dd-reinstall.sh           # 再 DD 重装

# 方式二：直接 DD 重装（脚本已内置 config-drive 阻断）
scp dd-reinstall.sh root@<服务器IP>:/root/
ssh root@<服务器IP>
bash /root/dd-reinstall.sh
```

### 重装后连接

```bash
ssh -p 8622 debian@<服务器IP>
# 密码：Tadminn..
```

## 常见问题

### Q: DD 重装后又回到了原系统怎么办？

这是因为 config-drive 的 `vendor_data.json` 中的 cloud-init 配置自动重新安装了所有腾讯组件。请使用本项目的 `dd-reinstall.sh` 脚本，它会在安装前、安装中、安装后三重阻断 config-drive。

### Q: 执行清理脚本后还能 DD 重装吗？

可以。而且由于清理脚本已经禁用了 cloud-init 并阻断了 config-drive，DD 重装后的新系统不会再被恢复。**推荐先执行清理脚本再 DD。**

### Q: 执行后还能在腾讯云控制台重装这些组件吗？

不能。脚本删除了所有安装文件和启动链，并禁用了 cloud-init 和 config-drive。如需恢复，只能通过腾讯云控制台的"重装系统"功能。

### Q: 会影响服务器上运行的业务吗？

不会。脚本只清理腾讯云自带的监控和安全组件，不影响用户自行安装的任何软件和服务。

### Q: 支持 CentOS / Ubuntu 吗？

支持。脚本会自动检测操作系统（通过 `/etc/os-release`），并做相应适配：
- apt 源替换仅对 Debian/Ubuntu 自动执行
- systemd/init.d/crontab 等在不同发行版上通用
- rpm 包卸载覆盖 CentOS 等 RedHat 系发行版

### Q: 脚本执行后需要重启吗？

强烈建议重启。重启可以验证所有清理是否彻底，确保 config-drive 和 cloud-init 不会复生。脚本提供了可选的重启功能。

### Q: 内存能释放多少？

取决于安装的组件数量。在 2核2G 的轻量应用服务器上，通常可以释放 **250-300MB** 内存（从约 500MB 占用降至约 220MB）。

## 免责声明

本脚本仅供学习和研究使用。使用者需自行承担使用本脚本带来的所有风险和后果。作者不对因使用本脚本而导致的任何直接或间接损失负责。

使用本脚本即表示您已了解并同意：
- 腾讯云控制台的监控、安全、自动化功能将永久失效
- apt 源将被替换为公网官方源
- NTP 服务器将被替换为公共 NTP
- cloud-init 将被禁用，config-drive 将被阻断

## License

[MIT](LICENSE)
