# 使用指南（Usage）

> [← 返回 README](../README.md) · 快速上手见 [QUICKSTART.md](QUICKSTART.md) · 报告与验收体系见 [REPORT.md](REPORT.md)

## 采集

```bash
sudo bash hwscope.sh                          # 全量采集（双层并行）
sudo bash hwscope.sh --serial                 # 串行（低负载）
sudo bash hwscope.sh                  # 输出目录 output/<SN>/（v1.45.6 起重复采集默认覆盖——采集=当前状态快照，历史自动归档 logs/；v1.45.7 覆盖前自动校验归档完整性，含未归档数据先补归档、补档失败拒绝覆盖）
sudo bash hwscope.sh --stamp          # 输出目录加时间戳后缀（保留多版本，换配件前后对比；默认 SN 目录或 --output 指定路径均已存在时均生效，v1.45.7）
sudo bash hwscope.sh --force          # （兼容保留：v1.45.6 起默认即覆盖）
sudo bash hwscope.sh --quiet                  # 静默模式（不打印模块明细）
sudo bash hwscope.sh --no-parallel            # 禁模块内并行（低负载）
sudo bash hwscope.sh --module-timeout 120     # 模块超时秒数（默认 300）
sudo bash hwscope.sh --modules gpu,cpu        # 只采部分模块
sudo bash hwscope.sh --skip gpu,fan           # 跳过指定模块
sudo bash hwscope.sh --output /data/collect   # 指定输出目录
bash modules/04_gpu.sh /path/output           # 单模块（调试）
```

输出结构：`output/<机器ID>/` 下按模块分目录（bmc/cpu/gpu/...），每命令一个日志 + 报告文件。

### 模块总览（17 个，与 `modules/*.sh` 逐项对应）

| 编号 | 模块 | 采集内容 | 主要工具 | conf 开关 |
|------|------|----------|----------|-----------|
| 01 | motherboard | 主板/BIOS/机箱 | dmidecode | `MODULE_MB` |
| 02 | cpu | CPU 信息 | dmidecode + lscpu | `MODULE_CPU` |
| 03 | memory | 内存插槽/容量/速率 | dmidecode | `MODULE_MEMORY` |
| 04 | gpu | GPU 信息 | nvidia-smi / amd-smi·rocm-smi / npu-smi / xpu-smi / 国产 SMI（v1.47.0 适配器框架，见 §采集说明）| `MODULE_GPU` |
| 05 | nvswitch | NVSwitch 信息 | nvswitch + fabric-manager | `MODULE_NVSWITCH` |
| 06 | pcie | PCIe 拓扑/速率 | lspci | `MODULE_PCIE` |
| 07 | network | 网络/IB/光模块 | ibstat + mlxlink + ethtool | `MODULE_NETWORK` |
| 08 | storage | 存储设备(SATA/SAS/NVMe/SMART) | lsblk + smartctl | `MODULE_STORAGE` |
| 09 | raid | RAID/HBA 卡信息 | storcli64 / sas3ircu | `MODULE_RAID` |
| 10 | psu | 电源 (PSU) 信息 | IPMI + sysfs | `MODULE_PSU` |
| 11 | fan | 风扇 (FAN) 信息 | IPMI + hwmon + sensors | `MODULE_FAN` |
| 12 | bmc | BMC/IPMI 带外信息 | ipmitool + Redfish | `MODULE_BMC` |
| 13 | nvsm | NVSM 综合(条件执行) | nvsm | `MODULE_NVSM` |
| 14 | dcgm | DCGM 诊断(条件执行) | dcgmi | `MODULE_DCGM` |
| 15 | firmware | 固件合规 (VBIOS/BMC/NIC/NVSwitch) | 对照 `conf/fw_required.txt` | `MODULE_FIRMWARE` |
| 16 | power | 能耗台账 (累计能耗) | BMC 累计能耗 + DCMI/Redfish 快照 | `MODULE_POWER` |
| 99 | os | OS 基础信息 | — | `MODULE_OS` |

> 单模块调试：`bash modules/<NN>_<模块>.sh <输出目录>`；开关默认全开（`conf/hwscope.conf` 置 0 关闭对应模块）。

**GPU 多厂商适配器（v1.47.0）**：04 模块按 `GPU_PLATFORM` 分发到 `modules/gpu/adapter_<vendor>.sh`——NVIDIA（nvidia-smi，金标准）/ AMD（amd-smi·rocm-smi）/ 昇腾（npu-smi）/ Intel（xpu-smi）/ 寒武纪·壁仞·摩尔线程·沐曦·天数智芯（cnmon·bmt-smi·mthreads-gmi·mx-smi·ix-smi）。每个适配器输出**统一 `gpu_inventory.csv`**（列与 nvidia-smi 18 列一致），报告/显存魔改检测/验收 GPU PCIe 项跨厂商零改动生效。厂商工具未装时自动降级 **lspci 层兜底**（PCIe 链路可判，卡不丢失），工具依赖见 `docs/DEPENDENCIES.md` §3.6。

## 报告生成

> 报告体系为独立 `report/` 模块（v1.35.0）：主入口 `report/report.sh`（v1.35.3 起移除 tools/ 兼容 wrapper，统一新路径）。

```bash
bash report/report.sh <采集目录>                          # json/md/txt/html 四件套
bash report/report.sh <采集目录> --acceptance             # 验收清单 md/html（14 项判定）
bash report/report.sh <采集目录> --baseline <历史目录>     # 时序差异对比
bash report/report.sh <采集目录> --test-dir <压测目录>     # 关联压测归档
bash report/report.sh <采集目录> --fld-dir <FLD日志目录>    # 关联 DGX FLD 诊断日志（logs-<TS>/，生成"FLD 诊断参考"段，v1.37.0）
bash report/report.sh <采集目录> --bmc-verify             # 开启 OS-BMC 一致性交叉核验
bash report/report.sh <采集目录> --json                   # 仅生成 json（也可 --md/--txt/--both）
```

报告**只读日志、不重新采集**，可反复生成；日志缺失字段显示 N/A。

## 远程采集与多机对比

### 远程采集（Linux/WSL）

```bash
bash tools/remote_collect.sh -H root@10.0.0.1                 # 全量采集并回拉
bash tools/remote_collect.sh -H root@10.0.0.1 --modules gpu   # 只采部分
bash tools/remote_collect.sh -H user@host --no-sudo           # 普通用户直接执行
bash tools/remote_collect.sh -H root@10.0.0.1 --install 1,2   # 先远端装基础+压测依赖再采集（v1.42.0）
```

- 流程：tar 临时推送项目 → 远端执行 hwscope → 回拉 → 清理（远端零持久占用）
- 认证：默认交互式密码（不落盘）+ ControlMaster 复用（输一次密码）；root 免 sudo，普通用户自动 `-t` 供 sudo 交互
- `--install <1,2,...>`：远端先跑 `install_tool.sh -c <列表> -y` 非交互装依赖再采集（远程冷启动）；安装失败中止
- 结果：`output/remote_output/<机器ID>/`；归档包 → `logs/remote_logs/`

### 远程采集（Windows 运维机）

```powershell
tools\win\remote_collect.bat -H root@10.0.0.1
tools\win\remote_collect.ps1 -H root@10.0.0.1 -Modules gpu,cpu -OutDir D:\hwout
tools\win\remote_collect.bat -H root@10.0.0.1 -InstallItems 1,2   # 先远端装基础+压测依赖再采集（v1.42.1）
```

- 依赖：Windows 自带 OpenSSH 客户端 + tar（零新依赖）
- 认证：交互式密码，每步失败自动重试 3 次（Windows OpenSSH 不支持 ControlMaster，共 3 次密码输入）
- `-InstallItems <1,2,...>`：远端先跑 `install_tool.sh -c <列表> -y` 非交互装依赖再采集（安装+采集合并一条 ssh 命令）

### 多机对比 / 批量运维

```bash
bash report/tools/batch_compare.sh <目录1> <目录2> ...   # 多机横向对比（差异 ⚠️ 标注；输出 logs/batch_compare/，-o 自定义）
bash tools/remote_run.sh -H "root@10.0.0.1 root@10.0.0.2" -c 'nvidia-smi -L'   # 多机命令（v1.43.0 由 remote_batch.sh 改名）
bash tools/remote_run.sh -H root@10.0.0.1 --script ./diag.sh --pull-logs /tmp/diag  # 推送执行脚本 + 回拉过程日志
```

## 运维工具

### 一键推送更新（开发维护）

```bash
bash tools/agent/git_push.sh            # 审查并推送（交互确认）
bash tools/agent/git_push.sh -y         # 跳过确认直接推
bash tools/agent/git_push.sh --dry-run  # 只审查不推送
```

直连失败自动探测本机代理重推；全部失败输出 `[AI-ACTION]` 指引。Windows 双击 `tools/agent/git_push.bat`。
**WSL 提示（v1.39.1）**：WSL 下 git_push 自动改用 Windows 的 `git.exe` + interop 探测 Windows 侧代理端口（v2ray 等），无需手动配代理；若输出"WSL NAT 不可达"类提示，说明 Windows 侧代理未连接，先启动代理客户端并点"连接"。

### 固件基线管理

```bash
bash tools/fw_baseline_import.sh <基准机采集目录> --diff   # 预览基线差异
bash tools/fw_baseline_import.sh <基准机采集目录> --apply  # 写入 conf/fw_required.txt
```

### 能耗持续采样

```bash
bash tools/power_monitor.sh start [--interval 60] [--duration 0]   # 后台采样（DCMI 优先/Redfish 兜底）
bash tools/power_monitor.sh status                                  # 查看采样状态
bash tools/power_monitor.sh stop                                    # 停止并输出聚合 + kWh 核算
```

### 报告在线预览

```bash
bash report/tools/report_server.sh          # 解包 logs/report/ → 本地预览（绑定 127.0.0.1）
```

### 网卡 / 线缆 / BMC 运维

```bash
bash tools/nic_tool.sh               # 网卡信息/固件管理（Mellanox）
bash tools/cable_map.sh              # IB 线缆拓扑（自动发现物理连线）
bash tools/bmc_tool.sh               # BMC 凭据/密码管理
```

### DHCP（新上架服务器批量发 IP）

```bash
sudo bash tools/dhcp_server.sh install            # 安装 dnsmasq
sudo bash tools/dhcp_server.sh config             # 配置网段（默认 192.168.50.0/24 .100-.200）
sudo bash tools/dhcp_server.sh start              # 启动 DHCP 服务（需先 config）
sudo bash tools/dhcp_server.sh leases-export <csv>  # 租约导出
sudo bash tools/dhcp_server.sh reconcile <目录...>  # 租约 ↔ 采集台账交叉核对
```

### AI 推理引擎安装

```bash
bash tools/install_ai.sh          # 交互菜单选择引擎：vLLM / SGLang / TRT-LLM / Ollama / llama.cpp
```

## 硬件压测（只读，不修改硬件配置）

> 聚合与实现解耦（v1.34.21）：`test_all.sh` 纯聚合入口；单工具脚本在 `test/<组件>/` 子目录，可独立执行。

```bash
bash test/test_all.sh                    # 菜单式入口（推荐，选测/全测）
bash test/test_all.sh --all              # 全部单脚本顺序执行
bash test/cpu/cpu_stress_ng.sh 60        # 单脚本独立执行（CPU 满载 60s）
bash test/cpu/cpu_sysbench.sh            # CPU 基准
bash test/memory/mem_stress_ng.sh        # 内存压力
sudo bash test/disk/disk_fio.sh          # 磁盘 IOPS（选盘交互，需 sudo）
bash test/network/net_iperf3.sh          # 网络吞吐（提示输入服务端地址）
sudo bash test/ib/ib_perftest.sh         # IB 链路（自动配对打流，需 sudo）
bash test/gpu/gpu_bandwidth.sh           # GPU 带宽（bandwidthTest 逐卡+P2P）
bash test/gpu/gpu_burn_test.sh 1800      # GPU 长时满载（gpu-burn -tc，默认 30 分钟）
bash test/nccl/nccl_test.sh              # NCCL 集合通信
```

单脚本支持 `[时长秒]` 参数与 `-h`/`--help`。结果落盘 `logs/test/<SN>/`。

**测试日志自包含机器身份**（v1.38.0）：各测试脚本在 test_init 后自动写入 `=== Server Info ===` 段（机器 ID/型号/CPU/内存/GPU/OS）到汇总日志 + `server_info.log`——单测一项也知道是哪台机器（参考厂商 FLD 日志做法）。单独查看：

```bash
bash test/test_server_info.sh          # 打印服务器信息（独立执行）
bash test/test_server_info.sh --append <文件>   # 追加到指定日志
```

## 多机器 / 多 Agent 协作（v1.37.2）

仓库可能被多台机器、多个 Agent 会话（DeepSeek Harness / Hermes 等）先后修改推送。规则：**一切状态以远程 origin/main 为真相**。

```bash
bash tools/agent/agent_sync.sh              # 开工第一步：fetch + 远程/本地 HEAD/版本对比 + 未推送状态
bash tools/agent/agent_sync.sh --mark       # 提交后：标记未推送（本地 AGENT_STATE.md，gitignore）
bash tools/agent/git_push.sh -y             # 推送（默认 fetch + 落后 rebase + 版本单调检查）
bash tools/agent/agent_sync.sh --clear      # 推送成功后：清空未推送标记
```

- **版本号只升不降**：升版本前看 agent_sync 显示的远程版本，在远程基础上升；git_push 会硬拦截"本地 < 远程"
- 协作规则全文见 [AGENTS.md](../AGENTS.md)「多机器/多 Agent 协作规则」
