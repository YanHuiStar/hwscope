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
| `remote_collect.ps1/.bat` | 远程采集 | Windows 原生远程采集（等价 remote_collect.sh：推送→远端执行→回拉 `output\remote_output\<机器ID>\`）；`-InstallItems 1,2` 先远端非交互装依赖再采集（v1.42.1，等价 Linux `--install`）；交互式密码，每步认证失败自动重试 3 次（Windows OpenSSH 无 ControlMaster，共 3 次密码输入）；首次连接免交互（v1.48.47：StrictHostKeyChecking=accept-new + LogLevel=ERROR——免 host key yes/no 确认、抑制 stderr Warning 致 NativeCommandError 中断）；v1.48.48：显式调用 System32 bsdtar（PATH 的 Git GNU tar 把 C:\ 当远程主机致打包失败）+ tar 调用统一错误容忍包装；**v1.48.82：① stderr 改「噪音白名单」**（v1.48.51 的整类丢弃 `-isnot [ErrorRecord]` 会连同采集进度一并吞掉——单次认证模式让 `bash hwscope.sh >&2` 走 stderr 以避开 stdout 上的 tar 流，两者相撞致用户只见头尾几行；现仅压制 ssh 客户端提示/NativeCommandError 红块，其余 stderr 照常逐行显示）**② host key 变更自动处理**（流动盘重装/换盘场景：识别 `REMOTE HOST IDENTIFICATION HAS CHANGED` → 备份 known_hosts → `ssh-keygen -R` 清旧记录 → 打印新旧指纹供核对 → 自动重试一次；仅对已知主机的变化放行，未知主机仍走 accept-new，不用 `StrictHostKeyChecking=no`）**；**v1.48.99：回拉改为「逐机器精准替换」**（原为 `tar x -C remote_output` 纯覆盖式解包，旧版本产物会永久残留、被报告端兜底误当本次数据；现先解到 `%TEMP%\hwscope_stage_<ts>` 再逐机器落地：有归档且归档不早于目录内容 → 清空旧目录，否则保留旧目录增量覆盖并告警；带目录名合法性/长度护栏，绝不静默删未归档数据）**；v1.48.83：stderr 文本改取 `$_.Exception.Message`**（`"$_"` 对空消息求值返回**类型名** `System.Management.Automation.RemoteException`，会把远端空 stderr 行整片刷成该串字、排版全乱；空消息改输出单空格占位——PowerShell 管道丢弃空串，单空格既保住空行又不破坏流式）|
| `fetch_report.ps1/.bat` | 巡检汇总 | 拉取各机报告三件套（json/md/txt），按主机名归档 |
| `remote_run.ps1/.bat` | 远程执行 | 对多台服务器执行同一命令（v1.43.0 由 ssh_batch 改名；Linux 对应 remote_run.sh；--script/--pull-logs Windows 二期） |

## 网络 / BMC 运维

| 工具 | 场景 | 说明 |
|------|------|------|
| `scan_ip.ps1/.bat` | 未知 IP | 并发 ping + ARP 定位设备 |
| `detect_bmc.ps1/.bat` | BMC 发现 | MAC 前缀 + 端口评分定位 BMC |
| `nic_switch.ps1/.bat` | 直连配网 | 自动识别网卡设固定 IP |
| `ipmi_power.ps1/.bat` | 远程电源 | BMC 开机/关机/重启（密码走环境变量，不落盘） |
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
