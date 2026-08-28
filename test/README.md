# HwScope 硬件压测（test/）

> 硬件压力测试脚本：**只测不改**（不修改硬件/系统配置；仅 fio/dd 会在指定盘写测试文件并自动清理）。
> 所有压测日志统一落盘 `logs/test/<SN>/`（test/lib/test_common.sh 负责），不污染采集目录。
> 工具概览索引见 [docs/TOOLS.md](../docs/TOOLS.md)（本文件为详细说明）。

## 架构：聚合与实现解耦

```
test/
├── test_all.sh           ← 纯聚合入口（菜单/--all，不含测试逻辑）
├── lib/test_common.sh    ← 公共库（日志落盘/结果记录/server_info 头）
├── cpu/    memory/    disk/    network/    ib/    gpu/    nccl/
│   └── <组件>_<工具>.sh   ← 单工具脚本（可独立执行）
└── README.md
```

- **单脚本独立可跑**：`bash test/cpu/cpu_stress_ng.sh 60`（不依赖聚合）
- **聚合只编排**：`bash test/test_all.sh`（分类菜单）或 `--all`（全部顺序）
- **新增工具**：加一个薄脚本 + test_all 工具表一行（零侵入）

## 测试项速查

| 单脚本 | 测试内容 | 依赖 | 注意 |
|--------|---------|------|------|
| `cpu/cpu_stress_ng.sh` | CPU 满载压测 | stress-ng | 默认 30s |
| `cpu/cpu_sysbench.sh` | CPU 性能基准 | sysbench | |
| `cpu/cpu_mprime.sh` | 素数计算散热验证 | mprime | 外层 300s 限制 |
| `memory/mem_stress_ng.sh` | 内存压力 | stress-ng | vm 80% |
| `memory/mem_memtester.sh` | 内存位翻转 | memtester | 内存一半 ×2 轮 |
| `memory/mem_sysbench.sh` | 内存带宽基准 | sysbench | |
| `disk/disk_fio.sh` | IOPS/延迟 | fio | ⚠️ 选盘 + 写测试文件（自动清理） |
| `disk/disk_hdparm.sh` | 缓存/盘面读取 | hdparm | |
| `disk/disk_dd.sh` | 顺序读吞吐 | dd | |
| `network/net_iperf3.sh` | TCP 吞吐 | iperf3 | 需服务端地址 |
| `network/net_mtr.sh` | 路径质量 | mtr | |
| `ib/ib_perftest.sh` | IB 打流配对 | perftest, mlxlink | 自动配对 serial 相同端口 |
| `gpu/gpu_bandwidth.sh` | GPU 带宽 | bandwidthTest | 逐卡 + P2P |
| `gpu/gpu_burn_test.sh` | GPU 长压测 | gpu-burn | 默认 1800s（-tc 张量核心） |
| `gpu/gpu_nvbandwidth.sh` | 带宽基准 | nvbandwidth | |
| `gpu/gpu_partnerdiag.sh` | 出厂诊断 | partnerdiag | FLD 包 |
| `nccl/nccl_test.sh` | 集合通信 | nccl-tests | 需编译产物 |

> **多平台提示（v1.46.x）**：GPU 压测工具均为 **CUDA/NVIDIA 生态**（bandwidthTest/gpu-burn/nvbandwidth/partnerdiag/nccl-tests），**AMD Instinct（ROCm）平台暂不适用**——采集与报告支持 AMD，压测扩展后续规划；GPU 压力测试请用采集侧 ROCm 路径（rocminfo/amd-smi ras）做基础核验。

## 使用

```bash
# 菜单式入口（推荐）
bash test/test_all.sh

# 全部顺序执行
bash test/test_all.sh --all

# 单脚本独立执行（以 CPU 为例，60 秒）
bash test/cpu/cpu_stress_ng.sh 60
```

## 日志位置

- 所有测试输出：`logs/test/<SN>/`（含 `test_report.txt` 汇总 + 各测试项 detail 日志 + manifest.txt）
- 报告归档：采集后可用 `report/report.sh <out> --test-dir <压测目录>` 将压测结果并入交付报告
- **标准测试报告**（v1.45.0）：`bash test/report.sh <logs/test/<SN>/目录>` 生成 `hwscope_test_report.{md,html}`——测试环境/工具方法/理论峰值/结果对比/分析/结论/附录，数据口径科学可追溯（内存理论峰值 = 通道×速率×8B，STREAM 利用率评价；HTML 可浏览器打印 PDF）
- **单组件测试 + 单组件报告**（v1.45.1）：只跑单个脚本（如 `bash test/memory/mem_sysbench.sh`）→ 日志目录只有该组件 → `bash test/report.sh <该目录>` 即出单组件报告（目录自适应，不需要额外参数）
- **目录组织语义**（v1.45.2-5）：**`logs/test/<SN>/` 稳定按机器累积**（用户方案）——单测/菜单/--all 全部落同一 SN 目录，文件名带时间戳（`<测试名>-<时间戳>.log`）区分重复测试；无 SN 平台兜底 `logs/test/<时间戳>/`；手动累积可 `export HW_TEST_SESSION_DIR=<目录>` 指定
- **磁盘测试默认屏蔽系统盘**（v1.45.1）：fio/dd 交互列表自动排除系统盘；参数指定系统盘时警告并要求输入 YES 确认（`--force` 跳过）——防写测试压垮系统盘/数据安全

## 依赖安装

```bash
# Ubuntu
sudo apt install -y stress-ng sysbench fio iperf3 mtr infiniband-diags perftest
# MFT（mlxlink，IB 测试需要）
bash tools/install_tool.sh   # 选 3 IB 诊断 / 5 MFT
# nccl-tests（GPU 集合通信）
git clone https://github.com/NVIDIA/nccl-tests && cd nccl-tests && make NCCL_HOME=/usr/local/nccl2
# gpu-burn（GPU 长压测）
git clone https://github.com/wilicc/gpu-burn && make
```

---

## 报告解析回归测试（report_regression.sh，v1.48.3）

> 与硬件压测无关：本脚本用**固定采集样本**跑报告生成，提取关键指标与基线比对，
> 防解析器/渲染层改动引入**静默回归**（历史教训：AMD 多卡明细全显示 card0、内存通道数
> 算成插槽数、表格列错位、1T9 容量误判——都只能靠真机样本发现，人工 review 易漏）。

```bash
bash test/report_regression.sh <采集目录>              # 跑报告 + 比对基线
bash test/report_regression.sh <采集目录> --update     # 刷新基线（确认改动正确后执行）
bash test/report_regression.sh --all                   # 遍历样本根全部样本
HWSCOPE_SAMPLE_ROOT=<多机样本根> bash test/report_regression.sh --all --update
```

- **10 组指标**：表格列数一致 / GPU / 内存 / PSU / PCIe 链路统计 / 磁盘 / NIC / JSON 字段与体积 / HTML 标签闭合 / 验收清单判定结果
- **样本零污染**：仅备份并还原 6 个报告文件（不复制整个采集目录——数百日志文件复制极慢）
- **基线**：`test/baseline/<机器ID>.txt`（指标摘要入库，几 KB）；采集数据不入仓库
- **退出码**：0=一致/已更新，1=存在差异（回归候选），2=无基线/无样本
- **改动解析器/渲染层的正确姿势**：改动前跑一次（确认当前一致）→ 改完再跑一次 → 有差异则人工确认是预期改动还是回归；确认预期后 `--update` 刷新基线

> **运行环境**：需 Linux（或 fork 稳定的环境）——`report.sh` 含数百个 `$( )`，
> Windows git-bash 下可能触发 MSYS fork 崩溃（AGENTS.md“环境故障止损纪律”）。
>
> **WSL 使用注意（实测坑）**：Windows 工作区文件是 **CRLF**（`core.autocrlf=true`），
> Linux bash 跑 CRLF 的 `.sh` 会**静默失败**（`\r: command not found`）——表现为报告"生成成功"
> 实际是旧的，指标全是旧值。Windows + WSL 场景务必先跑：
> ```bash
> cp -r /mnt/d/<项目> /tmp/hw && cd /tmp/hw && bash fixcrlf.sh   # 再跑回归
> ```
>
> **定位（v1.48.4）：主要给 Agent 用，也给人用。**
> - **Agent（WorkBuddy / Hermes 等）改动 `report/sections/`、`report/gen/`、`report/lib/` 或采集模块输出格式后，提交前必跑一次**——
>   本脚本存在的理由：v1.44–v1.48 实录的 4 个解析 bug（AMD 多卡明细全显示 card0、内存通道数算成插槽数、
>   表格列错位、1T9 容量误判）全是 Agent 改解析/渲染代码时引入、人工 review 漏掉的。改完跑一次，差异立刻暴露。
> - **人（交付/验收）**：真机采集后交付前自检、升级报告版本后确认输出未漂移。
