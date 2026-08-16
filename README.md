# HwScope — Server Hardware Inspection & Data Collection System

> 面向 AI 基础设施的服务器硬件巡检与数据采集系统：对每个物理组件进行**逐件、逐槽、逐端口**的独立采集与归档，并生成交付级的汇总报告与验收清单。

[![GitHub](https://img.shields.io/badge/GitHub-YanHuiStar%2Fhwscope-blue?logo=github)](https://github.com/YanHuiStar/hwscope)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

**Author:** YanHui · **Version:** 1.28.15 · **License:** [Apache 2.0](LICENSE)

> ⚠️ **开发测试阶段**：接口与输出格式可能随版本演进调整，请以最新代码为准。

---

## 目录

- [项目简介](#项目简介)
- [核心特性](#核心特性)
- [快速开始](#快速开始)
- [依赖工具清单](#依赖工具清单)
- [使用指南](#使用指南)
- [报告与验收体系](#报告与验收体系)
- [平台兼容](#平台兼容)
- [模块架构](#模块架构)
- [配套工具](#配套工具)
- [输出与配置](#输出与配置)
- [设计原则](#设计原则)
- [License](#license)

---

## 项目简介

HwScope（Hardware Scope）是面向 AI 基础设施运维与交付场景的服务器硬件巡检系统。针对 HGX 系列（B200/B300/GB300）、PCIe GPU 服务器及无 GPU 机头，系统以**组件级粒度**采集硬件信息，覆盖主板、CPU、内存、GPU、NVSwitch、PCIe 拓扑、网络、存储、RAID/HBA、电源、风扇、BMC、NVSM、DCGM、OS 共 15 类模块，并以结构化报告（JSON/Markdown/纯文本）与验收清单（Acceptance Checklist）形式输出，支撑**硬件验收、交付记录、故障报修**等场景。

**解决的核心问题：**

- **交付级数据完整性**：报告采用"标称 vs 检测"双轨标注，杜绝客户对容量、速率、功耗的误读；固件/SN/PN 关键信息逐件覆盖，报修可精确到部件。
- **采集与报告解耦**：采集端只读落盘（每命令独立日志），报告端只读解析——数据可回溯、可重跑，任何环节不修改硬件配置。
- **异构平台自适配**：x86/ARM 架构、SXM/PCIe 形态、有无 GPU 机头，启动时自动识别并调整采集与判定策略。

---

## 核心特性

| 特性 | 说明 |
|------|------|
| **逐件独立采集** | 每组件独立模块、互不耦合；每个查询命令独立日志文件，支持单模块执行与过滤 |
| **只读无害** | 全部查询只读，不执行任何配置变更；DCGM 仅 Level 1 纯获取，无压测 |
| **标称 vs 检测双轨** | GPU 显存 `288GB/268.6 GiB 可用`、内存 `2048GB/2015.4 GiB 可见`、PSU 标称容量/实时功耗、IB 标称速率/实际协商——全部标注来源，防误读 |
| **SN/PN/固件全覆盖** | 整机/主板/机箱/GPU/VBIOS/内存/盘/网卡/PSU/RAID/HBA 逐件覆盖；网卡真 SN 经 MST 读取，PSID 自 mlxfwmanager 回查，PSU 无 FRU 平台由 SMBIOS type 39 补齐 PN/容量/固件 |
| **RAID 虚拟盘独立呈现** | 物理盘与 RAID 逻辑盘分表展示（逻辑盘型号/SN(LUN)/容量独立段，不混入物理盘误导） |
| **基础设施状态监控** | 电源冗余（N+N）、SMART 整体健康、进风/CPU/内存温度概况、IB 端口 Link 状态（Active/Down/未插线缆） |
| **交付级验收清单** | 11 项判定（GPU 链路/NVLink/DCGM/VBIOS/内存/线缆/磁盘/SMART/电源冗余/温度/SEL），**有/无 GPU 场景采用差异化通过标准** |
| **平台自适应** | SXM 四重检测（nvswitch CLI → lspci NVSwitch → fabricmanager 进程 → NVLink 交叉验证）；WSL 虚拟盘自动跳过 SMART |
| **NVIDIA 专属段条件显示** | NVSwitch/NVLink/DCGM 无数据时整段隐藏，非 NVIDIA 平台报告干净 |

---

## 快速开始

> 📍 开发方向与待办见 [ROADMAP.md](ROADMAP.md)（活文档：条目完成即删除）

```bash
git clone https://github.com/YanHuiStar/hwscope.git && cd hwscope

# Windows 复制进来的文件先修复换行符
bash fixcrlf.sh

# 安装依赖工具（未安装的工具对应模块自动跳过，不影响整体采集）
apt install -y dmidecode pciutils ipmitool smartmontools lm-sensors i2c-tools usbutils      # Ubuntu
dnf install -y dmidecode pciutils ipmitool smartmontools lm_sensors i2c-tools usbutils      # Rocky/RHEL 8+

# 执行全量采集
sudo bash hwscope.sh                  # 全量采集（默认双层并行）
sudo bash hwscope.sh --serial         # 串行采集（实时逐命令输出）
sudo bash hwscope.sh --no-parallel    # 禁用模块内命令并行（仅模块间并行）
sudo bash hwscope.sh --quiet          # 静默模式（仅输出异常）
```

### 依赖工具清单

| 工具（包名） | 用途 | 必需/可选 |
|--------------|------|-----------|
| `dmidecode` | 主板/BIOS/CPU/内存/PSU/TPM 硬件表（type 0~43） | 必需 |
| `pciutils`（lspci） | PCIe 设备/链路速率（GPU/网卡/BDF） | 必需 |
| `ipmitool` | BMC 传感器/FRU/SEL/电源功耗（sensor/dcmi/sdr/fru） | 必需（有 BMC 的服务器） |
| `smartmontools`（smartctl） | 磁盘 SMART 健康/寿命 | 必需（有盘必装） |
| `lm-sensors` | 温度/风扇传感器（hwmon 备选） | 可选 |
| `i2c-tools`（i2cget/i2cdetect） | PMBus 直读 PSU 芯片（IPMI 无 FRU 平台补型号） | 可选（Inventec 等平台建议装） |
| `usbutils`（lsusb） | USB 设备列表（佐证 USB 网卡/外设） | 可选 |
| `storcli64` / `sas3ircu` / `sas2ircu` | RAID/HBA 控制器（LSI/Broadcom） | 可选（有 RAID/HBA 时） |
| `nvidia-smi` + 驱动 | GPU 信息/拓扑/ECC | 必需（NVIDIA 平台） |
| `dcgmi`（DCGM） | GPU 健康诊断（Level 1） | 可选（诊断项） |
| `mft`（mst/mstflint/mlxlink/mlxconfig） | Mellanox 网卡固件/SN/PSID | 可选（有 IB 网卡时） |
| `ethtool` | 网口链路/驱动信息 | 可选（有网卡时） |
| `numactl` | NUMA 拓扑（numactl --hardware） | 可选 |
| `fabricmanager`（nvidia-fabricmanager） | NVSwitch 管理服务检测 | 可选（SXM 平台） |

> 未安装的工具对应模块自动跳过（`[SKIP]`），不影响整体采集；`tools/install_tool.sh` 可按发行版自动安装。

### RAID/HBA 专业运维工具

采集端为**只读**设计，以下操作类工具不集成执行（会修改硬件配置），现场运维按需使用：

| 工具 | 平台 | 查询 | 操作 |
|------|------|------|------|
| `storcli64` | Broadcom MegaRAID | `storcli64 /c0 show all`（型号/SN/固件/VD/BBU） | 建/删 VD、改 RAID 级别、热备配置 |
| `sas3ircu` / `sas2ircu` | Broadcom SAS3/SAS2 HBA | `sas3ircu 0 display`（型号/固件/状态/PHY） | 查询为主（display/status） |
| `sas3flash` / `sas2flash` | Broadcom HBA | `sas3flash -list` | 固件刷写、SN 修改、PHY 配置 |
| `MegaCli64` | 老版 MegaRAID | 同 storcli（旧驱动环境） | 同 storcli |
| `perccli` | Dell PERC | `perccli /c0 show all` | 同 storcli（Dell 版） |
| `ssacli` / `hpssacli` | HPE Smart Array | `ssacli ctrl all show detail` | RAID 配置 |
| `arcconf` | Adaptec | `arcconf getconfig 1` | RAID 配置 |
| `sg3_utils`（sg_inq/sg_ses） | 通用 SCSI/SAS/SATA | `sg_inq`（VPD 厂商/型号/SN）、`sg_ses`（背板槽位） | 查询为主（只读） |

> 采集模块已自动识别 storcli64/sas3ircu/sas2ircu；报告端只读解析，不执行任何配置变更。

---

## 使用指南

### 采集

```bash
bash hwscope.sh                       # 双层并行（默认，模块间 + 模块内命令并发）
bash hwscope.sh --serial              # 模块串行（模块内仍并行）
bash hwscope.sh --no-parallel         # 禁用模块内命令并行
bash hwscope.sh --quiet               # 并行 + 静默

# 模块过滤
bash hwscope.sh --modules gpu,storage # 仅采集指定模块
bash hwscope.sh --skip dcgm,nvsm      # 跳过指定模块

# 其他
bash hwscope.sh --output /data/x      # 指定输出目录
bash hwscope.sh --force               # 覆盖已有目录
bash hwscope.sh --no-module           # 跳过光模块查询（缩短采集时长约 48s）
bash hwscope.sh --version             # 版本信息

# 单独执行模块
bash modules/04_gpu.sh /tmp/out
```

### 报告生成

```bash
# 采集完成后自动生成；可对任意已有采集目录手动重跑（只读，不重新采集）
bash tools/report.sh <output_dir>              # 生成 JSON + Markdown + TXT 三件套
bash tools/report.sh <output_dir> --acceptance # 单独生成验收清单
```

---

## 报告与验收体系

### 报告结构

报告按 14 个段落组织（环境/主板/CPU/内存/GPU/NVSwitch/存储/RAID/HBA/网络/BMC/风扇/电源/健康检查），核心信息维度：

- **标称 vs 检测双轨**：GPU 显存、内存容量、PSU 容量/功耗、IB 标称/协商速率、盘标称容量（型号自动提取，Samsung 映射表兜底）——全部标注来源
- **PCIe 速率语义**：显示协商值（LnkSta），与能力（LnkCap）不一致时标注 `(能力 X)`，表头标注"协商"
- **SN/PN/固件逐件覆盖**：整机/主板/机箱/GPU（含 VBIOS 聚合去重，混插固件自动检出）/内存每槽/盘/网卡（MST 真 SN + PSID）/PSU/RAID/HBA
- **RAID 虚拟盘独立段**：物理盘与 RAID 逻辑盘分表（逻辑盘标注 RAID 卡型号/SN(LUN)，不混入物理盘）
- **动态列隐藏**：整列无数据（旧采集/平台不支持）时隐藏该列并附注说明，有任一真实值即显示；JSON 始终保留全字段（程序消费稳定）
- **表格标题标准化**：内存插槽明细/GPU 每卡明细/PSU 明细统一命名，速率列明确"标称速率/当前速率"
- **基础设施状态**：电源冗余（N+N）、SMART 整体健康、温度概况（进风/出风/CPU/内存/电源/PCH）、IB Link 状态（Active/Down/未插线缆）
- **NVIDIA 专属段条件显示**：NVSwitch/NVLink/DCGM 无数据时整段隐藏；无 GPU 机头 GPU 段显示 `N/A (未检测到 GPU/无 NVIDIA 驱动)`
- **术语表**：报告末尾附 IB 速率/GPU直连/DCGM/SXM 等术语解释，非运维人员亦可读懂

### 验收清单（Acceptance Checklist）

交付场景自动生成 `hwscope_acceptance.md`，含 **11 项判定**与结论汇总：

| # | 检查项 | # | 检查项 |
|---|--------|---|--------|
| 1 | GPU PCIe 链路完整 | 7 | 磁盘寿命 |
| 2 | NVLink 互联 | 8 | SMART 健康状态 |
| 3 | DCGM 诊断 | 9 | 电源冗余（N+N） |
| 4 | GPU VBIOS 版本一致 | 10 | 整机温度正常 |
| 5 | 内存运行速率 | 11 | SEL 事件 |
| 6 | IB 线缆配对 | | |

**判定标准**：`PASS`（通过）/ `FAIL`（不通过）/ `WARN`（有条件通过）/ `N/A`（无数据）

- **有 GPU 平台**：GPU 相关 4 项（PCIe/NVLink/DCGM/VBIOS）按实际状态判定，关键硬件异常判 FAIL
- **无 GPU 机头**：GPU 相关 4 项判 `N/A`（无本地 GPU，模组单独采集验收），**不计入"数据不足"判定**——机头无 GPU 属平台固有形态，非数据缺失
- **平台规范豁免**：内存满插 2DPC 降速属平台规范判 PASS；DCGM 配置类 Fail（如 Persistence Mode 未开启）判 WARN（非硬件故障）
- **无数据不假 PASS**：SEL 采集失败、盘无 SMART 数据、N/A 项≥4 时判"数据不足"，禁止假阳性合格

---

## 平台兼容

| 标识 | 条件 | 代表机型 |
|------|------|---------|
| `x86_64_SXM` | x86 + SXM GPU + NVSwitch | HGX B200/B300 |
| `x86_64_head` | x86 + PCIe Gen5 Fabric Switch（PEX89xxx/PEX97xxx/Switchtec），非 SXM | HGX 机头（ESC N8-E11V 等，无本地 GPU，模组经 Switch 接入，单独采集） |
| `x86_64_PCIe` | x86 + PCIe GPU | 8×A100/H100 |
| `aarch64_SXM` | ARM + SXM GPU + NVSwitch | GB300 / Grace |
| `x86_64_none` | x86，无 GPU | 传统服务器 |

平台于启动时自动检测。CPU 模块自动适配 x86（`model name`）与 ARM（`CPU implementer`）格式。

SXM 四重检测：`nvswitch -q` → `lspci` NVSwitch 字样 → `nv-fabricmanager` 进程 → NVLink 交叉验证（兜底 lspci 不显示 NVSwitch 设备的场景）。

---

## 模块架构

| # | 模块 | 工具 | 内容 |
|---|------|------|------|
| 01 | motherboard | `dmidecode` | 主板/BIOS/机箱 型号/SN（type 0~43 全覆盖） |
| 02 | cpu | `dmidecode` + `lscpu` | FRU + OS 双视角 |
| 03 | memory | `dmidecode` + `free` | 每 DIMM 独立日志 + EDAC 错误计数 |
| 04 | gpu | `nvidia-smi` | 每 GPU + NVLink + ECC + VBIOS（每卡明细 + 汇总聚合） |
| 05 | nvswitch | `nvswitch` + `nvidia-smi nvswitch` | 每颗 NVSwitch + Fabric Manager（无独立 CLI 平台用驱动内置子命令兜底） |
| 06 | pcie | `lspci` | 拓扑/速率/NUMA/IOMMU（缺 lspci 时 SKIP 落盘） |
| 07 | network | `ibstat` + `mlxlink` + `ethtool` + `mstflint` | 每 IB 端口 + 每网口 + 光模块 + 真 SN；型号 lspci 直读 + PSID 回查 + MT 对照表 |
| 08 | storage | `lsblk` + `smartctl` | 全类型盘 + SMART 健康（WSL 虚拟盘自动跳过） |
| 09 | raid | `storcli64` + `sas3ircu` | RAID 阵列卡 + HBA 直通卡（型号/SN/固件/虚拟盘） |
| 10 | psu | `ipmitool` + `sysfs` | 每 PSU 功率/温度 + dcmi/sdr/PMBus/dmidecode type 39 |
| 11 | fan | `ipmitool` + `sensors` + `hwmon` | 每风扇转速/占空比 |
| 12 | bmc | `ipmitool` + Redfish | FRU/SEL/传感器/BMC 网络 |
| 13 | nvsm | `nvsm` | NVIDIA System Management |
| 14 | dcgm | `dcgmi` | Level 1 诊断（hostengine 未启动时自动拉起，可配置关闭） |
| 99 | os | `uname/dmesg/systemctl` | 内核/服务/NUMA/AER |

---

## 配套工具

除采集与报告外，项目提供两类交互式脚本（自动检测依赖工具，未安装时提示安装命令）。

### `test/` — 硬件压测（仅只读测试，不修改硬件配置）

| 脚本 | 内容 | 依赖 |
|------|------|------|
| `cpu_test.sh` | stress-ng / sysbench / mprime 三种 CPU 压测 | stress-ng, sysbench, mprime |
| `memory_test.sh` | stress-ng --vm / memtester / sysbench memory 内存测试 | stress-ng, memtester, sysbench |
| `disk_test.sh` | fio 随机 IOPS / hdparm / dd 硬盘吞吐 | fio, hdparm |
| `network_test.sh` | iperf3 / ib_write_bw / mtr 网络测试 | iperf3, perftest, mtr |
| `ib_test.sh` | IB 数据面打流（自动配对 mlx5 设备，ib_write_bw/ib_read_bw 逐对测试） | perftest, mlxlink |
| `nccl_test.sh` | NCCL 集群通信带宽测试（all_reduce/all_gather/all_to_all） | nccl-tests 编译产物 |

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
| `net_dhcp.sh` | 一键配置网口 DHCP 自动获取 IP（识别物理网口/自动选择/写 netplan） | netplan（Ubuntu 24.04） |
| `install_tool.sh` | 依赖安装（采集/压测/IB/DCGM/MFT），apt/dnf 自动识别 | - |
| `install_ai.sh` | AI 推理引擎安装（vLLM/SGLang/TRT-LLM/Ollama/llama.cpp） | uv/docker 自动检测 |
| `report.sh` | 从采集结果生成 json/md/txt 汇总报告（内存每槽/GPU每卡/CPU每颗/存储每盘/网络每端口/PSU/RAID/HBA/风扇/温度明细 + 术语表）；`--acceptance` 生成验收清单交接单 | 采集完成后自动调用 |
| `cable_map.sh` | 线缆拓扑图（BDF↔mlx5 映射 + EEPROM serial 线缆配对 + 断口联动验证） | mlxlink |
| `firmware_check.sh` | 固件版本核对（GPU VBIOS/BMC/CX8/NVSwitch），支持基线保存+对比 | nvidia-smi, ipmitool |
| `nvlink_verify.sh` | NVLink 完整性校验（全互联验证 + CRC 错误 + 降级链路检测） | nvidia-smi |
| `sel_monitor.sh` | SEL 事件对比巡检（记录基线，后续只报告新增事件） | ipmitool |
| `sync_version.sh` | 版本号同步（从 hwscope.sh 读取，自动更新 README 徽章） | - |

### `tools/win/` — Windows 配套工具

网线直连服务器时用于 BMC 发现与配置，不参与服务器采集：

| 脚本 | 场景 | 说明 |
|------|------|------|
| `scan_ip.ps1` / `.bat` | 未知服务器 IP | 并发 ping 网段 + ARP 关联 MAC，定位在线设备 |
| `detect_bmc.ps1` / `.bat` | 确认 BMC IP | MAC 厂商前缀 + 端口评分（623=IPMI/443=Web/5900=noVNC） |
| `nic_switch.ps1` / `.bat` | 直连前配网 | 自动识别插线网卡，设置固定 IP，完成后恢复 DHCP |
| `ipmi_power.ps1` / `.bat` | BMC 远程电源控制 | 开机/关机/重启/状态（密码走环境变量，不落盘） |
| `wol.ps1` / `.bat` | 远程唤醒 | Wake-on-LAN 魔术包 |
| `ssh_batch.ps1` / `.bat` | 批量命令 | 对多台服务器执行同一条命令 |
| `fetch_report.ps1` / `.bat` | 巡检汇总 | 拉取各机报告三件套，按主机名归档 |
| `dhcp_server.ps1` / `.bat` | 直连自动分配 IP | 纯 PowerShell DHCP 服务（零依赖），配合 `net_dhcp.sh` 即插即通 |
| `unblock_ps.ps1` / `.bat` | 首次使用前 | 解除 .ps1 运行限制 |

```powershell
# 首次使用：解除脚本运行限制（当前用户，无需管理员）
.\unblock_ps.ps1

# 场景一：直连服务器（网线直连，无交换机）
.\dhcp_server.ps1 -Subnet 192.168.50   # 1. 笔记本开 DHCP（需管理员）
#   服务器侧: sudo bash tools/net_dhcp.sh   # 2. 服务器自动获取 IP
.\scan_ip.ps1                          # 3. 扫描定位服务器
.\detect_bmc.ps1 -Hosts 192.168.1.1,... # 4. 确认 BMC
.\ipmi_power.ps1 -BmcIP <BMC_IP> -Action on    # 5. 远程开机

# 场景二：服务器已有固定 IP
.\nic_switch.ps1 -Action Set -IP 192.168.1.100   # 1. 设同网段 IP
.\scan_ip.ps1                 # 2. 扫描定位
.\nic_switch.ps1 -Action Restore   # 3. 恢复 DHCP

# 集群巡检（SSH 免密后）
.\fetch_report.ps1 -Hosts root@192.168.1.100,root@192.168.1.101
```

---

## 输出与配置

### 终端状态标识

| 标签 | 含义 |
|------|------|
| `[OK]` | 成功 (exit=0) |
| `[~]` | grep 无匹配 (exit=1)，不算异常 |
| `[N/A]` | 工具不存在 (exit=127) |
| `[WARN]` | 异常 (exit≠0/1/127) |
| `[SKIP]` | 模块跳过 |
| `[QUEUE]` | 并行启动 |
| `[ M:SSs ]` | 每条命令耗时（亚秒显示小数；≥1s 显示 `0:05s`/`1:34s`） |

### 输出目录

```text
output/
├── JZ5C4X8/                    # SN（首次）
├── JZ5C4X8-20260730_090000/    # 二次采集（自动追加时间戳）
├── MB-1234567/                 # 主板 SN 兜底
└── 20260728_120000/            # 时间戳兜底
```

单次采集典型结构：

```text
output/SN123456789/
├── hwscope.log              # 执行日志（纯文本）
├── config_backup.conf       # 配置快照
├── summary.txt              # 汇总（含 WARN 计数）
├── hwscope_report.json      # 汇总报告（结构化）
├── hwscope_report.md        # 汇总报告（Markdown）
├── hwscope_report.txt       # 汇总报告（纯文本）
├── hwscope_acceptance.md    # 验收清单（交付交接单）
├── motherboard/             # dmidecode 日志 ×6
├── cpu/                     # dmidecode + lscpu ×8
├── memory/                  # dmidecode + 每槽 + edac_errors ×N
├── gpu/                     # nvidia-smi 每卡 + ECC ×30+
├── nvswitch/                # nvswitch 每颗 ×7
├── pcie/                    # lspci 拓扑 ×10+
├── network/                 # IB + mlx + ethtool ×30+
├── storage/                 # lsblk + smartctl 每盘 ×20+
├── raid/                    # storcli + sas3ircu ×10+
├── psu/                     # IPMI + sysfs + PMBus ×5+
├── fan/                     # IPMI + hwmon ×5+
├── bmc/                     # IPMI + Redfish ×20+
├── nvsm/ / dcgm/ / os/     # 条件 + OS ×15+
└── (logs/)                  # 采集归档 tar.gz（项目根目录）
    └── report/              # 报告归档 tar.gz（单独打包）
```

采集完成后自动归档至 `logs/<SN>-<时间戳>.tar.gz`，报告三件套另打包至 `logs/report/<SN>-<时间戳>-report.tar.gz`。

### 日志格式

每条采集命令独立落盘，带完整上下文：

```log
# ============================================================
# Command  : nvidia-smi --query-gpu=name,serial,memory.total --format=csv
# Hostname : gpu-node-03
# Timestamp: 2026-07-28 10:30:15
# Encoding : UTF-8
# ============================================================
# --- output start ---
0, NVIDIA B300, 13245230xxxxxx, 196608 MiB
# --- output end ---
# --- exit code: 0, [ 0.23s ] ---
```

### 配置

`conf/hwscope.conf`：

```bash
# BMC（留空只查本地 IPMI）
BMC_IP=""; BMC_USER="admin"; BMC_PASS="admin"
HGX_BMC_IP=""              # HGX 基板 BMC（SXM 平台填写，默认留空不连接）

# 模块开关（1=启用）
MODULE_GPU=1; MODULE_STORAGE=1; MODULE_OS=1 ...

# 服务自动启动（验收/交付场景默认 1；只读巡检可关）
MST_AUTO_START=1           # Mellanox MST 未启动时自动 mst start（读真 SN）
DCGM_AUTO_START=1          # DCGM hostengine 未启动时自动拉起
MODULE_TIMEOUT=300         # 模块级超时（秒），防止命令卡死
```

---

## 设计原则

- **逐件独立** — 每组件独立模块，互不耦合，可单独执行
- **只读无害** — 全部只读查询，不写不改
- **全量采集** — 采集命令只过滤不截断（grep 过滤、不 head/tail 截断），保证数据真实可回溯；报告端按需截取展示
- **自动跳过** — 工具未安装静默跳过，不中断
- **无压测** — DCGM 仅 Level 1 纯获取
- **平台自适配** — x86/ARM、SXM/PCIe 自动识别（SXM 四重检测）
- **环境自适配** — WSL 虚拟磁盘自动跳过 SMART，避免误报
- **双层并行** — 模块间 + 模块内命令并发；`--no-parallel` 可降级；模块级超时兜底
- **N/A 隐藏** — NVIDIA 专属段与 RAID/HBA 无数据时整段隐藏，新平台报告干净
- **服务自拉起** — MST/DCGM hostengine 未启动时自动启动（验收场景默认开，可配置关闭）
- **真实数据只读** — 采集模块仅在 /tmp 副本测试（真实目录重跑会覆盖数据）；report.sh 只读生成器可直接跑真实目录
- **manifest 解耦** — 模块声明输出文件，报告生成器读 manifest，改文件名不连累报告
- **报告术语表** — 末尾附术语解释，非运维人员亦可读懂

## License

[Apache License 2.0](LICENSE) · [GitHub](https://github.com/YanHuiStar/hwscope)
