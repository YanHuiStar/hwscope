# tools/agent/ — Agent 开发协作工具

> 本目录是给**开发 agent（Hermes / DeepSeek Harness 等）与开发者**用的协作工具，
> 不是面向运维交付的产品工具（产品工具见 `tools/`，Windows 侧见 `tools/win/`）。
> 多机器/多会话协作规则见仓库根 `AGENTS.md`「多机器/多 Agent 协作规则」。

## 工具清单

| 工具 | 用途 | 关键用法 |
|------|------|---------|
| `agent_sync.sh` | 开工同步：fetch + 显示远程/本地 HEAD、版本、ahead/behind、版本回退警告 | `bash tools/agent/agent_sync.sh`；`--mark` 提交后标记；`--clear` 推送后清状态 |
| `git_push.sh` | 推送（内置防死循环：网络预检 + 3 败熔断 + `[PAUSE]` 纪律） | `bash tools/agent/git_push.sh -y`；`GIT_PUSH_BYPASS_COOLDOWN=1` 绕熔断 |
| `report_regression.sh` | **报告解析回归测试**（改解析/渲染后必跑） | `bash tools/agent/report_regression.sh <采集目录>`；`--all` / `--samples SN1,SN2` / `--update` |
| `regen_reports.sh` | 批量重生成报告（agent 调用，样本自动发现） | `bash tools/agent/regen_reports.sh`；`--samples SN1,SN2`；`--regression`；桌面路径三级探测（`DESKTOP_OVERRIDE` 环境变量 > `USERPROFILE` 推导 > 扫 `/mnt/c/Users/*/Desktop`）|
| `sn_check.sh` | **提交前 SN/MAC 自检**（隐私红线兜底——把检查做成可执行钩子） | `bash tools/agent/sn_check.sh`；`--install-hook` 装 git hooks；`--all-history` 全历史体检 |
| `repo_realign.sh` | **仓库对齐**（历史被重写后其他机器分叉的恢复） | 体检 `bash tools/agent/repo_realign.sh`；对齐见下节 |

推送失败时按 AGENTS「推送失败处理纪律」：**停止自动重试 → 上报用户 → 等指令**（网络不通是用户侧问题，重试空转烧 token）。

## 回归基线机制（`tools/agent/baseline/`）

### 基线是什么

报告解析代码靠 `grep`/`awk` 从日志抠数据，改一行就可能静默改坏（历史上出现过：AMD 多卡全显示 card0、内存通道数算成插槽数、加列漏改分隔符导致 29 处表格错位、1T9 容量误判 1TB——**全都肉眼看不出来**）。
基线 = 一份**指标快照**，回归 = 用同一份采集数据重新生成报告、提取指标、与基线逐项比对：

- **一致** → 改动没破坏原有解析
- **有差异** → 要么是本次有意的改动（确认后 `--update`），要么是**改坏了**（修代码）

**基线只保证"没变"，不保证"对"**——它抓不到"一直就存在的错误"，也抓不到采集端问题。所以差异**必须人工判读**（`--update` 前先看差异内容），并配合多样本交叉 + 真实值抽查 + 真机验证。

### 命名与覆盖

基线按**机型语义名**命名（`h200 / a100 / b200 / b300 / amd_oam / headless`），**仓库内零真实 SN**（隐私红线，v1.48.27 立规）。

**覆盖原则：每个机型保留一份权威样本**——选**采集版本最高、配置最全**（有 BMC、有盘、有 RAID 的那台）的样本作为基线源。

### 同型号多台机器怎么办（重要）

桌面/现场经常有多台同型号机器（如 3 台 B300），它们**共用一个语义名基线文件**——配置不同（网卡 12 vs 14 张、PCIe 83 vs 80 条）→ 谁最后刷基线"谁赢"，其他机器跑回归会报**满屏假差异**。

**v1.48.74 起脚本自带"同源判定"**：

```
[OK]   与基线一致（无解析回归）                          ← 指纹一致：真结论
[SKIP] 与基线不同源（同型号不同机器/配置变动）——差异属机器固有，不判为解析回归
          <   nic_rows=14     >   nic_rows=12
          <   pcie_appendix_rows=80   >   pcie_appendix_rows=83
```

- 判定依据是**机器指纹**（报告里的 GPU/网卡/内存/盘/PSU/PCIe **计数**，不含 SN 或任何机器标识）
- **看到 `[SKIP]` 不是错误**——说明你这台不是该语义的基线源

### 我这台机器想验证自己改的代码怎么办

`[SKIP]` 下拿不到 OK/DIFF 结论。两种做法：

1. **临时刷本地基线**（推荐，不改仓库内容）：
   ```bash
   HWSCOPE_SAMPLE_ROOT=<样本根> bash tools/agent/report_regression.sh --samples <本机样本> --update
   bash tools/agent/report_regression.sh --samples <本机样本>     # 得到 OK/DIFF 结论
   git checkout tools/agent/baseline/                            # 用完还原，别提交
   ```
2. **只做静态核对**：改解析代码时对照报告输出手工核字段（适用于小改动）。

**不要**为了让自己的机器变"绿"而提交 `--update` 的基线——那会把权威样本的基线换成你这台的，反过来让其他人 `[SKIP]`。

### 常用命令

```bash
# 全量比对（自动发现样本、同语义只比首台、指纹不符自动 SKIP）
HWSCOPE_SAMPLE_ROOT=<样本根> bash tools/agent/report_regression.sh --all

# 只跑受影响的样本（GPU 改动跑 GPU 样本；省时间）
bash tools/agent/report_regression.sh <采集目录> --samples <SN1,<SN2>

# 确认差异是预期改动后，刷新基线
bash tools/agent/report_regression.sh <采集目录> --update
```

**触发规则**（AGENTS.md）：改 `report/{sections,gen,lib}` 或采集模块输出格式 → **提交前必跑**；纯文档/版本号/非报告逻辑 → 不跑。

## 提交前自检（sn_check.sh）

隐私红线要求真实采集标识（机箱 SN / MAC 等）不进 git——但实践反复证明"写进规矩"不够：
历史上两次出现真实 SN 进提交正文（一次我自己、一次协作 agent），都需要重写历史才能清除。

`tools/agent/sn_check.sh` 把检查做成可执行钩子：

```bash
# 一次性安装（写 .git/hooks，仅本机生效，不影响他人）
bash tools/agent/sn_check.sh --install-hook

# 手动检查：暂存区 + 待推送提交
bash tools/agent/sn_check.sh

# 全历史体检（发布前跑）
bash tools/agent/sn_check.sh --all-history
```

**判定方式**：宽模式匹配 + **长度门限收敛** + 非敏感白名单：

- 真实 SN 普遍**长**（本机常见的三类形态：4 字母+3 数字+4 字母数字 = 11 字符；单字母+6 数字+混合 = 14 字符；13 位纯数字）；
  产品型号普遍**短**（`B300`/`A2000`/`MI300X`/`GA100`/`SC2163` ≤6）→ 字母数字混合 ≥10 字符、
  纯数字 9–13 位才算疑似，产品型号天然放行
- 同样检测 **MAC**（带分隔符或 12 位 hex 形式）
- 白名单放行**必须保留**的非敏感串：网卡 PSID 值（`NVD…`）、部件号（`MCX…`）、芯片型号
  （`MT…`/`MLX…`/`GA…`）、RAID 芯片（`SAS3xxx`）、盘型号（`MTFD…`）、Mellanox 占位序列号、
  Windows 错误码、换算常数、版本号、日期戳、`FAKE…` 示例与文档里的假 MAC

命中时给出**处理建议**（改语义名 / 加白名单 / 走 filter-repo 清除流程）。
需要临时跳过：`git commit --no-verify`。

## 仓库对齐（历史被重写之后）

git 历史被重写（filter-repo 清 SN、压提交等）后，**所有旧 clone 会与远程分叉**——`git pull` / `git push` / `git_push.sh` 的 rebase 全部失败。用本工具对齐：

```bash
# ① 体检（只读，先看局面）
bash tools/agent/repo_realign.sh
bash tools/agent/repo_realign.sh --no-fetch     # 断网时用本地引用体检

# ② 纯同步机（无本地改动、无未推提交）——安全对齐
bash tools/agent/repo_realign.sh --sync

# ③ 有本地改动/提交（开发机）——自动保护后对齐
bash tools/agent/repo_realign.sh --protect            # 备份分支 + stash + reset + 打印搬回指引
bash tools/agent/repo_realign.sh --protect --auto     # 再自动 cherry-pick（逐提交先扫 SN，命中则跳过）
```

**为什么不能直接 `git pull`**：重写只改 commit hash 不改内容，直接 pull 会分叉失败。
**为什么不能盲目 `git rebase origin/main`**：本地提交若改过基线/ROADMAP 等文件，rebase 重放会把**历史里已清除的 SN 又带回来**——所以 `--protect` 会**逐提交先扫 SN**，命中就跳过并告警。

## 环境与工具限制

开发时容易踩的坑（MSYS 管道吞输出、heredoc 吃反斜杠、PowerShell 缓冲输出、网络预检 HEAD 误判等）见 **`docs/AGENT_ENV.md`**——改脚本前建议先扫一眼。

## git_push.sh 网络预检

- 预检 = `curl --max-time <N> https://github.com`（直连）+ 经代理各试一次，判定可达性
- **超时 N 默认 15s**，可用环境变量 `GIT_PUSH_PRECHECK_TIMEOUT` 覆盖（如 `=30`）
- **慢 ≠ 断**：预检失败只代表"快速判定没通过"，不等于网络不通。预检失败后应先手工执行 `timeout 60 git push origin main` 确认；真实推送成功即完成，不必再走脚本。历史上预检超时已三次放宽（3s→5s→15s）。
