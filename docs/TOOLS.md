# 配套工具（Linux/WSL）

> [← 返回 README](../README.md) · Windows 运维机工具见 [WIN_TOOLS.md](WIN_TOOLS.md) · 压测参数见 [USAGE.md](USAGE.md)

## `test/` — 硬件压测（只读测试，不修改硬件配置）

| 脚本 | 场景 | 说明 |
|------|------|------|
| `cpu_test.sh` | CPU 稳定性 | 满载压测 |
| `memory_test.sh` | 内存压力 | 压力 + 校验 |
| `disk_test.sh` | 磁盘读写 | 吞吐 + 校验 |
| `network_test.sh` | 网络吞吐 | 双机吞吐（iperf3，需远端服务端） |
| `ib_test.sh` | IB 链路 | 带宽 + 丢包（perftest） |
| `gpu_test.sh` | GPU 压力 | 自动发现已装测试程序（bandwidthTest/gpu_burn 等） |
| `nccl_test.sh` | 集合通信 | NCCL 多卡测试 |
| `test_all.sh` | 一键全测 | 聚合入口（按需选测） |
| `test_common.sh` | 公共库 | 统一落盘 `logs/test/<时间戳>/` |

用法：`bash test/cpu_test.sh`（各脚本一致，进入后菜单选择测试项）。结果落盘 `logs/test/<时间戳>/`。

## `tools/` — 采集与运维

> **报告体系已独立为 `report/` 模块**（v1.35.0）：报告生成、验收清单、多机对比、在线预览迁至 `report/`（结构见 [report/README](../report/README.md)），`tools/` 下不再保留同名文件（v1.35.3 移除兼容 wrapper，统一 `report/` 路径）。详细报告体系见 [REPORT.md](REPORT.md)。

### 报告（→ `report/` 模块）

| 脚本 | 说明 |
|------|------|
| `report/report.sh` | 报告生成：四件套 json/md/txt/html + 验收清单（--acceptance）+ 基线对比（--baseline）+ 压测关联（--test-dir）+ OS-BMC 核验（--bmc-verify）；也可单格式 --json/--md/--txt/--both |
| `report/tools/batch_compare.sh` | 多机横向对比：读各机 JSON 生成同字段对比表（差异 ⚠️ 标注）；输出 `logs/batch_compare/`（`-o` 自定义） |
| `report/tools/report_server.sh` | 报告在线预览：解包 logs/report/ → 本地 HTTP（绑定 127.0.0.1） |
| `report/lib/md2html.awk` | 纯 awk Markdown→HTML 转换器（报告 HTML 件用，零依赖） |

### 诊断 / 对比（tools/ 原地）

| 脚本 | 说明 |
|------|------|
| `nvlink_verify.sh` | NVLink 完整性校验（拓扑比对） |
| `sel_monitor.sh` | SEL 事件对比巡检（历史 vs 当前） |
| `sync_version.sh` | 版本号三处同步（hwscope.sh 注释/变量 + README 徽章） |

### 远程 / 批量

| 脚本 | 说明 |
|------|------|
| `remote_collect.sh` | 远程采集：tar 推送 → 远端执行 → 回拉（交互式密码 + ControlMaster） |
| `remote_batch.sh` | 批量运维：多机同命令 / 推送文件 |

### 运维操作（含写操作，执行前二次确认）

| 脚本 | 说明 |
|------|------|
| `dhcp_server.sh` | dnsmasq 封装：安装/启停/租约查询 + `leases-export` 租约 CSV + `reconcile` 租约↔台账交叉核对 |
| `net_dhcp.sh` | 一键配置网口 DHCP 自动获取 IP（Ubuntu 24.04 netplan） |
| `fw_baseline_import.sh` | 固件基线自动导入：基准机 → conf/fw_required.txt（--diff 预览 / --apply 写入） |
| `firmware_check.sh` | 固件版本核对（对照基线快速核对） |
| `power_monitor.sh` | 能耗持续采样：后台循环 DCMI/Redfish → CSV，stop 输出聚合 + kWh 核算 |
| `nic_tool.sh` | 网卡运维：Mellanox 信息/固件管理 |
| `cable_map.sh` | IB 线缆拓扑：自动发现物理连线关系 |
| `bmc_tool.sh` | BMC 管理：凭据/密码 |
| `install_ai.sh` | AI 推理引擎安装：vLLM / SGLang / TRT-LLM / Ollama / llama.cpp |
| `install_tool.sh` | 环境安装：采集依赖工具（dmidecode/lspci/ipmitool/...） |
| `cleanup.sh` | 清理：output/ + logs/ 删除（显示大小 + 输入 yes 确认） |
