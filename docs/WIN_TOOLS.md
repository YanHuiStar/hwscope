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
| `remote_collect.ps1/.bat` | 远程采集 | Windows 原生远程采集（等价 remote_collect.sh：推送→远端执行→回拉 `output\remote_output\<机器ID>\`）；`-InstallItems 1,2` 先远端非交互装依赖再采集（v1.42.1，等价 Linux `--install`）；交互式密码，每步认证失败自动重试 3 次（Windows OpenSSH 无 ControlMaster，共 3 次密码输入） |
| `fetch_report.ps1/.bat` | 巡检汇总 | 拉取各机报告三件套（json/md/txt），按主机名归档 |
| `ssh_batch.ps1/.bat` | 批量命令 | 对多台服务器执行同一命令 |

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
| `ssh_batch.ps1` | `remote_batch.sh` |
| `fetch_report.ps1` | （无直接对应，批量拉取报告） |
| `scan_ip/detect_bmc/nic_switch/ipmi_power/wol` | （Windows 侧独有，网络/电源运维） |
