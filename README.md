# HwScope — Hardware Scope

> Server Hardware Inspection & Data Collection System · 服务器硬件一键巡检采集系统

> ⚠️ **开发测试阶段** — 本项目目前处于开发测试阶段，接口与输出格式可能随时变化，请以最新代码为准。

**Author:** YanHui / Hermes Agent  ·  **Version:** 1.4.3  ·  **License:** [Apache 2.0](LICENSE)

[![GitHub](https://img.shields.io/badge/GitHub-YanHuiStar%2Fhwscope-blue?logo=github)](https://github.com/YanHuiStar/hwscope)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

HwScope 对服务器每个物理组件进行**逐件、逐槽、逐端口**的独立采集，每个查询命令保存到独立日志文件。支持 x86/ARM、SXM/PCIe/传统服务器。

---

## 快速开始

```bash
git clone https://github.com/YanHuiStar/hwscope.git && cd hwscope

# 如果文件从 Windows 复制进来，先修换行符
bash fixcrlf.sh

# 安装工具（缺啥自动跳；Ubuntu 用 apt，Rocky/RHEL 用 dnf）
apt install -y dmidecode pciutils ipmitool smartmontools lm-sensors      # Ubuntu
dnf install -y dmidecode pciutils ipmitool smartmontools lm_sensors      # Rocky/RHEL 8+

# 开跑
sudo bash hwscope.sh                  # 全量（串行，约 1min）
sudo bash hwscope.sh --parallel       # 全量（并行，约 10s）
sudo bash hwscope.sh --quiet          # 只看异常
```

---

## 用法

```bash
# 模式
bash hwscope.sh                       # 串行（默认）
bash hwscope.sh --parallel            # 并行
bash hwscope.sh --parallel --quiet    # 并行 + 静默

# 过滤
bash hwscope.sh --modules gpu,storage # 只采部分
bash hwscope.sh --skip dcgm,nvsm      # 跳过部分

# 其他
bash hwscope.sh --output /data/x      # 指定输出目录
bash hwscope.sh --force               # 覆盖已有目录
bash hwscope.sh --version             # 版本

# 单独跑模块
bash modules/04_gpu.sh /tmp/out
```

## 平台兼容

| 标识 | 条件 | 代表机型 |
|------|------|---------|
| `x86_64_SXM` | x86 + SXM GPU + NVSwitch | HGX B200/B300 |
| `x86_64_PCIe` | x86 + PCIe GPU | 8×A100/H100 |
| `aarch64_SXM` | ARM + SXM GPU + NVSwitch | GB300 / Grace |
| `x86_64_none` | x86，无 GPU | 传统服务器 |

启动时自动检测。CPU 模块自动适配 x86 (`model name`) 和 ARM (`CPU implementer`) 格式。

---

## 模块总览

| # | 模块 | 工具 | 内容 |
|---|------|------|------|
| 01 | motherboard | `dmidecode` | 主板/BIOS/机箱 型号/SN |
| 02 | cpu | `dmidecode` + `lscpu` | FRU + OS 双视角 |
| 03 | memory | `dmidecode` + `free` | 每 DIMM 独立日志 |
| 04 | gpu | `nvidia-smi` | 每 GPU + NVLink + ECC |
| 05 | nvswitch | `nvswitch` | 每颗 NVSwitch + Fabric Manager |
| 06 | pcie | `lspci` | 拓扑/速率/NUMA/IOMMU |
| 07 | network | `ibstat` + `mlxlink` + `ethtool` | 每 IB 端口 + 每网口 + 光模块 |
| 08 | storage | `lsblk` + `smartctl` | 全类型盘 + SMART 健康 |
| 09 | raid | `storcli64` + `sas3ircu` | 控管器/VD/BBU/事件 |
| 10 | psu | `ipmitool` + `sysfs` | 每 PSU 功率/温度 |
| 11 | fan | `ipmitool` + `sensors` + `hwmon` | 每风扇转速/占空比 |
| 12 | bmc | `ipmitool` + Redfish | FRU/SEL/传感器/BMC 网络 |
| 13 | nvsm | `nvsm` | NVIDIA System Management |
| 14 | dcgm | `dcgmi` | Level 1 纯获取诊断 |
| 99 | os | `uname/dmesg/systemctl` | 内核/服务/NUMA/AER |

---

## 硬件测试与运维工具

除采集外，项目提供两类交互式脚本（均自动检测工具是否安装，未装则提示安装命令）：

### `test/` — 硬件压测（只测不改）

| 脚本 | 内容 | 依赖 |
|------|------|------|
| `cpu_test.sh` | stress-ng / sysbench / mprime 三种 CPU 压测 | stress-ng, sysbench, mprime |
| `memory_test.sh` | 内存带宽/压力测试（待开发） | stress-ng --vm, memtester |
| `disk_test.sh` | fio / hdparm 硬盘吞吐测试（待开发） | fio, hdparm |
| `network_test.sh` | iperf3 / ib_write_bw 网络吞吐（待开发） | iperf3, perftest |

```bash
bash test/test_all.sh          # 聚合菜单
bash test/cpu_test.sh          # 直接跑 CPU 测试
```

### `tools/` — 运维操作（会修改系统）

| 脚本 | 内容 | 依赖 |
|------|------|------|
| `bmc_tool.sh` | 查 FRU/传感器/SEL、清 SEL、重置 BMC 密码、重启 BMC | ipmitool |
| `nic_tool.sh` | 网卡端口重置/固件配置（待开发） | mlxlink, mlxconfig |
| `install_tool.sh` | 安装 DCGM/MFT/压测工具/推理引擎（待开发） | - |

```bash
sudo bash tools/bmc_tool.sh    # BMC 操作（写操作有二次确认）
```

测试结果输出 `output/test_*/cpu_report.md`（汇总报告）+ 详细日志。

---

## 终端状态

| 标签 | 含义 |
|------|------|
| `[OK]` | 成功 (exit=0) |
| `[~]` | grep 无匹配 (exit=1)，不算异常 |
| `[N/A]` | 工具不存在 (exit=127) |
| `[WARN]` | 异常 (exit≠0/1/127) |
| `[SKIP]` | 模块跳过 |
| `[QUEUE]` | 并行启动 |

`summary.txt` 每模块附带异常计数：

```
[14:12:59] 04.gpu - 12 files, 1s, 0 WARN
[14:13:02] 08.storage - 20 files, 0s, 14 WARN
```

---

## 输出格式

### 目录隔离

```
output/
├── JZ5C4X8/                    # SN（首次）
├── JZ5C4X8-20260730_090000/    # 二次（自动追加时间戳）
├── MB-1234567/                 # 主板 SN 兜底
└── 20260728_120000/            # 时间戳兜底
```

### 日志格式

```log
# ============================================================
# Command  : nvidia-smi --query-gpu=name,serial,memory.total --format=csv
# Hostname : gpu-node-03
# Timestamp: 2026-07-28 10:30:15
# Encoding : UTF-8
# ============================================================
# --- output start ---
0, NVIDIA B300, 13245230xxxxxx, 196608 MiB
# --- output end (exit code: 0) ---
```

单次采集典型结构：

```
output/JZ5C4X8/
├── hwscope.log              # 执行日志（纯文本）
├── config_backup.conf       # 配置快照
├── motherboard/             # dmidecode 日志 ×6
├── cpu/                     # dmidecode + lscpu ×8
├── memory/                  # dmidecode + 每槽 ×N
├── gpu/                     # nvidia-smi 每卡 + ECC ×30+
├── nvswitch/                # nvswitch 每颗 ×7
├── pcie/                    # lspci 拓扑 ×10+
├── network/                 # IB + mlx + ethtool ×30+
├── storage/                 # lsblk + smartctl 每盘 ×20+
├── raid/                    # storcli + sas3ircu ×10+
├── psu/                     # IPMI + sysfs ×5+
├── fan/                     # IPMI + hwmon ×5+
├── bmc/                     # IPMI + Redfish ×20+
├── nvsm/ / dcgm/ / os/     # 条件 + OS ×15+
└── summary.txt              # 汇总（含 WARN 计数）
```

---

## 配置

`conf/hwscope.conf`：

```bash
# BMC（留空只查本地 IPMI）
BMC_IP=""; BMC_USER="admin"; BMC_PASS="admin"
HGX_BMC_IP="192.168.1.1"      # HGX 基板 BMC

# 模块开关（1=启用）
MODULE_GPU=1; MODULE_STORAGE=1; MODULE_OS=1 ...
```

---

## 设计原则

- **逐件独立** — 每组件独立模块，互不耦合，可单独执行
- **只读无害** — 全部只读查询，不写不改
- **自动跳过** — 工具未安装静默跳过，不中断
- **无压测** — DCGM 仅 Level 1 纯获取
- **平台自适配** — x86/ARM、SXM/PCIe 自动识别
- **并行提速** — `--parallel` 2min → ~10s

## License

[Apache License 2.0](LICENSE) · [GitHub](https://github.com/YanHuiStar/hwscope)
