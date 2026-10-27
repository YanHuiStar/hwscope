# tools/agent/ — Agent 开发协作工具

> 本目录面向**开发 agent（Hermes / DeepSeek Harness 等）与开发者**，不属于交付给客户的产品工具。
> 交付 / 运维工具见 `tools/`（Linux）与 `tools/win/`（Windows）。
> 多机器 / 多会话协作规则见仓库根 [AGENTS.md](../../AGENTS.md)「多机器 / 多 Agent 协作规则」。

## 工具清单

| 工具 | 用途 | 关键参数 |
|------|------|---------|
| `agent_sync.sh` | 开工同步：fetch + 远程 / 本地 HEAD、版本、ahead / behind、版本回退警告；检测 SN / MAC 自检钩子是否已安装；fetch 经 `lib_proxy.sh` 的 `git_net_run`（直连失败自动探测代理并重试） | 无参数（检查）· `--mark` 提交后标记 · `--clear` 推送后清状态 · `-h` / `--help` |
| `lib_proxy.sh` | 代理探测公共库（被 `agent_sync.sh` / `repo_realign.sh` / `git_push.sh` 复用）：`detect_env` / `detect_proxy`（git-bash 与 WSL 双环境，`tasklist` / `netstat` / `ss`，防 `pgrep -f` 自匹配）/ `git_net_run`（直连优先、代理兜底，经 `GIT_NET_USED_PROXY` 回报） | `source` 后调用；`GIT_PROXY_URL` 可显式指定代理。代理端口每次启动会变，故一律动态获取 |
| `git_push.sh` | 一键推送：逐提交摘要审查 + 版本单调检查 + 版本三处一致 + SN 兜底 + 直连重试 + 代理兜底 + `[AI-ACTION]` 指引 | `-y` / `--yes` 跳过确认 · `--no-fetch` · `--dry-run` · `-q` / `--quiet` 机器可读 · `-h`；`GIT_PUSH_BYPASS_COOLDOWN=1` 绕过熔断 · `SKIP_SN_CHECK=1` 跳过 SN 检查 |
| `git_push.bat` | Windows 双击启动器（自动定位 Git for Windows 的 `bash.exe`，参数 `%*` 透传给 `git_push.sh`） | 与 `git_push.sh` 同参数 |
| `report_regression.sh` | 报告解析回归测试（改动解析 / 渲染后必跑） | `<采集目录>` · `--all` · `--samples SN1,SN2` · `--update` · `--keep` |
| `regen_reports.sh` | 批量重生成报告（agent 调用，样本自动发现） | `<目录...>` · `--samples SN1,SN2` · `--regression` · `--update` · `--acceptance` |
| `sn_check.sh` | 提交前 SN / MAC 自检（隐私红线兜底，可装成 git hook） | 无参数（暂存区 + 待推送提交）· `--staged` · `--commit-msg <文件>` · `--install-hook` · `--all-history` · `--include-remotes` |
| `repo_realign.sh` | 仓库对齐（历史被重写后其他机器分叉的恢复）；代理探测经 `lib_proxy.sh` | 体检无参数 · `--sync` · `--protect [--auto]` · `--no-fetch` |
| `bmc_pass_smoke.sh` | BMC 密码通道冒烟测试（tty / 管道 / sudo 三种条件组合） | 无参数；需真 bash（Linux / WSL） |

推送失败时按 AGENTS.md「推送失败处理纪律」执行：**停止自动重试 → 上报用户 → 等待指令**。
网络不通属用户侧问题，重试只会空耗资源。

## bmc_pass_smoke.sh — BMC 密码通道冒烟测试（v1.54.0）

BMC 密码的读取与转发是**环境敏感**逻辑：tty 有无、stdin 是否管道、sudo 是否剥离环境变量，三种条件在不同
机器上组合不同，同一份代码可能在一台机器正常、在另一台永久阻塞（v1.53.45 曾因优先读 `/dev/tty`，在无交互
终端时阻塞）。此类代码「验证过一次」不等于「在其他机器同样成立」，故用本地 bash 仿真各分支并断言变量终值。

```bash
bash tools/agent/bmc_pass_smoke.sh
```

- 覆盖 4 个分支：管道喂密码 / 无输入降级 / 已有密码不重复提示 / 不给参数不提示；每项断言**退出码非 124**
  （即不阻塞）。
- 另含 3 条 `remote_collect.sh` 的静态断言：两个 BMC 变量按 IP 分别拼接、分别提示、密码以 `printf '%s\n'` 传递。
- 环境：Linux / WSL（`/dev/tty` 与管道语义与 git-bash 不同，git-bash 结论不可用）。退出码 0 = 全部通过，1 = 有失败项。

## 回归基线机制（`tools/agent/baseline/`）

### 基线是什么

报告解析代码通过 `grep` / `awk` 从日志提取数据，改一行就可能静默改坏（历史案例：AMD 多卡明细全显示
card0、内存通道数算成插槽数、加列漏改分隔符致 29 处表格错位、1T9 容量误判 1TB，均无法靠人工 review 发现）。

基线 = 一份**指标快照**。回归 = 用同一份采集数据重新生成报告、提取指标、与基线逐项比对：

- **一致** → 本次改动未破坏原有解析
- **有差异** → 要么是本次有意的改动（确认后 `--update`），要么是改坏了（修代码）

**基线只保证「没变」，不保证「对」**：它抓不到一直存在的错误，也抓不到采集端问题。差异必须人工判读
（`--update` 前先看差异内容），并配合多样本交叉、真实值抽查与真机验证。

### 命名与覆盖

基线按**机型语义名**命名（`h200` / `a100` / `b200` / `b300` / `amd_oam` / `headless`），仓库内零真实 SN
（隐私红线，v1.48.27 立规）。

**覆盖原则**：每个机型保留一份权威样本 —— 选采集版本最高、配置最全（有 BMC、有盘、有 RAID）的那台。

### 同型号多台机器（同源判定）

同型号机器（例如 3 台 B300）共用一个语义名基线文件。配置不同（网卡 12 对 14 张、PCIe 83 对 80 条）时，
后刷基线者覆盖先刷者，其他机器跑回归会产生大量假差异。

v1.48.74 起脚本自带**同源判定**：

```
[OK]   与基线一致（无解析回归）                          ← 指纹一致：结论有效
[SKIP] 与基线不同源（同型号不同机器/配置变动）——差异属机器固有，不判为解析回归
          <   nic_rows=14     >   nic_rows=12
          <   pcie_appendix_rows=80   >   pcie_appendix_rows=83
```

判定依据是**机器指纹**（报告中的 GPU / 网卡 / 内存 / 盘 / PSU / PCIe **计数**，不含 SN 或任何机器标识）。
`[SKIP]` 不是错误，只说明本机不是该语义的基线来源。

### 本机验证改动的两种做法

`[SKIP]` 下拿不到 OK / DIFF 结论，可选：

1. **临时刷本地基线**（推荐，不改仓库内容）：

   ```bash
   HWSCOPE_SAMPLE_ROOT=<样本根> bash tools/agent/report_regression.sh --samples <本机样本> --update
   bash tools/agent/report_regression.sh --samples <本机样本>     # 得到 OK / DIFF 结论
   git checkout tools/agent/baseline/                             # 用完还原，不提交
   ```

2. **静态核对**：对照报告输出人工核字段（适用于小改动）。

不得为了让本机「通过」而提交 `--update` 后的基线 —— 那会把权威样本的基线换成当前机器，使其他机器转为 `[SKIP]`。

### 常用命令

```bash
# 全量比对（自动发现样本，同语义只比首台，指纹不符自动 SKIP）
HWSCOPE_SAMPLE_ROOT=<样本根> bash tools/agent/report_regression.sh --all

# 只跑受影响的样本（GPU 改动跑 GPU 样本）
bash tools/agent/report_regression.sh <采集目录> --samples SN1,SN2

# 确认差异为预期改动后刷新基线
bash tools/agent/report_regression.sh <采集目录> --update
```

| 判据 | 说明 |
|------|------|
| 长度指标 | `json_bytes` / `html_bytes`：同语义换机器或换次采集本就有 0.2%–0.3% 浮动，差异 < 5% 输出 `[NOTE]`，不判回归（v1.52.14） |
| 结构指标 | 其余 32 项（行数 / 列数 / 字段名 / 值格式 / 硬件概览）不一致才报 `[DIFF]` |
| 基线溯源 | 基线记录 `source_fp_hash`（来源样本哈希，非 SN），便于确认基线出自哪台机器 |
| 退出码 | 0 = 一致或已更新；1 = 存在差异；2 = 无基线 / 无样本 |
| `--keep` | 保留临时工作目录；配合 `--update` 时另存 `<语义名>.candidate.txt`，便于与既有基线逐行比对后再采纳 |

**触发规则**（AGENTS.md）：改动 `report/{sections,gen,lib}` 或采集模块输出格式 → 提交前必跑；
纯文档 / 版本号 / 非报告逻辑 → 不跑。

### 样本根与覆盖力（v1.50.6）

- **默认样本根为 `<项目>/output`**，多机样本通常不在此处，应使用 `HWSCOPE_SAMPLE_ROOT=<多机样本根>` 显式指定
  （桌面样本：`HWSCOPE_SAMPLE_ROOT=/mnt/c/Users/<user>/Desktop`）。
- 默认根下自动跳过非样本目录（`testdata` / `tmp` / `test` / `bak` / `logs` / `report` 等）并打印 `[SKIP]`。
  此前 `output/testdata/` 会被当作样本，语义误配后只输出「1 个样本，0 个差异，1 个跳过」，看似通过实则零覆盖。
- **仅发现 1 个样本时告警**：单样本结果不具横向覆盖力。
- 判断回归是否真的跑到内容：看 `汇总: N 个样本` 中的 N，以及是否出现 `[SKIP]` / `[WARN]` 行。

## 提交前自检（sn_check.sh）

隐私红线要求真实采集标识（机箱 SN / MAC 等）不进 git。实践中仅靠文字约定不足：历史上两次出现真实 SN
进入提交正文，均需重写历史才能清除。

### 检测规则与豁免（v1.52.19 起补充）

| 规则 | 说明 |
|------|------|
| 容量 / 字节数上下文豁免 | 纯数字 token **紧跟容量单位**（`B` / `bytes` / `KiB` / `MiB` / `GiB` / `TiB` / `KB` / `MB` / `GB` / `TB` / `PB`）时不判疑似 SN —— 注释中的「容量 1874715648 bytes」属正常工程描述。**仅在紧跟单位时豁免**，裸长数字仍按原规则判定：真实 SN 有 13 位纯数字形态，不能按长度收窄，宁可误报不可漏报 |
| 已知无害串（`NOISE`） | 网卡 PSID / 部件号（`NVD…` / `MCX…`）、芯片与型号（`MT…` / `MLX…`）、占位序列号、路由与广播地址、Windows 错误码、单位换算常数、`source_fp_hash=<12hex>`（不可逆，与 SN 无关）等 |
| 长度门限 | 字母数字混合 token ≥ 10 字符、纯数字 token 9–13 位才算疑似；内网 IP 与 MAC 形态直接判高置信 |
| 规则维护纪律 | `PATTERN`（grep 初筛，用 `\b`）与 `sn_filter`（awk 精筛，用 `\<` `\>` 词边界）是两份无法复用的正则，**必须同步维护** —— 曾因只改 `PATTERN` 未改 `sn_filter`，导致新增的 IP 检测完全不生效 |

### 用法

```bash
# 一次性安装钩子（写 .git/hooks，仅本机生效，不影响他人）
bash tools/agent/sn_check.sh --install-hook

# 手动检查：暂存区 + 待推送提交
bash tools/agent/sn_check.sh

# 全历史体检（发布前执行）
bash tools/agent/sn_check.sh --all-history
```

**判定方式**：宽模式匹配 + 长度门限收敛 + 非敏感白名单。

- 真实 SN 普遍较长（常见形态：4 字母 + 3 数字 + 4 位字母数字 = 11 字符；单字母 + 6 数字 + 混合 = 14 字符；
  13 位纯数字）；产品型号普遍较短（`B300` / `A2000` / `MI300X` / `GA100` / `SC2163` ≤ 6）→ 混合 ≥ 10 字符、
  纯数字 9–13 位才算疑似，产品型号天然放行。
- 同样检测 MAC（带分隔符或 12 位 hex 形式）。
- 白名单放行必须保留的非敏感串：网卡 PSID（`NVD…`）、部件号（`MCX…`）、芯片型号（`MT…` / `MLX…` / `GA…`）、
  RAID 芯片（`SAS3xxx`）、盘型号（`MTFD…`）、Mellanox 占位序列号、Windows 错误码、换算常数、版本号、
  日期戳、`FAKE…` 示例与文档中的假 MAC。

命中时给出处理建议（改语义名 / 加白名单 / 走 filter-repo 清除流程）。临时跳过：`git commit --no-verify`。

## 仓库对齐（`repo_realign.sh`）

git 历史被重写（filter-repo 清 SN、压提交等）后，所有旧 clone 会与远程分叉，`git pull` / `git push` /
`git_push.sh` 的 rebase 全部失败。用本工具对齐：

```bash
# ① 体检（只读，先看局面）
bash tools/agent/repo_realign.sh
bash tools/agent/repo_realign.sh --no-fetch     # 断网时用本地引用体检

# ② 纯同步机（无本地改动、无未推提交）安全对齐
bash tools/agent/repo_realign.sh --sync

# ③ 有本地改动或提交（开发机）自动保护后对齐
bash tools/agent/repo_realign.sh --protect            # 备份分支 + stash + reset + 输出搬回指引
bash tools/agent/repo_realign.sh --protect --auto     # 再自动 cherry-pick（逐提交先扫 SN，命中则跳过）
```

| 退出码 | 含义 |
|--------|------|
| 0 | 一致或已成功对齐 |
| 1 | 需人工处理 |
| 2 | 网络失败（fetch 不通） |

不能直接 `git pull`：重写只改 commit hash 不改内容，直接 pull 会分叉失败。
也不能盲目 `git rebase origin/main`：本地提交若改过基线 / ROADMAP 等文件，rebase 重放会把历史中已清除的 SN
带回仓库，因此 `--protect` 对每个提交先扫 SN，命中即跳过并告警。

## git_push.sh 网络预检

| 项 | 说明 |
|----|------|
| 预检方式 | `curl --max-time <N> https://github.com`（直连）+ 经代理各试一次 |
| 超时 | 默认 15 s，可用 `GIT_PUSH_PRECHECK_TIMEOUT` 覆盖（历史上由 3 s 放宽至 5 s，再至 15 s） |
| 降级策略（v1.48.92） | 预检探的是 GitHub 首页，而 `git push` 走 `/<owner>/<repo>.git` 的 git 端点，两者路径不同（首页 curl 更易受 schannel 影响）。实测多次「预检判不可达、手工 push 20 s 内成功」，故预检失败降级为 `pre_degraded` 并继续：试 1 次直连 → 代理兜底 → 仍失败才上报 |
| 防死循环 | 网络预检 + 连续 3 次失败触发 **5 分钟熔断冷却**（冷却期内秒拒，`GIT_PUSH_BYPASS_COOLDOWN=1` 可手动绕过）+ 失败输出 `[PAUSE]` / `[REPORT]` 指令；推送成功自动复位计数 |
| 状态行 | 末尾输出 `PUSH_STATUS=OK\|FAIL\|USER_ABORT\|NOOP\|DRY_RUN`；退出码 0 = 成功，1 = 失败，2 = 用户取消或前置检查不通过 |
| 环境适配 | git-bash(MSYS) / WSL / 原生 Linux 自动识别；WSL 下自动改用 Windows 的 `git.exe`（走 Windows 网络栈）+ interop 探测 Windows 侧代理端口，解决 WSL2 NAT 下 127.0.0.1 不可达 |

## git_push.sh 推送前检查（v1.51.5 起三条）

| 检查 | 作用 |
|------|------|
| 版本单调性 | 本地 `HWSCOPE_VERSION` 小于远程 → 拒绝（防凭记忆回退版本号） |
| 版本三处一致 | `hwscope.sh` 变量 / 头部注释 / `README.md` 徽章三者不一致 → **拒绝推送**，提示运行 `tools/sync_version.sh`（v1.51.3 / .4 曾连续两次只改变量而漏同步徽章与注释） |
| SN 兜底 | 推送前运行 `sn_check.sh` 扫暂存内容与提交信息（`.git/hooks/` 不进仓库，换机器即失效） |

三条检查置于 `git_push.sh` 而非 git hook：推送是进入公开仓库的唯一必经关口，不依赖任何人的自觉。

## 环境与工具限制

开发环境的限制清单（MSYS 管道吞输出、heredoc 处理反斜杠、PowerShell 输出缓冲、网络预检 HEAD 误判等）
见 [docs/AGENT_ENV.md](../../docs/AGENT_ENV.md)。修改脚本前建议先阅读该文。
