# HwScope — Hardware Scope

> Server Hardware Inspection & Data Collection System · 服务器硬件一键巡检采集系统

**Author:** YanHui / Hermes Agent  ·  **Version:** 1.0.0  ·  **License:** [Apache 2.0](LICENSE)

[![GitHub](https://img.shields.io/badge/GitHub-YanHuiStar%2Fhwscope-blue?logo=github)](https://github.com/YanHuiStar/hwscope)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

HwScope 对服务器每个物理组件进行**逐件、逐槽、逐端口**的独立采集，每个查询命令保存到独立日志文件，方便后续定位和对比。

---

## 平台兼容

| 平台 | 识别标识 | 代表机型 |
|------|---------|---------|
| `x86_64_SXM` | Intel/AMD CPU + SXM GPU + NVSwitch | HGX B200/B300 |
| `x86_64_PCIe` | Intel/AMD CPU + PCIe GPU（无 NVSwitch） | 8×A100/H100 PCIe 服务器 |
| `aarch64_SXM` | ARM CPU + SXM GPU + NVSwitch | GB300 / Grace-Hopper |
| `x86_64_none` | Intel/AMD CPU，无 GPU | 传统服务器 |

HwScope 启动时自动检测平台类型，CPU 模块自动适配 x86 (`model name`) 和 ARM (`CPU implementer / CPU part`) 的 `/proc/cpuinfo` 格式。

---

## 快速开始

```bash
# 上传到目标服务器
scp -r hwscope root@<server_ip>:/root/

# 安装必要工具（按需，缺少的工具会自动跳过）
ssh root@<server_ip>
yum install -y dmidecode pciutils ipmitool smartmontools lm_sensors

# 一键采集全部硬件
cd /root/hwscope
sudo bash collect_all.sh

# 输出在 output/<服务器SN>/<时间戳>/
```

---

## 用法

```bash
sudo bash collect_all.sh                              # 全部采集
sudo bash collect_all.sh --modules gpu,storage        # 只采 GPU + 存储
sudo bash collect_all.sh --skip dcgm,nvsm             # 跳过诊断模块
sudo bash collect_all.sh --output /data/inspect       # 指定输出目录
sudo bash collect_all.sh --force                      # 覆盖已有目录

# 单独跑某个模块（不依赖总入口）
sudo bash modules/04_gpu.sh /tmp/my_output
```

---

## 模块总览

| # | 模块 | 采集工具 | 内容 |
|---|------|---------|------|
| 01 | **motherboard** | `dmidecode` | 主板型号/SN，BIOS 版本/日期，机箱型号/SN |
| 02 | **cpu** | `dmidecode` + `lscpu` + `/proc/cpuinfo` | CPU FRU（制造商/核心数/插槽），OS 视角（架构/线程/缓存/频率），自动适配 x86/ARM |
| 03 | **memory** | `dmidecode` + `free` | 每 DIMM 独立日志（位置/容量/速率/SN/部件号），全局容量统计 |
| 04 | **gpu** | `nvidia-smi` | 每 GPU 独立详情，资产清单 CSV，NVLink 状态，ECC 错误（volatile + aggregate），拓扑 |
| 05 | **nvswitch** | `nvswitch` + `nvidia-fabricmanager` | 每颗 NVSwitch 独立信息，Fabric Manager 版本/服务状态 |
| 06 | **pcie** | `lspci` | PCIe 树形拓扑，每 GPU 速率/宽度，NUMA 映射，IOMMU 分组 |
| 07 | **network** | `ibstat` + `mlxlink` + `ethtool` + `mlxfwmanager` | 每 IB 设备/每网口独立信息，光模块 DDM，固件/配置 |
| 08 | **storage** | `lsblk` + `smartctl` + `lsscsi` | 全部盘清单，按 SATA/SAS/NVMe 分类，每盘 SMART 全量+健康摘要，SSD/HDD 区分 |
| 09 | **raid** | `storcli64` + `sas3ircu` + `sas2ircu` | RAID/HBA 控制器型号/SN/固件，VD 配置，BBU 状态，事件日志 |
| 10 | **psu** | `ipmitool` + `sysfs` + `i2cdetect` | 每 PSU 功率/温度/状态，pmbus 寄存器 |
| 11 | **fan** | `ipmitool` + `sensors` + `hwmon` | 每风扇转速/占空比/阈值 |
| 12 | **bmc** | `ipmitool` + `curl` (Redfish) | FRU/SEL/传感器/网络/用户，Redfish API，HGX 基板 BMC |
| 13 | **nvsm** | `nvsm` | NVIDIA System Management（仅 MGX 认证整机，未安装自动跳过） |
| 14 | **dcgm** | `dcgmi` | DCGM Level 1 纯获取诊断（仅安装时，不产生 GPU 负载） |
| 99 | **os** | `uname/dmesg/systemctl/numactl` | 内核/OS 版本，硬件相关 dmesg，服务状态，NUMA 拓扑，PCIe AER 错误，NVIDIA sysfs |

---

## 前置工具

```bash
# RHEL / Rocky / CentOS
yum install -y dmidecode pciutils ipmitool infiniband-diags nvme-cli smartmontools lm_sensors

# Ubuntu / Debian
apt install -y dmidecode pciutils ipmitool infiniband-diags nvme-cli smartmontools lm-sensors
```

以下工具需要从厂商下载（未安装时自动跳过对应模块）：

- **Mellanox Firmware Tools** (MFT) — `mlxfwmanager`, `mlxlink`, `mlxconfig` — [下载](https://network.nvidia.com/products/adapter-software/firmware-tools/)
- **Broadcom storcli64** — RAID 管理 — [下载](https://www.broadcom.com/support/download-search)
- **NVIDIA DCGM** — GPU 诊断 — `yum install datacenter-gpu-manager`

---

## 输出格式

### 多机隔离

输出目录以**物理标识**命名，不同机器自动分开，同一机器多次采集不互相覆盖。首次运行使用纯 SN 目录，再次运行自动追加时间戳：

```
output/
├── JZ5C4X8/                          # 服务器 SN（首次运行）
├── JZ5C4X8-20260730_090000/          # 第二次运行（自动追加时间戳）
├── MB-1234567/                       # 主板 SN（服务器 SN 为空时）
├── 4C4C454400574D31/                 # 机器 UUID（前两者均空时）
└── 20260728_120000/                  # 时间戳兜底
```

`--force` 直接覆盖 `output/JZ5C4X8/` 不追加时间戳。

### 单次采集目录结构

```bash
# 首次运行 → output/JZ5C4X8/
# 第二次运行 → output/JZ5C4X8-20260730_090000/

ls output/JZ5C4X8/
```
├── collect_all.log                    # 执行过程日志（终端输出同步保存）
├── config_backup.conf                 # 本次采集使用的配置快照
├── motherboard/                       # 主板/BIOS/机箱
│   ├── dmidecode_system.log
│   ├── dmidecode_baseboard.log
│   ├── dmidecode_bios.log
│   ├── dmidecode_chassis.log
│   ├── system_summary.log
│   └── baseboard_summary.log
├── cpu/                               # CPU（x86/ARM 自动适配）
│   ├── dmidecode_processor.log
│   ├── lscpu.log / lscpu_extended.log
│   ├── cpu_core_count.log
│   ├── cpu_summary.log                # x86: model name / ARM: CPU implementer
│   ├── proc_cpuinfo_full.log          # 兜底全量
│   ├── cpu_freq.log / cpu_freq_range.log
│   └── smt_status.log
├── memory/                            # 内存
│   ├── dmidecode_memory_full.log
│   ├── memory_slot_fields.log
│   ├── memory_slot_blocks.log
│   ├── memory_capacity.log
│   ├── free_h.log / proc_meminfo.log
│   └── slot_CPU1_DIMM_A1.log ... slot_CPU2_DIMM_H2.log
├── gpu/                               # GPU
│   ├── gpu_full.log
│   ├── gpu_inventory.csv              # CSV，方便 Excel 导入
│   ├── gpu_0_detail.log ... gpu_7_detail.log
│   ├── gpu_nvlink_status.log / gpu_nvlink_cap.log
│   ├── gpu_ecc_full.log / gpu_ecc_inventory.csv
│   ├── gpu_0_ecc.log ... gpu_7_ecc.log
│   ├── gpu_pmon.log / gpu_processes.csv
│   ├── gpu_driver_version.log
│   └── gpu_topo.log
├── nvswitch/                          # NVSwitch
│   ├── nvswitch_all.log / nvswitch_0.log ... nvswitch_3.log
│   ├── nvswitch_version.log
│   └── fabricmanager_version.log / fabricmanager_service.log
├── pcie/                              # PCIe 拓扑
│   ├── lspci_all.log / lspci_tree.log
│   ├── lspci_nvidia.log / pcie_bridge.log
│   ├── pcie_speed_width.log
│   ├── gpu_pcie_0.log ... gpu_pcie_7.log
│   ├── gpu_pcie_bus_map.log
│   ├── pci_numa_map.log
│   └── iommu_groups.log
├── network/                           # 网络 / IB / 光模块
│   ├── ibstat.log / ibstatus.log / ibv_devinfo.log / ibdev2netdev.log
│   ├── mlxfwmanager.log / mlxconfig.log
│   ├── mlxlink_mlx5_0.log / mlxlink_mlx5_0_module.log ... per device
│   ├── ethtool_ens1f0.log / ethtool_ens1f0_driver.log / ethtool_ens1f0_module.log
│   ├── ip_addr.log / ip_link.log / ip_route.log
│   └── lstopo_network.txt
├── storage/                           # 硬盘（SATA/SAS/NVMe 全覆盖）
│   ├── block_devices_all.log / block_devices_summary.log
│   ├── block_devices_by_type.log
│   ├── drive_type_ssd_hdd.log
│   ├── smart_scan.log
│   ├── smart_nvme0n1.log / smart_nvme0n1_health.log ... per NVMe
│   ├── smart_sda.log / smart_sda_scsi.log / smart_sda_health.log ... per SATA/SAS
│   ├── lsscsi_all.log / lsscsi_detail.log
│   └── df_h.log / mount.log / proc_partitions.log
├── raid/                              # RAID/HBA 控制器
│   ├── pci_raid_hba_list.log / storcli_controllers.log
│   ├── ctrl0_info.log / ctrl0_summary.log
│   ├── ctrl0_vd_all.log / ctrl0_vd0.log ... per VD
│   ├── ctrl0_enc0_slot0.log ... per physical drive
│   ├── ctrl0_pd_summary.log
│   ├── ctrl0_bbu.log / ctrl0_events.log
│   ├── sas3_hba0.log / sas3_hba0_status.log ... per HBA
│   └── lspci_raid_0.log
├── psu/                               # 电源
│   ├── ipmi_psu_sensors.log / ipmi_psu_temp.log / ipmi_psu_power.log
│   ├── sysfs_PSU0/all_fields.log ... sysfs_PSU3/
│   └── psu_present.log
├── fan/                               # 风扇
│   ├── ipmi_fan_sensors.log / ipmi_fan_status.log
│   ├── sensors_all.log / sensors_fan.log
│   └── hwmon_hwmon0_*/fan_values.log ... per hwmon
├── bmc/                               # BMC / IPMI
│   ├── ipmi_fru.log / ipmi_fru_all.log / ipmi_fru_summary.log
│   ├── ipmi_mc.log / ipmi_bmc_guid.log
│   ├── ipmi_sensors.log / ipmi_sdr.log
│   ├── ipmi_sensors_temp.log / ipmi_sensors_fan.log / ipmi_sensors_volt.log / ipmi_sensors_power.log
│   ├── ipmi_sel.log / ipmi_sel_elist.log
│   ├── ipmi_chassis.log / ipmi_power.log
│   ├── ipmi_lan1.log / ipmi_lan2.log / ipmi_users.log
│   ├── remote_bmc_fru.log / remote_bmc_sensors.log ... 远程 BMC
│   ├── hgx_bmc_fru.log / hgx_bmc_sensors.log ... HGX 基板 BMC
│   └── redfish_system.log / redfish_managers.log
├── nvsm/                              # NVSM（仅 MGX 整机）
│   ├── nvsm_dump_system.log / nvsm_dump_health.log
│   ├── nvsm_components.log / nvsm_sensors.log / nvsm_asset.log
│   ├── nvsm_gpu_sxm_1.log ... nvsm_gpu_sxm_8.log
│   ├── nvsm_nvswitch_1.log ... nvsm_nvswitch_4.log
│   ├── nvsm_nic.log / nvsm_memory.log / nvsm_psu.log / nvsm_fan.log
│   └── nvsm_version.log
├── dcgm/                              # DCGM（仅安装时，Level 1 纯获取）
│   ├── dcgmi_discovery.log / dcgmi_stats.log / dcgmi_config.log
│   ├── dcgmi_diag_level1.log
│   ├── dcgmi_diag_gpu0.log ... dcgmi_diag_gpu7.log
│   └── dcgmi_version.log
├── os/                                # OS 基础
│   ├── uname.log / os-release.log
│   ├── kernel_modules_gpu_net.log / lsmod_all.log
│   ├── uptime.log / loadavg.log
│   ├── dmesg_hardware.log / dmesg_nvidia.log / dmesg_nvswitch.log
│   ├── service_nvidia-fabricmanager.log / service_nvsmd.log
│   ├── numa_hardware.log / numa_nodes.log / node0_cpus.log ...
│   ├── pcie_aer.log
│   └── sysfs_*_nvidia*.log
└── summary.txt                        # 整体汇总报告
```

### 日志文件格式

每个日志文件统一带命令头、主机名、时间戳、编码信息：

```log
# ============================================================
# Command  : nvidia-smi --query-gpu=index,name,serial,pci.bus_id,memory.total --format=csv
# Hostname : gpu-node-03
# Timestamp: 2026-07-28 10:30:15
# Encoding : UTF-8
# ============================================================
# --- output start ---
0, NVIDIA B300, 13245230xxxxxx, 00000000:17:00.0, 196608 MiB
1, NVIDIA B300, 13245230xxxxx1, 00000000:35:00.0, 196608 MiB
...
# --- output end (exit code: 0) ---
```

### 终端状态标签

| 标签 | 颜色 | 含义 |
|------|------|------|
| `[OK]` | 绿色 | 命令执行成功 (exit=0) |
| `[N/A]` | 黄色 | 命令不存在 (exit=127) |
| `[WARN]` | 黄色 | 命令执行异常 (exit>0) |
| `[SKIP]` | 黄色 | 工具未安装，跳过整个模块 |

### 平台信息

终端和 `summary.txt` 中自动输出平台识别结果：

```
[INFO] Platform: x86_64_SXM (GPU: 8)
```

---

## 配置

`conf/hwscope.conf`：

```bash
# BMC 远程采集（留空则跳过远程，只查本地 IPMI）
BMC_IP=""
BMC_USER="admin"
BMC_PASS="admin"
BMC_INTERFACE="lanplus"

# HGX 基板 BMC（独立管理 GPU/NVSwitch）
HGX_BMC_IP="192.168.1.1"
HGX_BMC_USER="admin"
HGX_BMC_PASS="admin"

# 模块开关（1=启用 0=跳过）
MODULE_MB=1           # 主板/BIOS/机箱
MODULE_CPU=1          # CPU
MODULE_MEMORY=1       # 内存
MODULE_GPU=1          # GPU
MODULE_NVSWITCH=1     # NVSwitch
MODULE_PCIE=1         # PCIe 拓扑
MODULE_NETWORK=1      # 网络/IB/光模块
MODULE_STORAGE=1      # 存储设备
MODULE_RAID=1         # RAID/HBA 卡
MODULE_PSU=1          # 电源
MODULE_FAN=1          # 风扇
MODULE_BMC=1          # BMC/IPMI
MODULE_NVSM=1         # NVSM（自动检测）
MODULE_DCGM=1         # DCGM（自动检测）
MODULE_OS=1           # OS 基础信息

# 输出目录（留空则自动: output/<机器SN>/<时间戳>/）
OUTPUT_BASE_DIR=""

# 运行模式
SKIP_IF_NO_CMD=1      # 命令不存在时静默跳过
FORCE=0               # 1=覆盖已有目录
```

---

## 设计原则

- **逐件独立** — 每个物理组件独立一个模块，互不耦合，可单独执行
- **逐日志标识** — 每个查询命令保存到独立日志文件，头部记录完整命令 + 时间戳 + 编码
- **只读无害** — 所有命令只读查询，不写硬件、不改配置
- **命令不存在自动跳过** — 工具未安装或平台不支持时静默跳过，不中断采集
- **BMC 双通道** — 本地 IPMI + 远程 IPMI + Redfish API 三层覆盖
- **无压测** — DCGM 仅跑 Level 1 纯获取，不产生任何 GPU 负载
- **自动编码处理** — 非 UTF-8 环境自动尝试切换，日志头部记录实际编码
- **多平台兼容** — x86_64 / aarch64，SXM / PCIe / 纯 CPU 服务器自动识别

## License

本项目采用 [Apache License 2.0](LICENSE) 开源协议。

## 贡献

欢迎提交 Issue 和 Pull Request。

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/xxx`)
3. 提交更改 (`git commit -m 'feat: xxx'`)
4. 推送到分支 (`git push origin feature/xxx`)
5. 打开 Pull Request
