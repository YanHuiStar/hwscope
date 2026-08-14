# AGENTS.md — HwScope 项目指南

HwScope (Hardware Scope) — 服务器硬件一键巡检采集系统。逐件、逐槽、逐端口采集物理组件信息，每命令一个日志。

## 项目概述

- Shell (bash) 编写的硬件巡检工具，Apache 2.0
- 支持 x86/ARM，SXM/PCIe/传统服务器自动识别
- 目标用户：AI 基础设施工程师（HGX B200/B300、GB300、IB 网络）
- 仓库: https://github.com/YanHuiStar/hwscope

## 目录结构

- `hwscope.sh` — 主入口：参数解析、平台检测、串行/并行执行、汇总、归档
- `lib/common.sh` — 公共函数：run_and_log / run_and_log_parallel / write_manifest / check_cmd / module_start / WARN 计数
- `lib/platform.sh` — 平台检测：detect_machine_id / detect_platform / ipmi_preheat
- `lib/nvlink.sh` — NVLink 拓扑解析库（纯解析，不执行命令；供 nvlink_verify.sh / report.sh 调用）
- `modules/*.sh` — 15 个采集模块（01_motherboard … 99_os），每个一物理组件
- `conf/hwscope.conf` — 模块开关、BMC 凭据、输出目录配置
- `test/` — 硬件压测脚本（cpu/memory/disk/network/ib/nccl），只测不改；`test_common.sh` 统一落盘 `logs/test/<时间戳>/`
- `tools/` — 运维操作脚本（BMC/网卡/安装），会修改系统
- `tools/win/` — Windows 配套工具（.ps1/.bat）
- `fixcrlf.sh` — Windows→Linux CRLF 换行符修复
- `output/` — 采集结果（gitignored），`logs/` — 压缩归档（gitignored）

## 常用命令

- 全量采集: `sudo bash hwscope.sh`（默认双层并行，旋转动画 + 完成计数；串行用 `--serial`；禁模块内并行用 `--no-parallel`）
- 只采部分: `sudo bash hwscope.sh --modules gpu,cpu`
- 跳光模块: `sudo bash hwscope.sh --no-module`
- 单模块: `bash modules/04_gpu.sh /path/output`
- CRLF 修复: `bash fixcrlf.sh`
- 语法检查: `bash -n <script.sh>`

## 版本号规则

格式 `v主.中.补`（Semantic Versioning），改动前先与用户确认升哪级：

| 层级 | 触发条件 | 示例 |
|------|---------|------|
| 主版本 | 输出结构不兼容、核心重构、删模块 | `1.2.0 → 2.0.0` |
| 中版本 | 新模块、新数据维度、新执行模式 | `1.1.1 → 1.2.0` |
| 补丁 | Bug 修复、小优化、文档 | `1.1.0 → 1.1.1` |

**规则：每次任务完成若有修改或新增文件，必须按上表升级版本号（补丁/中/主）。** 版本号唯一权威来源：`hwscope.sh` 的 `HWSCOPE_VERSION`。升版本只需改 hwscope.sh 一处，然后跑 `bash tools/sync_version.sh` 自动同步 README.md 徽章。当前惯例：功能改动与版本升级合并一条 commit，格式 `<type>: <摘要>; release vX.Y.Z`。

## README 更新规则

- README 与功能同步：新模块/新参数/新目录结构出现后，README 必须当天更新
- 快速开始保持可复制粘贴，命令必须真实可跑
- 模块总览表逐项对应 `modules/*.sh`，新增模块必加一行
- 版本升级时同步更新头部 `**Version:**` 与示例输出
- README 保持精简（当前 ~230 行），细节留给 AGENTS.md

## Git 提交规范

提交信息格式: `<type>: <摘要>`，摘要用英文，动词开头，一句话说清改动。

| type | 用途 | 示例 |
|------|------|------|
| `feat` | 新功能/新模块 | `feat: add memory_test.sh` |
| `fix` | Bug 修复 | `fix: platform detection fallback to lspci` |
| `docs` | 文档 | `docs: update README quick start` |
| `refactor` | 重构（行为不变） | `refactor: rename fix.sh to fixcrlf.sh` |
| `perf` | 性能优化 | `perf: skip module queries with --no-module` |
| `release` | 版本发布 | `release: v1.2.0 — add test/tools modules` |

规则：
- **改动完成立即 `git commit` 到本地**，不等待、不批量攒
- **不主动 `git push`** — 只有用户明确说"提交到远程/推送"才 push
- 当前惯例：功能改动与版本升级合并一条 commit，格式 `<type>: <摘要>; release vX.Y.Z`
- CRLF 等纯换行修复：`refactor` 或并入同主题 commit

## 报告与归档

- 采集完成自动调用 `tools/report.sh`：从各模块日志提取关键字段，生成 `hwscope_report.{json,md,txt}` 三件套（含明细表：内存每槽/GPU每卡/CPU每颗/存储每盘/网络每端口/PSU/SEL事件/风扇；内存明细含 Rank，PSU 明细含实时输入功率，网卡明细含 GPU直连 标记 + 报告末尾术语表；HBA 直通卡章节有卡才显示）
- **验收清单**：`bash tools/report.sh <out> --acceptance` 生成 `hwscope_acceptance.md`（8 项逐项 PASS/FAIL/WARN/N/A + 结论判定），交付时作为交接单；判定规则：有 FAIL=不合格、有 WARN=有条件通过、全 PASS=合格
- 报告**只读日志、不重新采集**，可对同一份数据反复生成；日志缺失字段显示 N/A
- 双压缩包：`logs/<SN>-<ARCHIVE_TS>.tar.gz`（详细分级日志）+ `logs/report/<SN>-<ARCHIVE_TS>-report.tar.gz`（报告三件套），共用同一 `ARCHIVE_TS` 变量（勿各自调 date，时间戳必须一致）
- 修改 report.sh 后必须用真实采集数据回归验证（桌面有 HGX B200 / B300 两份样例数据）

## 安全约定

- **BMC 密码禁止 `-P` 内嵌命令字符串**（会明文进日志 header / ps），必须 `export IPMI_PASSWORD` 后用干净命令（`bash -c` 子进程自动继承）
- `HGX_BMC_IP` 默认留空（防非 HGX 机器白连 192.168.1.1 浪费 24s+ 产生 WARN），SXM 平台自行填写
- 采集只读无害：不写硬件、不改配置；DCGM 仅 Level 1
- **隐私数据红线**：真实采集数据（服务器/机箱/GPU/内存 SN、MAC 地址、BMC IP 与凭据、SEL 日志等）**禁止进入 git 索引，更禁止 push 到远程**：
  - `output/`、`logs/` 已被 .gitignore 排除，**禁用 `git add -A` / `git add .`** 强制添加
  - 提交前必须 `git status` 审查；默认 `git add <指定文件>` 逐文件确认
  - push 前复查 `git ls-files`，确认无 `bmc/`、`gpu/`、`memory/` 等采集日志目录混入
  - 误提交已 push：立即在远程删除并重写历史（filter-repo），同时轮换受影响凭据
- 允许提交**脱敏示例数据**（SN/IP 替换为 FAKE 值，如 `FAKESN123`），禁止真实值
- **模拟/测试环境警示**（防重蹈覆辙）：开发/调试用的 mock 脚本、测试数据、辅助工具**可以用真实数据进行本地测试**，但**必须加入 `.gitignore`，禁止提交到仓库**；如需提交示例数据，必须用 FAKE 值（SN/IP 替换为 `FAKESN123` 等）
- **真实采集数据目录只读铁律**（v1.26.33 事故教训）：**禁止在真实采集数据目录上重跑采集模块**——`bash modules/07_network.sh <真实目录>` 会把 nic_inventory.csv 等覆盖成**当前环境**的数据（WSL 重跑 = WSL 空网卡覆盖真实 8 卡数据，MAC/SN 永久丢失且日志无备份）。规则：
  1. 验证采集/回退逻辑 → 先 `cp -r` 副本到 `/tmp/`，在副本上跑，**目录名带测试标记**（如 `/tmp/hwtest_<SN>_<用途>`）
  2. report.sh 是只读生成器（不改原始日志），可以直接在真实目录跑；**采集模块（modules/*.sh）必须副本测试**
  3. 覆盖前 `ls -la` 检查目标文件时间戳/大小，确认是预期目标而非真实数据
  4. 真实数据唯一恢复途径是**真机重采**（MAC/SN 等无日志备份），破坏前先确认有无备份

## Windows 配套工具（tools/win/）约定

- 定位：笔记本/运维机侧 PowerShell 工具（直连找 BMC/配网/DHCP/远程电源/批量运维），不参与服务器采集，改 Linux 侧代码无需动这里
- **编码（必须遵守，否则中文乱码/解析错）**：
  - `.ps1` 用 UTF-8 **带 BOM**（PowerShell 5.1 无 BOM 会把中文当 ANSI 解析乱码）
  - `.bat` 用 UTF-8 无 BOM + 首行 `chcp 65001 >nul`（cmd 中文显示正常）
  - 每个 .ps1 在 param 块后加 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`（管道/重定向中文不乱码）
- 新增/修改 .ps1 后必须 PowerShell 语法校验：
  `powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('<path>',[ref]$null,[ref]$e) > $null; $e.Count"`（输出 0 = 无错误）
- 交互式脚本尽量零依赖（纯 .NET/PowerShell 内置）；需要管理员权限的操作在脚本内自检并提示提升方式
- 每个工具提供同名 .bat 启动器（chcp 65001 + ExecutionPolicy Bypass + 管理员提升/参数透传）

## 新增模块流程

1. 创建 `modules/<NN>_<name>.sh`，定义 `run_<name>()` 函数
2. 加入 `hwscope.sh` 的 MODULES 注册表 + MODULE_SWITCH 开关
3. `conf/hwscope.conf` 加对应开关变量
4. 所有采集命令必须走 `run_and_log "cmd" "path.log"`（自动记录命令+退出码）；独立命令可用 `run_and_log_parallel N "cmd1" "log1" "cmd2" "log2" ...` 并行采集
5. 每个模块末尾调 `write_manifest "${dir}/manifest.txt" "key1" "file1" ...` 声明输出文件（report.sh 读 manifest 解耦）
6. 工具不存在用 `check_cmd` 检测后 `[SKIP]`，不中断
7. 版本号：主=输出不兼容，中=新模块/新功能，补=修复/文档

## 设计约束（勿违反）

- 只读无害：采集命令不写硬件、不改配置；DCGM 仅 Level 1 纯获取，无 GPU 压测负载
- **采集数据完整性（禁止截断）**：需要全量的数据必须全量落盘，采集命令只允许 grep 过滤，**禁止 head/tail 行数截断**（v1.25.5 踩坑：`head -80/100/200` 在 B300 高密度平台切断 PSU9/PCIe 链路信息，导致报告数据缺失且无法回溯）。仅以下语义允许截断：数据源本身是"最新 N 条/摘要"（如 dmesg 环形缓冲 `tail -200`、systemctl 状态 `head -40`、事件日志 `tail -100`、API 响应 `head -100`）。报告端按需截取展示，不丢原始数据
- 模块零耦合：每模块可独立执行，不依赖其他模块；模块通过 `write_manifest` 声明输出文件，report.sh 读 manifest 解耦（不硬编码文件名）
- 不用 eval（已踩坑：awk 变量展开 bug，统一用 bash -c）
- **run_and_log 转义层数**：cmd 字符串经 bash -c 双层解析，awk 内 `$` 变量写 `\$`（单反斜杠），**禁止 `\\$`（双反斜杠）**——会在第一层被 bash 展开成位置参数，set -u 下直接崩溃（v1.5.1 真机踩坑）
- locale 切换仅进程内，不修改系统环境
- 输出目录按 SN 命名，多机隔离；WARN 计数进 summary.txt

## 验证方式

- WSL 或真机运行 `sudo bash hwscope.sh`，检查 exit=0、日志生成
- 模块单独跑: `bash modules/04_gpu.sh /tmp/out`，对比日志完整性
- 平台检测验证: `bash hwscope.sh | grep Platform`，应为 xx_SXM/xx_PCIe/xx_none；SXM 四重检测（nvswitch CLI → lspci NVSwitch → nv-fabricmanager 进程 + NVLink 交叉验证）
- 变更后跑 `bash -n` 全量语法校验
- **WSL 真机测试**：`wsl -d Ubuntu` 同步项目到 `/opt/hwscope` 后 `bash hwscope.sh`（本机 StarMachine，RTX 5070，lspci/BMC 缺失属 WSL 预期）
- **HGX mock 模拟**：桌面数据 mock 命令（nvidia-smi/lspci/dmidecode 等）放 `/tmp/hwscope_mock/bin` 前置 PATH，可复现 HGX 场景（8×B200/B300、SXM 识别、24/32 槽内存）

## 常见陷阱

- **CRLF**: 从 Windows 拷贝后所有 .sh 会带 \r，bash 报 $'\r' 错误 → 先跑 fixcrlf.sh
- **grep exit=1** = 无匹配，不是错误（终端显示 [~]，不记 WARN）
- **locale**: 非 UTF-8 环境脚本自动尝试切换，日志头记录实际编码
- 并行模式模块输出走临时文件，完成后按注册表顺序拼接，勿直接写共享日志
- **模块头部注释编号必须与文件名一致**（07/08 曾漏修导致注释错位）
- **WSL 环境**：无 lspci → pcie 模块 SKIP 落盘 `00_skip_lspci.log`；虚拟盘不支持 SMART → storage 自动跳过，避免误报 WARN
- **报告解析**：report.sh 通过 manifest 解耦文件名（模块声明输出，report 读 manifest），但 grep/awk 提取仍依赖工具输出格式（如新版 nvidia-smi 的 `[Deprecated]` 提示、dmidecode 字段顺序），改解析逻辑必回归
