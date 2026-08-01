# HwScope — Hardware Scope

> Server Hardware Inspection & Data Collection System · 服务器硬件一键巡检采集系统

> ⚠️ **开发测试阶段** — 本项目目前处于开发测试阶段，接口与输出格式可能随时变化，请以最新代码为准。

**Author:** YanHui / Hermes Agent  ·  **Version:** 1.6.2  ·  **License:** [Apache 2.0](LICENSE)

[![GitHub](https://img.shields.io/badge/GitHub-YanHuiStar%2Fhwscope-blue?logo=github)](https://github.com/YanHuiStar/hwscope)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

HwScope 对服务器每个物理组件进行**逐件、逐槽、逐端口**的独立采集，每个查询命令保存到独立日志文件。支持 x86/ARM、SXM/PCIe/传统服务器。

---

## 快速开始

```bash
git clone https://github.com/YanHuiStar/hwscope.git && cd hwscope

# 如果文件从 Windows 复制进来，先修换行符
bash fixcrlf.sh

# 安装依赖工具（未安装的工具对应模块自动跳过，不影响整体采集；Ubuntu 使用 apt，Rocky/RHEL 8+ 使用 dnf）
apt install -y dmidecode pciutils ipmitool smartmontools lm-sensors      # Ubuntu
dnf install -y dmidecode pciutils ipmitool smartmontools lm_sensors      # Rocky/RHEL 8+

# 执行采集
sudo bash hwscope.sh                  # 全量采集（串行，约 1min）
sudo bash hwscope.sh --parallel       # 全量采集（并行，约 10s）
sudo bash hwscope.sh --quiet          # 静默模式（仅输出异常）
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
bash hwscope.sh --no-module           # 跳过光模块查询（缩短采集时长约 48s）
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

SXM 三重检测：`nvswitch -q` → `lspci` NVSwitch 字样 → `nv-fabricmanager` 进程（HGX 平台专属守护进程，兜底 lspci 不显示 NVSwitch 设备的场景）。

---

## 模块总览

| # | 模块 | 工具 | 内容 |
|---|------|------|------|
| 01 | motherboard | `dmidecode` | 主板/BIOS/机箱 型号/SN |
| 02 | cpu | `dmidecode` + `lscpu` | FRU + OS 双视角 |
| 03 | memory | `dmidecode` + `free` | 每 DIMM 独立日志 |
| 04 | gpu | `nvidia-smi` | 每 GPU + NVLink + ECC |
| 05 | nvswitch | `nvswitch` | 每颗 NVSwitch + Fabric Manager |
| 06 | pcie | `lspci` | 拓扑/速率/NUMA/IOMMU（缺 lspci 时 SKIP 落盘） |
| 07 | network | `ibstat` + `mlxlink` + `ethtool` | 每 IB 端口 + 每网口 + 光模块 |
| 08 | storage | `lsblk` + `smartctl` | 全类型盘 + SMART 健康（WSL 虚拟盘自动跳过） |
| 09 | raid | `storcli64` + `sas3ircu` | 控管器/VD/BBU/事件 |
| 10 | psu | `ipmitool` + `sysfs` | 每 PSU 功率/温度 |
| 11 | fan | `ipmitool` + `sensors` + `hwmon` | 每风扇转速/占空比 |
| 12 | bmc | `ipmitool` + Redfish | FRU/SEL/传感器/BMC 网络 |
| 13 | nvsm | `nvsm` | NVIDIA System Management |
| 14 | dcgm | `dcgmi` | Level 1 纯获取诊断 |
| 99 | os | `uname/dmesg/systemctl` | 内核/服务/NUMA/AER |

---

## 硬件测试与运维工具

除采集外，项目提供两类交互式脚本（自动检测依赖工具是否安装，未安装时提示安装命令）：

### `test/` — 硬件压测（仅执行只读测试，不修改硬件配置）

| 脚本 | 内容 | 依赖 |
|------|------|------|
| `cpu_test.sh` | stress-ng / sysbench / mprime 三种 CPU 压测 | stress-ng, sysbench, mprime |
| `memory_test.sh` | stress-ng --vm / memtester / sysbench memory 内存测试 | stress-ng, memtester, sysbench |
| `disk_test.sh` | fio 随机 IOPS / hdparm / dd 硬盘吞吐 | fio, hdparm |
| `network_test.sh` | iperf3 / ib_write_bw / mtr 网络测试 | iperf3, perftest, mtr |

```bash
bash test/test_all.sh          # 聚合菜单入口
bash test/cpu_test.sh          # 直接执行 CPU 测试
```

测试日志输出至 `logs/test/<时间戳>/`（汇总 + 每项详细日志）。

### `tools/` — 运维操作（含写操作，执行前二次确认）

| 脚本 | 内容 | 依赖 |
|------|------|------|
| `bmc_tool.sh` | FRU/传感器/SEL 查询、SEL 清空、BMC 密码重置、BMC 重启 | ipmitool |
| `nic_tool.sh` | 网卡状态/光模块/固件查询、端口复位、MTU 配置 | mlxlink, mlxfwmanager |
| `install_tool.sh` | 依赖安装（采集/压测/IB/DCGM/MFT/推理引擎），apt/dnf 自动识别 | - |
| `report.sh` | 从采集结果提取关键信息，生成 json/md/txt 汇总报告（环境/主板/CPU/内存每槽/GPU/存储/网络/BMC/风扇） | 采集完成后自动调用 |

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
output/SN123456789/
├── hwscope.log              # 执行日志（纯文本）
├── config_backup.conf       # 配置快照
├── summary.txt              # 汇总（含 WARN 计数）
├── hwscope_report.json      # 汇总报告（结构化）
├── hwscope_report.md        # 汇总报告（Markdown）
├── hwscope_report.txt       # 汇总报告（纯文本）
├── motherboard/             # dmidecode 日志 ×6
├── cpu/                     # dmidecode + lscpu ×8
├── memory/                  # dmidecode + 每槽 ×N
├── gpu/                     # nvidia-smi 每卡 + ECC ×30+
├── nvswitch/                # nvswitch 每颗 ×7
├── pcie/                    # lspci 拓扑 ×10+（缺 lspci 时 00_skip_lspci.log）
├── network/                 # IB + mlx + ethtool ×30+
├── storage/                 # lsblk + smartctl 每盘 ×20+（WSL 时 00_skip_smart_wsl.log）
├── raid/                    # storcli + sas3ircu ×10+
├── psu/                     # IPMI + sysfs ×5+
├── fan/                     # IPMI + hwmon ×5+
├── bmc/                     # IPMI + Redfish ×20+
├── nvsm/ / dcgm/ / os/     # 条件 + OS ×15+
└── (logs/)                  # 采集归档 tar.gz（项目根目录）
    └── report/              # 报告归档 tar.gz（单独打包）

采集完成后自动归档至 `logs/<SN>-<时间戳>.tar.gz`（详细分级日志），报告三件套另打包至 `logs/report/<SN>-<时间戳>-report.tar.gz`。
```

---

## 配置

`conf/hwscope.conf`：

```bash
# BMC（留空只查本地 IPMI）
BMC_IP=""; BMC_USER="admin"; BMC_PASS="admin"
HGX_BMC_IP=""              # HGX 基板 BMC（SXM 平台填写，默认留空不连接）

# 模块开关（1=启用）
MODULE_GPU=1; MODULE_STORAGE=1; MODULE_OS=1 ...
```

---

## 设计原则

- **逐件独立** — 每组件独立模块，互不耦合，可单独执行
- **只读无害** — 全部只读查询，不写不改
- **自动跳过** — 工具未安装静默跳过，不中断
- **无压测** — DCGM 仅 Level 1 纯获取
- **平台自适配** — x86/ARM、SXM/PCIe 自动识别（SXM 三重检测含 fabric manager）
- **环境自适配** — WSL 虚拟磁盘自动跳过 SMART，避免误报
- **并行提速** — `--parallel` 2min → ~10s

## License

[Apache License 2.0](LICENSE) · [GitHub](https://github.com/YanHuiStar/hwscope)
