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
bash report/report.sh <采集目录>              # 四件套 json/md/txt/html
bash report/report.sh <采集目录> --acceptance  # 验收清单（14 项判定，另有 5 项条件追加）
```

## 只采部分模块 / 单模块

```bash
sudo bash hwscope.sh --modules gpu,cpu       # 只采指定模块
bash modules/04_gpu.sh /path/output          # 单模块（调试用）
```

## 带外 BMC 采集（v1.53.45 起；v1.54.5 起地址自动探测）

带内（KCS `/dev/ipmi0`）只看得到本机 CPU 侧传感器；**FRU / SEL / 风扇转速 / 电源实时功率 / DCMI 功耗**要通过 BMC 网口（带外）才能拿全。

```bash
# ① 默认：从带内自动探测 BMC 地址（读 BMC 的 LAN 配置不需要密码）
sudo bash hwscope.sh
#   [INFO] 带内探测到 BMC 地址: 10.0.0.9（通道 8）
#   BMC 密码（回车跳过带外）:   ← 输入即采带外；直接回车只采带内

# ② 手动指定（探测不到，或指定某个通道的地址）
sudo bash hwscope.sh --bmc-ip 10.0.0.9 --bmc-user admin

# ③ HGX 双 BMC（主机 BMC 与基板 BMC 密码可不同，分别提示）
sudo bash hwscope.sh --bmc-ip 10.0.0.9 --hgx-bmc-ip 10.0.0.10

# ④ 只要带内
sudo bash hwscope.sh --no-bmc-auto
```

要点：

- **通道各家不同**（实测同一台机：`channel 1` = `0.0.0.0`、`channel 7` = `169.254.x`、`channel 8` = 真实管理口）。探测遍历 1–14 取第一个可用地址并**打印命中的通道号**；多个通道都有地址时全部列出，取第一个，要换用 `--bmc-ip`。
- 探测不到（全 `0.0.0.0` / `169.254` / 无带内权限）会**提示手输 IP**，20 秒无人应答自动跳过带外（`BMC_IP_PROMPT_TIMEOUT` 可调），不阻塞无人值守批量采集。
- **密码一律运行时输入**，不落盘、不进命令行/进程列表/日志；`BMC_PASS_TIMEOUT`（默认 300s；自动探测场景 20s）控制等待。
- 带外结果落 `bmc/remote_bmc_*.log`，报告「BMC」段合并展示；带内仍是默认路径，两者互补。

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
