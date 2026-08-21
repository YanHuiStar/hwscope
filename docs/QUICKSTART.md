# 快速开始（Quick Start）

> [← 返回 README](../README.md) · 完整使用指南见 [USAGE.md](USAGE.md) · 报告与验收体系见 [REPORT.md](REPORT.md)

## 环境准备

- Linux x86_64 / aarch64（root 或 sudo 用户）；Windows 仅用于运维机侧工具（`tools/win/`）
- 依赖工具：`dmidecode`、`lspci`、`nvidia-smi`（GPU 机器）等——**未安装的工具对应模块自动跳过，不影响整体采集**；完整依赖清单与厂商工具（DCGM/MFT/storcli）安装步骤见 [docs/DEPENDENCIES.md](DEPENDENCIES.md)
- Windows 复制进来的文件先修复换行符：

```bash
bash fixcrlf.sh
```

## 全量采集

```bash
# 安装依赖工具（可选；交互菜单选 1 基础采集工具，未装的模块自动跳过）
sudo bash tools/install_tool.sh

# 执行全量采集（双层并行 + 完成计数；串行用 --serial）
sudo bash hwscope.sh
```

输出目录：`output/<机器ID>/`（机器 ID = SN → 主板 SN → UUID → 时间戳兜底）。

## 生成报告

采集完成后**自动生成**报告；也可对任意已有采集目录手动重跑（只读，不重新采集）：

```bash
bash report/report.sh <采集目录>              # 四件套 json/md/txt/html（旧路径 tools/report.sh 兼容）
bash report/report.sh <采集目录> --acceptance  # 验收清单（13 项判定）
```

## 只采部分模块 / 单模块

```bash
sudo bash hwscope.sh --modules gpu,cpu       # 只采指定模块
bash modules/04_gpu.sh /path/output          # 单模块（调试用）
```

## 远程采集（无需在目标机安装）

```bash
# Linux/WSL 运维机
bash tools/remote_collect.sh -H root@10.0.0.1

# Windows 运维机
tools\win\remote_collect.bat -H root@10.0.0.1
```

默认交互式密码（不落盘），认证失败自动重试 3 次；结果回拉到 `output/remote_output/<机器ID>/`。

## 清理采集输出

```bash
bash tools/cleanup.sh          # 输入 yes 确认删除 output/ 与 logs/
tools\win\cleanup.bat          # Windows 版
```
