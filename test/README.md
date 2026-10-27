# HwScope 硬件压测（test/）

> ⚠️ **状态：占位（未完成、未经真机验证）。**
> ① 测试项目尚未最终确定，现有脚本会增删调整，不代表最终清单；
> ② 未在真实硬件上完成验证 —— 脚本可执行，但参数取值、输出正确性、判定口径均未经检验。
>
> **本模块结果不得作为硬件验收依据。** 正式交付验收以厂商工具（DCGM / NCCL / FLD 等）为准。

原则：**只测不改** —— 不修改硬件与系统配置；仅 `fio` / `dd` 会在指定盘写入测试文件并自动清理。
索引见 [docs/TOOLS.md](../docs/TOOLS.md)（本文件为详细说明）。

## 架构：聚合与实现解耦

```
test/
├── test_all.sh           ← 纯聚合入口（菜单 / --all，不含测试逻辑）
├── lib/test_common.sh    ← 公共库（日志落盘 / 结果记录 / server_info 头）
├── cpu/  memory/  disk/  network/  ib/  gpu/  nccl/
│   └── <组件>_<工具>.sh   ← 单工具脚本（可独立执行）
└── README.md
```

- **单脚本独立可跑**：`bash test/cpu/cpu_stress_ng.sh 60`（不依赖聚合入口）
- **聚合只编排**：`bash test/test_all.sh`（分类菜单）或 `--all`（全部顺序执行）
- **新增工具**：加一个薄脚本 + `test_all.sh` 工具表一行，无需改聚合逻辑

## 测试项

| 单脚本 | 测试内容 | 参数 | 依赖 | 备注 |
|--------|---------|------|------|------|
| `cpu/cpu_stress_ng.sh` | CPU 满载压测 | 时长秒（默认 30） | stress-ng | 全核 |
| `cpu/cpu_sysbench.sh` | CPU 性能基准 | 时长秒（默认 30） | sysbench | |
| `cpu/cpu_mprime.sh` | 素数计算散热验证 | 时长秒（默认 300） | mprime | 内部固定 `timeout 300`，时长参数不改变该上限 |
| `memory/mem_stress_ng.sh` | 内存压力 | 时长秒（默认 30） | stress-ng | `--vm 4 --vm-bytes 80%` |
| `memory/mem_memtester.sh` | 内存位翻转 | 时长秒（默认 60） | memtester | 取 `MemTotal/2` × 2 轮；时长参数未参与实际命令 |
| `memory/mem_sysbench.sh` | 内存带宽基准 | 时长秒（默认 30） | sysbench | |
| `disk/disk_fio.sh` | IOPS / 延迟 | `/dev/<dev>` 或交互选盘；`--force` 跳过系统盘确认 | fio | 写测试文件（自动清理）；未挂载盘 `[SKIP]` |
| `disk/disk_hdparm.sh` | 缓存 / 盘面读取 | 交互选盘 | hdparm | |
| `disk/disk_dd.sh` | 顺序读吞吐 | `/dev/<dev>` 或交互选盘；`--force` | dd | 日志名带设备名 `disk_dd_<dev>.log` |
| `network/net_iperf3.sh` | TCP 吞吐 | 交互输入服务端地址 | iperf3 | 命令内固定 `-t 10 -P 4` |
| `network/net_mtr.sh` | 路径质量 | 时长秒（默认 10） | mtr | |
| `ib/ib_perftest.sh` | IB 打流配对 | 自动配对 / 手动配对 | perftest、mlxlink | 按 EEPROM serial 相同配对端口，支持单口回环 |
| `gpu/gpu_bandwidth.sh` | GPU 带宽 | 无 | bandwidthTest | 逐卡 + P2P |
| `gpu/gpu_burn_test.sh` | GPU 长压测 | 时长秒（默认 1800） | gpu-burn | `-tc` 走张量核心 |
| `gpu/gpu_nvbandwidth.sh` | 带宽基准 | 无 | nvbandwidth | |
| `gpu/gpu_partnerdiag.sh` | 出厂诊断 | 交互输入诊断参数 | partnerdiag（FLD 包） | |
| `nccl/nccl_test.sh` | 集合通信 | 无 | nccl-tests | 需已编译产物 |
| `test_server_info.sh` | 测试前机器信息（v1.38.0，非压测项） | `--append <文件>` / `--out <目录>` / `--help` | 无 | 机器 ID / 型号 / CPU / 内存 / GPU / OS 约 10 行只读；各单脚本 `test_init` 后自动调用 |

> **平台限制（v1.46.x）**：GPU 压测工具均属 CUDA / NVIDIA 生态（bandwidthTest / gpu-burn / nvbandwidth /
> partnerdiag / nccl-tests），**AMD Instinct（ROCm）平台暂不适用**。采集与报告支持 AMD；压测扩展在规划中，
> 该平台的基础核验请使用采集侧的 ROCm 路径（`rocminfo` / `amd-smi ras`）。

## 使用

```bash
# 菜单式入口
bash test/test_all.sh

# 全部顺序执行（可选第二参数作为各测试项的时长秒）
bash test/test_all.sh --all
bash test/test_all.sh --all 60

# 单脚本独立执行（60 秒 CPU 满载）
bash test/cpu/cpu_stress_ng.sh 60

# 指定盘的可破坏性测试（系统盘需 YES 确认，--force 跳过）
sudo bash test/disk/disk_fio.sh /dev/<dev> --force
```

## 日志与报告

- **所有测试输出**：`logs/test/<SN>/`（`test/lib/test_common.sh` 负责），含 `test_report.txt` 汇总、
  各测试项 detail 日志与 `manifest.txt`。
- **目录语义**（v1.45.2–5）：`logs/test/<SN>/` 按机器稳定累积 —— 单测、菜单、`--all` 全部落同一 SN 目录，
  文件名带时间戳（`<测试名>-<时间戳>.log`）区分重复测试；无 SN 平台（WSL / 开发机）兜底
  `logs/test/<时间戳>/`；可用 `export HW_TEST_SESSION_DIR=<目录>` 指定会话目录。
- **聚合入口日志根**（v1.49.21）：`test_all.sh --all` 原先把自身 `SCRIPT_DIR`（`<仓库>/test`）当仓库根，
  `test_common.sh` 内 `source <root>/test/lib/common.sh` 静默失败致 `detect_machine_id` 不可用，整轮日志落到
  `test/logs/test/<时间戳>/`；现由 `test_common.sh` 从 `BASH_SOURCE` 自行推根，独立执行与聚合执行一致。
- **磁盘保护**（v1.45.1）：`fio` / `dd` 的交互列表默认排除系统盘（识别方式：根挂载所在物理盘）。
  用参数显式指定系统盘时给出警告并要求输入 `YES`，`--force` 跳过确认。
- **并入交付报告**：`bash report/report.sh <采集目录> --test-dir <压测目录>`。

### 压测报告生成器（`test/report.sh`）

```bash
bash test/report.sh logs/test/<SN>/
bash test/report.sh logs/test/<SN>/ --channels 8 --speed 5600
```

| 参数 | 说明 |
|------|------|
| `<压测目录>` | 压测日志目录（必填） |
| `--channels N` | 内存通道数（默认自动探测：`dmidecode` 的 Bank Locator 去掉 DIMM 槽位维度后去重；厂商命名不含 DIMM 时退化为槽级，可能大于真实通道数） |
| `--speed MT/s` | 内存速率（默认从 `Configured Memory Speed` 提取数字） |
| `-h` / `--help` | 显示用法 |

输出 `hwscope_test_report.{md,html}`（测试环境 / 工具方法 / 理论峰值 / 结果对比 / 分析 / 结论 / 附录），
HTML 可浏览器打印 PDF。单组件测试同样适用：日志目录只含该组件即生成单组件报告，无需额外参数。
报告头部带「占位模块、不构成验收依据」声明。

- **理论峰值口径**：内存 = 通道 × 速率 × 8 B，结果与 STREAM 实测对比给出利用率。
- **v1.49.21 修正**：原 `awk '{print $NF}'` 取到的是 `MT/s`（非速率），文本插值进公式后 `MT/s` 被解析为
  `MT / s`（`s=0`）触发除零，导致「与理论峰值比」整列消失。

## 已知限制

| 限制 | 说明 |
|------|------|
| 时长参数不生效 | `cpu_mprime.sh`（固定 `timeout 300`）、`mem_memtester.sh`、`net_iperf3.sh`（固定 `-t 10`）接受时长参数但不用于实际命令 |
| 需要交互 | `disk_*` / `net_iperf3` / `gpu_partnerdiag` 需终端输入，不适合无人值守批量执行 |
| 未验证 | 全部测试项的判定口径待真机标定，指标不作验收依据 |

## 依赖安装

```bash
# Ubuntu 基础压测工具
sudo apt install -y stress-ng sysbench fio iperf3 mtr infiniband-diags perftest

# MFT（mlxlink，IB 测试需要）：install_tool 菜单项 3（IB 诊断）/ 5（MFT）
sudo bash tools/install_tool.sh

# nccl-tests（GPU 集合通信）
git clone https://github.com/NVIDIA/nccl-tests && cd nccl-tests && make NCCL_HOME=/usr/local/nccl2

# gpu-burn（GPU 长压测）
git clone https://github.com/wilicc/gpu-burn && make
```

---

## 报告解析回归测试（`tools/agent/report_regression.sh`）

> 与硬件压测无关：用固定采集样本重跑报告生成，提取关键指标与基线比对，防止解析器 / 渲染层改动引入
> **静默回归**。完整机制见 [tools/agent/README.md](../tools/agent/README.md)。

```bash
bash tools/agent/report_regression.sh <采集目录>              # 跑报告 + 比对基线
bash tools/agent/report_regression.sh <采集目录> --update     # 刷新基线（确认改动正确后执行）
bash tools/agent/report_regression.sh --all                   # 遍历样本根全部样本
HWSCOPE_SAMPLE_ROOT=<多机样本根> bash tools/agent/report_regression.sh --all --update
```

| 项 | 说明 |
|----|------|
| 指标组 | 表格列数 / GPU / 内存 / PSU / PCIe 链路统计 / 磁盘 / NIC / JSON 字段与体积 / HTML 标签闭合 / 验收清单判定 |
| 判据分类（v1.52.14） | `json_bytes` / `html_bytes` 为长度指标，差异 < 5% 输出 `[NOTE]`；其余 32 项结构指标不一致才报 `[DIFF]` |
| 基线 | `tools/agent/baseline/<语义名>.txt`（h200 / a100 / b200 / b300 / amd_oam / headless；零真实 SN） |
| 退出码 | 0 = 一致或已更新；1 = 存在差异；2 = 无基线 / 无样本 |
| 样本零污染 | 仅备份并还原 6 个报告文件，不复制整个采集目录 |

**运行环境**：需 Linux（或 fork 稳定的环境）。`report/report.sh` 含大量 `$( )`，在 Windows git-bash 下会触发
MSYS fork 崩溃（见 [AGENTS.md](../AGENTS.md)「环境故障止损纪律」）。

**WSL 的 CRLF 问题**：Windows 工作区文件为 CRLF（`core.autocrlf=true`），Linux bash 执行 CRLF 的 `.sh`
会静默失败（`$'\r': command not found`），表现为「报告生成成功」但内容仍是旧值。WSL 场景先转换换行：

```bash
cp -r /mnt/d/<项目> /tmp/hw && cd /tmp/hw && bash fixcrlf.sh
```

**触发规则**：改动 `report/{sections,gen,lib}` 或采集模块输出格式 → 提交前必跑；
纯文档 / 版本号 / 非报告逻辑改动不跑。
