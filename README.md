# HwScope — Server Hardware Inspection & Data Collection System

![Version](https://img.shields.io/badge/Version-1.54.37-blue.svg) ![Platform](https://img.shields.io/badge/Platform-Linux%20x86__64%20%7C%20aarch64-lightgrey.svg) ![License](https://img.shields.io/badge/License-Apache%202.0-green.svg) ![GitHub](https://img.shields.io/badge/GitHub-YanHuiStar%2Fhwscope-181717.svg?logo=github) ![Last Commit](https://img.shields.io/github/last-commit/YanHuiStar/hwscope.svg)

面向 AI 基础设施运维与交付场景的**服务器硬件巡检系统**。适用于 HGX 系列（H200/B200/B300）、PCIe GPU 服务器、AMD Instinct（ROCm）、华为昇腾（Atlas）及无 GPU 机头，按组件粒度采集硬件信息，自动生成结构化报告与验收清单，支持远程采集（Linux/Windows）与多机对比。

## 核心特性

- **组件级采集**：主板 / CPU / 内存 / GPU / NVSwitch / PCIe / 网络 / 存储（RAID/HBA）/ 电源 / 风扇 / BMC / NVSM / DCGM / 固件合规 / 能耗 / OS 共 17 个模块；自动识别平台形态（`x86_64_SXM`、`x86_64_OAM`、`x86_64_PCIe`、`x86_64_head`、`x86_64_none`）
- **报告四件套**：JSON + Markdown + TXT + HTML（浏览器交付版，零依赖）
- **验收清单**：默认判定项最多 17 项（按平台能力裁剪，无数据项不渲染），另有 6 项仅在检出时追加的条件项（采集时机 / PCIe AER 错误 / CPU MCE / GPU XID 错误历史 / GPU 功耗上限 / RAID 缓存电池）；平台固有 N/A 折叠为表尾汇总且不计入「数据不足」；硬件概览自动生成配置单
- **GPU 魔改识别**：内置 60 余款型号的额定显存规格库，覆盖 NVIDIA、AMD Instinct 及昇腾 / Intel / 国产型号（后三类的厂商串待真机核对），检测值与额定值交叉验证，疑似魔改或伪装的卡标注 `⚠️`
- **远程采集**：tar 推送执行回拉，Linux/WSL 与 Windows 原生环境均支持（交互式密码，不落盘）
- **只读无害**：采集不写硬件，报告不重新采集；GPU 健康诊断按厂商分流——NVIDIA 用 DCGM Level 1、AMD 用 ROCm、昇腾用 `npu-smi`（适配器框架统一 CSV 输出）
- **多机对比与配套运维**：批次一致性抽检、时序基线对比、能耗采样、固件基线、DHCP、批量运维、硬件压测（状态：占位，未完成）

## 快速开始

```bash
# 全量采集（未安装的工具，其对应模块自动跳过）
sudo bash hwscope.sh

# 只采指定模块 / 跳过指定模块
sudo bash hwscope.sh --modules gpu,cpu
sudo bash hwscope.sh --skip dcgm,nvsm

# 生成报告（采集完成后自动生成；也可对已有采集目录手动重跑，只读不重采）
bash report/report.sh output/<机器ID>              # 四件套 json/md/txt/html
bash report/report.sh output/<机器ID> --acceptance  # 验收清单 md/html

# 模块开关 / BMC 凭据 / 输出目录：conf/hwscope.conf（默认全开，工具缺失自动跳过）
# BMC 带外采集参数（--bmc-ip / --bmc-user / --bmc-auto / --no-bmc-auto）见 docs/USAGE.md

# 远程采集（无需在目标机安装）—— Linux/WSL 运维机
bash tools/remote_collect.sh -H root@<target-IP>
bash tools/remote_collect.sh -H root@<target-IP> --install 1,2    # 冷启动：远端先装基础与压测依赖，再采集

# 远程采集 —— Windows 运维机（PowerShell 原生，与 sh 版功能等价）
tools\win\remote_collect.bat -H root@<target-IP>
```

## 文档

| 文档 | 内容 |
|------|------|
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | 快速开始：采集 / 报告 / 远程采集 |
| [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) | 依赖环境安装：全景依赖表 / 厂商工具 / 发行版差异 |
| [docs/USAGE.md](docs/USAGE.md) | 使用指南：全部参数 / 运维工具 / 压测 |
| [docs/REPORT.md](docs/REPORT.md) | 报告与验收体系：四件套 / 判定项 / 条件驱动 N/A |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构：目录结构 / 模块 / 平台兼容 / 安全约定 |
| [docs/TOOLS.md](docs/TOOLS.md) | 配套工具（test/ 与 tools/，Linux/WSL） |
| [docs/WIN_TOOLS.md](docs/WIN_TOOLS.md) | Windows 运维机工具（tools/win/，13 个） |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 路线图与版本归档 |

## 平台支持

- **采集**：Linux x86_64 / aarch64（root 或 sudo）
- **运维机工具**：Linux / WSL / Windows（`tools/win/`，零新依赖）
- **目标形态**：HGX B200/B300/GB300、PCIe GPU 服务器、AMD Instinct（ROCm）、HGX 机头、传统服务器、虚拟机

## 依赖与许可证

| 工具 | 用途 | 必需/可选 |
|------|------|----------|
| `dmidecode` · `lspci` · `ipmitool` | 主板 / CPU / 内存 / PCIe / BMC 基础采集 | 必需（核心数据）|
| `nvidia-smi` · `nvswitch-audit` | GPU / NVSwitch 采集（`nvswitch-audit` 随 `nvidia-fabricmanager` 提供）| GPU 机器必需 |
| `smartctl` · `ethtool` · `ibstat` 等 | 存储 / 网络 / 光模块增强 | 可选，缺失自动跳过 |

> 工具未安装时，其对应模块以 `[SKIP]` 跳过，不影响整体采集；安装方法见 [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)（全景依赖表与厂商工具步骤）。
> **合规**：hwscope 以进程调用方式使用上述工具，不修改、不捆绑、不分发；各工具版权归其作者。

[Apache License 2.0](LICENSE)
