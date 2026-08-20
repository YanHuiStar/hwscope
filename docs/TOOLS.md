# 配套工具

## `test/` — 硬件压测（只读测试，不修改硬件配置）

| 脚本 | 场景 | 说明 |
|------|------|------|
| `cpu_test.sh` | CPU 稳定性 | 满载压测 |
| `memory_test.sh` | 内存压力 | 压力 + 校验 |
| `disk_test.sh` | 磁盘读写 | 吞吐 + 校验 |
| `network_test.sh` | 网络吞吐 | 单机回环/双机 |
| `ib_test.sh` | IB 链路 | 带宽 + 丢包（perftest） |
| `gpu_test.sh` | GPU 压力 | 算力压测（DCGM 监测） |
| `nccl_test.sh` | 集合通信 | NCCL 多卡测试 |

结果落盘 `logs/test/<时间戳>/`。

## `tools/` — 运维操作（含写操作，执行前二次确认）

| 脚本 | 场景 | 说明 |
|------|------|------|
| `report.sh` | 报告生成 | 四件套 + 验收清单 + 基线对比 + 压测关联 |
| `batch_compare.sh` | 多机对比 | 读各机 JSON 生成对比表（差异 ⚠️） |
| `remote_collect.sh` | 远程采集 | tar 推送 → 远端执行 → 回拉（交互式密码） |
| `remote_batch.sh` | 批量运维 | 多机同命令/推文件 |
| `dhcp_server.sh` | DHCP | 新上架服务器批量发 IP + 租约核对 |
| `fw_baseline_import.sh` | 固件基线 | 基准机 → fw_required.txt |
| `power_monitor.sh` | 能耗采样 | 后台循环 → CSV + kWh 核算 |
| `report_server.sh` | 报告预览 | 本地 HTTP 预览（127.0.0.1） |
| `nic_tool.sh` | 网卡运维 | Mellanox 信息/固件 |
| `cable_map.sh` | 线缆拓扑 | IB 物理连线发现 |
| `bmc_tool.sh` | BMC 管理 | 凭据/密码 |
| `install_ai.sh` | AI 引擎安装 | vLLM/SGLang/TRT-LLM/Ollama/llama.cpp |
| `cleanup.sh` | 清理 | output/logs 删除（yes 确认） |

## `tools/win/` — Windows 配套工具

| 脚本 | 场景 | 说明 |
|------|------|------|
| `remote_collect.ps1/.bat` | 远程采集 | Windows 原生远程采集（等价 remote_collect.sh） |
| `fetch_report.ps1/.bat` | 巡检汇总 | 拉取各机报告四件套归档 |
| `ssh_batch.ps1/.bat` | 批量命令 | 多机执行同一命令 |
| `scan_ip.ps1/.bat` | 未知 IP | 并发 ping + ARP 定位设备 |
| `detect_bmc.ps1/.bat` | BMC 发现 | MAC 前缀 + 端口评分定位 BMC |
| `nic_switch.ps1/.bat` | 直连配网 | 自动识别网卡设固定 IP |
| `ipmi_power.ps1/.bat` | 远程电源 | BMC 开机/关机/重启（密码走环境变量） |
| `wol.ps1/.bat` | 远程唤醒 | Wake-on-LAN |
| `dhcp_server.ps1/.bat` | 直连 DHCP | 纯 PowerShell DHCP（零依赖） |
| `unblock_ps.ps1/.bat` | 首次使用 | 解除 .ps1 运行限制 |

> 每个工具配套同名 `.bat` 启动器（chcp 65001 + ExecutionPolicy Bypass + 参数透传）。
