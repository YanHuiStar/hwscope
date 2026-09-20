# Windows 运维机工具（tools/win/）

> [← 返回 README](../README.md) · Linux/WSL 侧工具见 [TOOLS.md](TOOLS.md)
>
> 所有工具为 `.ps1` 脚本 + 同名 `.bat` 启动器（chcp 65001 + ExecutionPolicy Bypass + 参数透传），
> 依赖 Windows 自带 OpenSSH 客户端 / PowerShell（零新依赖）。

## 首次使用

```powershell
tools\win\unblock_ps.bat        # 解除 .ps1 运行限制（当前用户，无需管理员）
```

## 远程采集 / 汇总

| 工具 | 场景 | 说明 |
|------|------|------|
| `remote_collect.ps1/.bat` | 远程采集 | Windows 原生远程采集（等价 remote_collect.sh：推送→远端执行→回拉 `output\remote_output\<机器ID>\`）；`-InstallItems 1,2` 先远端非交互装依赖再采集（v1.42.1，等价 Linux `--install`）；交互式密码，每步认证失败自动重试 3 次（Windows OpenSSH 无 ControlMaster，共 3 次密码输入）；首次连接免交互（v1.48.47：StrictHostKeyChecking=accept-new + LogLevel=ERROR——免 host key yes/no 确认、抑制 stderr Warning 致 NativeCommandError 中断）；v1.48.48：显式调用 System32 bsdtar（PATH 的 Git GNU tar 把 C:\ 当远程主机致打包失败）+ tar 调用统一错误容忍包装；**v1.48.82：① stderr 改「噪音白名单」**（v1.48.51 的整类丢弃 `-isnot [ErrorRecord]` 会连同采集进度一并吞掉——单次认证模式让 `bash hwscope.sh >&2` 走 stderr 以避开 stdout 上的 tar 流，两者相撞致用户只见头尾几行；现仅压制 ssh 客户端提示/NativeCommandError 红块，其余 stderr 照常逐行显示）**② host key 变更自动处理**（流动盘重装/换盘场景：识别 `REMOTE HOST IDENTIFICATION HAS CHANGED` → 备份 known_hosts → `ssh-keygen -R` 清旧记录 → 打印新旧指纹供核对 → 自动重试一次；仅对已知主机的变化放行，未知主机仍走 accept-new，不用 `StrictHostKeyChecking=no`）**；**v1.48.99：回拉改为「逐机器精准替换」**（原为 `tar x -C remote_output` 纯覆盖式解包，旧版本产物会永久残留、被报告端兜底误当本次数据；现先解到 `%TEMP%\hwscope_stage_<ts>` 再逐机器落地：有归档且归档不早于目录内容 → 清空旧目录，否则保留旧目录增量覆盖并告警**——**v1.49.10 再改**：归档被人工移走是常态，原「找不到归档就 WARN」成了噪音 → 降级为 `[INFO]`；同时补一道**真风险**检查：增量覆盖会留下"本次没拉到"的旧文件（如本次未采的模块、已改名的日志），而报告端按文件名找数据会读到过期内容，故覆盖后用**文件清单差集**找出这类残留，确有才 `[WARN]` 并列出前 5 个（不用时间戳判定——Copy-Item 保留原始时间戳，远端采集时间常早于本次回拉，用时间比会把本次文件误判为残留）；带目录名合法性/长度护栏。**v1.51.0：废除上述「保留旧目录 + 残留检测」整套做法，回拉一律清空重建**——实测弊大于利：归档被人工移走是常态，绝大多数回拉因此落到「不删」分支，旧文件（本次未采的模块、已拔掉的外设日志）留在目录里，而报告端「按文件名找数据」的前提是「目录内文件同属一次采集」→ 旧文件被当本次数据读，**新采集数据被污染**且从报告外观看不出来；「保护旧数据」本无必要（历史留存由 logs\remote_logs\ 的归档承担，每次回拉都归档一份）；该逻辑还引入过一次误报（两侧相对路径基准不一致 → 全部文件被判为残留））**；v1.48.83：stderr 文本改取 `$_.Exception.Message`**（`"$_"` 对空消息求值返回**类型名** `System.Management.Automation.RemoteException`，会把远端空 stderr 行整片刷成该串字、排版全乱；空消息改输出单空格占位——PowerShell 管道丢弃空串，单空格既保住空行又不破坏流式）|
| `fetch_report.ps1/.bat` | 巡检汇总 | 拉取各机报告三件套（json/md/txt），按主机名归档；**v1.49.22**：scp 改用 `StrictHostKeyChecking=accept-new`（原 `=no` 会连被替换的主机密钥一起接受）、去掉 `BatchMode`（对齐"默认交互式密码"）、不再 `2>$null` 吞掉真实报错 |
| `remote_run.ps1/.bat` | 远程执行 | 对多台服务器执行同一命令（v1.43.0 由 ssh_batch 改名；Linux 对应 remote_run.sh；--script/--pull-logs Windows 二期）；**v1.49.22**：输出改为**完成一台即打印一台**（原 `Wait-Job \| Receive-Job` 会攒到全部结束才出，分钟级采集时看着像卡死——AGENTS v1.48.53 流式要求）；`-Timeout` 文档更正为"SSH 连接超时" |

## 网络 / BMC 运维

| 工具 | 场景 | 说明 |
|------|------|------|
| `scan_ip.ps1/.bat` | 未知 IP | 并发 ping + ARP 定位设备；**v1.49.22**：网段解析修正——原 `TrimEnd('/24')` 按字符集削尾，会把 192.168.2 → 192.168.、192.168.12 → 192.168.1，自动检测时静默扫 0 台 |
| `detect_bmc.ps1/.bat` | BMC 发现 | MAC 前缀 + 端口评分定位 BMC；**v1.49.22**：ARP 表改到**端口探测之后**读取（ARP 缓存靠探测填充，先读则 MAC 恒为 `-`、真 BMC 被降级） |
| `nic_switch.ps1/.bat` | 直连配网 | 自动识别网卡设固定 IP；**v1.49.22**：`-Action Restore` 按状态文件记录的**网卡名**找回原网卡（原来用当前探测到的网卡，插拔/改线后会清掉别的网卡 IP）；记录网卡不存在时拒绝恢复 |
| `ipmi_power.ps1/.bat` | 远程电源 | BMC 开机/关机/重启（密码走环境变量，不落盘）；**v1.49.22**：`.bat` 支持省略 action（原来 `-Action` 空值导致参数绑定失败，而头部文档说 action 可省）；末行 `exit /b %RC%` 不再把失败吞成 0 |
| `wol.ps1/.bat` | 远程唤醒 | Wake-on-LAN 魔术包 |

## 服务 / 清理

| 工具 | 场景 | 说明 |
|------|------|------|
| `dhcp_server.ps1/.bat` | 直连 DHCP | 纯 PowerShell DHCP 服务（零依赖），配合 `net_dhcp.sh` 即插即通 |
| `cleanup.ps1/.bat` | 清理 | output/ + logs/ 删除（显示大小 + 输入 yes 确认） |

## 其他

| 工具 | 场景 | 说明 |
|------|------|------|
| `Launch-DeepSeekHarness.ps1/.bat` | AI 工具 | DeepSeek Harness Web GUI 一键启动（从工作目录启动保证会话存储路径正确） |
| `unblock_ps.ps1/.bat` | 首次使用 | 解除 .ps1 运行限制 |

## 与 Linux 版对应关系

| Windows 工具 | Linux 对应 |
|--------------|-----------|
| `remote_collect.ps1` | `remote_collect.sh` |
| `cleanup.ps1` | `cleanup.sh` |
| `dhcp_server.ps1` | `dhcp_server.sh` |
| `remote_run.ps1` | `remote_run.sh` |
| `fetch_report.ps1` | （无直接对应，批量拉取报告） |
| `scan_ip/detect_bmc/nic_switch/ipmi_power/wol` | （Windows 侧独有，网络/电源运维） |
