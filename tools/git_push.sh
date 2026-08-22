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
#   bash tools/git_push.sh              # 审查+推送（默认 fetch + 逐提交改动摘要，交互确认）
#   bash tools/git_push.sh -y           # 跳过确认直接推（AI agent 场景）
#   bash tools/git_push.sh --no-fetch   # 跳过推送前 fetch（网络极差时）
#   bash tools/git_push.sh --dry-run    # 只审查（环境/待推提交/改动摘要/代理探测），不推送
#   bash tools/git_push.sh --quiet      # 机器可读模式：仅输出状态行与关键信息
#   bash tools/git_push.sh --help       # 帮助
#
# 退出码: 0=推送成功  1=推送失败（网络/代理）  2=用户取消或前置检查不通过
# 状态行: 末尾输出 PUSH_STATUS=OK|FAIL|USER_ABORT（AI agent 解析用）
#
# 环境自适应: git-bash(MSYS)/WSL/原生 Linux 自动识别；Windows 用 tasklist+netstat，
#             Linux 用 pgrep+ss/netstat 探测代理进程与监听端口。
# =============================================================================
set -uo pipefail

# ─── 常量与参数 ───
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # tools/
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"          # 项目根
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
    if ! git fetch "$REMOTE" 2>&1 | tail -2; then
        warn "fetch 失败（网络问题），继续尝试推送（若被拒会提示 pull）"
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
            git pull --rebase "$REMOTE" "$BRANCH" 2>&1 | tail -3 || { fail "rebase 失败（可能冲突）"; status FAIL; exit 1; }
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
try_push() {   # $1=proxy(可空)；timeout 30 + http.connectTimeout 6 防网络挂起
    local proxy="${1:-}"
    if [ -n "$proxy" ]; then
        timeout 30 env HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" git -c http.connectTimeout=6 push "$REMOTE" "$BRANCH" 2>&1 | tail -3
    else
        timeout 30 git -c http.connectTimeout=6 push "$REMOTE" "$BRANCH" 2>&1 | tail -3
    fi
    return "${PIPESTATUS[0]:-1}"
}

# 4.2 代理探测（v2ray/xray/clash 进程 → 监听端口）
detect_proxy() {
    local pid="" port="" wsl_win=0
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
            # WSL interop：Windows 侧 v2ray.exe 进程（但 NAT 下 127.0.0.1 不可达，仅作提示）
            pid="$(/mnt/c/Windows/System32/tasklist.exe /FO CSV 2>/dev/null | grep -iE '"v2ray.exe"' | head -1 | cut -d'"' -f4)"
            wsl_win=1
        fi
        if [ -n "$pid" ]; then
            port="$(ss -tlnp 2>/dev/null | grep "127.0.0.1:" | grep "pid=$pid" | head -1 | awk '{print $4}' | cut -d: -f2)"
            [ -z "$port" ] && port="$(netstat -tlnp 2>/dev/null | grep "127.0.0.1:" | grep "$pid" | head -1 | awk '{print $4}' | cut -d: -f2)"
        fi
    fi
    if [ -n "$port" ] && [ "$port" != "0" ]; then
        echo "http://127.0.0.1:${port}"
    elif [ "${wsl_win}" = "1" ]; then
        echo "WSL_WIN_PROXY_DETECTED"   # Windows 侧有 v2ray 但 NAT 不可达
    fi
}

push_main() {
    local proxy attempt out
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
    # 策略：先快速直连 1 次（connectTimeout 压到 6s）→ 失败再代理（预检+推送）→
    #       代理不可用/失败再回退直连补 2 次。总耗时 <30s，适配短超时 agent（v1.38.2）
    info "推送尝试 1/3（直连，connectTimeout=6s）..."
    out="$(try_push)"
    if [ $? -eq 0 ]; then return 0; fi
    echo "$out" | sed 's/^/    /'

    proxy="$(detect_proxy)"
    if [ "$proxy" = "WSL_WIN_PROXY_DETECTED" ]; then
        fail "检测到 Windows 侧有 v2ray 代理，但 WSL NAT 模式下 127.0.0.1 不可达"
        ai "在 Windows 侧（git-bash）运行本脚本推送；或将 WSL 网络改为镜像模式（.wslconfig networkingMode=mirrored，需重启 WSL）"
    elif [ -n "$proxy" ]; then
        info "发现代理 ${proxy}，验证连通性..."
        if command -v curl >/dev/null 2>&1; then
            if curl -x "$proxy" -sI --max-time 6 https://github.com -o /dev/null; then
                info "代理连通 ✓，走代理推送..."
                out="$(try_push "$proxy")"
                if [ $? -eq 0 ]; then return 0; fi
                echo "$out" | sed 's/^/    /'
                warn "代理推送失败，回退直连..."
            else
                warn "代理端口在监听但节点未连通（代理未连上节点/协议不匹配），回退直连..."
            fi
        else
            info "无 curl，跳过连通性预检直接尝试..."
            out="$(try_push "$proxy")"
            if [ $? -eq 0 ]; then return 0; fi
            echo "$out" | sed 's/^/    /'
        fi
    else
        warn "未探测到本机代理，直连重试..."
    fi

    # 直连补 2 次（间隔 3-5s，处理 Connection reset 偶发）
    for attempt in 2 3; do
        info "推送尝试 ${attempt}/3（直连）..."
        out="$(try_push)"
        if [ $? -eq 0 ]; then return 0; fi
        echo "$out" | sed 's/^/    /'
        [ "$attempt" -lt 3 ] && sleep $((attempt + 2))
    done

    fail "推送失败"
    echo ""
    ai "按顺序处理:"
    ai "  1) 启动本机代理客户端并在界面点击『连接』（进程在跑≠已连节点，须有 v2ray/xray 子进程监听 127.0.0.1 端口）"
    ai "  2) 连上后重跑: bash tools/git_push.sh -y"
    ai "  3) 若输出含 rejected/fetch first: 先 git pull --rebase $REMOTE $BRANCH 再重推"
    ai "  4) 仍失败: 手动确认网络（ping github.com / 浏览器访问 github.com）"
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
    status OK
    exit 0
else
    exit 1
fi
