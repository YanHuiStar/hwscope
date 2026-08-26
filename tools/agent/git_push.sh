#!/bin/bash
# =============================================================================
# git_push.sh — HwScope 一键推送更新（审查 → 直连重试 → 代理兜底 → AI/用户提示）
#
# 背景: GitHub 直连偶发失败（Connection reset / Could not connect），本机代理
#       客户端的 v2ray/xray 子进程监听端口每次启动动态变化。
#       本脚本封装完整推送链，供人类与 AI agent（DeepSeek Harness 等）共用：
#       每个失败分支都会输出 [AI-ACTION] 提示，指明下一步该做什么。
#
# 用法:
#   bash tools/agent/git_push.sh              # 审查+推送（默认 fetch + 逐提交改动摘要，交互确认）
#   bash tools/agent/git_push.sh -y           # 跳过确认直接推（AI agent 场景）
#   bash tools/agent/git_push.sh --no-fetch   # 跳过推送前 fetch（网络极差时）
#   bash tools/agent/git_push.sh --dry-run    # 只审查（环境/待推提交/改动摘要/代理探测），不推送
#   bash tools/agent/git_push.sh --quiet      # 机器可读模式：仅输出状态行与关键信息
#   bash tools/agent/git_push.sh --help       # 帮助
#
# 退出码: 0=推送成功  1=推送失败（网络/代理）  2=用户取消或前置检查不通过
# 状态行: 末尾输出 PUSH_STATUS=OK|FAIL|USER_ABORT（AI agent 解析用）
#
# 环境自适应: git-bash(MSYS)/WSL/原生 Linux 自动识别；Windows 用 tasklist+netstat，
#             Linux 用 pgrep+ss/netstat 探测代理进程与监听端口。
# =============================================================================
set -uo pipefail

# ─── 常量与参数 ───
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # tools/agent/
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"       # 项目根（tools/agent/ 上溯两级）
BRANCH="main"
REMOTE="origin"
PROXY_PROC_NAMES=("v2ray" "xray" "clash")
FETCH_FIRST=1          # 默认推送前 fetch（防推旧：其他 agent 可能已推送）
SKIP_CONFIRM=0
DRY_RUN=0
QUIET=0

for arg in "$@"; do
    case "$arg" in
        --no-fetch) FETCH_FIRST=0 ;;
        -y|--yes) SKIP_CONFIRM=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -q|--quiet) QUIET=1 ;;
        -h|--help)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo -e "\033[0;33m[WARN] 忽略未知参数: $arg\033[0m" ;;
    esac
done

C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
info()  { [ "$QUIET" -eq 1 ] || echo -e "${C_CYAN}[INFO]${C_NC} $*"; }
ok()    { [ "$QUIET" -eq 1 ] || echo -e "${C_GREEN}[OK]${C_NC} $*"; }
warn()  { [ "$QUIET" -eq 1 ] || echo -e "${C_YELLOW}[WARN]${C_NC} $*"; }
fail()  { echo -e "${C_RED}[FAIL]${C_NC} $*"; }
ai()    { [ "$QUIET" -eq 1 ] || echo -e "${C_YELLOW}[AI-ACTION]${C_NC} $*"; }   # 给 AI agent 的明确指令
status() { echo "PUSH_STATUS=$1"; }   # 机器可读状态行（--quiet 也输出）

# ─── 1. 环境检测 ───
detect_env() {
    local os uname_out
    uname_out="$(uname -s 2>/dev/null)"
    case "$uname_out" in
        MINGW*|MSYS*|CYGWIN*) os="git-bash" ;;
        Linux)
            if grep -qi "microsoft" /proc/version 2>/dev/null; then os="wsl"
            else os="linux"; fi ;;
        *) os="unknown" ;;
    esac
    echo "$os"
}
ENV_NAME="$(detect_env)"
info "环境: ${ENV_NAME} | 项目: ${PROJECT_DIR}"

# WSL 且项目在 Windows 盘（/mnt/...）→ 转交 Windows 侧 git_push.bat：
# WSL 网络栈（NAT 出口 + 够不着 Windows 代理）远不如 Windows 侧；bat → git-bash
# 环境 → tasklist/netstat/直连/代理全走 Windows（v1.39.2）
# 递归防护（v1.40.4）：bat 里 `where bash` 可能命中 WSL 的 bash.exe（本机 System32\bash.exe），
# 导致 bat 又调回 WSL bash → 无限转交；GIT_PUSH_HANDOFF=1 时跳过转交，走 WSL 内直连/代理逻辑
if [ "$ENV_NAME" = "wsl" ] && [ "${PROJECT_DIR#/mnt/}" != "$PROJECT_DIR" ] && [ "${GIT_PUSH_HANDOFF:-0}" != "1" ]; then
    win_path="$(wslpath -w "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
    # v1.40.4: git_push.bat 已随 agent 工具迁至 tools/agent/（v1.40.1），此处路径同步，否则 WSL 转交找不到 bat
    bat_path="${win_path}\\tools\\agent\\git_push.bat"
    info "WSL 访问 Windows 盘项目，转交 Windows 侧推送: ${bat_path}"
    # WSLENV 声明后环境变量才传给 Windows 进程（WSL interop 默认只传 WSLENV 白名单）
    WSLENV=GIT_PUSH_NO_PAUSE:GIT_PUSH_HANDOFF GIT_PUSH_NO_PAUSE=1 GIT_PUSH_HANDOFF=1 /mnt/c/Windows/System32/cmd.exe /c "${bat_path}" "$@" 2>&1
    exit $?
fi

# 代理探测（v2ray/xray/clash 进程 → 监听端口）——须在 fetch 前定义（bash 函数先定义后调用）
detect_proxy() {
    local pid="" port=""
    # Windows（tasklist CSV + grep 过滤；MSYS 下 //FI 转义不生效——v1.36.3 教训）
    if [ "$ENV_NAME" = "git-bash" ]; then
        for p in "${PROXY_PROC_NAMES[@]}"; do
            pid="$(tasklist /FO CSV 2>/dev/null | grep -iE "\"${p}\.exe\"" | head -1 | cut -d'"' -f4)"
            [ -n "$pid" ] && [ "$pid" != "0" ] && break
        done
        if [ -n "$pid" ] && [ "$pid" != "0" ]; then
            port="$(netstat -ano 2>/dev/null | grep "LISTENING" | grep "127.0.0.1:" | grep "$pid" | head -1 | awk '{print $2}' | cut -d: -f2)"
        fi
    else
        # Linux/WSL
        # pgrep -f 自匹配陷阱：探测命令自身命令行含 "v2ray" 字符串会被匹配（v1.37.3 实测）
        # 用 [v]2ray 正则字符类技巧排除自身；WSL 内再尝试 Windows 侧 tasklist（interop）
        pid="$(pgrep -f "[v]2ray|[x]ray|[c]lash" 2>/dev/null | head -1)"
        if [ -z "$pid" ] && [ -x /mnt/c/Windows/System32/tasklist.exe ] 2>/dev/null; then
            # WSL interop：Windows 侧 v2ray.exe 进程 + 端口（用 Windows netstat.exe 取监听端口）
            pid="$(/mnt/c/Windows/System32/tasklist.exe /FO CSV 2>/dev/null | grep -iE '"v2ray.exe"' | head -1 | cut -d'"' -f4)"
            if [ -n "$pid" ]; then
                port="$(/mnt/c/Windows/System32/netstat.exe -ano 2>/dev/null | grep "LISTENING" | grep "127.0.0.1:" | grep "$pid" | head -1 | awk '{print $2}' | cut -d: -f2)"
            fi
        fi
        if [ -n "$pid" ] && [ -z "$port" ]; then
            port="$(ss -tlnp 2>/dev/null | grep "127.0.0.1:" | grep "pid=$pid" | head -1 | awk '{print $4}' | cut -d: -f2)"
            [ -z "$port" ] && port="$(netstat -tlnp 2>/dev/null | grep "127.0.0.1:" | grep "$pid" | head -1 | awk '{print $4}' | cut -d: -f2)"
        fi
    fi
    if [ -n "$port" ] && [ "$port" != "0" ]; then
        echo "http://127.0.0.1:${port}"
    fi
}

# 选择 git 命令：WSL 环境用 Windows 的 git.exe（走 Windows 网络栈——127.0.0.1 指向 Windows 自身，
# 可访问 Windows 侧 v2ray 代理；直连也走 Windows 网络栈，成功率高）（v1.38.5 实测）
pick_git() {
    if [ "$ENV_NAME" = "wsl" ] && command -v git.exe >/dev/null 2>&1; then
        echo "git.exe"
    else
        echo "git"
    fi
}

# ─── 2. 前置检查 ───
cd "$PROJECT_DIR" || { fail "无法进入项目目录 ${PROJECT_DIR}"; exit 1; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "不是 git 仓库: ${PROJECT_DIR}"
    ai "在正确的项目目录下运行（应为 hwscope 仓库根）"
    status FAIL
    exit 1
fi

DIRTY="$(git status --short 2>/dev/null)"
if [ -n "$DIRTY" ]; then
    warn "工作区有未提交改动（${PROJECT_DIR}）:"
    echo "$DIRTY" | head -15 | sed 's/^/    /'
    echo ""
    ai "先提交工作区改动（显式 git add <文件>，禁 git add -A），或本机 stash 后再推送；或确认无需提交（如 output/logs 产物）"
    if [ "$DRY_RUN" -eq 0 ] && [ "$SKIP_CONFIRM" -eq 0 ]; then
        echo -n "  仍要继续推送吗？[y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) echo "已取消"; status USER_ABORT; exit 2 ;; esac
    fi
    if [ "$SKIP_CONFIRM" -eq 1 ] && [ -n "$DIRTY" ]; then
        ai "工作区存在未提交改动（可能为其他 agent 在途工作）——推送仅包含已提交内容，改动仍留在本地"
    fi
fi

# ─── 3. fetch 与落后检测 ───
if [ "$FETCH_FIRST" -eq 1 ]; then
    info "fetch 远程（${REMOTE}）..."
    fproxy="$(detect_proxy)"
    if ! "$(pick_git)" fetch "$REMOTE" 2>&1 | tail -2; then
        if [ -n "$fproxy" ]; then
            warn "直连 fetch 失败，走代理 ${fproxy} 重试..."
            HTTPS_PROXY="$fproxy" HTTP_PROXY="$fproxy" "$(pick_git)" fetch "$REMOTE" 2>&1 | tail -2
        fi
    fi
fi

AHEAD="$(git rev-list --count "$REMOTE/$BRANCH"..HEAD 2>/dev/null || echo 0)"
BEHIND="$(git rev-list --count HEAD.."$REMOTE/$BRANCH" 2>/dev/null || echo 0)"
if [ "${AHEAD:-0}" -eq 0 ] && [ "${BEHIND:-0}" -eq 0 ]; then
    ok "本地与远程一致（$REMOTE/$BRANCH），无待推送提交"
    status NOOP
    exit 0
fi
info "待推送: ${AHEAD} 个提交领先远程${BEHIND:+，${BEHIND} 个落后}"
if [ "${BEHIND:-0}" -gt 0 ]; then
    warn "本地落后远程 ${BEHIND} 个提交，直接推送会被拒"
    ai "先 git pull --rebase $REMOTE $BRANCH 合并远程改动（有冲突则解决后重跑本脚本），或 git push --force-with-lease（确认覆盖才用）"
    if [ "$DRY_RUN" -eq 0 ]; then
        echo -n "  自动执行 git pull --rebase ？[y/N] "
        read -r ans
        case "$ans" in y|Y)
            "$(pick_git)" pull --rebase "$REMOTE" "$BRANCH" 2>&1 | tail -3 || { fail "rebase 失败（可能冲突）"; status FAIL; exit 1; }
            ;;
        *) echo "已取消"; status USER_ABORT; exit 2 ;;
        esac
    else
        status USER_ABORT
        exit 2
    fi
fi

if [ "$DRY_RUN" -eq 0 ]; then
    echo ""
    echo "────── 待推送提交与改动摘要（审查） ──────"
    for c in $(git rev-list "$REMOTE/$BRANCH"..HEAD); do
        echo ""
        git log -1 --format="%h %s" "$c" | cat
        git show --stat --format="" "$c" | head -20 | sed 's/^/    /'
    done
    echo ""
    echo "────────────────────────────────────────"
    if [ "$SKIP_CONFIRM" -eq 0 ]; then
        echo -n "审查以上提交后确认推送？[y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) echo "已取消"; status USER_ABORT; exit 2 ;; esac
    fi
fi

# ─── 4. 推送尝试链 ───
# 4.1 直连（重试 N 次，偶发 Connection reset）
try_push() {   # $1=proxy(可空)；WSL 用 Windows git.exe（127.0.0.1 可达 Windows 代理）；timeout+connectTimeout 防挂起
    local proxy="${1:-}" gcmd
    gcmd="$(pick_git)"
    if [ -n "$proxy" ]; then
        timeout 30 env HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" "$gcmd" -c http.connectTimeout=6 push "$REMOTE" "$BRANCH" 2>&1 | tail -3
    else
        timeout 30 "$gcmd" -c http.connectTimeout=6 push "$REMOTE" "$BRANCH" 2>&1 | tail -3
    fi
    return "${PIPESTATUS[0]:-1}"
}

# （detect_proxy/pick_git 已上移至文件前部——fetch 前定义，v1.38.5）

push_main() {
    local proxy attempt out
    # ─── 熔断冷却（v1.45.8）：连续失败 ≥3 次 → 冷却期 5 分钟，期内调用直接快速 FAIL——
    #     防 agent（WorkBuddy 等）在断网时死循环调用 git_push 空转烧积分/时间（用户反馈） ───
    local cooldown_file="${PROJECT_DIR}/.git/git_push_cooldown"
    local fail_count_file="${PROJECT_DIR}/.git/git_push_fail_count"
    if [ -f "$cooldown_file" ] && [ -n "${GIT_PUSH_BYPASS_COOLDOWN:-}" ] && [ "$GIT_PUSH_BYPASS_COOLDOWN" = "1" ]; then
        rm -f "$cooldown_file" "$fail_count_file"
    fi
    if [ -f "$cooldown_file" ]; then
        local cd_until=$(cat "$cooldown_file" 2>/dev/null | tr -d ' ')
        if [ "$(date +%s)" -lt "$cd_until" ] 2>/dev/null; then
            fail "熔断冷却中（连续推送失败，$(date -d "@$cd_until" '+%H:%M:%S' 2>/dev/null || echo 稍后) 后可重试）——网络不通时请勿反复重试，检查代理/直连后再推"
            ai "[PAUSE] 熔断冷却中——暂停推送尝试；上报用户：连续推送失败已触发冷却，网络恢复后告知我再推"
            return 1
        else
            rm -f "$cooldown_file" "$fail_count_file"   # 冷却期结束，复位
        fi
    fi
    # ─── 网络快速预检（v1.45.8）：github.com 直连 3s + 代理 3s 都不通 → 快速 FAIL——
    #     断网时避免 3×21s 直连空转（WorkBuddy 死循环场景每轮开销从 ~90s 降到 ~4s），
    #     预检失败也计入失败计数（连续 3 次仍触发熔断冷却） ───
    local pre_ok=0
    if command -v curl >/dev/null 2>&1; then
        curl -sI --max-time 3 https://github.com -o /dev/null && pre_ok=1
        if [ "$pre_ok" -eq 0 ]; then
            local pre_proxy
            pre_proxy="$(detect_proxy)"
            [ -n "$pre_proxy" ] && curl -x "$pre_proxy" -sI --max-time 3 https://github.com -o /dev/null && pre_ok=1
        fi
        if [ "$pre_ok" -eq 0 ]; then
            local fc0=0
            [ -f "$fail_count_file" ] && fc0=$(cat "$fail_count_file" 2>/dev/null | tr -d ' ')
            fc0=$((fc0 + 1))
            echo "$fc0" > "$fail_count_file"
            [ "$fc0" -ge 3 ] && { echo "$(( $(date +%s) + 300 ))" > "$cooldown_file"; warn "连续 ${fc0} 次失败——已触发 5 分钟熔断冷却"; }
            fail "网络预检失败（直连+代理均不可达，4s 快速判定）——断网状态请勿反复重试，连上节点/网络恢复后再推"
            ai "[PAUSE] 网络预检失败——暂停推送尝试，不要再自动重试；上报用户：检查代理节点是否已连接/网络是否恢复"
            return 1
        fi
    fi
    # 版本单调性检查（v1.37.2）：本地 HWSCOPE_VERSION < 远程 → 拒绝（防凭记忆回退版本；fetch 已在上一步执行）
    local lver rver
    lver=$(grep '^HWSCOPE_VERSION=' "${PROJECT_DIR}/hwscope.sh" 2>/dev/null | head -1 | sed 's/.*"v\(.*\)".*/\1/')
    rver=$(git show "${REMOTE}/${BRANCH}:hwscope.sh" 2>/dev/null | grep '^HWSCOPE_VERSION=' | head -1 | sed 's/.*"v\(.*\)".*/\1/')
    if [ -n "$lver" ] && [ -n "$rver" ] && [ "$lver" != "$rver" ] \
        && [ "$(printf '%s\n%s\n' "$lver" "$rver" | sort -V 2>/dev/null | head -1)" = "$lver" ]; then
        fail "版本回退: 本地 v${lver} < 远程 v${rver}，拒绝推送"
        ai "先 git pull --rebase $REMOTE $BRANCH，在远程 v${rver} 基础上升级版本（tools/sync_version.sh），再重推"
        return 1
    fi
    # 策略：默认直连优先（3 次，connectTimeout=6s 快速失败——直连有时反而能成功，
    #       不因探测到代理就跳过直连）；3 次全失败才走代理兜底（v1.38.3 用户确认）
    for attempt in 1 2 3; do
        info "推送尝试 ${attempt}/3（直连）..."
        out="$(try_push)"
        if [ $? -eq 0 ]; then rm -f "$fail_count_file" "$cooldown_file"; return 0; fi
        echo "$out" | sed 's/^/    /'
        [ "$attempt" -lt 3 ] && sleep 2
    done

    proxy="$(detect_proxy)"
    if [ -n "$proxy" ]; then
        info "发现代理 ${proxy}，验证连通性..."
        if command -v curl >/dev/null 2>&1; then
            if curl -x "$proxy" -sI --max-time 6 https://github.com -o /dev/null; then
                info "代理连通 ✓，走代理推送..."
                out="$(try_push "$proxy")"
                if [ $? -eq 0 ]; then rm -f "$fail_count_file" "$cooldown_file"; return 0; fi
                echo "$out" | sed 's/^/    /'
            else
                warn "代理端口在监听但节点未连通（代理未连上节点/协议不匹配）"
            fi
        else
            info "无 curl，跳过连通性预检直接尝试..."
            out="$(try_push "$proxy")"
            if [ $? -eq 0 ]; then rm -f "$fail_count_file" "$cooldown_file"; return 0; fi
            echo "$out" | sed 's/^/    /'
        fi
    else
        warn "未探测到本机代理"
    fi

    # 失败计数 + 熔断（v1.45.8）：连续 3 次失败 → 冷却 5 分钟（冷却期内调用直接快速 FAIL）
    local fc=0
    [ -f "$fail_count_file" ] && fc=$(cat "$fail_count_file" 2>/dev/null | tr -d ' ')
    fc=$((fc + 1))
    echo "$fc" > "$fail_count_file"
    if [ "$fc" -ge 3 ]; then
        echo "$(( $(date +%s) + 300 ))" > "$cooldown_file"
        warn "连续 ${fc} 次推送失败——已触发 5 分钟熔断冷却（防 agent 死循环烧积分）；网络恢复后重试（或 GIT_PUSH_BYPASS_COOLDOWN=1 手动绕过）"
    else
        warn "推送失败（${fc}/3 次，连续 3 次后触发熔断冷却）"
    fi

    fail "推送失败"
    echo ""
    # v1.45.9：失败后明确指示 AI 暂停推送并上报用户——网络不通是用户侧问题（代理节点/网络状态），
    # 盲目重试只会空转烧 token/积分（WorkBuddy 死循环教训）。不要自动重试，等用户指令。
    ai "[PAUSE] 推送已全部失败——暂停推送尝试，不要再自动重试（每轮重试浪费 token/积分）"
    ai "[REPORT] 将结果上报用户：\"推送失败（原因见上），请检查代理节点是否已连接 / 网络是否恢复，确认后我再推\""
    ai "仅在用户明确说『推送/重试』或确认网络恢复后才重新运行本脚本"
    status FAIL
    return 1
}

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    info "DRY-RUN: 不执行推送。将执行: git push $REMOTE $BRANCH"
    proxy="$(detect_proxy)"
    [ -n "$proxy" ] && info "当前可用的代理探测结果: ${proxy}" || warn "当前未探测到代理进程（直连可用时不必要）"
    status DRY_RUN
    exit 0
fi

if push_main; then
    echo ""
    ok "推送成功: $REMOTE/$BRANCH 已更新（$(git rev-parse --short HEAD)）"
    git log --oneline -1 | cat
    # 同步协作状态文件（防 AGENT_STATE.md 版本过期——推送成功自动刷新，v1.39.5）
    if [ -f "$SCRIPT_DIR/agent_sync.sh" ]; then
        bash "$SCRIPT_DIR/agent_sync.sh" --clear >/dev/null 2>&1 || true
    fi
    status OK
    exit 0
else
    exit 1
fi
