# 依赖环境安装指南（docs/DEPENDENCIES.md）

> [← 返回 README](../README.md) · 快速开始见 [QUICKSTART.md](QUICKSTART.md)
>
> HwScope 采用**进程调用**方式使用外部工具：采集时按模块 `check_cmd` 检测，**未安装的工具对应模块自动跳过**（`[SKIP]`），不影响整体采集。
> 本文档覆盖全部依赖的安装方法：包管理器一键装、install_tool.sh、以及厂商/手动工具（官方地址 + 步骤）。
> 快速路径：基础环境一条命令 `sudo bash tools/install_tool.sh`（选 1 基础采集工具）即可跑通采集；本文档用于**补齐全部能力**。

---

## 1. 依赖全景（按模块分组）

| 模块 | 工具 | 包名（apt / dnf）| 必需性 |
|------|------|------------------|--------|
| **核心基础** | `dmidecode` | `dmidecode` | 必需 |
| | `lspci` | `pciutils` | 必需 |
| | `ipmitool` | `ipmitool` | 有 BMC 时必需 |
| **04 GPU** | `nvidia-smi` | `nvidia-driver-*`（驱动自带，勿单独装）| GPU 机器必需 |
| **05 NVSwitch** | `nvswitch` | NVIDIA 平台包（见 §3.4）| SXM 平台 |
| | `nvidia-fabricmanager` | NVIDIA 平台包 | SXM 平台 |
| **06 PCIe** | `lspci`（同核心）| `pciutils` | 必需 |
| **07 网络** | `ethtool` | `ethtool` | 必需 |
| | `ibstat`/`ibstatus` | `infiniband-diags` | IB 机器 |
| | `ibv_devinfo` | `rdma-core` | IB 机器 |
| | `ibdev2netdev` | MFT（§3.2）| IB 机器 |
| | `lstopo` | `hwloc` | 可选（拓扑图）|
| | `mlxconfig`/`mlxlink`/`mlxfwmanager`/`mst`/`mstflint` | MFT（§3.2）| Mellanox 卡 |
| **08 存储** | `lsblk` | `util-linux`（系统自带）| 必需 |
| | `lsscsi` | `lsscsi` | 可选 |
| | `nvme` | `nvme-cli` | NVMe 盘 |
| | `smartctl` | `smartmontools` | 必需 |
| **09 RAID/HBA** | `storcli64` | 厂商工具（§3.3）| 有 RAID 卡 |
| | `sas3ircu`/`sas2ircu` | 厂商工具（§3.3）| 有 SAS HBA |
| **10 PSU / 11 风扇** | `ipmitool`（同核心）| `ipmitool` | 有 BMC |
| | `i2cdetect`/`i2cget` | `i2c-tools` | 可选（PSU PMBus）|
| | `sensors` | `lm-sensors` | 必需（风扇/温度）|
| **12 BMC** | `curl` | `curl`（系统自带）| 有 BMC |
| **13 NVSM** | `nvsm` | NVIDIA NVSM（§3.4）| HGX 平台 |
| **14 DCGM** | `dcgmi`/`nv-hostengine` | DCGM（§3.1）| GPU 机器 |
| **16 能耗** | `curl`/`ipmitool`（同核心）| — | 有 BMC |
| **99 OS** | `dmesg`/`systemctl` | `systemd`（系统自带）| 必需 |
| | `lsusb` | `usbutils` | 可选 |
| | `numactl` | `numactl` | 可选 |
| **压测 test/** | `stress-ng` `sysbench` `fio` `iperf3` `mtr` | 对应包名 | 压测场景 |
| | `ib_write_bw`/`ib_read_bw` | `perftest` | IB 压测 |

> `timeout`（coreutils）、`dmesg`、`lsblk`、`systemctl` 等为发行版基础组件，一般已存在，无需单独安装。

## 2. 一键安装（install_tool.sh）

```bash
sudo bash tools/install_tool.sh
```
菜单 9 项（自动识别 apt/dnf/yum；7-9 为实验态自动安装）：

| # | 安装项 | 包含 | 方式 |
|---|--------|------|------|
| 1 | 基础采集工具 | dmidecode pciutils ipmitool smartmontools lm-sensors | 包管理器 |
| 2 | 压测工具 | stress-ng sysbench fio iperf3 mtr | 包管理器 |
| 3 | IB 诊断工具 | infiniband-diags perftest rdma-core | 包管理器 |
| 4 | DCGM 诊断 | NVIDIA DCGM | **手动**（打印官方指引）|
| 5 | MFT 固件工具 | Mellanox Firmware Tools | **手动**（打印官方指引）|
| 6 | 推理引擎 | Triton / TensorRT-LLM | **手动**（打印官方指引）|
| 7-9 | DCGM/MFT/厂商 RAID 自动安装 | 自动安装代码 | **实验**（默认注释态，真机验证后取消注释启用）|

> RHEL/Rocky/Alma 的 stress-ng/sysbench/fio/iperf3 依赖 **EPEL 源**，装不上先执行：
> `sudo dnf install -y epel-release` 再重试。

## 3. 手动/厂商工具详解（install_tool.sh 覆盖不了的部分）

### 3.1 NVIDIA DCGM（GPU 健康监控/诊断，模块 14）

```bash
# Ubuntu（官方仓库）
sudo apt-get install -y datacenter-gpu-manager
# 或先加 NVIDIA 仓库再装（版本更全）：
#   https://developer.nvidia.com/datacenter/dcgm  → 按发行版选仓库配置命令

# RHEL/Rocky
sudo yum install -y datacenter-gpu-manager
```
安装后自启动 hostengine：`sudo systemctl enable --now nvidia-dcgm`（未启动时模块降级采集，仅 diag 可用）。

### 3.2 NVIDIA MFT（Mellanox 固件工具，模块 07 / cable_map / nic_tool）

官方下载页：`https://network.nvidia.com/products/adapter-software/firmware-tools/`
（需登录 NVIDIA 账号；RHEL 用 `.rpm`，Ubuntu 用 `.deb`）

```bash
# 以 Ubuntu 为例（实际文件名以下载页为准）
sudo dpkg -i mft-<版本>-x86_64-deb.tgz 提供的 .deb 包   # 或 sudo yum install mft-<版本>.rpm
# 或解压后运行安装脚本
sudo tar -xzf mft-*.tgz -C /opt && cd /opt/mft-* && sudo ./install.sh
mst status    # 验证：能列出 Mellanox 设备即成功
```
提供：`mlxlink`、`mlxconfig`、`mlxfwmanager`、`mst`、`mstflint`、`ibdev2netdev`。

### 3.3 厂商 RAID/HBA 工具（模块 09）

| 工具 | 适用 | 来源 |
|------|------|------|
| `storcli64` | Broadcom/MegaRAID 卡 | Broadcom 官网 → MegaRAID 存储管理器（公开下载，无需登录）|
| `sas3ircu` | LSI/Broadcom SAS3008 等 | Broadcom 官网 → 3 Series 适配器工具 |
| `sas2ircu` | LSI/Broadcom SAS2008 等 | Broadcom 官网 → 2 Series 适配器工具 |

下载 `.zip` 解压出二进制，复制到 `/usr/local/bin/` 并 `chmod +x` 即可（无依赖，纯静态二进制）。
> 未安装时 RAID 模块只出 lspci 层信息（控制器存在性），虚拟盘/物理盘明细缺失——**不安装不报错**，仅少数据。

### 3.4 SXM 平台专用（模块 05/13）

| 工具 | 说明 | 来源 |
|------|------|------|
| `nvswitch` | NVSwitch 管理 CLI | NVIDIA HGX 平台软件栈（随整机出厂镜像提供；无独立公开包）|
| `nvidia-fabricmanager` | Fabric 管理服务 | NVIDIA 官方仓库（与驱动同版本匹配）|
| `nvsm` | NVIDIA System Management | NVIDIA NVSM（HGX 平台包，随整机镜像）|

> 无独立 nvswitch CLI 的 B300/GB300 平台：模块自动降级走 `nvidia-smi nvswitch` 子命令（驱动 525+ 内置），**无需额外安装**。

## 4. 发行版差异速查

| 场景 | 命令 | 说明 |
|------|------|------|
| Ubuntu/Debian | `sudo apt install -y <包名>` | 默认源含全部核心依赖 |
| RHEL/Rocky/Alma 9 | `sudo dnf install -y <包名>` | **先装 EPEL**：`sudo dnf install -y epel-release`（stress-ng/sysbench/fio/iperf3 在 EPEL）|
| 旧 RHEL 系 | `sudo yum install -y <包名>` | 同上 |
| **离线/内网机房** | 外网机 `apt download`/`dnf download` 下载 .deb/.rpm → `scp` 到目标机 → `sudo dpkg -i *.deb` / `sudo dnf install -y *.rpm` | 交付现场无外网时的标准做法；厂商工具（storcli/MFT/DCGM）建议**提前下载好随 U 盘带进机房** |

## 5. 安装后验证

```bash
# 跑一次全量采集，看 [SKIP] 数量
sudo bash hwscope.sh 2>&1 | grep -E "\[SKIP\]|WARN" | head

# 针对性验证关键工具
dmidecode -t system | head -3        # 主板模块
nvidia-smi -L                          # GPU 模块
smartctl -V >/dev/null && echo OK      # 存储模块
storcli64 /c0 show | head -5          # RAID 模块（如装了）
mst status                             # Mellanox 工具（如装了）
```
装齐后应无 `[SKIP]`（无对应硬件/平台的模块除外，如无 IB 卡的机器跳过 IB 工具属正常）。
