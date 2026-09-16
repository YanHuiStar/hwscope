# 开发环境陷阱清单（AGENT_ENV）

> 给开发 agent / 开发者：本项目在 **Windows(git-bash/MSYS) + WSL + Linux 真机** 三种环境下开发，
> 下列每条都是**真实踩过并浪费时间**的坑。改脚本、跑长任务、调网络前先扫一眼。
> 格式：**症状 → 判定 → 对策**。与 `AGENTS.md`「环境故障止损纪律」互补（那里是纪律，这里是细节）。

---

## 1. MSYS / git-bash（Windows 下 agent 最常踩）

### 1.1 fork 崩溃（最耗时，容易误当代码 bug）

- **症状**：命令**静默 exit 1 且零输出**（连开头的 `echo` 都不执行）；或 stderr 报
  `dofork: child died … 0xC0000142` / `Resource temporarily unavailable`。
- **判定**：`ls`/`cat`/`grep` 等直接 exec 的命令正常，**凡 fork 类全崩**（子 bash、`$( )` 密集脚本、复杂 git 操作）。
  多为杀软实时扫描锁定 DLL。
- **对策**：**立即停止全部操作并上报用户**——不要重试、不要排查代码（重试只会继续崩）。
  通常分钟级自愈（实测 60s 内恢复）。根治：把项目目录与 Git 安装目录加入杀软白名单。

### 1.2 管道吞掉缓冲输出（"脚本无输出"的假象）

- **症状**：长脚本 `bash script.sh | tail -20` 什么都没有，看起来像脚本没跑。
- **判定**：MSYS 下管道缓冲 + 脚本被 kill 时缓冲丢弃。
- **对策**：诊断时**重定向到文件**（`bash script.sh > $TEMP/out.log 2>&1`），再看文件；
  或用 `tee`。**不要用管道来判断"脚本有没有输出"**。

### 1.3 原生程序不认 MSYS 路径

- **症状**：`git clone --mirror … /d/backup.git` 之后，备份出现在 **`D:\d\backup.git`**；
  `node /tmp/a.js` → `cannot find module`。
- **判定**：MSYS 路径转换对**原生 Windows 程序**（git.exe / node / python / tar）不生效，
  除非显式开启；`/d/x` 被当成相对路径。
- **对策**：给原生程序一律传 **`D:/x` / `C:/x`** 正斜杠原生路径；
  **bash 内建命令**（`cd` / `ls`）才用 `/d/x`。临时文件优先放 `$LOCALAPPDATA/Temp`，别放 `/tmp`。

### 1.4 其他高频小程序坑

| 症状 | 原因 | 对策 |
|------|------|------|
| `tasklist //FI "…"` 报无效参数、静默失败 | MSYS 吞转义 | `tasklist /FO CSV \| grep` |
| `tr '|' '、'` 输出乱码（`、` 变半个字节）| `tr` 是**单字节**转换，中文多字节被截 | 用 `sed 's/\|/、/g'` |
| `curl … -o /dev/null` 退出码 23（HTTP 明明 200）| MSYS 把 `/dev/null` 转成路径给原生 curl，写入失败 | 空设备**按环境选**：MSYS 用 `NUL`，Linux 用 `/dev/null` |
| 网络预检"直连+代理均不可达"，但浏览器能开 | 预检用 `curl -I`（HEAD）——**代理下恒返回 000** | 改 **GET + 状态码**：`curl -s --max-time 5 <url> -o "$NULL_DEV" -w '%{http_code}'` 判 `^[23]` |
| 长任务（>5 分钟）在 MSYS 下莫名中断 | 前台超时 / shell 被杀 | 用后台 + 完成通知；诊断输出落文件 |

---

## 2. bash 语法隐蔽坑（Linux 与 MSYS 都有）

### 2.1 未引号 heredoc 吃掉反斜杠 → 条件静默失效

- **症状**：写在 `<<EOF`（未引号）里的 `grep -qE '\| Down \|$'` 永远不匹配，注脚/分支**静默不输出**。
- **判定**：未引号 heredoc 先做反斜杠处理，`\|` 变成裸 `|`（ERE 里是"或"）——模式被毁。
  同类：`\(`、`\.`、`\+`。
- **对策**：把**判断逻辑放进函数**（函数内的引号不经过 heredoc），或把结果先算进变量，
  heredoc 里只 `printf '%s' "$VAR"`。**改完必须重新生成产物并 grep 确认出现**（源码里有 ≠ 输出里有）。

### 2.2 声明与赋值同语句的展开时机

```bash
local dir="$1" json="${dir}/report.json"   # ❌ ${dir} 展开时 dir 还是旧的(空) → json 只剩文件名
local dir json; dir="$1"; json="${dir}/report.json"   # ✅ 拆开
local x=$(cmd)                             # ❌ 吞掉 cmd 的退出码
local x; x=$(cmd)                          # ✅
```

### 2.3 其他

| 症状 | 原因 | 对策 |
|------|------|------|
| `[ -f /dir ]` 恒假 | 对目录用文件测试 | 用 `[ -d ]` |
| `grep -c` 无匹配时变量变 `0\n0` | `grep -c` 自身输出 0 且 exit 1，`\|\| echo 0` 又追加一行 | 去掉 `\|\| echo`（grep -c 的 0 就是答案） |
| `grep -c $'\r'` 判 CRLF 结果离谱 | 该写法在部分 shell 展开成字面 `r`，数的是含字母 r 的行 | 用 python 字节级：`data.count(b'\r\n')` |
| `a && b` 在 `set -e` 下中断脚本 | `a` 失败使整条返回 1 | 用 `if a; then b; fi` |
| 数组/变量在 `{ }` 组命令里赋值后丢失 | `{ }` 非子 shell 不丢；`( )` 或管道会丢 | 确认用 `{ }` 或进程替换 `< <(...)` |
| 函数内 `while read` 用 herestring 空读 | MSYS bash 的 herestring quirk | 用 `done < <(printf '%s\n' "$VAR")` |

---

## 3. PowerShell / Windows 工具

| 症状 | 原因 | 对策 |
|------|------|------|
| ps1 中文乱码 / 语法解析失败 | 文件丢失 UTF-8 BOM，PS5.1 按 ANSI 解析 | ps1 **必须带 BOM**；每次用脚本改写后校验（`[System.Text.UTF8Encoding]::new($true)` 重写） |
| `.bat` 中文注释报 "xxx is not recognized" | cmd 按系统代码页解析 | `.bat` **保持纯 ASCII**（中文输出交给 ps1/bash 侧） |
| 交互脚本"卡死"、迟迟无输出 | **`$raw = & cmd` 会缓冲全部输出，命令结束才显示** | 保持**管道流式**：`& cmd 2>&1 \| ForEach-Object { … } \| Out-Host` |
| 打包静默失败：`Cannot connect to C:` | PowerShell 的 `tar` 解析到 Git 自带 **GNU tar**，把盘符当远程主机 | 显式用 `$env:SystemRoot\System32\bsdtar.exe` |
| 首连 ssh 报 host key 中断脚本 | NativeCommandError | `-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR` + 内层作用域 EAP |

---

## 4. 工具调用限制（agent 自身）

| 症状 | 原因 | 对策 |
|------|------|------|
| terminal 命令被 BLOCK（"oversized/unparseable payload"） | 超大 inline payload：heredoc、巨型单行、嵌套引号 | 用 write_file 落脚本文件再 `bash <file>` 执行 |
| WSL 里"函数未定义/变量空/命令找不到"，但代码没问题 | 多层嵌套 `wsl … bash -c '… bash -c "…"'`，外层先展开破坏了内层命令 | 写测试脚本文件 → `cp` 进 WSL → `sed -i 's/\r$//'` → `bash` 执行（单层 `bash -c` 次之） |
| 长脚本运行中出现 `unexpected EOF` / 行为混乱 | 运行中改文件 → bash 读到新旧混合内容 | 改脚本前等它跑完或杀掉；批量验证用后台 + notify |
| `wsl` 命令输出带 `\0` 或 `wsl:` 噪音 | UTF-16 转换 / localhost 警告 | `tr -d '\0'` + `grep -v '^wsl:'` |

---

## 5. git / 推送 / 历史

| 症状 | 原因 | 对策 |
|------|------|------|
| 推送"失败"但远程其实已更新 | 超时被杀 / `timeout` 太短 | **先查远程真实状态**（`git rev-list --count origin/main..HEAD`）再决定是否上报 |
| 推送失败 → 自动重试越重越糟 | 网络不通是用户侧问题 | 按 AGENTS 纪律：**停止重试 → 上报用户 → 等指令** |
| 清 SN 后 `git log -S <SN>` 仍命中 | `-S` 查内容，**message 要单独查** | 三查：内容 `-S` + `git log --format='%s%n%b' \| grep` + 路径 `--name-only` |
| filter-repo 跑完 remote 没了 | 工具行为 | 重新 `git remote add origin <url>` 后 push |
| filter-repo 报 `EOFError`（sanity check） | 需要交互确认 | `printf 'y\ny\ny\n' \| git filter-repo …` |
| 其他机器 clone 分叉（历史重写后） | reset 才能对齐 | 用 `tools/agent/repo_realign.sh`（`--sync` / `--protect`），别盲目 rebase |
| 提交后又想看"能不能重写" | 已推送则禁止重写 | 未推送才能 amend/rebase |

---

## 6. 网络与代理（本机开发）

- **代理端口每次启动都变**：现场探测——`tasklist | grep -iE "v2ray|xray|clash"` 拿 PID →
  `netstat -ano | grep <PID> | grep LISTENING` 拿端口 → `curl -s -x http://127.0.0.1:<port> …` 验证。
- **端口在监听 ≠ 节点已连**：代理界面开着、进程在跑，节点可能断——以 curl 实测为准。
- **不要改 `git config` 的 proxy**：用一次性环境变量（`export HTTPS_PROXY=…`）或走 `tools/agent/git_push.sh`。
- **预检/连通性判断一律用 GET + 状态码**（见 1.4）。
- **隐私**：脚本/文档/README **不写代理产品名**（用户明确要求），统称"本机代理客户端"。

---

## 7. 与本项目强相关的两条

1. **改脚本前先看 `AGENTS.md`**：版本号规则、提交规范、文档三处登记、隐私红线、采集只读铁律都在那里，本文件只补充环境细节。
2. **真机样本目录只读**：`bash modules/*.sh <真实目录>` 会覆盖采集数据（MAC/SN 无备份）——
   验证必须 `cp -r` 到 `$TEMP` 副本、目录名带测试标记；`report/report.sh` 是只读生成器可以就地跑。
