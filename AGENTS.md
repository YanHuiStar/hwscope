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
- `modules/*.sh` — 17 个采集模块（01_motherboard … 16_power，99_os），每个一物理组件
- `report/` — **报告模块（交付物本体，v1.35.0 自 tools/report.sh 拆分）**：`report.sh` 薄入口 + `lib/`（report_common 解析辅助 / gpu_spec 显存规格库 / md2html.awk）+ `sections/`（数据解析×9，source 顺序=原行序勿乱）+ `gen/`（生成器×7）+ `tools/`（batch_compare 多机对比 / report_server 在线预览）
- `conf/hwscope.conf` — 模块开关、BMC 凭据、输出目录配置
- `conf/fw_required.txt` — 固件推荐版本基线（15_firmware 模块判定 合规/落后 用，按厂商验收手册维护；全部注释 = 判未知不误报）
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
- **README 保持精简（~70 行）**：详细内容放 `docs/`（QUICKSTART/USAGE/REPORT/ARCHITECTURE/TOOLS），README 只放简介/特性/快速开始/文档导航；新功能文档优先写入 docs/ 对应文件，README 仅当核心特性变化时更新
- **工具文档同步铁律（v1.34.20 立规）**：`tools/`、`test/`、`tools/win/` 下**任何工具新增/改名/参数变化/输出变化**，必须同步更新：① 所在目录的详细文档（`tools/README.md` / `test/README.md`）② 概览索引 `docs/TOOLS.md` / `docs/WIN_TOOLS.md` ③ 若影响用法则 `docs/USAGE.md`——三处缺一不可（曾因 remote_collect 输出结构变化漏更 tools/README 致文档与实现不符）

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

## 多机器/多 Agent 协作规则（v1.37.2 立规）

> 同一仓库可能被**多台机器、多个 Agent 会话**（DeepSeek Harness / Hermes 等）先后修改提交推送。
> 各会话凭记忆操作会导致版本号回退/跳号、推送交叉。规则目标：**一切状态以远程 origin/main 为真相**，杜绝凭记忆。

- **开工前必跑** `bash tools/agent_sync.sh`（fetch + 显示 远程/本地 HEAD、版本、未推送数、版本对比；自动刷新本地状态文件）——每个会话一次，约几十 token
- **版本号只升不降**：升版本前先看 agent_sync 显示的**远程版本**，在远程版本基础上升（不要凭本地记忆）；`git_push.sh` 会硬拦截"本地版本 < 远程版本"的推送
- **推送一律走** `bash tools/git_push.sh -y`（默认 fetch + 落后 rebase + 版本单调检查），推送成功后跑 `bash tools/agent_sync.sh --clear`
- **提交后**跑 `bash tools/agent_sync.sh --mark`（本地状态文件 AGENT_STATE.md 标记未推送提交；该文件 gitignore，仅单机多会话协调用，不承担跨机器——跨机器以 fetch 为准）
- **多机器提示**：换机器开工同样先 agent_sync（fetch 到该机最新）；禁止"我以为远程是 vX"——以 agent_sync 输出为准
- 提交前 `git status` 审查只 add 本会话文件（禁 add -A，见安全约定）

## 报告与归档

- 采集完成自动调用 `report/report.sh`（报告体系为独立模块，见 `report/` 目录）：从各模块日志提取关键字段，生成 `hwscope_report.{json,md,txt,html}` 四件套（含明细表：内存每槽/GPU每卡(含VBIOS)/CPU每颗/存储每盘/网络每端口/PSU/SEL事件/风扇/RAID(虚拟盘级)/HBA；内存明细含 Rank，PSU 明细含实时输入功率 + DCMI/整机功耗独立行，网卡明细含 GPU直连 标记 + chip 列 + 报告末尾术语表；HBA 直通卡章节有卡才显示；**v1.29.0 新增**：固件合规段（15_firmware 输出，对照 fw_required.txt 判 合规/落后/较新/未知）、能耗台账段（16_power 输出，累计 kWh + 功耗快照）、BMC 数据一致性校验段（OS vs BMC 交叉校验，零新采集，不一致 WARN 并排显示两边值）、压测归档段（--test-dir 关联 test/ 目录，test_common.sh 写 manifest 解耦））
- **HTML 件**：`hwscope_report.html` 由 `report/lib/md2html.awk`（纯 awk 转换器，内嵌 CSS，零依赖）从 MD 转换生成——卡片分区/状态着色（PASS绿/WARN橙/FAIL红/N/A灰）/斑马纹表格/打印友好；验收清单同理生成 `hwscope_acceptance.html`；改 MD 模板后须回归 HTML 闭合（python HTMLParser 或浏览器验证）
- **GPU 额定显存规格库**：report.sh 内置 60+ 型号→额定容量映射（检测值交叉验证：GB 十进制/GiB 双口径 3% 容差自动匹配，多版本型号如 A100 40|80 自动选近者）；**匹配顺序=正确性**（长型号优先防子串误配：GH200 在 H200 前、L20 在 L2 前、A2 兜底防配 A2000、T4 兜底防配 T400）；检测与额定不符 → `⚠️ 疑似显存魔改或伪装`；新增型号加映射时注意 case 模式含空格须引号（`*"RTX 6000"*`）
- **动态列隐藏**：明细表整列全为占位符（—/N/A）时隐藏该列并附注说明（如"寿命%、健康 列因旧采集无 SMART 数据而隐藏"），有任一真实值即显示；JSON 始终保留全字段（程序消费稳定，不受隐藏影响）
- **验收清单**：`bash report/report.sh <out> --acceptance` 生成 `hwscope_acceptance.{md,html}`（硬件概览配置单表 + **14 项**逐项 PASS/FAIL/WARN/N/A + 结论判定），交付时作为交接单；14 项 = GPU PCIe/NVLink/DCGM/VBIOS/内存/线缆/磁盘寿命/SMART/电源冗余/温度/SEL/**风扇冗余**（v1.36.0：11_fan 采 Fan Redundancy 传感器，无风扇平台判 N/A 不计入、有风扇无冗余数据=采集缺失计入，判定同电源冗余）+ **固件版本合规**（15_firmware 输出：落后=FAIL、无基线判未知=N/A 不误报、较新不算落后）+ **OS-BMC 口径一致**（零新采集交叉校验：不一致=FAIL、仅单侧数据=WARN；**无 BMC 机器判 N/A 不计入数据不足**——IPMI 日志全错误=平台无 BMC 属固有形态，无任何 IPMI 日志=ipmitool 未装/模块关则如实计入数据不足）；配置单（准系统/CPU/内存/GPU模组/计算网卡/网卡&端口/存储/电源模块/系统管理）自动生成自检测数据，可对照采购配置单核对；判定规则：有 FAIL=不合格、有 WARN=有条件通过、N/A 计数≥4=数据不足；**条件驱动 N/A 计数**（v1.33.7-8，非一刀切）：场景/平台固有 N/A 不计入（无 GPU 机头、无 IB 卡或链路未接线、无数据盘、固件无基线、OS-BMC 未启用/无 BMC），真缺数据计入（已接线 Active 但无线缆数据、有盘无 SMART、有基线无固件数据、启用后采集失败）；**无 GPU 机头**的 GPU 相关 4 项（PCIe/NVLink/DCGM/VBIOS）判 N/A 且不计入"数据不足"（无 GPU 是平台固有形态，非数据缺失）
- 报告**只读日志、不重新采集**，可对同一份数据反复生成；日志缺失字段显示 N/A
- 双压缩包：`logs/<SN>-<ARCHIVE_TS>.tar.gz`（详细分级日志）+ `logs/report/<SN>-<ARCHIVE_TS>-report.tar.gz`（报告四件套），共用同一 `ARCHIVE_TS` 变量（勿各自调 date，时间戳必须一致）
- **时间戳格式统一约定**：全项目文件名时间戳一律 `date '+%Y%m%d%H%M%S'` **连写、无下划线、14 位纯数字**（如 `20260818001530`），输出目录后缀/归档包/test 目录/运维工具等全部一致（v1.33.1 复核 10 处无例外）。**依赖此格式的解析**：`report_server.sh` 的 SN 提取 `sed 's/-[0-9]\{14\}-report$//'`——若改时间戳格式（加下划线/分隔符），必须同步该正则与 README 输出目录示例（v1.33.1 教训：代码已改连写，README 示例漏同步仍写 `20260730_090000` 带下划线）
- 多机横向对比：`report/tools/batch_compare.sh <dir1> <dir2> ...` 读各机 hwscope_report.json 生成同字段对比表（差异 ⚠️ 标注），批次一致性抽检用
- 报告基线对比：`bash report/report.sh <cur> --baseline <prev>` 生成时序差异章节——标量（BIOS/CPU/内存/GPU数/VBIOS/BMC固件）变化 + SN 集合（GPU/盘/网卡）新增移除 + 固件版本逐项变化；**注意**：JSON 单行对象必须用 index() 定位键再取值（贪心 sub 会取行尾字段），含空格 key 必须 while read 逐行（for 会单词拆分）
- SSH 远程采集：`tools/remote_collect.sh -H user@host [hwscope 参数]`——**tar 暂存模式**（流式 bash -s 无法满足多文件 source 结构，v1.29.0 实测结论）：tar 临时推送项目 → 远端执行 → 结果回拉 → 清理；默认交互式密码（不落盘）+ ControlMaster 复用（输一次密码），禁 sshpass 明文密码；**认证重试**（ps1 每步认证失败自动重试最多 3 次，Linux 依赖 ssh 原生 3 次提示）；**root 免 sudo**（root@* 自动去 sudo），普通用户 + sudo 步骤带 `-t`（sudo 交互输密码）；**输出结构对标本地**：远端不传 --output（hwscope.sh 默认输出 output/<MACHINE_ID>/），回拉 tar `-C` 切换打包（output 内容 + logs）→ 本地落 `output/remote_output/<机器ID>/`（固定 remote_output 层 + SN 层），归档包 → `logs/remote_logs/`（与本地采集日志区分）；**Windows 版 `tools/win/remote_collect.ps1/.bat`**（v1.34.0+）功能等价（ssh/scp/tar 系统自带），**无 ControlMaster**（Windows OpenSSH 不支持，v1.34.2 实测 getsockname failed），3 次密码分步输入，ps1 须 UTF-8 BOM（PS5.1 无 BOM 中文注释乱码致语法错误）；远程采集输出目录命名由远端 detect_machine_id 保证非空（无 SN → UUID → 时间戳兜底）
- **v1.31.0 新增工具**：`fw_baseline_import.sh` 固件基线自动导入（基准机采集目录/表格 → fw_required.txt，--diff 预览/--apply 写入+自动 .bak 备份）；`power_monitor.sh` 能耗持续采样（后台循环 DCMI/Redfish → CSV，stop 输出小时/日聚合 + 梯形积分 kWh；子进程模式 = `bash $0 __sampler` 重跑本脚本，避免 export -f 依赖）；`report_server.sh` 报告在线预览（解包 logs/report/ 到 web/ + index.html + python3 http.server，零新依赖）；`remote_batch.sh` SSH 批量运维（-H 列表 + -c 命令/--push 推送，逐机 .out 落盘，默认交互式密码 + ControlMaster 复用）；`dhcp_server.sh` 扩展 `leases-export <csv>` + `reconcile <目录...>`（租约↔报告 JSON BMC IP/MAC 交叉核对；`--lease-file` 自定义租约路径；**主脚本顶层禁用 local**——非函数上下文报错）；`cleanup.sh`（v1.34.7，Windows 版 tools/win/cleanup.ps1/.bat）清理 output/ + logs/——显示大小/文件数 + 输入 yes 确认（--force 跳过），不碰源码
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
- **report_server 必须 `--bind 127.0.0.1`**：`python3 -m http.server` 默认监听 `0.0.0.0`，会把含 SN/MAC/BMC IP 的报告无鉴权暴露到局域网（v1.33.1 安全修复）；改动时勿移除 bind 参数，提示 URL 固定 127.0.0.1
- **模拟/测试环境警示**（防重蹈覆辙）：开发/调试用的 mock 脚本、测试数据、辅助工具**可以用真实数据进行本地测试**，但**必须加入 `.gitignore`，禁止提交到仓库**；如需提交示例数据，必须用 FAKE 值（SN/IP 替换为 `FAKESN123` 等）
- **真实采集数据目录只读铁律**（v1.26.33 事故教训）：**禁止在真实采集数据目录上重跑采集模块**——`bash modules/07_network.sh <真实目录>` 会把 nic_inventory.csv 等覆盖成**当前环境**的数据（WSL 重跑 = WSL 空网卡覆盖真实 8 卡数据，MAC/SN 永久丢失且日志无备份）。规则：
  1. 验证采集/回退逻辑 → 先 `cp -r` 副本到 `/tmp/`，在副本上跑，**目录名带测试标记**（如 `/tmp/hwtest_<SN>_<用途>`）
  2. report.sh 是只读生成器（不改原始日志），可以直接在真实目录跑；**采集模块（modules/*.sh）必须副本测试**
  3. 覆盖前 `ls -la` 检查目标文件时间戳/大小，确认是预期目标而非真实数据
  4. 真实数据唯一恢复途径是**真机重采**（MAC/SN 等无日志备份），破坏前先确认有无备份
- **删除走回收站（防误删）**：删除**未跟踪文件**（测试数据/临时脚本/本地产物）时，优先移入回收站而非直接 `rm`/`Remove-Item`，给恢复留后路：
  - Windows/pwsh：`Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,'OnlyErrorDialogs','SendToRecycleBin')`（文件）或 `DeleteDirectory(...,'SendToRecycleBin')`（目录）
  - Linux/WSL：装 `trash-cli` 用 `trash <路径>`（未装则删除前 `cp -r` 到 `/tmp/` 备份）
  - **git 托管文件**由版本历史兜底（`git rm` + commit 可恢复），无需走回收站；但删除前仍先 `git status` 确认范围
  - 例外：采集输出/日志等**已 gitignore 的批量产物**（output/logs）用 `tools/cleanup.sh` 统一清理（有确认环节），不逐文件回收站

## Windows 配套工具（tools/win/）约定

- 定位：笔记本/运维机侧 PowerShell 工具（直连找 BMC/配网/DHCP/远程电源/批量运维），不参与服务器采集，改 Linux 侧代码无需动这里
- **编码（必须遵守，否则中文乱码/解析错）**：
  - `.ps1` 用 UTF-8 **带 BOM**（PowerShell 5.1 无 BOM 会把中文当 ANSI 解析乱码）
  - `.bat` 用 UTF-8 无 BOM + `@echo off` 后第二行 `chcp 65001 >nul`（cmd 中文显示正常）
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
- **WSL sudo 重置 PATH**：`sudo bash hwscope.sh` 会因 secure_path 不含 `/usr/lib/wsl/lib` 而检测不到 nvidia-smi → GPU 误判 0；common.sh 已内置 `/usr/lib/wsl/lib` 路径兜底，改 GPU 检测逻辑勿移除
- **函数内 herestring 空读（MSYS bash quirk）**：`gen_json/gen_md/gen_txt` 等函数内 `while read ... done <<< "$VAR"` 在 MSYS/Git-Bash 下会空读（循环体不执行、明细数组全空）；统一用 `done < <(printf '%s\n' "$VAR")` 进程替换替代 herestring（v1.28.17 已全部替换，勿改回）
- **命令替换剥尾换行**：`VAR=$(cmd)` 会剥离输出末尾换行，直接 `while read ... <<< "$VAR"`/`printf '%s' "$VAR"` 会导致最后一行 read 返回非零、循环体不执行（丢最后一条明细）；进程替换必须用 `printf '%s\n'` 补尾换行
- **报告解析**：report.sh 通过 manifest 解耦文件名（模块声明输出，report 读 manifest），但 grep/awk 提取仍依赖工具输出格式（如新版 nvidia-smi 的 `[Deprecated]` 提示、dmidecode 字段顺序），改解析逻辑必回归
- **perftest 模式判定**：`ib_write_bw/ib_read_bw` **无地址参数 = server 模式，带地址 = client 模式**；`-S` 是 `--sl`（服务等级）不是 server 标志——server 端勿加 `-S`（v1.33.4 教训：第三方工具参数建议必须查 man/help 核验后再采纳）
- **awk 数值守卫须先 trim**：nvidia-smi CSV 值带前导空格（` 700.00 W`），`^[0-9.]+$` 守卫会全拒 → 功耗/温度全 N/A；须先 `gsub(/^ +| +$/, "", v)` 再校验（v1.33.5 回归修复）
- **smartctl Transport protocol 值判断**：SATA 盘输出也有 `Transport protocol: SATA` 行，判 SAS 必须匹配值（`Transport protocol:.*SAS`）而非仅匹配行名（v1.33.4 修正）
