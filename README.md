# 腾讯云云盾全家桶一键清理脚本

一键卸载腾讯云服务器上的所有云盾、监控、自动化组件，恢复为纯净的 Linux 系统。

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

这些组件合计占用约 **250-300MB 内存**（在 2G 内存的机器上约 15%），并且存在以下问题：

- **自恢复机制**：sgdaemon 伪装为 `sleep 100` 进程，一旦检测到云盾被卸载，会自动从腾讯服务器下载重装
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

### 文件清理
16. 删除 `/usr/local/qcloud`（主安装目录）
17. 删除 `/qcloud_init`（安装源目录）
18. 删除 `/etc/qcloudzone`、`/var/lib/qcloud`、`/opt/qcloud` 等
19. 删除 `/usr/local/bin/tat_agent` 符号链接
20. 删除 `/etc/tencentcloud_ipv6_base.sh`
21. 清理 `/tmp` 下所有安装包、守护脚本（30+ 个文件）
22. 清理 pid/lock/cgroup 残留

### 配置清理
23. 清理 `/etc/environment` 中的腾讯 Go 代理（`GOPROXY`）
24. 清理 `/etc/profile.d/go_conf.sh` 腾讯代理脚本
25. 替换 NTP 服务器为 `pool.ntp.org`（替换 `time[1-5].tencentyun.com`）
26. 替换 apt 源为官方源（Debian → `deb.debian.org`，Ubuntu → `archive.ubuntu.com`）

### 安全检查
27. 检查 `/etc/ld.so.preload` 中的 LD_PRELOAD 注入
28. 检查 `/etc/profile.d/`、`/root/.bashrc` 等中的 shell 注入
29. 检查 systemd tmpfiles 中的注入
30. 卸载通过 dpkg/rpm 安装的腾讯软件包

### 全面验证（12 项检查）
脚本执行完成后会自动进行以下验证：

| # | 检查项 | 说明 |
|---|--------|------|
| 1 | 进程检查 | 扫描所有腾讯相关进程 |
| 2 | 关键目录 | 检查 6 个关键目录是否已删除 |
| 3 | 定时任务 | crontab + cron.d |
| 4 | systemd 自启 | enabled 服务列表 |
| 5 | networking.service | 是否包含 tencentcloud |
| 6 | rc.local | 是否包含腾讯内容 |
| 7 | cloud-init | per-boot + runcmd + part-001 |
| 8 | LD_PRELOAD | 注入检查 |
| 9 | 配置文件 | environment + profile.d + ntp |
| 10 | apt 源 | 是否仍指向腾讯镜像 |
| 11 | 全盘扫描 | 深度 5 层文件系统扫描 |
| 12 | 包管理器 | dpkg/rpm 已安装包检查 |

## 使用方法

### 方式一：直接上传运行

```bash
scp remove_tencent_cloud.sh root@<服务器IP>:/tmp/
ssh root@<服务器IP> 'bash /tmp/remove_tencent_cloud.sh'
```

### 方式二：curl 下载运行

```bash
curl -sL https://raw.githubusercontent.com/<user>/tencent-cloud-cleanup/main/remove_tencent_cloud.sh -o remove_tencent_cloud.sh
bash remove_tencent_cloud.sh
```

### 方式三：一键执行

```bash
curl -sL https://raw.githubusercontent.com/<user>/tencent-cloud-cleanup/main/remove_tencent_cloud.sh | bash
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
│              阶段 4/4：全面验证（12 项）               │
│                                                     │
│  进程 ✓  目录 ✓  定时任务 ✓  systemd ✓               │
│  networking ✓  rc.local ✓  cloud-init ✓             │
│  LD_PRELOAD ✓  配置文件 ✓  apt源 ✓  全盘 ✓          │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## 注意事项

1. **不可逆操作**：执行后腾讯云控制台的以下功能将永久失效：
   - 主机安全（云镜）防护
   - 自动化助手（TAT）远程命令执行
   - 云监控数据采集和展示
   - 安全基线检查

2. **apt 源替换**：脚本会将腾讯内网镜像源替换为公网官方源。如果你的服务器需要通过内网访问 apt 源（例如没有公网带宽），请执行后手动改回。

3. **NTP 替换**：腾讯 NTP 服务器会被替换为 `pool.ntp.org`。

4. **重启验证**：强烈建议执行后重启服务器，确认所有组件不会复生。

5. **备份说明**：脚本修改关键文件前会自动创建 `.bak.tencleanup` 备份文件，如需恢复可以参考备份内容。

## 自恢复机制详解

腾讯云盾的自恢复设计非常复杂，这也是本脚本存在的核心价值：

```
                    ┌──────────────────┐
                    │   config-drive   │
                    │   (/dev/sr0)     │  ← 只读虚拟光驱，包含所有安装包
                    └────────┬─────────┘
                             │ 首次启动
                             ▼
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

本脚本的解决思路是**先杀 sgdaemon（断根），再清理所有启动链（剪枝），最后删除所有文件（清场）**。

## 常见问题

### Q: 执行后还能在腾讯云控制台重装这些组件吗？

不能。脚本删除了所有安装文件和启动链。如需恢复，只能通过腾讯云控制台的"重装系统"功能。

### Q: 会影响服务器上运行的业务吗？

不会。脚本只清理腾讯云自带的监控和安全组件，不影响用户自行安装的任何软件和服务。

### Q: 支持 CentOS / Ubuntu 吗？

支持。脚本会自动检测操作系统（通过 `/etc/os-release`），并做相应适配：
- apt 源替换仅对 Debian/Ubuntu 自动执行
- systemd/init.d/crontab 等在不同发行版上通用
- rpm 包卸载覆盖 CentOS 等 RedHat 系发行版

### Q: 脚本执行后需要重启吗？

强烈建议重启。重启可以验证所有清理是否彻底，确保没有组件通过其他途径复生。脚本提供了可选的重启功能。

### Q: 内存能释放多少？

取决于安装的组件数量。在 2核2G 的轻量应用服务器上，通常可以释放 **250-300MB** 内存（从约 500MB 占用降至约 220MB）。

## 免责声明

本脚本仅供学习和研究使用。使用者需自行承担使用本脚本带来的所有风险和后果。作者不对因使用本脚本而导致的任何直接或间接损失负责。

使用本脚本即表示您已了解并同意：
- 腾讯云控制台的监控、安全、自动化功能将永久失效
- apt 源将被替换为公网官方源
- NTP 服务器将被替换为公共 NTP

## License

[MIT](LICENSE)
