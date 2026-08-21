# 架构与目录结构

## 采集流水线

```
hwscope.sh ─── 参数解析 / 平台检测（SXM → PCIe → head → none）
     │
     ├─ 并行执行 15 个采集模块（每模块独立进程、每命令一个日志）
     │      │  write_manifest 声明输出
     │      ▼
     │   output/<机器ID>/   （各模块子目录 + manifest.txt）
     │      │
     │      ▼
     ├─ summary.txt 汇总 → 归档 logs/<SN>-<TS>.tar.gz
     │
     ▼
tools/report.sh（只读日志，不重新采集）
     ├─ 读各模块 manifest 解耦定位日志
     ├─ hwscope_report.{json,md,txt,html}   报告四件套
     ├─ hwscope_acceptance.{md,html}        验收清单（13 项判定）
     └─ --baseline / --test-dir / --bmc-verify
```

**数据流**：采集（写日志）→ 报告（读日志）单向流动，模块零耦合、可单独重跑、可审计。

## 目录结构

```
hwscope/
├── hwscope.sh          # 主入口：参数解析、平台检测、并行执行、汇总、归档
├── lib/
│   ├── common.sh       # 公共函数：run_and_log / 并行执行 / check_cmd / 模块调度
│   ├── platform.sh     # 平台检测：detect_machine_id / detect_platform
│   └── nvlink.sh       # NVLink 拓扑解析库（纯解析）
├── modules/            # 17 个采集模块（01_motherboard … 16_power，99_os），每模块一物理组件
├── conf/
│   ├── hwscope.conf    # 模块开关、BMC 凭据、输出目录配置
│   └── fw_required.txt # 固件推荐版本基线（15_firmware 判定用）
├── test/               # 硬件压测脚本（cpu/memory/disk/network/ib/nccl），只测不改
├── tools/              # 运维操作脚本（Linux/WSL 侧）
├── tools/win/          # Windows 配套工具（.ps1/.bat）
├── docs/               # 详细文档（本目录）
├── output/             # 采集结果（gitignored）
└── logs/               # 压缩归档（gitignored）
```

## 平台兼容

| 平台 | 识别方式 | 说明 |
|------|---------|------|
| x86_64_SXM | nvidia-smi + NVSwitch | HGX B200/B300 一体化主机 |
| x86_64_PCIe | nvidia-smi 无 NVSwitch | PCIe GPU 服务器 |
| x86_64_head | PEX89/PEX97 Switchtec + 无 GPU | HGX 机头（模组单独采集） |
| x86_64_none | 无 GPU 无 Switch | 传统服务器/虚拟机 |
| aarch64_SXM | ARM + GPU | 国产/ARM 平台 |

机器 ID（目录命名）：SN → baseboard SN → UUID → 时间戳兜底（四层保证非空且路径安全）。

## 模块架构

- **采集/报告分离**：`modules/*.sh` 只生成数据；`tools/report.sh` 只读生成报告（不重新采集）
- **每命令一个日志**：可审计、可单模块重跑
- 模块自动跳过：工具未装 / 平台无此硬件（如虚拟机无 BMC）时 `[SKIP]`，不影响整体
- 依赖按需降级：dmidecode/lspci 缺失时系统汇总仍可用

## 输出结构

```
output/<机器ID>/
├── bmc/ cpu/ gpu/ memory/ storage/ network/ ...   # 各模块日志
├── hwscope_report.{json,md,txt,html}              # 报告四件套
├── hwscope_acceptance.{md,html}                   # 验收清单（--acceptance 生成）
├── summary.txt                                    # 采集汇总
└── hwscope.log                                    # 采集日志

output/remote_output/<机器ID>/                     # 远程采集回拉（对标本地结构）
logs/
├── <SN>-<TS>.tar.gz                               # 日志归档包
├── report/<SN>-<TS>-report.tar.gz                 # 报告包
└── remote_logs/                                   # 远程采集归档
```

## 安全约定

- **BMC 密码禁止 `-P` 内嵌命令**（明文进日志），必须 `export IPMI_PASSWORD` 传递
- 采集只读无害：不写硬件、不改配置；DCGM 仅 Level 1
- **隐私红线**：真实采集数据（SN/MAC/BMC IP）禁止进入 git，`output/`、`logs/` 已 gitignore
- report_server 绑定 `127.0.0.1`（防报告无鉴权暴露局域网）
- 远程采集：交互式密码不落盘；SSH key 免密仅限受信内部网络
