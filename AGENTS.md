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
- `test/` — 硬件压测（聚合与实现解耦，v1.41.3）：`test_all.sh` 纯聚合入口（菜单/--all）+ `test/<组件>/` 单工具脚本（可独立执行，如 `test/cpu/cpu_stress_ng.sh`）+ `lib/test_common.sh` 公共库（落盘 `logs/test/<SN>/`）；只测不改
- `tools/` — 运维操作脚本（BMC/网卡/安装），会修改系统
- `tools/agent/` — **开发协作工具（agent/开发者用，agent 流程调用）**：`git_push.sh`/`.bat`（一键推送）、`agent_sync.sh`（多机/多会话状态同步）、`report_regression.sh`（报告解析回归 + 基线比对）、`regen_reports.sh`（批量重生成报告）、`repo_realign.sh`（历史重写后的仓库体检/对齐）、`sn_check.sh`（提交前 SN/MAC 自检）；**说明见 `tools/agent/README.md`**；Launch-DeepSeekHarness 属用户手动启动，留 `tools/win/`
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
- 模块总览表在 `docs/USAGE.md`「采集」章节（v1.43.11 起，README 精简化后落点），逐项对应 `modules/*.sh`，新增模块必加一行
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
- **不主动 `git push`** — 只有用户明确说"提交到远程/推送"才 push，且**必须走 `git_push.sh`**（已内置防死循环：4s 网络预检 + 3 败熔断冷却 + `[PAUSE]` 失败纪律，见协作规则章节；裸 `git push` 禁用）
- 当前惯例：功能改动与版本升级合并一条 commit，格式 `<type>: <摘要>; release vX.Y.Z`
- CRLF 等纯换行修复：`refactor` 或并入同主题 commit

## 多机器/多 Agent 协作规则（v1.37.2 立规）

> 同一仓库可能被**多台机器、多个 Agent 会话**（DeepSeek Harness / Hermes 等）先后修改提交推送。
> 各会话凭记忆操作会导致版本号回退/跳号、推送交叉。规则目标：**一切状态以远程 origin/main 为真相**，杜绝凭记忆。

- **开工前必跑** `bash tools/agent/agent_sync.sh`（fetch + 显示 远程/本地 HEAD、版本、未推送数、版本对比；自动刷新本地状态文件）——每个会话一次，约几十 token
- **版本号只升不降**：升版本前先看 agent_sync 显示的**远程版本**，在远程版本基础上升（不要凭本地记忆）；`git_push.sh` 会硬拦截"本地版本 < 远程版本"的推送
- **推送一律走** `bash tools/agent/git_push.sh -y`（默认 fetch + 落后 rebase + 版本单调检查），推送成功后跑 `bash tools/agent/agent_sync.sh --clear`
- **推送预检已降级为「提示」而非「判决」（v1.48.92）**：`git_push.sh` 的网络预检探的是 `https://github.com`（**首页**），而 git push 走 `/<owner>/<repo>.git` 的 **git 端点**——**不是同一条路径**（首页 curl 还被 schannel 的 `server closed abruptly` 拖累）。实测**连续两次**同一时刻：预检判「直连+代理均不可达」，紧接着手工 `git push` 20s 内成功。故预检失败**不再直接放弃推送**，而是记为 `pre_degraded` 并继续：只试 **1 次**直连（不盲试 3 次，省 ~42s）→ 失败转代理兜底 → 仍失败才按真实失败上报。熔断（连续 3 次失败 → 5 分钟冷却）保留，防真断网空转。**判断依据**：`[WARN] 网络预检未通过` 后若出现 `[OK] 推送成功` 即为该情形；若真实推送也失败，再看 `[FAIL]/[PAUSE]` 按 v1.45.9 纪律上报用户。超时仍可调：`GIT_PUSH_PRECHECK_TIMEOUT`（默认 15s）。
- **推送失败处理纪律（v1.45.9 立规，防浪费 token/积分）**：git_push 输出 `[PAUSE]` 指令后**禁止自动重试**——网络不通是用户侧问题（代理节点/网络状态），盲目重试每轮空转烧 token。失败后：① 停止推送尝试 ② 把失败原因**上报用户**（"推送失败，请检查代理节点/网络，确认后我再推"）③ 等用户明确说『推送/重试』或确认网络恢复后才重新运行。git_push 已内置 4s 网络预检 + 连续 3 次失败 5 分钟熔断冷却（冷却期内调用秒败）
- **提交后**跑 `bash tools/agent/agent_sync.sh --mark`（本地状态文件 AGENT_STATE.md 标记未推送提交；该文件 gitignore，仅单机多会话协调用，不承担跨机器——跨机器以 fetch 为准）
- **多机器提示**：换机器开工同样先 agent_sync（fetch 到该机最新）；禁止"我以为远程是 vX"——以 agent_sync 输出为准
- **历史重写后同步（v1.48.28 立规，SN 泄漏清除等 force-push 重写历史场景）**：**v1.48.75 起首选脚本 `bash tools/agent/repo_realign.sh`**（体检 / `--sync` 纯同步机 / `--protect[ --auto]` 有本地提交自动备份+逐提交扫 SN 再搬回）；手动流程如下（排障参考）。远程历史被重写后，所有旧 clone 本地历史分叉——`git pull`/`git push`/git_push 的 rebase 全部失败（报"不会快进"/分叉）。
  - **无本地独特未推提交（以同步远程为主）**：统一一次性处理
    ```bash
    git fetch --force origin && git reset --hard origin/main && git log --oneline -1
    ```
    重置后文件内容与远程一致（重写只改 commit hash 不变内容）。
  - **本地有未推提交/未提交改动（笔记本等开发机）**：先保护现场再对齐，逐提交检查 SN：
    ```bash
    git branch backup-$(date +%s)        # ① 备份当前分支（含本地提交）
    git stash push -u                    # ② 暂存未提交改动（含未跟踪）
    git fetch --force origin
    git reset --hard origin/main         # ③ 对齐新远程
    # ④ 逐提交搬回（先查是否触及 SN 相关文件/内容，有则先清理再搬）
    git show <未推提交> --stat | grep -iE "<SN 模式，如厂商前缀+数字>|baseline"   # 检查
    git cherry-pick <未推提交>
    git stash pop                        # ⑤ 恢复未提交改动
    ```
    **禁忌**：不要直接 `git rebase origin/main` 盲目搬——rebase 重放可能重新引入旧历史中的 SN 文件名/内容（本地提交若改过基线/ROADMAP 等）。
- 提交前 `git status` 审查只 add 本会话文件（禁 add -A，见安全约定）

## 环境故障止损纪律（v1.45.11 立规，Windows/git-bash 实测教训）

> 2026-08-26/27 实录：Agent 在环境故障上反复重试消耗大量 token/积分后总结。核心原则：**环境类故障一次尝试失败即停，上报用户等指示**——重试不解决网络/杀软/系统问题，只烧积分。**具体症状与对策（MSYS 管道吞缓冲输出、未引号 heredoc 吃反斜杠致条件静默失效、PowerShell `$x = & cmd` 缓冲输出、curl HEAD 经代理误判断网、filter-repo 不改 commit message 等）见 `docs/AGENT_ENV.md`。**

- **推送失败 = 用户侧问题**：网络不通（代理节点/断网）时重试每轮空转 ~90s+ 大量 token。git_push 已内置 4s 预检 + 3 败熔断；输出 `[PAUSE]` 后禁止再碰，上报原因即止（详见上节 v1.45.9 纪律）
- **MSYS bash fork 崩溃识别**（git-bash 特有）：特征 = 命令**静默 exit 1 且零输出**（连开头的 echo 都不执行）或 stderr 报 `dofork: child died ... 0xC0000142` / `Resource temporarily unavailable`。规律：`ls`/`cat`/`grep` 等直接 exec 的命令正常，**fork 类全崩**（子 bash、`$( )` 密集脚本、git 复杂操作）。应对：**立即停全部操作上报用户**（多为杀软实时扫描锁定 DLL，通常分钟级自愈；曾实测 60s 后恢复）——静默失败时最容易犯的错误是以为代码有 bug 反复排查重跑，实际是环境
- **环境不稳期间禁做写 git 元数据的操作**：`git stash`/`git reset` 撞上 fork 崩溃会损坏仓库（实录：refs/ 目录丢失 + .pack 文件消失 → "not a git repository"）。环境异常时：改动用 `git commit` 固化或 `cp` 备份文件到仓库外，**不用 stash**；只用只读 git 命令（log/diff/status）
- **仓库损坏恢复路径**（万一发生）：源码文件不受 .git 损坏影响（工作区零丢失）——① `mkdir -p .git/refs/heads .git/refs/tags` ② `git -c http.proxy=http://127.0.0.1:<端口> fetch origin`（走系统代理，端口见 Windows Internet 选项）③ `git update-ref refs/heads/main <远程HEAD>` ④ `rm -f .git/index && git reset`（重建 index，不动工作区）⑤ 重新 commit
- **Windows 杀软是环境故障首要嫌疑**：.pack 被隔离 + DLL 锁定（fork 崩溃）同时发生基本可断定。建议用户把项目目录与 Git 安装目录加入杀软白名单（根治）；`echo > /dev/tcp/127.0.0.1/<port>` 可探测代理端口（常见 7890/7897/10809/1080）
- **MSYS 下 native 命令的空设备陷阱（v1.48.67 立规）**：git-bash 里把 `/dev/null` **作为参数**传给 native 程序（如 `curl -o /dev/null`）会被路径转换导致写入失败，curl 退出码 **23（CURLE_WRITE_ERROR）**；叠加 `set -o pipefail`，`curl ... | grep -q` **整条判定为失败**——症状是 **HTTP 200 却永远"网络预检失败"**（`git_push.sh` 长期误报断网的真根因，实测同命令手工跑退出码 23 被忽略、只看状态码就误判"可用"）。**规则**：① 传参用 `NUL`（Windows）/`/dev/null`（Linux），按环境变量区分（非参数位置的 `>/dev/null` 由 bash 处理，安全）② 排查网络类"预检失败"时**必须同时看 HTTP 状态码和退出码**，两者矛盾即命中此类陷阱 ③ 同一命令在 git-bash 与 PowerShell 行为不同时（本机实测 HEAD 请求 git-bash 000 / PowerShell 200），优先信 PowerShell 的结果，别在 MSYS 行为差异上反复试
- **长任务前先说风险**：执行含大量 fork 的脚本（report.sh 等含数百个 `$( )`）前，告知用户"Windows 下有 fork 崩溃风险，失败即停"；失败一次后不重试，改用静态验证（`bash -n` 语法 + 抽取核心 awk/grep 逻辑单独验证）交付结论
- **计算网卡 / DPU 归类判据 = 物理直连，不是协议模式（v1.48.85 立规，用户口径）**：配置单里「计算网卡」的定义是 **GPU 直连的网卡**（`nvidia-smi topo -m` 的 `PIX` = 与 GPU 同 PCIe switch），**不是「当前跑 IB 模式的口」**——协议模式（IB/ETH）随时可配，物理直连是固定的。归类顺序：① **DPU 优先**（BlueField 系列，它可能同时 GPU 直连，先判避免两桶重复计数）② **GPU直连** → 计算网卡 ③ 其余 → 网卡&端口。**数量单位用「口」**：`NIC_DETAILS` 每行是一个网络端口，双口卡占两行。
  - 教训：旧实现按接口名 `^ib` 归类（v1.43.10 起）。实测 B200-sample-c 上 **18 口真 GPU 直连网卡全跑 ETH 模式**，被划入「以太」；而**唯一跑 IB 的 CX-7**（PCIe 仅 x2、物理位置 M2_1、不在 GPU 域）反被当成计算网卡——判据反了。
  - **GPU 直连 = `PIX` 或 `PXB`（v1.48.86 放宽）**：NVIDIA 拓扑距离分级里，`PIX`（同一 PCIe switch）与 `PXB`（跨多个 switch 但同处一个 PCIe 域、不经 CPU）**都属「本地」连接**，是 GPUDirect RDMA 的可用形态；`PHB`/`NODE`/`SYS` 才经 CPU。**只认 `PIX` 会漏判老 HGX 平台**：实测 A100 HGX（A100-sample-a）4 口 CX-6 计算网卡全为 `PXB`（经 PLX switch 上连），无一条 `PIX`，导致「GPU直连」整列隐藏、计算网卡行消失。**且必须叠加卡型过滤**（`ConnectX-6/7/8`、`BlueField`）——`PXB` 会把同 PCIe 域的非计算卡一并纳入（实测该机 `MCX556A-ECAT`（CX-5）也是 `PXB`）。
    **必须保留「无 topo 时按接口名回退」分支**（`GPU_TOPO_AVAIL != 1` 且接口名 `^ib`）：**AMD / 昇腾平台没有 `nvidia-smi topo`**，`GPU_DIRECT_NIC` 恒为空，若不回退会把这类平台的计算网卡整批丢进「网卡&端口」——实测 AMD MI300X（AMD-sample-a）8 口 CX-7 400G 计算网卡因此全部消失。分工：**有 topo → 用物理直连（准确）；无 topo → 用 IB 协议口兜底（可用）**。
  - **topo 尾部的 `NIC<n>: mlx5_<m>` 对照表是权威映射**，**禁止假设「NIC 列序 = 网卡 BDF 升序」**——topo 只列出具备 RDMA 能力的口，列数与网卡口数不等时按序硬对必然错位（实测 18 列 vs 26 口，导致 X710 管理口被误标 GPU直连、部分 MCX 反而漏标）。老版本无对照表时降级走旧逻辑。
  - **BlueField 识别走 lspci 型号串**：`ibstat` 的 `CA type` 是 SoC 编号（MT41692），**不含 BlueField 字样**；lspci 写作 `MT43244 BlueField-3 integrated ConnectX-7`（**裸文本、无方括号**——正则不能要求方括号）。且型号提取必须**对所有接口生效**，不能锁在 `ibp*/ibs*` 分支里（BlueField 的接口名是 `ens*`）。
- **`--acceptance` 只生成验收清单，不含报告四件套（v1.48.91 立规）**：`report.sh <dir>` 与 `report.sh <dir> --acceptance` 是**两个独立分支**（`case "$FORMAT"` 里 `--acceptance) gen_acceptance ;;`），**批量重生成必须调用两次**，否则只刷新 `hwscope_acceptance.{md,html}`，而 `hwscope_report.{json,md,txt,html}` 仍是采集时那一份——表现是「验收判定变了、报告内容没变」，极易误判为"改动没生效"。**判断方法**：看报告头部 `**报告生成器:** vX.Y.Z` 是否等于当前版本，以及文件 mtime 是否更新。参考实现见 `tools/agent/regen_reports.sh`（两次调用）。
- **IPMI 超时统一为可配置的 `IPMI_TIMEOUT`（默认 30s，v1.48.91 立规）**：此前各模块硬编码 `timeout 10`（10_psu/11_fan/12_bmc/16_power），对 BMC 响应慢的平台不够——实测技嘉 B200 五台机上各有 **10~13 个 IPMI 命令在 10s 内全部超时**（`ipmi_sensors`/`sdr`/`fan_*`/`psu_*`/`sensors_temp` 全线 `exit=124`），导致风扇/温度/PSU 冗余三项落成「采集失败」，其中一台因此 N/A 达 4 项、跨过「≥4 项 = 数据不足」阈值而无法验收。**规则**：统一由 `lib/common.sh` 的 `IPMI_TIMEOUT="${HWSCOPE_IPMI_TIMEOUT:-30}"` 提供，模块内写 `timeout ${IPMI_TIMEOUT:-30}`（保留兜底，独立跑模块时不 source common.sh 也安全）；新增 IPMI 命令一律引用该变量，禁止再写死数值。**调大默认值的代价可控**：`timeout` 只对**卡住的命令**生效，正常命令 1s 内返回就不会等满 30s，所以对健康 BMC 的采集耗时几乎无影响，只让慢 BMC 有机会把数据取回来。
- **NVMe 错误必须按 `status_field` 分类，不能只数「非零错误」（v1.48.96 立规，验收误报事故）**：`nvme error-log` 里两类错误性质完全不同，混在一起数会误报。**实测**：B300（B300-sample-a）`nvme0n1`/`nvme1n1` 各有 1~2 条 `0x6002 Invalid Field in Command`，被渲染成「⚠️ 2 块盘有非零错误」，像盘要坏；但细看字段 `opcode=0`、`lba=0xffffffffffffffff`、`parm_err_loc=0x28`——**没有任何读写失败**，是主机侧发了固件不支持的管理命令（典型成因：nvme-cli/libnvme 比盘固件新）。**分类规则**（`status_field` 低 12 位，`0x6x` 前两位是固定前缀，后 3 位为 status code）：① **通用类 `0x0xx`**（Invalid Field/Opcode/Namespace）→ **主机侧命令不兼容 → 仅提示，不计 WARN**；② **介质/掉电类 `0x28x`**（Unsafe Shutdown / Write Fault / Unrecovered Read / Data Protection）→ **盘自身或供电问题 → 报 ⚠️ WARN**，且文案要区分：「非正常掉电（建议排查供电/拔盘历史）」vs「介质错误（建议复查该盘）」；③ **无法归类 → 保守按介质类**（宁可报，不可漏）。**验证要求**：改分类逻辑后必须**构造 4 类用例**（纯命令 / 掉电 / 介质 / 混合）确认「真故障仍会报、假故障不报」——分类过头即漏报，是更严重的错。
- **报告只给「读数 + 口径」，不倒采集中间量（v1.48.97 立规，客户展示事故）**：采集端为算出某个值而取的**中间读数是给机器看的，不是给客户看的**——**实测**：RAPL 段原样输出 `package-0: 172.1 W (E1=219240499839 uJ, E2=219760644869 uJ, 间隔 3.0 s)`，`E1/E2/间隔` 是两次能量计采样，客户不需要（原始值留在 `rapl_power.log` 可追溯即可）。**规则**：报告里只保留**结论值**（功率/温度/速率），中间量、原始计数器、采样间隔一律不进报告。
- **口径不同的数值不得并排展示（v1.48.97 立规）**：**实测**：DCMI 段把 `Instantaneous`（瞬时）与 `Min/Max/Average`（**BMC 内部采样窗口**内统计）并排成 `当前 X · 最小 Y · 最大 Z · 平均 W`，出现 `当前 4410W · 平均 58W`（窗口 14810s ≈ 4h，平均值被大量空闲拉低）这种**自相矛盾**的展示，客户会当成数据坏了或电源超载。**规则**：并排前先确认**同一口径/同一时间基准**；口径不同就分段（`瞬时 X ｜ 窗口内 …`）**并把分母条件写明**（如"BMC 内部 5s 采样窗口"）。
- **采集命令里的管道 grep 必须加 `--line-buffered`（v1.48.98 立规，实测丢数据事故）**：`timeout N cmd | grep pat` 形式下，**grep 在管道里是块缓冲（默认 4KB）**——命令被 `timeout` kill 时缓冲区尚未 flush，**整份输出全丢**（连已匹配到的行也丢）。**实测**：B300（B300-sample-a，22.224）`ipmitool sensor list` 超时 30s，`bmc/ipmi_sensors.log`（直接重定向到文件，行缓冲）**保留 100 行含 15 行风扇**，而 `fan/ipmi_fan_sensors.log`（`… | grep -iE FAN\|RPM`）**0 行**——报告因此写「风扇 数量 N/A（未取到数据）」，**同一份数据就在隔壁文件里**。**规则**：所有 `ipmitool/… | grep` 的采集命令一律 `grep --line-buffered`（全项目已统一，目标机为 Ubuntu 的 GNU grep）；仅"输出到文件"而无管道时不需要。
- **报告端的兜底路径假设「目录内文件同属一次采集」（v1.48.98 立规）**：给报告加兜底（如「`fan/` 空就读 `bmc/ipmi_sensors.log`」）前，先确认**数据源目录真的是干净的一次采集**。**本地采集**有 `rm -rf` 清目录，假设成立；**远程回拉**曾因纯覆盖式解包不成立（**v1.48.99 已修为「逐机器精准替换」**：清空旧目录+归档校验+目录名护栏）。**旧版本产生过、新版本不再产生的文件会残留**（实证：`remote_output/*/nvswitch/nvswitch_smi_*.log`），兜底会把这些**旧批次文件当本次数据渲染**。加兜底时要么先保证目录干净，要么在兜底处校验批次。
- **`date -d` 的「- N unit」是**加**不是减（实测反向判定，v1.48.99 立规）**：`date -d "2026-09-18 09:02:56 - 1 hour"` **得到 19:02:56（比原时刻还晚 10 小时）**。**规则**：要算"某时刻 ± 偏移"时**先取 epoch 再算术相减**（`t=$(date -d "$TS" +%s); cut=$((t-3600))`），或写 `"$TS 1 hour ago"`；**别写 `"$TS - 1 hour"`**。这类错误**静默反向**：把正常数据判成异常、真异常放过，**不报任何错**。
- **`summary.txt` 的 `Timestamp` 是远端机器本地时间，不能拿来与本机时间比较**：远端若为 UTC 机器（实测 22.224 是），本机 +0800 上同一时刻显示差 8 小时（summary 写 09:02:56，文件 mtime 是 17:02:56，实为同一时刻）。跨机比较前必须先把时区归一（而本机通常不知道远端时区）——**能只用相对量（如"总时长"）就别用绝对时刻**。
- **解析日志必须排除 `^#` 头行——否则命令头会自匹配（v1.48.95 立规，验收误报事故）**：HwScope 每个日志文件头部写入 `# Command : <原始命令行> | grep -iE '<模式>' ...`，**该行本身就含被搜索的关键词**。报告端若直接 `grep "Xid" $log`（不排除头行），就会匹配到自己的采集命令行，**凭空报出「检出 GPU XID 错误」**——实测 B300（B300-sample-a）：`journal_xid.log` 正文仅 1 条驱动加载日志（`NVRM: loading NVIDIA ... 580.105.08`），却因命令头含 `grep -iE 'Xid|NVRM'` 被判 WARN，客户看到"GPU XID 错误历史"以为显卡有故障史；`journal_mce.log` 同理（正文全是 `EDAC MC: Ver: 3.0.0` 等驱动初始化，命令头含 `MCE|machine check` → 误报 CPU MCE）。**规则**：① 报告端读任何带 HwScope 头的日志，**先 `grep -vE "^#"` 再去匹配**；② 采集端 grep 模式**避免用宽泛词**——`NVRM`（只是"NVIDIA 内核模块"前缀，正常加载也打）、`EDAC`（纠错驱动初始化也含）、裸 `MCE` 都会把正常启动日志当成故障；③ 模式要锚定**真实错误格式**（XID 用 `Xid *(PCI|NVRM: *Xid`，MCE 用 `machine check|Hardware Error|mce:|MCA: `）。**通用教训**：任何「从日志里 grep 关键词判故障」的实现，都要先问「这个文件名/命令头里会不会出现同一个词」。
- **故障历史必须来自持久化日志，不能只靠 dmesg（v1.48.90 立规）**：`dmesg` 是**环形缓冲，重启即丢**，而 GPU XID（79 掉卡/48 双bit ECC/13·31 显存）、CPU MCE 这类「曾经出过事」的证据，往往正是重启之后才需要回溯。**规则**：`journalctl -k --since "7 days ago"` 采持久化内核日志（限 /-k + 时间窗 + tail，避免 journal 巨大拖慢采集），dmesg 仅作本次开机的补充；报告端按journal → dmesg 的优先级取第一个命中的来源并**标注来源**。
- **验收项只在检出时追加，不改变默认项数（v1.48.90 立规）**：新增「故障历史」类验收项（XID/MCE/BBU）时用「仅检出才 add_item」的写法，保证无故障机器的验收项数与既有基线一致——否则每台机的项数都会漂移，回归基线与横向对比全部失效。
- **数据源分层兜底：能用 OS 侧就别只认 BMC（v1.48.89 立规）**：风扇/温度/功耗这类信息往往有**多路来源**，只认一路会在该路故障时误报「无数据」。**实例**：风扇此前只读 `ipmi_fan_sensors.log`，而采集端其实还采了 lm-sensors（`sensors_fan.log`）、hwmon sysfs（`hwmon_*/fan_values.log`）、ACPI、以及全量 dmidecode（Type 27 Cooling Device）——**采了却没用**，BMC 一慢就显示「风扇数量 0」。**规则**：BMC/IPMI 优先（带状态与冗余语义），其后依次回退 OS 侧，并按「信息量」排序（有转速的 lm-sensors/hwmon 优于只有 Type/Status 的 SMBIOS Type 27）；**报告必须标注数据来源**，客户才能判断可信度。同理：dmidecode 采集直接上**裸 `dmidecode`（全量）**，单条命令覆盖全部 type（27 风扇/29 电流/26 电压/28 温度/11 OEM Strings/38 IPMI…），比逐个 `-t` 补全成本更低且不会遗漏。
- **SMBIOS 里的「Not Specified」记录要识别并友好渲染（v1.48.94 立规）**：BIOS 填 SMBIOS 时如果**没读到**某个部件的 FRU，会把该条记录的字段留成 `Not Specified`——这不是采集失败，也不是部件故障，但**原样渲染会难看且误导**。**实例**：Gigabyte B200 NVL8（B200-sample-a）12 条 Type 39 中恰有 1 条字段全空，报告按「厂商+Name+Rev+Revision」拼接后输出 `Not Specified Not Specified Rev Not Specified`，客户会以为采集坏了；而同机 IPMI 侧 `PS1..PS12_Status` 全为 `ok`，另 4 台同 BIOS/BMC（F11 / 13.06）的机器均无此空记录 → 属**该颗 PSU 的 FRU 读取失败**（BIOS 经 PMBus 读，BMC 另走一路，故 BMC 能读到）。**规则**：判据 = 关键字段（Name/厂商/SN）**全部**为 `Not Specified` 或空 → 渲染为「（FRU 未读到——BIOS 未填充该条记录…）」而非堆叠 `Not Specified`；**但同一记录里的真实字段必须保留**（该空记录仍带 `Max Power Capacity: 3000 W`，容量是真数据，不能因"这行是空的"一并丢弃）；同时在平台限制标注里说明「N 颗在位，其中 M 条记录 FRU 未填充」，让数字对得上。**注意两条代码路径都要改**：段落间的 `Handle` 分支与文件尾的"最后一段"分支。
- **报告不下未经证实的口径断言（v1.48.88 立规）**：`DCMI 整机功耗（主板侧，不含 GPU）` 这个标注（v1.48.24 加）**没有依据**——DCMI 规范里 `dcmi power reading` 定义是**平台总功耗**，但各厂 BMC 实现不一（有的只报主板域）。报告替客户断言口径，一旦对方用别的工具交叉验证对不上，就是信任问题。**规则**：读数只如实写「值 + 字段来源」（如 `DCMI 平台功耗读数（ipmitool dcmi power reading）`），口径交由客户判断；确有分口径需求时，先确认平台实际行为再写死结论。
- **SEL 判定按「告警终态」，不是「是否出现过 Critical 字样」（v1.48.86 立规）**：SEL 的 `Asserted`/`Deasserted` 是**同一事件的进入/解除两态**——同「传感器 + 事件类型」出现 `Deasserted` 即表示已恢复正常。旧实现 `grep -ciE "critical|fatal"` 数行数，**连 Deasserted 行也计入**（其事件描述里同样含 "Critical"），把已自愈的历史事件报成当前故障。**判定口径**：`SEL_CRIT_UNRESOLVED > 0` → FAIL（当前仍告警）；`SEL_CRIT_RECOVERED > 0` → **WARN**（曾告警已自愈，文案带自愈日期，告知但不卡交付）；其余 → PASS。**累积型事件**（Uncorrectable ECC 等）没有 Deassert 配对，会自动落到 UNRESOLVED，规则自洽，**不需额外按告警级别分级**。教训：实测 A100 机 2022 年风扇瞬停 19 秒后自愈（2 Asserted + 2 Deasserted），被报成"2 条 Critical"→ 整个验收判 FAIL。
- **禁把本机用户名/路径写进脚本（v1.48.87 立规）**：`tools/agent/regen_reports.sh` 曾把桌面路径写死成 `/mnt/c/Users/yanhu/Desktop`，换账号（本机实为 `15707`）后样本发现静默返回空，直接报「无有效样本目录」。**跨机器复用的脚本不得硬编码任何本机路径/用户名**——同类检查：脚本里出现具体用户名（`yanhu`/`15707` 等）即为违规。**桌面类路径按三级探测**：① `DESKTOP_OVERRIDE` 显式指定 ② `USERPROFILE` 推导（git-bash 下已设，反斜杠转斜杠再转 MSYS 风格）③ 扫 `/mnt/c/Users/*/Desktop`（跳过 `Public`/`Default`/`All Users`）。
- **网络报告里「芯片」「PSID」的判据看驱动名，不看接口名（v1.48.88 立规）**：Mellanox 卡跑**以太模式**时接口名是 `ens*`（不含 ib/mlx 字样），而 `ibstat`/`ethtool -i` 的数据**照样存在**。两处旧实现都按接口名 `ib*|*mlx*|*ConnectX*` 判定，把以太模式的卡整批漏掉：① **芯片列**恒为 `—`（`CA_MODEL` 取值锁在 `ibp*/ibs*` 分支内）；② **PSID** 取不到权威来源（`ethtool -i` 固件串括号值），只能靠 mstflint 兜——兜到就有、兜不到就 N/A，同型号两张卡结果还不一致。**两处判据统一改为驱动名**（`mlx5_core`/`mlx4_core`，一次 `ethtool -i` 即可取到 `driver:`）。
  - **PSID 必须让 `ethtool -i` 覆盖而非仅兜底**：实测 `mlxfwmanager` 查询失败时（`-E- Failed to query 0000:b6:00.0 device, error : FwInit has failed!`）会把**他卡的 PSID** 配过来——`b6:00.0`（`ens10f0np0`，MCX755106AS，真值 `MT_0000000834`）被写成 `MT_0000000884`，而后者实际属于 `ens1f0np0`（BlueField-3）。即 AGENTS 记过的「MST 设备↔BDF 误配读到他卡 PSID」，`ethtool -i` 由内核按 netdev 提供、不会错配。
  - **报告端同步回捞**：旧采集数据的 `nic_inventory` 里这些值已是 N/A/错值，但 `ethtool_<dev>_driver.log` 已落盘 → 报告端直接读该日志修正，**无需重采**。
- **「0 条」不等于「没有」——采集失败必须与平台固有形态区分（v1.48.88 立规）**：报告里凡由日志计数得出的「数量」，都可能是**命令超时后日志为空**算出的 0，直接渲染成「0/无」会把**数据缺口伪装成平台特性**，还让验收放过它。**风扇实例**：Giga B200（B200-sample-c）上 `ipmitool sensor list`（不带参数的裸命令最慢）10s 超时 → 日志空 → 报告写「风扇数量 **0**，无风扇（平台配置形态）」，而该机是 8×B200 整机、风扇必然存在；验收项也因此**不计入数据不足**。**修法**：加 `FAN_DATA_OK`（日志有非注释数据行才为 1），三种情形分开渲染——① 采集失败（`FAN_DATA_OK=0`）→ `N/A（未取到数据）` + 提示复核 BMC 响应，验收项**如实计入数据不足**；② 有数据但无风扇项 → 「平台风扇不经标准 IPMI 传感器暴露」；③ 有风扇明细 → 正常显示。**推广**：任何「计数为 0」的字段都应先确认日志是否真有数据。
- **报告解析回归纪律（v1.48.4 立规，v1.48.14 迁移 tools/agent + 触发规则细化）**：改动 `report/sections/`、`report/gen/`、`report/lib/`（解析/渲染逻辑）或采集模块输出格式后，**提交前必须跑** `bash tools/agent/report_regression.sh <采集目录>`（或 `--all` 全量；`--samples SN1,SN2` 选跑受影响样本省时间——GPU 改动跑 GPU 样本等）——与基线有差异时人工确认是预期改动还是回归，确认预期后 `--update` 刷新基线。**触发规则：解析/渲染/输出格式相关改动必跑；纯文档、版本号、非报告逻辑改动不跑**（避免每次提交空等 ~5 分钟）。历史教训：AMD 多卡明细全显示 card0、内存通道数算成插槽数、表格列错位、1T9 容量误判，均由 Agent 改解析代码引入且人工 review 漏检；脚本纯 bash/awk 实现，**需 Linux 环境**（git-bash 下 report.sh 的 fork 密集会触发 MSYS 崩溃——实测整个 shell 被杀，且管道会吞掉缓冲输出造成"脚本无输出"的假象，诊断应重定向到文件而非管道）。**同源判定（v1.48.74）**：基线按机型语义名命名，同型号多台机器（如桌面 3 台 B300）共用一个基线文件——比对前先查"机器指纹"（GPU/网卡/内存/盘/PSU/PCIe 计数，来自报告指标、不含 SN 与机器标识）：指纹不符 → 输出 `[SKIP] 不同源`（差异属机器固有，**不判为回归**）；指纹一致才报 `[DIFF]`。全团队**每个机型以一份权威样本**为基线源（选采集版本最高、配置最全的那台），刷新用 `--all --update`。**基线机制/同型号多机处理/仓库对齐的完整说明见 `tools/agent/README.md`**

## 报告与归档

- 采集完成自动调用 `report/report.sh`（报告体系为独立模块，见 `report/` 目录）：从各模块日志提取关键字段，生成 `hwscope_report.{json,md,txt,html}` 四件套（含明细表：内存每槽/GPU每卡(含VBIOS)/CPU每颗/存储每盘/网络每端口/PSU/SEL事件/风扇/RAID(虚拟盘级)/HBA；内存明细含 Rank，PSU 明细含实时输入功率 + DCMI/整机功耗独立行，网卡明细含 GPU直连 标记 + chip 列 + **物理位置列**（v1.48.53，SMBIOS 槽位表+PCIe 上溯，GPU 直连卡显示 SXM*_GPU*）+ **PSID 来源**（v1.48.56：`ethtool -i` 固件字符串括号值（权威——内核按 netdev 提供、每卡每口都有）→ mstflint → mlxfwmanager → 报告端 devlink 兜底；多口卡同 BDF 前缀共享——MST 只注册 function 0）+ 报告末尾术语表；HBA 直通卡章节有卡才显示；**v1.29.0 新增**：固件合规段（15_firmware 输出，对照 fw_required.txt 判 合规/落后/较新/未知）、能耗台账段（16_power 输出，累计 kWh + 功耗快照）、BMC 数据一致性校验段（OS vs BMC 交叉校验，零新采集，不一致 WARN 并排显示两边值）、压测归档段（--test-dir 关联 test/ 目录，test_common.sh 写 manifest 解耦））
- **HTML 件**：`hwscope_report.html` 由 `report/lib/md2html.awk`（纯 awk 转换器，内嵌 CSS，零依赖）从 MD 转换生成——卡片分区/状态着色（PASS绿/WARN橙/FAIL红/N/A灰）/斑马纹表格/打印友好；验收清单同理生成 `hwscope_acceptance.html`；改 MD 模板后须回归 HTML 闭合（python HTMLParser 或浏览器验证）
- **GPU 额定显存规格库**：report.sh 内置 60+ 型号→额定容量映射（检测值交叉验证：GB 十进制/GiB 双口径 3% 容差自动匹配，多版本型号如 A100 40|80 自动选近者）；**匹配顺序=正确性**（长型号优先防子串误配：GH200 在 H200 前、L20 在 L2 前、A2 兜底防配 A2000、T4 兜底防配 T400）；检测与额定不符 → `⚠️ 疑似显存魔改或伪装`；新增型号加映射时注意 case 模式含空格须引号（`*"RTX 6000"*`）
- **动态列隐藏**：明细表整列全为占位符（—/N/A）时隐藏该列并附注说明（如"寿命%、健康 列因旧采集无 SMART 数据而隐藏"），有任一真实值即显示；JSON 始终保留全字段（程序消费稳定，不受隐藏影响）
- **验收清单**：`bash report/report.sh <out> --acceptance` 生成 `hwscope_acceptance.{md,html}`（硬件概览配置单表 + **逐项 PASS/FAIL/WARN/N/A** + 结论判定），交付时作为交接单；判定项 = GPU PCIe/NVLink/DCGM/VBIOS/内存/线缆/磁盘寿命/SMART/电源冗余/温度/SEL+ **固件版本合规**（15_firmware 输出：落后=FAIL、无基线判未知=N/A 不误报、较新不算落后）+ **OS-BMC 口径一致**（零新采集交叉校验：不一致=FAIL、仅单侧数据=WARN；**无 BMC 机器判 N/A 不计入数据不足**——IPMI 日志全错误=平台无 BMC 属固有形态，无任何 IPMI 日志=ipmitool 未装/模块关则如实计入数据不足）+ **PCIe 链路完整**（v1.41.0：06_pcie 采 pcie_full 全量，PEX Fabric Switch 枚举 + LnkCap/LnkSta 满速/降速判定——交付核对扩展板卡通路与模组接口链路；空闲 Gen1 x16 与 x0 未连接端口不算降速；旧采集无 pcie_full 判 N/A 不计数）+ **CPU 配置一致/内存容量一致/内存 ECC**（v1.48.40 类A 自洽校验：多颗 CPU 型号/Stepping/核数混插=FAIL、内存空槽排除后容量混插=WARN、ECC 类型——Single-bit 也 PASS 注明、无 ECC 服务器 WARN 消费正常）；**内存运行速率判定按 DPC 而非"是否插满"（v1.48.69 用户口径）**：超过 1DPC（已插槽位 > 总槽位/2，即至少部分通道插 2 条）时内存控制器必须降频，属平台规范 → PASS；典型如 24 根插 32 槽（8 通道 2DPC + 8 通道 1DPC）降速完全正常，旧实现只在"插满"时才 PASS 会把这类正常配置误报 WARN。仅 ≤1DPC（每通道 1 条）仍降速才 WARN（建议核查 BIOS 设置/混插兼容性）。实现：`10_env_mb_cpu.sh` 算 `MEM_OVER_1DPC`（`POPULATED*2 > SLOTS`）与 `MEM_FULL`，`gen_acceptance.sh` 两项任一成立即 PASS；配置单（准系统/CPU/内存/GPU模组/计算网卡/网卡&端口/存储/电源模块/系统管理）自动生成自检测数据，可对照采购配置单核对；判定规则：有 FAIL=不合格、有 WARN=有条件通过、N/A 计数≥4=数据不足；**条件驱动 N/A 计数**（v1.33.7-8，非一刀切）：场景/平台固有 N/A 不计入（无 GPU 机头、无 IB 卡或链路未接线、无数据盘、固件无基线、OS-BMC 未启用/无 BMC），真缺数据计入（已接线 Active 但无线缆数据、有盘无 SMART、有基线无固件数据、启用后采集失败）；**无 GPU 机头**的 GPU 相关 4 项（PCIe/NVLink/DCGM/VBIOS）判 N/A 且不计入"数据不足"（无 GPU 是平台固有形态，非数据缺失）；**AMD 平台**（v1.46.x：GPU_PLATFORM=amd）NVLink/DCGM 判 N/A 不计入（AMD 无 NVLink/DCGM，xGMI 互联 + ROCm 诊断 rocminfo/amd-smi ras）；**消费级 NVIDIA**（v1.48.40 能力感知：nvlink --capabilities 无 Link 行/型号 GeForce·RTX·GTX）NVLink/DCGM 判 N/A（无该能力/DCGM 面向数据中心卡，不再假 PASS/WARN"驱动异常"）；**无 BMC 平台**的 IPMI 依赖项（电源冗余/整机温度）同样判"平台无 BMC"N/A 不计入（v1.40.7：IPMI 日志存在但全错误=平台无 BMC 属固有形态；无任何 IPMI 日志=ipmitool 未装/模块关则如实计数）
- 报告**只读日志、不重新采集**，可对同一份数据反复生成；日志缺失字段显示 N/A
- 双压缩包：`logs/<SN>-<ARCHIVE_TS>.tar.gz`（详细分级日志）+ `logs/report/<SN>-<ARCHIVE_TS>-report.tar.gz`（报告四件套），共用同一 `ARCHIVE_TS` 变量（勿各自调 date，时间戳必须一致）
- **时间戳格式统一约定**：全项目文件名时间戳一律 `date '+%Y%m%d%H%M%S'` **连写、无下划线、14 位纯数字**（如 `20260818001530`），输出目录后缀/归档包/test 目录/运维工具等全部一致（v1.33.1 复核 10 处无例外）。**依赖此格式的解析**：`report_server.sh` 的 SN 提取 `sed 's/-[0-9]\{14\}-report$//'`——若改时间戳格式（加下划线/分隔符），必须同步该正则与 README 输出目录示例（v1.33.1 教训：代码已改连写，README 示例漏同步仍写 `20260730_090000` 带下划线）
- 多机横向对比：`report/tools/batch_compare.sh <dir1> <dir2> ...` 读各机 hwscope_report.json 生成同字段对比表（差异 ⚠️ 标注），批次一致性抽检用
- 报告基线对比：`bash report/report.sh <cur> --baseline <prev>` 生成时序差异章节——标量（BIOS/CPU/内存/GPU数/VBIOS/BMC固件）变化 + SN 集合（GPU/盘/网卡）新增移除 + 固件版本逐项变化；**注意**：JSON 单行对象必须用 index() 定位键再取值（贪心 sub 会取行尾字段），含空格 key 必须 while read 逐行（for 会单词拆分）
- SSH 远程采集：`tools/remote_collect.sh -H user@host [hwscope 参数]`——**tar 暂存模式**（流式 bash -s 无法满足多文件 source 结构，v1.29.0 实测结论）：tar 临时推送项目 → 远端执行 → 结果回拉 → 清理；默认交互式密码（不落盘）+ ControlMaster 复用（输一次密码），禁 sshpass 明文密码；**`--install <1,2,...>`**（v1.42.0）：推送后先远端非交互装依赖（`install_tool.sh -c <列表> -y`——install_tool 的 -c/-y 非交互参数即为此扩展）再采集，远程冷启动一条龙；普通用户时安装+采集合并一条 `-t` 命令（同 tty 内 sudo 密码缓存只输一次），安装失败 `&&` 短路中止不采集；**认证重试**（ps1 每步认证失败自动重试最多 3 次，Linux 依赖 ssh 原生 3 次提示）；**首次连接免交互**（v1.48.47 全部远程工具加 `-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR`——新主机免 yes/no 确认、抑制 "Permanently added" stderr 噪音，已记录 key 变更仍拒绝=安全）；**root 免 sudo**（root@* 自动去 sudo），普通用户 + sudo 步骤带 `-t`（sudo 交互输密码）；**输出结构对标本地**：远端不传 --output（hwscope.sh 默认输出 output/<MACHINE_ID>/），回拉 tar `-C` 切换打包（output 内容 + logs）→ 本地落 `output/remote_output/<机器ID>/`（固定 remote_output 层 + SN 层），归档包 → `logs/remote_logs/`（与本地采集日志区分）；**Windows 版 `tools/win/remote_collect.ps1/.bat`**（v1.34.0+）功能等价（ssh/scp/tar 系统自带），**`-InstallItems <1,2,...>`**（v1.42.1，等价 Linux `--install`：先远端非交互装依赖再采集，安装+采集合并一条 ssh 命令），**无 ControlMaster**（Windows OpenSSH 不支持，v1.34.2 实测 getsockname failed），3 次密码分步输入，ps1 须 UTF-8 BOM（PS5.1 无 BOM 中文注释乱码致语法错误）；远程采集输出目录命名由远端 detect_machine_id 保证非空（无 SN → UUID → 时间戳兜底）
- **v1.31.0 新增工具**：`fw_baseline_import.sh` 固件基线自动导入（基准机采集目录/表格 → fw_required.txt，--diff 预览/--apply 写入+自动 .bak 备份）；`power_monitor.sh` 能耗持续采样（后台循环 DCMI/Redfish → CSV，stop 输出小时/日聚合 + 梯形积分 kWh；子进程模式 = `bash $0 __sampler` 重跑本脚本，避免 export -f 依赖）；`report_server.sh` 报告在线预览（解包 logs/report/ 到 web/ + index.html + python3 http.server，零新依赖）；`remote_run.sh` 远程执行（v1.43.0 由 remote_batch.sh 改名：-H 列表 + -c 命令/--push 推送/--script 脚本执行/--pull-logs 日志回拉，逐机 .out + <host>_logs/ 落盘，默认交互式密码 + ControlMaster 复用；Windows 版 tools/win/remote_run.ps1/.bat 同更名）；`dhcp_server.sh` 扩展 `leases-export <csv>` + `reconcile <目录...>`（租约↔报告 JSON BMC IP/MAC 交叉核对；`--lease-file` 自定义租约路径；**主脚本顶层禁用 local**——非函数上下文报错）；`cleanup.sh`（v1.34.7，Windows 版 tools/win/cleanup.ps1/.bat）清理 output/ + logs/——显示大小/文件数 + 输入 yes 确认（--force 跳过），不碰源码
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
- **提交前自检（v1.48.77，把规矩做成钩子）**：`bash tools/agent/sn_check.sh --install-hook` 安装 pre-commit + commit-msg 钩子（仅本机生效）；提交时自动扫**暂存改动 + 提交信息**里的疑似 SN/MAC，命中即拦下。手动体检用 `--all-history`。**开工跑 `agent_sync.sh` 时会自动检测钩子是否安装并提醒**（未装则给出安装命令）；`git_push.sh` 推送前另有一道 sn_check 兜底。判定 = 宽模式 + **长度门限**（真实 SN ≥10 字符、纯数字 9–13 位；产品型号如 B300/A2000/MI300X/GA100 短于此，天然放行）+ 非敏感白名单（PSID 值、网卡部件号、芯片型号、占位序列号、Windows 错误码、换算常数、版本号、日期戳、FAKE 示例）。**提交正文禁用真实样本标识**——写 "real B200 run" 即可，勿附真 SN/MAC
- **上下文压缩后必须回源重读，不得凭摘要行动（v1.49.5 立规）**：agent（Hermes 等）上下文接近上限时会自动压缩历史，**摘要是有损的**——可能丢资产记忆、把口径改走、把"已完成"记成"待做"、或漏掉**其他会话刚做的改动**。**规则**：一旦察觉自己刚经历上下文压缩（对话里出现摘要/交接块），**动手前先回源**：① 读本项目 `PROJECT_STATE.md`（状态/资产/待办）② 读工作区级与本目录 `AGENTS.md`（规则）③ `ls` 项目目录（压缩会丢"工作区有哪些文件"的记忆）。**原因**：同一仓库可能被多台机器、多个 agent 会话先后修改，摘要不反映他人改动；凭摘要行动是做重复劳动与无用功的常见来源（曾把"已完成的双架构编译"当成没做过）。
- **真实标识零容忍范围 = 文档 + 注释 + 提交信息 + 文件名（v1.49.5 立规）**：**提交信息也要扫**——一次事故正是把 SN 写进了**提交信息**（只装 pre-commit 不够，要 `--commit-msg` 钩子才拦得住）。**改用语义名**：`B300-sample-a` / `A100-sample-a` / `B200-sample-a~c` / `AMD-sample-a`，测试机 IP 写 `<test-host>`。**"我的机器 ID 不是 SN" 不是理由**——客户机器序列号对第三方同样敏感。
- **钩子靠自觉不可靠——推送关口必须有兜底检查（v1.49.5 立规）**：`.git/hooks/` **不进仓库**，换机器/新 clone 就没有；历史多次泄漏都发生在"以为装了钩子"或"钩子没装"的时刻。故 `git_push.sh` 推送前除版本单调检查外，还调 `sn_check.sh` 兜底（推送是进公开仓库的**唯一必经关口**，放这里不依赖任何人的自觉）。临时绕过：`SKIP_SN_CHECK=1`。
- **跨 shell 重写 git 历史（filter-branch / filter-repo）先看两件事（实测 23 分钟才跑完的教训）**：
  - **① 两侧 `core.autocrlf` 可能不一致** —— 同一仓库在 git-bash（`autocrlf=true`）与 WSL（未设=false）下，`.ps1` 这类不受 `.gitattributes` 约束的文件会一边干净一边报 `Cannot rewrite branches: You have unstaged changes.`。**修法**：给命令临时传 `git -c core.autocrlf=true filter-branch ...`（不改永久配置、不动文件）。
  - **② 仓库在 `/mnt/*`（Windows 盘）时极慢** —— 走 9p 跨 VM 文件系统比原生盘慢 5~20 倍（实测 1002 个对象跑 23 分钟）。**做法**：先把仓库复制到 WSL 原生盘（`/tmp`、`~/`）再重写，完事拷回。**另**：`git log` 在重写期间报 `not a git repository` 是正常现象（refs 被临时移动）。
- **`SLOT_BY_BUS` 必须处理「多槽位共享同一 bus」（v1.49.6 立规，DGX A100 网卡位置串成硬盘槽）**：`dmidecode` Type 9 的 `Bus Address` **并不唯一**——实测某 DGX A100 上 29 个槽位里 `NIC3`(`51:10.0`) 与 `U.2_NVMe2`(`51:00.0`) 同为 bus 51、`NIC7`(`bf:10.0`) 与 `U.2_NVMe6`(`bf:04.0`) 同为 bus bf、`U.2_NVMe0/3/4/7` 四个全是 `ff:00.0`、`M.2_0/1` 与 `OCulink` 都是 `20:03.x`。原实现 `SLOT_BY_BUS[$bus]=$name` 是**一对多压成一对一、后写覆盖先写**，导致网卡「物理位置」列显示成 `U.2_NVMe2`（硬盘槽）。**修法**：解析时连 **`Type` 字段**一起读，按优先级取优——真扩展槽（Type 含 `PCI Express` 且名字不像存储）> 中立（Proprietary 等）> 存储槽（`SFF-8639` / `M.2` / `SATA` / `SAS` / 名字含 `U.2`·`NVMe`·`M.2`·`OCulink`）。**用 SMBIOS 客观 Type + 命名双判据，不靠单一名猜**。
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
  - `.bat` **必须纯 ASCII（注释/echo/title 全英文）**——cmd 按系统代码页解析 bat，UTF-8 中文注释字节会破坏 rem 行解析报 "xxx is not recognized"（v1.43.2 实测教训：即使 chcp 65001 也不可靠）；如确有中文需求，用 ps1 实现（ps1 有 BOM 支持中文）
  - 每个 .ps1 在 param 块后加 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`（管道/重定向中文不乱码）
- 新增/修改 .ps1 后必须 PowerShell 语法校验：
  `powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('<path>',[ref]$null,[ref]$e) > $null; $e.Count"`（输出 0 = 无错误）
- **native 输出必须流式（v1.48.53 立规，输出时机回归教训）**：ps1 中调用 native 命令（ssh/scp/tar）**禁止 `$x = & $cmd` 形式先把输出整体捕获到变量再处理**——PowerShell 会**消费完 native 全部输出才赋值**，把"逐行实时"变成"命令结束才一次性显示"；远程采集场景表现为**长时间无输出 → 用户误判卡死**（v1.48.51 修 stderr 红字噪音时误引入，v1.48.53 修复）。需过滤/累积输出时**保持管道流式**：
  `& { $ErrorActionPreference = "Continue"; & $Action 2>&1 } | ForEach-Object { $out += "$_"; if ($_ -isnot [System.Management.Automation.ErrorRecord]) { $_ } } | Out-Host`
  **验证铁律**：改输出相关代码后必须验证**输出的时机**（逐行实时到达），不能只验"最终有没有输出"——v1.48.51 的 mock 只验了后者，漏掉了实时性回归，真机才暴露
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
8. **采集命令必须实机验证（v1.48.62 立规——四处同源 bug 教训）**：新增或修改任何采集命令，必须在目标平台**实跑一次**，确认 ①输出非空且语义正确 ②退出码符合预期 ③子命令/参数形式正确；**禁止凭文档、记忆或"看起来对"确定命令写法**。工具版本差异（选项不存在、子命令顺序、子系统缺失）只有真机才暴露，而失败会被 `run_and_log` 静默成 `no match`（`[~]`），可长期无人察觉。教训：`dcgmi stats -v`（缺必需参数，stats 须带 `{pid|enable|jstart|...}`）、`mlxconfig query -d <dev>`（子命令须排在 `-d` 之后 → `mlxconfig -d <dev> q`）、`nvidia-smi nvswitch`（该驱动版本无此子命令）、`nvidia-smi nvlink --error_count`（正确选项为 `-e`）——**四处均从未成功采集过**，其中三处还配套写了报告端解析（永久空转）。配套检查：`timeout N cmd | grep ...` **只包住 cmd**，超时码会被管道末端的 grep 吞成 1（=no match），需 `timeout N bash -c "cmd | grep ..."` 才能让超时可见

**新增 test/ 测试脚本规范（v1.38.0）**：`test_init "<名称>"` 后必须紧跟一行
`bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true`
（保证测试日志自包含服务器身份——机器 ID/型号/CPU/内存/GPU/OS，参考厂商 FLD 日志做法）

## 设计约束（勿违反）

- 只读无害：采集命令不写硬件、不改配置；DCGM 仅 Level 1 纯获取，无 GPU 压测负载
- **采集数据完整性（禁止截断，v1.41.1 全量兜底原则）**：**全量采集是兜底，专项提取不冲突——每类数据必须有全量落盘，同时可保留指定获取某项信息的精准命令，两者并存，提取时按需从全量或专项取**。采集命令禁止 head/tail 行数截断（v1.25.5 踩坑：`head -80/100/200` 在 B300 高密度平台切断 PSU9/PCIe 链路信息，导致报告数据缺失且无法回溯）。**v1.41.1 全量整改**（用户明确要求"每个模块必须都有全量采集，否则后面信息不全都不知道怎么改进"）：dmesg 全量 `dmesg_full.log` + grep 专项并存（原仅 tail-200 专项）、systemctl status 全量（原 head-40）、storcli show event 全量（原 tail-100）、redfish API 响应全量（原 head-100）、每网卡 lspci -vv 全量 `nic_<dev>_pcie.log` + inventory 提取并存（原仅提取字段落盘）。报告端按需截取展示，不丢原始数据
- 模块零耦合：每模块可独立执行，不依赖其他模块；模块通过 `write_manifest` 声明输出文件，report.sh 读 manifest 解耦（不硬编码文件名）
- 不用 eval（已踩坑：awk 变量展开 bug，统一用 bash -c）
- **run_and_log 转义层数**：cmd 字符串经 bash -c 双层解析，awk 内 `$` 变量写 `\$`（单反斜杠），**禁止 `\\$`（双反斜杠）**——会在第一层被 bash 展开成位置参数，set -u 下直接崩溃（v1.5.1 真机踩坑）
- locale 切换仅进程内，不修改系统环境
- 输出目录按 SN 命名，多机隔离；WARN 计数进 summary.txt；**v1.45.6 覆盖语义**：重复采集默认覆盖 `output/<SN>/`（采集=当前状态快照，机器可换配件；历史数据每次采集自动归档 logs/），`--stamp` 加时间戳后缀保留多版本（换配件前后对比）

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
- **Mellanox 网卡勿用 ethtool -m 读光模块（v1.48.84 立规）**：mlx5_core 驱动的网卡执行 `ethtool -m` 会在部分固件/驱动组合下触发**内核报错刷屏**（`mlx5_cmd_out_err` / `QUERY_MCIA_REG status 0x3` / `mlx5_query_module_eeprom_by_page failed:0xffffffff`），后果不只是屏幕刷屏——这些是 **printk（内核日志）**，`2>/dev/null` **挡不住**，会一并污染 `dmesg_full.log`（实测 47 行噪音）与报告 dmesg 段落。**规则**：`07_network.sh` 对 `/sys/class/net/<dev>/device/driver` 为 `mlx5_core` 的口**跳过 `ethtool -m`**——光模块信息已由 `mlxlink -d <dev> -m` 采集，不丢数据；非 mlx5 网卡（ixgbe/rndis 等，只有 ethtool 能读光模块）照旧保留。**判断驱动必须读 sysfs 而非 `ethtool -i` 的输出格式**（后者各驱动不一致）。
- **smartctl Transport protocol 值判断**：SATA 盘输出也有 `Transport protocol: SATA` 行，判 SAS 必须匹配值（`Transport protocol:.*SAS`）而非仅匹配行名（v1.33.4 修正）
- **ps1/bat 编辑陷阱（v1.43.1 教训，真机测试暴露）**：write/edit 工具重写会**剥掉 .ps1 的 UTF-8 BOM**（PowerShell 5.1 按 ANSI 读中文乱码致语法解析崩）且把 .bat 写成 **LF 行尾**（cmd 解析含中文的 LF 批处理崩溃）；改完必须：① ps1 补 BOM（`[System.Text.UTF8Encoding]::new($true)` 重写）② 用 **`powershell`（5.1）** 而非 pwsh7 做 ParseFile 校验（pwsh7 默认 UTF-8 查不出 BOM 问题）③ bat 转 CRLF（`-replace "`n","`r`n"`）；仓库侧 git autocrlf 提交时 .bat 归一为 LF、.ps1 保留 BOM 字节
