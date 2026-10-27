# Windows 运维机工具（tools/win/）

> [← 返回 README](../README.md) · Linux / WSL 侧工具见 [TOOLS.md](TOOLS.md)
>
> 依赖：Windows 自带 OpenSSH 客户端（`ssh` / `scp`）与 PowerShell 5.1，零新增依赖。
> 组成：13 个 `.ps1` 脚本 + 同名 `.bat` 启动器；启动器统一 `chcp 65001` + `ExecutionPolicy Bypass`。

## 安全约定

| 约定 | 说明 |
|------|------|
| 凭据 | 一律交互式输入密码（`Read-Host -AsSecureString` / `SSH_ASKPASS`）；**不使用 `sshpass` 等明文密码方式**，密码不落盘、不进命令行与进程列表 |
| 主机密钥 | `StrictHostKeyChecking=accept-new`（首次连接免交互确认），不使用 `=no`；已知主机密钥变更时自动处理并打印新旧指纹供核对 |
| 报告预览 | 在线预览服务位于 `report/tools/report_server.sh`（Linux 侧），强制绑定 `127.0.0.1`。Windows 侧不提供预览服务 |
| 破坏性操作 | 关机 / 重启前需输入 `yes` 二次确认（`ipmi_power.ps1`） |

## 启动器与参数接受方式

`.bat` 启动器**不做统一 `%*` 透传**：多数启动器只接收固定位置参数（各自的 `rem` 头部已注明），
需要完整参数（如 `-VerifyBmc`、`-Modules`、`-OutDir`）时直接调用 `.ps1`。

| 启动器 | 接受的位置参数 | 备注 |
|--------|--------------|------|
| `remote_collect.bat` | 全部（`%*` 透传） | 可直接传 `-BmcIp` / `-InstallItems` 等；交互式密码建议直接在 PowerShell 中运行 `.ps1` |
| `cleanup.bat` | 全部（`%*` 透传） | `-Force` |
| `dhcp_server.bat` | 全部（`%*` 透传） | |
| `nic_switch.bat` | 全部（`%*` 透传） | 需管理员 |
| `Launch-DeepSeekHarness.bat` | 全部（`%*` 透传） | |
| `scan_ip.bat` | `[网段]` | 无参数 = 自动取本机网段 |
| `detect_bmc.bat` | `<IP1,IP2,...>` | 必填 |
| `fetch_report.bat` | `<user@ip1,user@ip2,...>` | 必填 |
| `remote_run.bat` | `<user@ip1,...> ["命令"]` | 命令省略时默认 `uptime` |
| `ipmi_power.bat` | `<BMC_IP> [status\|on\|off\|cycle]` | 动作可省略（默认 `status`）；失败时 `exit /b` 透出非零退出码 |
| `sync_time.bat` | `user@ip1[,user@ip2,...] [-DryRun] [-Bmc:auto\|yes\|no]` | `.bat` 用 `-Bmc:yes` 形式，内部转 `.ps1` 的 `-Bmc yes` |
| `wol.bat` | `<MAC>` | 只用 MAC；广播地址需直接调 `.ps1` 的 `-Broadcast` |
| `unblock_ps.bat` | 无 | |

## 首次使用

```powershell
tools\win\unblock_ps.bat
```

将当前用户执行策略设为 `RemoteSigned`（`CurrentUser` 范围，无需管理员），并对本目录 `.ps1` 执行
`Unblock-File` 解除「来自互联网」标记。运行后可双击 `.bat` 或 `.ps1` 使用。

---

## 远程采集 / 汇总

### `remote_collect.ps1` — 远程采集（等价 `tools/remote_collect.sh`）

```powershell
tools\win\remote_collect.bat -H root@<host>
tools\win\remote_collect.bat -H root@<host> -Modules gpu,cpu
tools\win\remote_collect.bat -H root@<host> -InstallItems 1,2
tools\win\remote_collect.bat -H root@<host> -BmcIp <BMC-IP> -BmcUser <user>
tools\win\remote_collect.bat -H root@<host> -BmcIp <BMC-IP> -HgxBmcIp <HGX-BMC-IP>
```

| 参数 | 说明 |
|------|------|
| `-H <user@host>` | SSH 目标机（必填） |
| `-Modules <列表>` | 只采指定模块，如 `gpu,cpu`（对应 `hwscope.sh --modules`） |
| `-OutDir <目录>` | 本地回拉目录（默认 `<项目>\output`） |
| `-NoSudo` | 远端以当前用户执行（默认 `sudo`；`root@` 自动免 sudo） |
| `-InstallItems <1,2,...>` | 推送后先远端非交互安装依赖（`install_tool.sh -c <列表> -y`）再采集（v1.42.1，等价 Linux `--install`） |
| `-BmcIp <IP>` | 主机 BMC 地址（等价 Linux `--bmc-ip`；BMC 密码运行时提示） |
| `-BmcUser <user>` | 主机 BMC 用户名（默认 `admin`） |
| `-HgxBmcIp <IP>` | HGX 基板 BMC 地址（等价 `--hgx-bmc-ip`） |
| `-HgxBmcUser <user>` | HGX 基板 BMC 用户名（默认 `admin`） |
| `-VerifyBmc` | 采集前预校验 BMC 密码（**默认关闭**，v1.54.23 改为可选） |

#### 输出位置

| 产物 | 路径 |
|------|------|
| 采集结果 | `output\remote_output\<机器ID>\`（对标本地 `output\<SN>\`） |
| 归档包 | `logs\remote_logs\<机器ID>-<时间戳>.tar.gz` |
| 报告 | `output\remote_output\<机器ID>\hwscope_report.{json,md,txt,html}` |

完成信息会打印本次采集目录、报告与归档包完整路径（v1.53.6）。v1.53.19 起按本轮实际写入的机器目录
（`$replacedSNs`）定位：原实现用「回拉前后目录差集」，多台并发采集时每台都会看到其他机器新建的目录，
`$newDirs[0]` 可能取到另一台，导致横幅印成别台的 SN 与归档包。

#### 认证与会话

- **单次认证模式**（v1.48.63）：root 或 `-NoSudo` 时，一条 ssh 内完成推送 → 采集 → 回拉，只需一次密码。
- **三步模式**：给出 BMC 参数且远端免 sudo 时自动改走此模式 —— 单次认证模式的 stdin 被项目包占用，
  无法同时携带 BMC 密码。
- **SSH 密码只输一次**（v1.54.16）：开头提示一次，经 OpenSSH 原生 `SSH_ASKPASS` 复用（askpass 脚本内只有
  变量名、无密码本体）；探测失败（旧版 OpenSSH）自动退回逐条提示。
- Windows OpenSSH 无 ControlMaster，每步认证失败自动重试 3 次（最多 3 次密码输入）。
- **全角字符检测**（v1.54.18）：SSH / BMC 密码做 ASCII 校验，全角字符（中文输入法全角状态下输入）立即
  提示重输 —— 掩码显示的星号数量相同，肉眼无法分辨，但必然认证失败。

#### BMC 密码通道（v1.54.4 起）

- `-BmcIp` / `-BmcUser` / `-HgxBmcIp` / `-HgxBmcUser` 等价 Linux `--bmc-ip` / `--bmc-user` / `--hgx-bmc-ip` / `--hgx-bmc-user`。
- 密码用 `Read-Host -AsSecureString` 运行时输入，经 **stdin** 送远端 `read` 后 export；不落盘、不进命令行 / 进程列表。
- **回显密码形态**（v1.54.24）：接收后打印长度、`@` 个数与是否纯 ASCII，便于与实际密码核对。
- `HWSCOPE_BMC_PASSWORD` 可用于无人值守预置。
- **预校验为可选**（v1.54.23）：`-VerifyBmc` 打开时先发一条极短 ssh（密码走 stdin、不进远端 argv）验证
  `ipmitool mc info`。默认关闭的原因：`Unable to establish IPMI v2` 无法区分「密码错」与「BMC 会话已满 /
  不可达」，默认开启会连报三次假告警。
- **校验失败不中止**（v1.54.18）：预校验失败仅告警并继续，由采集端对 `remote_bmc_*` 失败项串行重试一次
  （间隔 3 s）。

#### 打包与回拉

- **tar**：显式调用 `System32\bsdtar`（v1.48.48）——PATH 中的 Git for Windows GNU tar 会把 `C:\` 盘符当作
  远程主机，导致打包失败；tar 调用统一包裹错误容忍。
- **回拉用 scp**（v1.54.15）：远端结果包由采集那条 ssh 打包（`output` 内容平铺到包根 + `logs/` 一并带上）。
  修正两处缺陷：① `tar -C dir . -C dir logs` 参数位置错误 → GNU tar `exit=2` 且 **logs 整包丢失**；
  ② 「ssh + 命令重定向」回拉在 Windows 上出现认证通过但客户端立即 255、远端命令未执行。
- **回拉一律清空重建**（v1.51.0）：解包到 `%TEMP%\hwscope_stage_<ts>` 后逐机器落地，落地前清空旧目录。
  旧实现「保留旧目录 + 残留检测」实测弊大于利：归档被人工移走是常态，绝大多数回拉落入「不删」分支，
  本次未采的模块、已拔掉的外设日志留在目录内，而报告端按文件名取数 → **新采集数据被旧文件污染**，
  且从报告外观不可见。与 `remote_collect.sh`、本地 `hwscope.sh` 的语义一致。
- **stderr 透传**（v1.48.82 / v1.48.83）：仅压制 ssh 客户端提示与 `NativeCommandError` 红块，其余 stderr 逐行
  显示（采集进度可见）；文本取 `$_.Exception.Message`，空消息输出单空格占位 —— 旧实现把空消息渲染成类型名
  `System.Management.Automation.RemoteException`，整片刷屏并破坏排版。
- **主机密钥变更**（v1.48.82）：识别 `REMOTE HOST IDENTIFICATION HAS CHANGED` → 备份 `known_hosts` →
  `ssh-keygen -R` 清除旧记录 → 打印新旧指纹供核对 → 自动重试一次。仅对已知主机的变化放行，未知主机仍走
  `accept-new`。

### `fetch_report.ps1` — 巡检报告汇总

```powershell
tools\win\fetch_report.bat root@<h1>,root@<h2>
```

| 参数 | 说明 |
|------|------|
| `-Hosts <列表>` | `user@host` 逗号分隔（必填） |
| `-HwscopeDir <目录>` | 远端 HwScope 目录（默认 `/opt/hwscope`） |
| `-DestDir <目录>` | 本地归档目录（默认桌面 `hwscope_reports`） |
| `-Timeout <秒>` | SSH 连接超时（默认 15） |

拉取各机报告三件套（json / md / txt），按主机名归档。v1.49.22 起 scp 使用 `StrictHostKeyChecking=accept-new`
（原 `=no` 会连同被替换的主机密钥一起接受）、移除 `BatchMode`（对齐「默认交互式密码」）、不再以 `2>$null`
吞掉真实报错。

### `remote_run.ps1` — 多机远程执行

```powershell
tools\win\remote_run.bat root@<h1>,root@<h2> "uptime && nvidia-smi -L"
```

| 参数 | 说明 |
|------|------|
| `-Hosts <列表>` | `user@host` 逗号分隔（必填） |
| `-Command <命令>` | 远程命令（默认 `uptime`） |
| `-Timeout <秒>` | SSH 连接超时（默认 15） |

每台独立进程并发执行；**完成一台即打印一台**（v1.49.22：原 `Wait-Job | Receive-Job` 会攒到全部结束才输出，
分钟级采集时表现为卡死）。v1.43.0 由 `ssh_batch` 改名；Linux 对应 `remote_run.sh`。
`--script` / `--pull-logs` 为 Windows 侧二期功能，尚未实现。

### `sync_time.ps1` — 时间同步（OS / RTC / BMC）

```powershell
tools\win\sync_time.bat root@<host>
tools\win\sync_time.bat root@<host> -DryRun
tools\win\sync_time.bat root@<h1>,root@<h2> -Bmc:no
tools\win\sync_time.ps1 -Help
```

| 参数 | 说明 |
|------|------|
| `-Hosts <列表>` | `user@host` 逗号分隔；为空或给 `-Help` 时打印用法 |
| `-DryRun` | 只探测并显示偏差，不做修改 |
| `-Bmc auto\|yes\|no` | BMC 时间同步模式（默认 `auto`：目标机有 `ipmitool` 与 `/dev/ipmi0` 才执行） |
| `-Timeout <秒>` | SSH 连接超时（默认 10） |
| `-Help` / `-h` / `--help` | 显示用法（v1.53.4；此前 `--help` 会被当作主机名交给 ssh） |

以本机时间为基准，同步目标机 OS 时间 + RTC +（可选）BMC 时间。**只有 OS 时间决定成败**，RTC / BMC 失败
仅 `[WARN]`（v1.53.0）。RTC 三级兜底：`hwclock` → `python3` 直写 `/dev/rtc0` → `[WARN]`（Ubuntu 24.04
基础包不含 `hwclock`）。NTP 原值在设置后无条件还原。epoch 秒传递，不修改目标机时区。

**远程脚本经 base64 传参**：旧实现把含引号 / 括号的命令作为参数传递，PowerShell 5.1 重拼命令行时会丢弃引号，
远端报 `syntax error near unexpected token '('`（实测 native 侧只收到 `echo `）；v1.53.0 修复。`.ps1` 的
here-string 还会把行尾 CR 带入 payload（`core.autocrlf=true` 致检出错位，远端报 `$'\r': command not found`），
v1.53.2 在编码前去除 CR。

Linux 对应：`tools/sync_time.sh`。

---

## 网络 / BMC 运维

### `scan_ip.ps1` — 网段扫描与设备定位

```powershell
tools\win\scan_ip.bat
tools\win\scan_ip.bat 192.168.1
```

| 参数 | 说明 |
|------|------|
| `-Subnet <前三段>` | 目标网段（默认自动取本机有线网卡所在网段） |
| `-Range <起-止>` | 主机位范围（默认 `1-254`） |

并发 ping + ARP 表定位在线设备。v1.49.22 修正网段解析：原 `TrimEnd('/24')` 按字符集削尾，会把
`192.168.2` 变成 `192.168.`、`192.168.12` 变成 `192.168.1`，自动检测时静默扫描 0 台。

### `detect_bmc.ps1` — BMC 识别

```powershell
tools\win\detect_bmc.bat 192.168.1.1,192.168.1.100
```

| 参数 | 说明 |
|------|------|
| `-Hosts <IP 列表>` | 逗号分隔的候选 IP（必填） |
| `-Ports <端口列表>` | 探测端口（默认 `22,80,443,623,5900`） |

按 MAC 前缀（常见 BMC 厂商 OUI）+ 端口开放情况评分定位 BMC。v1.49.22 改为**端口探测完成后**再读取 ARP 表：
ARP 缓存依赖探测填充，先读会得到 MAC 恒为 `-`，使真实 BMC 被降级。

### `nic_switch.ps1` — 直连网卡配网

```powershell
tools\win\nic_switch.bat
tools\win\nic_switch.bat -Action Restore
```

| 参数 | 说明 |
|------|------|
| `-Action Set\|Restore` | `Set` 设固定 IP（默认）；`Restore` 按状态文件恢复原网卡配置 |
| `-AdapterName <名称>` | 指定网卡（默认自动选「已插线」的网卡） |
| `-IP <地址>` | 固定 IP（默认 `192.168.1.100`） |
| `-Prefix <位数>` | 前缀长度（默认 24） |
| `-Gateway <地址>` | 网关（默认为空） |

需管理员权限。`Set` 时把原网卡名与配置记录到脚本目录下的 `nic_switch_state.txt`，`Restore` 依此还原。
v1.49.22 起 `-Action Restore` 按状态文件记录的**网卡名**找回原网卡（原实现用当前探测到的网卡，插拔或改线后
会清掉其他网卡的 IP）；记录中的网卡不存在时拒绝恢复。

### `ipmi_power.ps1` — 远程电源控制

```powershell
tools\win\ipmi_power.bat <BMC-IP> status
tools\win\ipmi_power.bat <BMC-IP> cycle
```

| 参数 | 说明 |
|------|------|
| `-BmcIP <IP>` | BMC 地址（必填） |
| `-User <用户名>` | BMC 用户名（默认 `admin`） |
| `-Action status\|on\|off\|cycle` | 查询状态 / 开机 / 强制关机 / 重启（默认 `status`） |

密码优先取环境变量 `IPMI_PASSWORD`，否则交互输入；经 `ipmitool -E` 读取，命令串不含密码。
`off` / `cycle` 前需输入 `yes` 确认。依赖 PATH 中的 `ipmitool`（`winget install ipmitool` 或手动放置）。
v1.49.22：`.bat` 支持省略 action（原空值 `-Action` 导致参数绑定失败，而头部文档写明可省）；
末行 `exit /b %RC%` 不再把失败吞成 0。

### `wol.ps1` — 远程唤醒

```powershell
tools\win\wol.bat <MAC>
tools\win\wol.ps1 -Mac <MAC> -Broadcast <网段广播地址>
```

| 参数 | 说明 |
|------|------|
| `-Mac <MAC>` | 目标 MAC（必填，12 位十六进制；带 `-` / `:` 分隔与连写两种写法均可，非十六进制字符会被剔除） |
| `-Broadcast <地址>` | 广播地址（默认 `255.255.255.255`；跨网段唤醒可指定目标网段的广播地址） |
| `-Port <端口>` | 唤醒端口（默认 9；部分设备用 7） |

发送魔术包（6 × `FF` + MAC × 16）。服务器网卡需在 BIOS / 网卡属性或 BMC 中开启 Wake-on-LAN；
MAC 可用 `scan_ip.ps1` 获取。

---

## 服务 / 清理

### `dhcp_server.ps1` — 直连 DHCP 服务

```powershell
tools\win\dhcp_server.bat
tools\win\dhcp_server.bat -Subnet 192.168.60 -LeaseHours 24
```

| 参数 | 说明 |
|------|------|
| `-Subnet <前三段>` | 网段（默认 `192.168.50`）；服务地址为 `<Subnet>.1`，地址池 `.100`–`.200` |
| `-LeaseHours <小时>` | 租约时长（默认 12） |
| `-Port <端口>` | 服务端口（默认 67） |
| `-NoNIC` | 不修改本机网卡 IP |
| `-TestMode` | 测试模式（跳过管理员检查） |

纯 PowerShell 实现的 DHCP 服务（零依赖），配合 Linux 侧 `net_dhcp.sh` 使用。需管理员权限（绑定 67 端口
与修改网卡）；`-TestMode` 跳过管理员检查。

### `cleanup.ps1` — 清理采集输出

```powershell
tools\win\cleanup.bat
tools\win\cleanup.bat -Force
```

| 参数 | 说明 |
|------|------|
| `-Force` | 跳过确认 |

删除项目根下的 `output` 与 `logs`（先显示体积，再要求输入 `yes`）。Linux 对应 `tools/cleanup.sh`。

---

## 其他

### `Launch-DeepSeekHarness.ps1` — DeepSeek Harness Web GUI

```powershell
tools\win\Launch-DeepSeekHarness.bat
tools\win\Launch-DeepSeekHarness.ps1 -Port 3080 -NoBrowser
```

| 参数 | 说明 |
|------|------|
| `-Port <端口>` | 监听端口（默认 3080） |
| `-NoBrowser` | 不自动打开浏览器 |
| `-DryRun` | 只打印将执行的命令 |

从项目内 `workspace/`（已加入 `.gitignore`）启动，保证会话 JSONL 归档路径正确；目录不存在时自动创建。

### `unblock_ps.ps1` — 解除脚本运行限制

将当前用户执行策略设为 `RemoteSigned`（已为 `RemoteSigned` / `Unrestricted` 时跳过），并对本目录 `.ps1`
执行 `Unblock-File`。无参数，无需管理员。

---

## 与 Linux 版对应关系

| Windows 工具 | Linux 对应 | 说明 |
|--------------|-----------|------|
| `remote_collect.ps1` | `remote_collect.sh` | 采集流程等价；Windows 无 ControlMaster，密码复用机制不同 |
| `fetch_report.ps1` | —（无直接对应） | 批量拉取各机报告并归档 |
| `remote_run.ps1` | `remote_run.sh` | Windows 侧缺 `--script` / `--pull-logs` |
| `sync_time.ps1` | `sync_time.sh` | 判据与兜底策略一致 |
| `dhcp_server.ps1` | `dhcp_server.sh` | Windows 为纯 PowerShell 实现，Linux 为 dnsmasq 封装 |
| `cleanup.ps1` | `cleanup.sh` | |
| `scan_ip.ps1` · `detect_bmc.ps1` · `nic_switch.ps1` · `ipmi_power.ps1` · `wol.ps1` | —（Windows 侧独有） | 网络 / 电源运维 |
| `Launch-DeepSeekHarness.ps1` · `unblock_ps.ps1` | —（Windows 侧独有） | 本机工具 |
