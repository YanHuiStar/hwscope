# HwScope — Server Hardware Inspection & Data Collection System

![Version](https://img.shields.io/badge/Version-1.48.28-blue.svg) ![Platform](https://img.shields.io/badge/Platform-Linux%20x86__64%20%7C%20aarch64-lightgrey.svg) ![License](https://img.shields.io/badge/License-Apache%202.0-green.svg) ![GitHub](https://img.shields.io/badge/GitHub-YanHuiStar%2Fhwscope-181717.svg?logo=github) ![Last Commit](https://img.shields.io/github/last-commit/YanHuiStar/hwscope.svg)

面向 AI 基础设施运维与交付场景的**服务器硬件巡检系统**。针对 HGX 系列（H200/B200/B300）、PCIe GPU 服务器、AMD Instinct（ROCm）、华为昇腾（Atlas）及无 GPU 机头，以组件级粒度采集硬件信息，自动生成结构化报告与验收清单，支持远程采集（Linux/Windows）与多机对比。

## 核心特性

- **组件级采集**：主板/CPU/内存/GPU/NVSwitch/PCIe/网络/存储/RAID/HBA/电源/风扇/BMC/NVSM/DCGM/固件合规/能耗/OS 共 17 类模块，自动识别平台（SXM/PCIe/机头/传统）
- **报告四件套**：JSON + Markdown + TXT + **HTML**（浏览器交付版，零依赖）
- **验收清单**：15 项判定（含固件合规/OS-BMC 一致性/风扇冗余/PCIe 链路），条件驱动 N/A 计数，硬件概览自动生成配置单
- **GPU 魔改识别**：内置 60+ NVIDIA + AMD Instinct + 昇腾/Intel/国产型号额定显存规格库，检测值交叉验证，魔改/伪装卡自动 `⚠️` 提示
- **远程采集**：tar 推送执行回拉，Linux/WSL + **Windows 原生**均支持（交互式密码，不落盘）
- **只读无害**：采集不写硬件、报告不重新采集；GPU 健康诊断 NVIDIA=DCGM Level 1、AMD=ROCm、昇腾=npu-smi（v1.47.0 适配器框架，多厂商统一 CSV）
- **多机对比 / 配套运维**：批次一致性抽检、时序基线对比、能耗采样、固件基线、DHCP、批量运维、硬件压测

## 快速开始

```bash
# 全量采集（未安装的工具对应模块自动跳过）
sudo bash hwscope.sh

# 只采 / 跳过部分模块
sudo bash hwscope.sh --modules gpu,cpu   # 只采指定模块
sudo bash hwscope.sh --skip dcgm,nvsm    # 跳过指定模块

# 生成报告（采集后自动生成；也可对任意采集目录手动重跑）
bash report/report.sh output/<机器ID> --acceptance

# 远程采集（无需在目标机安装）
bash tools/remote_collect.sh -H root@10.0.0.1
bash tools/remote_collect.sh -H root@10.0.0.1 --install 1,2   # 先远端装基础+压测依赖再采集（冷启动）
tools\win\remote_collect.bat -H root@10.0.0.1   # Windows 运维机
```

## 文档

| 文档 | 内容 |
|------|------|
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | 快速开始：采集/报告/远程采集 |
| [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) | 依赖环境安装：全景依赖表/厂商工具/发行版差异 |
| [docs/USAGE.md](docs/USAGE.md) | 使用指南：全部命令/运维工具/压测 |
| [docs/REPORT.md](docs/REPORT.md) | 报告与验收体系：四件套/15 项判定/条件驱动 N/A |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构：目录结构/模块/平台兼容/安全约定 |
| [docs/TOOLS.md](docs/TOOLS.md) | 配套工具（test/ + tools/，Linux/WSL） |
| [docs/WIN_TOOLS.md](docs/WIN_TOOLS.md) | Windows 运维机工具（tools/win/，12 个） |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 路线图与版本归档 |

## 平台支持

- **采集**：Linux x86_64 / aarch64（root 或 sudo）
- **运维机工具**：Linux / WSL / Windows（`tools/win/`，零新依赖）
- **目标形态**：HGX B200/B300/GB300、PCIe GPU 服务器、AMD Instinct（ROCm）、HGX 机头、传统服务器、虚拟机

## 依赖与许可证

| 工具 | 用途 | 必需/可选 |
|------|------|----------|
| `dmidecode` · `lspci` · `ipmitool` | 主板/CPU/内存/PCIe/BMC 基础采集 | 必需（核心数据）|
| `nvidia-smi` · `nvswitch` | GPU / NVSwitch 采集 | GPU 机器必需 |
| `smartctl` · `ethtool` · `ibstat` 等 | 存储/网络/光模块增强 | 可选，缺失自动跳过 |

> 全部工具**未安装时对应模块自动跳过**（`[SKIP]`），不影响整体采集；安装见 [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)（全景依赖表 + 厂商工具步骤）。
> **合规**：hwscope 以进程调用方式使用上述工具，不修改、不捆绑、不分发；各工具版权归其作者。

[Apache License 2.0](LICENSE)
