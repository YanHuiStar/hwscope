# 快速开始（Quick Start）

> [← 返回 README](../README.md) · 完整使用指南见 [USAGE.md](USAGE.md) · 报告与验收体系见 [REPORT.md](REPORT.md)

## 环境准备

- Linux x86_64 / aarch64（root 或 sudo 用户）；Windows 仅用于运维机侧工具（`tools/win/`）
- 依赖工具：`dmidecode`、`lspci`、`nvidia-smi`（GPU 机器）等。未安装的工具，其对应模块自动跳过，不影响整体采集；完整依赖清单与厂商工具（DCGM / MFT / storcli）安装步骤见 [DEPENDENCIES.md](DEPENDENCIES.md)
- 从 Windows 复制进来的文件先修复换行符：

```bash
bash fixcrlf.sh
```

## 全量采集

```bash
# 安装依赖工具（可选；交互菜单选 1 为基础采集工具。未安装的工具，其模块自动跳过）
sudo bash tools/install_tool.sh

# 执行全量采集（默认双层并行 + 完成计数；串行用 --serial）
sudo bash hwscope.sh
```

输出目录：`output/<机器ID>/`（机器 ID 取 SN，缺失时依次回退到主板 SN、UUID，最后用时间戳兜底）。

> BMC 带外采集参数（`--bmc-ip` / `--bmc-user` / `--bmc-auto` / `--no-bmc-auto`）与厂商默认账户见 [USAGE.md](USAGE.md) 的「BMC 带外采集」一节。

## 生成报告

采集完成后**自动生成**报告；也可对任意已有采集目录手动重跑（只读，不重新采集）：

```bash
bash report/report.sh <采集目录>              # 四件套 json/md/txt/html
bash report/report.sh <采集目录> --acceptance  # 验收清单（默认判定项按平台能力裁剪，另有 6 项条件项）
```

## 只采部分模块与单模块执行

```bash
sudo bash hwscope.sh --modules gpu,cpu       # 只采指定模块
sudo bash hwscope.sh --skip dcgm,nvsm        # 跳过指定模块
bash modules/04_gpu.sh /path/output          # 单模块（调试用）
```

> 单模块执行会覆盖目标目录内该模块的日志。对已有采集数据调试时，先复制一份副本并在副本上执行；`report/report.sh` 只读日志，可直接在原始目录运行。

## 远程采集（无需在目标机安装）

```bash
# Linux/WSL 运维机
bash tools/remote_collect.sh -H root@<target-IP>
bash tools/remote_collect.sh -H root@<target-IP> --install 1,2    # 冷启动：远端先装基础与压测依赖，再采集

# Windows 运维机（PowerShell 原生，与 sh 版功能等价）
tools\win\remote_collect.bat -H root@<target-IP>
powershell -ExecutionPolicy Bypass -File tools\win\remote_collect.ps1 -H root@<target-IP> -Modules gpu,cpu
```

默认交互式密码（不落盘），认证失败自动重试 3 次；结果回拉到 `output/remote_output/<机器ID>/`，归档包进 `logs/remote_logs/`。

## 清理采集输出

```bash
bash tools/cleanup.sh          # 列出目录与大小，输入 yes 确认后删除 output/ 与 logs/
bash tools/cleanup.sh --force  # 跳过交互确认（谨慎使用）
tools\win\cleanup.bat          # Windows 版
```
