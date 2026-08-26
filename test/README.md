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
