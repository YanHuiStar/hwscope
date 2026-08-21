# HwScope 硬件压测（test/）

> 硬件压力测试脚本：**只测不改**（不修改硬件/系统配置；仅 fio 会在指定盘写测试文件并自动清理）。
> 所有压测日志统一落盘 `logs/test/<时间戳>/`（test_common.sh 负责），不污染采集目录。
> 支持 `-h` / `--help` 查看用法；入口：`bash test/test_all.sh`（菜单式选择）。
> 工具概览索引见 [docs/TOOLS.md](../docs/TOOLS.md)（本文件为详细说明）。

## 测试项速查

| 脚本 | 测试内容 | 依赖工具 | 注意 |
|------|---------|---------|------|
| `test_all.sh` | 菜单式聚合入口 | — | 推荐入口（选测/全测） |
| `cpu_test.sh` | CPU 压测（stress-ng / sysbench / mprime） | stress-ng, sysbench, mprime | — |
| `memory_test.sh` | 内存压测（stress-ng vm / memtester / sysbench） | stress-ng, memtester, sysbench | — |
| `disk_test.sh` | 磁盘 IOPS/吞吐（fio / hdparm / dd） | fio, hdparm | ⚠️ 选盘时注意，fio 写测试文件 |
| `network_test.sh` | 网络吞吐（iperf3 / mtr） | iperf3, mtr | 需要远端服务端 |
| `nccl_test.sh` | GPU 集合通信（all_reduce 等） | nccl-tests 编译产物 | 需编译安装 nccl-tests |
| `gpu_test.sh` | GPU 测试（自动发现系统已装测试程序） | 系统已有（bandwidthTest/gpu_burn 等）| 只调用不安装 |
| `ib_test.sh` | IB 数据面打流（ib_write_bw / ib_read_bw） | perftest, mlxlink | 自动配对 serial 相同端口 |
| `test_common.sh` | 公共库：菜单/日志落盘/结果记录 | — | 被以上脚本 source，勿直接运行 |

## 使用说明

### 入口与单测
```bash
# 菜单式入口（推荐）
bash test/test_all.sh

# 单独跑某测试（以 CPU 为例；进入后菜单选择测试项）
bash test/cpu_test.sh
```

### 各测试要点

- **cpu_test**：stress-ng `--cpu 0 --cpu-method all` 全核 30s + sysbench CPU 基准 + mprime 素数计算（散热验证）
- **memory_test**：stress-ng vm 压测 + memtester（可用内存一半 ×2 轮）+ sysbench 内存带宽
- **disk_test**：启动时列出 `lsblk` 让用户选盘；fio 随机/顺序 4K + hdparm 缓存读 + dd 顺序读；fio 临时文件自动清理
- **network_test**：提示输入 iperf3 服务端 IP（如 `192.168.1.100`），TCP 吞吐 + mtr 路径质量
- **nccl_test**：自动查找 `all_reduce_perf` 等编译产物（`/usr /opt /root ~` 限深扫描 + PATH）
- **gpu_test**：扫描系统已安装的 GPU 测试程序（bandwidthTest / gpu_burn / nvbandwidth / all_reduce_perf / partnerdiag），列出可选；**不自动安装**
- **ib_test**：自动配对（mlxlink serial 相同=同一根线）→ 逐对 `ib_write_bw` / `ib_read_bw` 打流（4MB 消息、20s）；需要两根线互联或回环头

### 日志位置
- 所有测试输出：`logs/test/<时间戳>/`（每个测试项一个 `<测试名>.log` 汇总 + 各工具 detail 日志；`manifest.txt` 记录汇总文件供 report.sh --test-dir 关联）
- 报告归档：采集后可用 `tools/report.sh <out> --test-dir <压测目录>` 将压测结果并入交付报告

## 依赖安装

```bash
# Ubuntu
sudo apt install -y stress-ng sysbench fio iperf3 mtr infiniband-diags perftest
# MFT（mlxlink，IB 测试需要）
bash tools/install_tool.sh   # 选 3 IB 诊断 / 5 MFT
# nccl-tests（GPU 集合通信）
git clone https://github.com/NVIDIA/nccl-tests && cd nccl-tests && make NCCL_HOME=/usr/local/nccl2
```
