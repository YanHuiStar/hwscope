# 配套工具（Linux/WSL）

> [← 返回 README](../README.md) · Windows 运维机工具见 [WIN_TOOLS.md](WIN_TOOLS.md) · 压测参数见 [USAGE.md](USAGE.md)

## `test/` — 硬件压测（只读测试，不修改硬件配置）

> 架构：聚合与实现解耦（v1.34.21）——`test_all.sh` 纯聚合入口（菜单/--all），单工具脚本在 `test/<组件>/` 子目录（可独立执行），公共库 `test/lib/test_common.sh`。

| 单脚本 | 测试内容 | 说明 |
|--------|---------|------|
| `cpu/cpu_stress_ng.sh` | CPU 满载 | stress-ng 全核，默认 30s |
| `cpu/cpu_sysbench.sh` | CPU 基准 | sysbench |
| `cpu/cpu_mprime.sh` | 散热验证 | mprime（300s 上限） |
| `memory/mem_stress_ng.sh` | 内存压力 | stress-ng vm 80% |
| `memory/mem_memtester.sh` | 位翻转 | memtester |
| `memory/mem_sysbench.sh` | 内存带宽 | sysbench |
| `disk/disk_fio.sh` | IOPS/延迟 | fio（选盘交互） |
| `disk/disk_hdparm.sh` | 缓存读 | hdparm |
| `disk/disk_dd.sh` | 顺序读 | dd |
| `network/net_iperf3.sh` | TCP 吞吐 | iperf3 |
| `network/net_mtr.sh` | 路径质量 | mtr |
| `ib/ib_perftest.sh` | IB 打流 | 自动配对 serial |
| `gpu/gpu_bandwidth.sh` | GPU 带宽 | bandwidthTest 逐卡+P2P |
| `gpu/gpu_burn_test.sh` | GPU 长压测 | gpu-burn（默认 1800s，-tc 张量核心） |
| `gpu/gpu_nvbandwidth.sh` | 带宽基准 | nvbandwidth |
| `gpu/gpu_partnerdiag.sh` | 出厂诊断 | partnerdiag（FLD 包） |
| `nccl/nccl_test.sh` | 集合通信 | nccl-tests |
| `test_server_info.sh` | 测试前服务器信息（v1.38.0） | 机器 ID/型号/CPU/内存/GPU/OS ~10 行轻量只读；各单脚本 test_init 后自动调用；可单独执行 |

用法：`bash test/test_all.sh`（菜单）/ `--all`（全部顺序）/ 单脚本直接 `bash test/<组件>/<工具>.sh [时长]`。结果落盘 `logs/test/<SN>/`。

## `tools/` — 采集与运维

> **报告体系已独立为 `report/` 模块**（v1.35.0）：报告生成、验收清单、多机对比、在线预览迁至 `report/`（结构见 [report/README](../report/README.md)），`tools/` 下不再保留同名文件（v1.35.3 移除兼容 wrapper，统一 `report/` 路径）。详细报告体系见 [REPORT.md](REPORT.md)。

### 报告（→ `report/` 模块）

| 脚本 | 说明 |
|------|------|
| `report/report.sh` | 报告生成：四件套 json/md/txt/html + 验收清单（--acceptance）+ 基线对比（--baseline）+ 压测关联（--test-dir）+ FLD 诊断参考（--fld-dir）+ OS-BMC 核验（--bmc-verify）；也可单格式 --json/--md/--txt/--both |
| `report/tools/batch_compare.sh` | 多机横向对比：读各机 JSON 生成同字段对比表（差异 ⚠️ 标注）；输出 `logs/batch_compare/`（`-o` 自定义） |
| `report/tools/report_server.sh` | 报告在线预览：解包 logs/report/ → 本地 HTTP（绑定 127.0.0.1） |
| `report/lib/md2html.awk` | 纯 awk Markdown→HTML 转换器（报告 HTML 件用，零依赖） |

### 诊断 / 对比（tools/ 原地）

| 脚本 | 说明 |
|------|------|
| `nvlink_verify.sh` | NVLink 完整性校验（拓扑比对） |
| `sel_monitor.sh` | SEL 事件对比巡检（历史 vs 当前） |
| `sync_time.sh` | SSH 时间同步 | 本机时间基准 → 目标机（epoch 秒无时区歧义；停 NTP + date -s + hwclock -w） |
| `sync_version.sh` | 版本号三处同步（hwscope.sh 注释/变量 + README 徽章） |

### 开发 / Agent 协作（v1.36.1+）

| 脚本 | 说明 |
|------|------|
| `tools/agent/agent_sync.sh` | 多机器/多 Agent 状态同步（v1.37.2）：开工第一步，fetch + 远程/本地 HEAD/版本对比 + 未推送状态，防凭记忆乱改版本；`--mark`/`--clear` 维护本地状态文件 AGENT_STATE.md（gitignore） |
| `tools/agent/git_push.sh` | 一键推送（v1.36.1+）：默认 fetch + 逐提交摘要 + **版本单调检查**（本地 < 远程拒绝）+ 直连重试 + 代理探测 + `[AI-ACTION]` 指引；**WSL 支持**（v1.39.1：WSL 下自动用 Windows git.exe + interop 探测 Windows 侧代理端口，绕过 WSL NAT 的 127.0.0.1 不可达问题） |

### 远程 / 批量

| 脚本 | 说明 |
|------|------|
| `remote_collect.sh` | 远程采集：tar 推送 → 远端执行 → 回拉（交互式密码 + ControlMaster）；`--install <1,2,...>` 先远端非交互装依赖再采集（v1.42.0） |
| `remote_run.sh` | 远程执行：多机命令 / 推送文件 / 推送执行脚本（--script）+ 日志回拉（--pull-logs）；v1.43.0 由 remote_batch.sh 改名 |

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
| `install_tool.sh` | 环境安装：采集依赖工具（dmidecode/lspci/ipmitool/...）；`-c <1,2,...> -y` 非交互安装（远程自动安装用，v1.42.0） |
| `cleanup.sh` | 清理：output/ + logs/ 删除（显示大小 + 输入 yes 确认） |
- **`test/report_regression.sh`（v1.48.3）**：报告解析回归测试——固定样本跑报告 + 10 组指标与基线比对，防解析/渲染静默回归；用法 `bash test/report_regression.sh <采集目录> [--update] [--all]`，基线 `test/baseline/<机器ID>.txt`；改解析器前后各跑一次。需 Linux 环境（fork 密集脚本在 git-bash 下易崩）
