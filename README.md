# 腾讯云云盾全家桶一键清理脚本

一键卸载腾讯云服务器上的云盾、监控、自动化组件，恢复为更纯净的 Linux 系统。**同时提供 DD 重装前的 config-drive 阻断、GRUB 启动链检查和 kexec 直跳安装器兜底，避免重启后仍直接进入旧系统。**

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

- **config-drive 自恢复**：`/dev/sr0`（label `config-2`）中的 `vendor_data.json` 包含 cloud-init 配置，**新系统如果带 cloud-init，首次启动后可能自动重新安装腾讯组件**
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

### config-drive 阻断（防止新系统首次启动后重装组件）
16. **卸载 config-drive**：卸载 `/dev/sr0` 并从 fstab 中删除
17. **udev 规则**：创建 `99-ignore-config-drive.rules`，忽略 label 为 `config-2` 的设备
18. **黑名单内核模块**：在 `/etc/modprobe.d/blacklist-cdrom.conf` 中禁用 `sr_mod` 和 `cdrom`
19. **禁用 cloud-init**：创建 `/etc/cloud/cloud-init.disabled` 并停止所有 cloud-init 服务
20. **清除缓存**：清除 `/var/lib/cloud/*` 中已解析的 vendor_data
21. **配置覆盖**：在 `/etc/cloud/cloud.cfg.d/99-disable.cfg` 中写入禁用配置

### 通用 DD 前置修复（不依赖特定 DD 脚本）
22. **识别系统盘**：从当前根分区反查真正的启动磁盘，方便确认 DD 目标盘
23. **清理 GRUB 状态**：用正确的 `grub-editenv /boot/grub/grubenv unset ...` 语法清除 `recordfail`/`next_entry`
24. **重装 BIOS GRUB**：BIOS 模式下将 GRUB 重新安装到根分区所在系统盘，避免实际启动链绕过当前 `grub.cfg`
25. **写入 GRUB 安全参数**：创建 `/etc/default/grub.d/99-tencent-dd-safe.cfg`，追加 `cloud-init=disabled`、`ds=nocloud`、`modprobe.blacklist=sr_mod,cdrom`
26. **刷新启动镜像**：执行 `update-initramfs` 或 `dracut`，让 `sr_mod/cdrom` 黑名单尽早生效
27. **刷新 GRUB 配置**：执行 `update-grub`/`grub-mkconfig`，使任意后续 DD 脚本获得更干净的启动环境
28. **kexec 直跳安装器**：当平台启动链不消费 `grubenv`/`GRUB_DEFAULT` 时，使用 `kexec_debi_installer.sh` 直接进入 debi 生成的 Debian Installer

### 文件清理
29. 删除 `/usr/local/qcloud`（主安装目录）
30. 删除 `/qcloud_init`（安装源目录）
31. 删除 `/etc/qcloudzone`、`/var/lib/qcloud`、`/opt/qcloud` 等
32. 删除 `/usr/local/bin/tat_agent` 符号链接
33. 删除 `/etc/tencentcloud_ipv6_base.sh`
34. 清理 `/tmp` 下所有安装包、守护脚本（30+ 个文件）
35. 清理 pid/lock/cgroup 残留

### 配置清理
36. 清理 `/etc/environment` 中的腾讯 Go 代理（`GOPROXY`）
37. 清理 `/etc/profile.d/go_conf.sh` 腾讯代理脚本
38. 保留腾讯云 NTP（中国大陆网络更稳定）
39. 保留腾讯云内网 apt 源（`mirrors.tencentyun.com`）

### 安全检查
40. 检查 `/etc/ld.so.preload` 中的 LD_PRELOAD 注入
41. 检查 `/etc/profile.d/`、`/root/.bashrc` 等中的 shell 注入
42. 检查 systemd tmpfiles 中的注入
43. 卸载通过 dpkg/rpm 安装的腾讯软件包

### 全面验证
清理脚本执行完成后会自动进行以下验证；独立的 `verify_cleanup.sh` 还会额外检查 GRUB / DD 启动链：

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
| 10 | apt 源 | 是否保留腾讯云内网镜像 |
| 11 | config-drive | 禁用状态 + udev + modprobe + fstab + 挂载 |
| 12 | GRUB / DD 启动链 | `verify_cleanup.sh` 检查系统盘、通用 DD GRUB 参数、grub.cfg、grubenv、当前 cmdline 是否消费 GRUB 参数 |
| 13 | 全盘扫描 | 深度 5 层文件系统扫描 |

## 使用方法

### 方式一：直接上传运行

```bash
scp remove_tencent_cloud.sh verify_cleanup.sh kexec_debi_installer.sh configure_ipv6.sh root@<服务器IP>:/tmp/
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
│  ⭐ config-drive + 通用 DD 前置修复 ⭐                 │
│  卸载 sr0 ──udev 忽略──> 黑名单 sr_mod ──禁用         │
│  cloud-init ──disabled──> 清缓存 ──GRUB 参数刷新      │
│                                                     │
├─────────────────────────────────────────────────────┤
│              阶段 3/4：删除文件 + 配置清理             │
│                                                     │
│  /usr/local/qcloud ──rm──> /qcloud_init ──rm──>      │
│  /tmp/* ──rm──> /etc/environment ──清理──>            │
│  /etc/profile.d/go_conf.sh ──rm──>                   │
│  NTP/apt 腾讯云内网配置 ──保留──>                    │
│  dpkg/rpm 包 ──卸载                                  │
│                                                     │
├─────────────────────────────────────────────────────┤
│              阶段 4/4：全面验证                       │
│                                                     │
│  进程 ✓  目录 ✓  定时任务 ✓  systemd ✓               │
│  networking ✓  rc.local ✓  cloud-init ✓             │
│  LD_PRELOAD ✓  配置文件 ✓  apt源保留 ✓               │
│  ⭐ config-drive / DD 前置参数 ✓ ⭐                   │
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

2. **config-drive 阻断**：脚本会禁用 cloud-init，并通过 udev、modprobe、initramfs、GRUB kernel args 阻止当前系统继续读取 config-drive，为后续任意 DD 脚本提供更干净的启动环境。

3. **不修改腾讯云 DNS/内网源**：脚本保留腾讯云 NTP 和 `mirrors.tencentyun.com`，适合中国大陆服务器无法稳定访问海外源的场景。

4. **DD 脚本仍需正确写入引导**：本脚本负责清理当前系统的干扰项；具体 DD 脚本仍需要正确写入目标系统、引导器和下一次启动项。

5. **重启验证**：强烈建议执行后重启服务器，确认所有组件不会复生，再运行你选择的 DD 脚本。

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
              新系统首次启动后，cloud-init 检测到 config-drive
                               │
                               ▼
                    ┌──────────────────────────────────────┐
                    │   vendor_data.json 中的配置被执行      │
                    │   → 安装 YunJing + Stargate + TAT     │
                    │   → 安装 Barad + sgdaemon             │
                    │   → 设置 root 密码、hostname          │
                    │   → 新系统被重新植入腾讯组件           │
                    └──────────────────────────────────────┘
```

**注意：如果 VNC 没有任何安装过程、直接进入旧系统，优先排查 GRUB 没有启动 DD Installer；vendor_data 不能瞬间把整块磁盘还原成旧系统。**

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

DD 重装失败常见有两类，现象不同，处理方向也不同：

1. **VNC 直接进入旧系统，没有安装进度**：当前系统的 GRUB/启动链没有把控制权交给 DD 脚本，或平台实际启动链没有消费磁盘上的 `grubenv`/`GRUB_DEFAULT`。
2. **已经进入新系统，但腾讯组件又出现**：新系统的 cloud-init 读取 config-drive (`/dev/sr0`, label `config-2`) 中的 `vendor_data.json`，执行了腾讯 vendor-data 配置。

如果 VNC 没有任何安装过程、直接进入原系统，优先排查 GRUB/启动链；`vendor_data.json` 不能瞬间把整块磁盘还原成旧系统。腾讯云轻量实例若重启后 `next_entry` 仍未被消费，直接用 `kexec_debi_installer.sh` 绕过 GRUB。

### 实战结论

腾讯云轻量实例可能出现一种特殊情况：`debi.sh` 已经生成 `/boot/debian-*`、`grub.cfg` 里也有 `Debian Installer` 菜单项，甚至 `grubenv` 里仍显示 `next_entry=debi`，但重启后还是直接回旧系统。这说明平台实际启动链没有消费磁盘上的 `grubenv`/`GRUB_DEFAULT`，继续修改 GRUB 不会稳定解决；应使用 `kexec` 从当前内核直接跳入 Debian Installer。

### 通用处理方式

不要把修复写死到某一个 DD 脚本里。推荐流程是：

1. 先运行 `remove_tencent_cloud.sh`，清理当前系统中的腾讯组件、自恢复链、config-drive/cloud-init 干扰，并写入通用 DD 前置启动参数。
2. 运行 `verify_cleanup.sh`，确认 `config-drive 阻断` 和 `GRUB / DD 启动链` 两部分通过或只有可接受的提示。
3. 再运行你选择的任意 DD 脚本。
4. 如果重启后仍回旧系统，或 `verify_cleanup.sh` 提示当前启动链没有消费 GRUB 参数，运行 `kexec_debi_installer.sh` 直接跳入 debi 生成的 Debian Installer。

### 通用 DD 前置修复内容

| 项目 | 作用 |
|------|------|
| `/etc/cloud/cloud-init.disabled` | 禁用当前系统 cloud-init，避免重启前再次消费 vendor-data |
| `/etc/udev/rules.d/99-ignore-config-drive.rules` | 在当前系统忽略 label 为 `config-2` 的 config-drive |
| `/etc/modprobe.d/blacklist-cdrom.conf` | 禁止当前系统加载 `sr_mod`/`cdrom` |
| `update-initramfs` / `dracut` | 让模块黑名单尽早进入当前系统启动镜像 |
| `/etc/default/grub.d/99-tencent-dd-safe.cfg` | 追加 `cloud-init=disabled ds=nocloud modprobe.blacklist=sr_mod,cdrom` |
| `update-grub` / `grub-mkconfig` | 刷新当前系统 GRUB 配置，清理 `recordfail` 等旧状态 |
| `kexec_debi_installer.sh` | 在 GRUB/grubenv 被平台绕过时，直接从当前内核切换到 debi 的 Debian Installer |

### 推荐使用方法

```bash
# 1. 先清理当前系统，建立通用 DD 前置环境
bash remove_tencent_cloud.sh

# 2. 验证 config-drive / cloud-init / GRUB 状态
bash verify_cleanup.sh

# 3. 再运行你自己的任意 DD 脚本
bash <你的DD脚本>

# 4. 如果重启后仍回旧系统，或你想绕过 GRUB 直接进入 debi 安装器
KEXEC_CONFIRM=1 bash kexec_debi_installer.sh
```

项目自带 `dd-reinstall.sh` 已默认优先使用 kexec：

```bash
NEW_PASSWORD='你的新系统密码' bash dd-reinstall.sh
# 最后提示时输入 BOOT
```

### DD 后配置腾讯云 IPv6

腾讯云轻量 DD 后如果只剩 `fe80::/64` 链路本地地址，需要把控制台分配的 IPv6 手动写回系统。参考 `ubuntu-cloud-desktop` 的网络逻辑：优先保留旧系统 IPv6 地址/网关；当 SLAAC/DHCPv6 不可用或地址不一致时，改用静态 IPv6，并先添加网关的 on-link 路由，再添加默认路由。

推荐直接使用脚本：

```bash
# 从腾讯云控制台复制 IPv6 地址；不要把真实地址提交到公开仓库
TENCENT_IPV6='你的腾讯云IPv6地址' bash configure_ipv6.sh
```

脚本默认值适配腾讯云中国大陆环境：

```bash
IFACE=eth0
TENCENT_IPV6_PREFIX=64
TENCENT_IPV6_GW='fe80::feee:ffff:feff:ffff'
IPV6_DNS='2402:4e00:: 2400:3200::1'
```

它会即时执行等价操作：

```bash
ip -6 addr add <IPv6>/64 dev eth0
ip -6 route replace fe80::feee:ffff:feff:ffff dev eth0
ip -6 route replace default via fe80::feee:ffff:feff:ffff dev eth0
```

并写入持久化配置：

- `/etc/network/interfaces`：追加 `iface eth0 inet6 static` 管理块
- `/etc/sysctl.d/99-tencent-ipv6.conf`：开启 IPv6，关闭错误的 RA/autoconf 兜底
- `/etc/resolv.conf`：保留 IPv4 DNS，并补充腾讯/国内 IPv6 DNS

如果你的实例控制台显示的 IPv6 网关不是默认值，用 `TENCENT_IPV6_GW='...'` 覆盖。

### 中国大陆网络说明

脚本不会替换腾讯云 DNS、NTP 或腾讯云内网 apt 源。服务器在中国大陆时，保留 `mirrors.tencentyun.com` 通常比切到海外源更可靠。

## 常见问题

### Q: DD 重装后又回到了原系统怎么办？

先看 VNC 现象：

- **没有任何安装过程，直接进旧系统**：优先检查当前系统是否已经写入通用 DD 前置参数，以及你运行的 DD 脚本是否正确写入下一次启动项。如果 `next_entry` 重启后仍未被消费，说明平台启动链绕过了磁盘 GRUB 状态，直接运行 `kexec_debi_installer.sh`。
- **已经进入新系统，但腾讯组件又出现**：这是新系统的 cloud-init 执行了 config-drive/vendor-data。先运行 `remove_tencent_cloud.sh` 可减少当前系统重启前的干扰；若 DD 镜像自带 cloud-init，仍建议选择可禁用 cloud-init/config-drive 的 DD 方案。

也可以先运行 `verify_cleanup.sh`，查看“GRUB / DD 启动链”部分是否提示通用 DD 参数缺失、安装器菜单项缺失、当前 cmdline 未消费 GRUB 参数或 `recordfail` 异常。

### Q: 执行清理脚本后还能 DD 重装吗？

可以。推荐先执行清理脚本，让当前系统不再读取 config-drive，并刷新通用 DD 前置启动参数；然后再运行你选择的 DD 脚本。

### Q: 执行后还能在腾讯云控制台重装这些组件吗？

不能。脚本删除了所有安装文件和启动链，并禁用了 cloud-init 和 config-drive。如需恢复，只能通过腾讯云控制台的"重装系统"功能。

### Q: 会影响服务器上运行的业务吗？

不会。脚本只清理腾讯云自带的监控和安全组件，不影响用户自行安装的任何软件和服务。

### Q: 支持 CentOS / Ubuntu 吗？

支持。脚本会自动检测操作系统（通过 `/etc/os-release`），并做相应适配：
- apt 源默认保留腾讯云内网镜像，不切换海外源
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
- 腾讯云内网 apt 源和腾讯云 NTP 会被保留
- cloud-init 将被禁用，config-drive 将被阻断
- GRUB 会追加通用 DD 前置启动参数

## License

[MIT](LICENSE)
