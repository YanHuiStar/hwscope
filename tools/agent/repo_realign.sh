#!/bin/bash
# =============================================================================
# 仓库对齐工具 — tools/agent/repo_realign.sh
#
# 用途: git 历史被重写（filter-repo 清 SN / 压提交等）后，其他机器的 clone 会与
#       远程分叉——git pull / git push / git_push.sh 的 rebase 全部失败。本脚本把
#       "体检 → 安全对齐 → 本地提交搬回" 固化，避免记忆式操作漏步骤（尤其漏掉
#       "搬回本地提交时又把 SN 带回历史" 这一条）。
#
# 用法:
#   bash tools/agent/repo_realign.sh              # 体检（只读，不动任何东西）
#   bash tools/agent/repo_realign.sh --sync       # 纯同步机对齐（fetch --force + reset --hard）
#                                                 # 仅在"无未推提交 + 无未提交改动"时执行
#   bash tools/agent/repo_realign.sh --protect    # 有本地改动/提交时：备份分支 + stash + 对齐
#                                                 # + 打印逐提交搬回指引（含 SN 自查）
#   bash tools/agent/repo_realign.sh --protect --auto
#                                                 # 在 --protect 基础上自动 cherry-pick 本地提交
#                                                 # （逐提交先扫 SN，命中则跳过该提交并告警）
#
# 退出码: 0=一致或已成功对齐  1=需人工处理  2=网络失败（fetch 不通）
# 说明: 网络预检与 git_push.sh 同源（直连优先，4s 快速判定，代理兜底），不自动重试
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR" || { echo "[ERROR] 无法进入项目目录: $PROJECT_DIR"; exit 1; }

MODE="check"; AUTO=0; NO_FETCH=0
for a in "$@"; do
    case "$a" in
        --sync)    MODE="sync" ;;
        --protect) MODE="protect" ;;
        --auto)    AUTO=1 ;;
        --no-fetch) NO_FETCH=1 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[WARN] 未知参数: $a（忽略）" ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── 环境检测 / 空设备（与 git_push.sh 同源）───
# MSYS(git-bash) 下把 /dev/null 传给 native curl 时路径被转换 → curl 退出码 23
# （CURLE_WRITE_ERROR）→ 叠加 pipefail 后 curl|grep 整条判定失败：症状是 HTTP 200 却"预检失败"
detect_env() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) echo "git-bash" ;;
        Linux) grep -qi "microsoft" /proc/version 2>/dev/null && echo "wsl" || echo "linux" ;;
        *) echo "unknown" ;;
    esac
}
ENV_NAME="$(detect_env)"
NULL_DEV="/dev/null"
[ "$ENV_NAME" = "git-bash" ] && NULL_DEV="NUL"

# ─── 网络预检（与 git_push.sh 同策略：直连优先，快速判定，代理兜底，不自动重试）───
# v1.48.74：预检必须用 GET + 状态码校验——HEAD(-I) 在本机代理下恒返回 000，
# 会导致"代理明明可用却判定直连+代理均不可达"（git_push v1.48.66 同修）
net_precheck() {
    command -v curl >/dev/null 2>&1 || return 0   # 无 curl 则跳过预检（交给 git 自己失败）
    curl -s --max-time 5 https://github.com -o "$NULL_DEV" -w '%{http_code}' 2>/dev/null | grep -qE '^[23]' && return 0
    local pid port
    pid=$(tasklist 2>/dev/null | grep -iE "v2ray|xray|clash" | awk '{print $2}' | head -1)
    if [ -n "$pid" ]; then
        port=$(netstat -ano 2>/dev/null | grep "$pid" | grep LISTENING | awk '{print $2}' | head -1 | sed 's/.*://')
        if [ -n "$port" ] && curl -s -x "http://127.0.0.1:${port}" --max-time 8 https://github.com -o "$NULL_DEV" -w '%{http_code}' 2>/dev/null | grep -qE '^[23]'; then
            export HTTPS_PROXY="http://127.0.0.1:${port}" HTTP_PROXY="http://127.0.0.1:${port}"
            info "直连不可达，改用代理 127.0.0.1:${port}"
            return 0
        fi
    fi
    return 2
}

echo "========================================"
echo "  仓库对齐体检 — repo_realign"
echo "========================================"

if [ "$NO_FETCH" -eq 1 ]; then
    info "跳过 fetch（--no-fetch，使用本地已有的 origin/main 引用做体检）"
else
    info "拉取远程（fetch --force）..."
    net_precheck || { err "网络预检失败（直连+代理均不可达）——停止，请检查网络/代理后重试"; exit 2; }
    git fetch --force origin 2>&1 | tail -2
    [ $? -ne 0 ] && { err "fetch 失败（网络或凭据问题）"; exit 2; }
fi

LOCAL_HEAD=$(git rev-parse --short HEAD 2>/dev/null)
REMOTE_HEAD=$(git rev-parse --short origin/main 2>/dev/null)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
echo ""
echo "  分支      : ${BRANCH}"
echo "  本地 HEAD : ${LOCAL_HEAD}"
echo "  远程 HEAD : ${REMOTE_HEAD}"

# 未提交改动 / 未推提交
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null)
BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null)
echo "  未提交改动: ${DIRTY} 个文件"
echo "  本地未推  : ${AHEAD} 个提交"
echo "  远程领先  : ${BEHIND} 个提交"

# 是否分叉（本地含远程没有的提交，且不是快进关系）
DIVERGED=0
if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    DIVERGED=1
fi

# ─── 本地独有提交的 SN 自查（历史重写搬回前必查——防把 SN 又带回历史）───
sn_scan() {
    local range="$1"
    [ -z "$range" ] && return 0
    git log "$range" --format="%h|%s%n%b" 2>/dev/null \
        | grep -nE "[A-Z]{2,}[0-9]{5,}|[0-9]{11,}" | head -10
}

echo ""
if [ "$DIVERGED" -eq 1 ]; then
    warn "本地与远程已分叉（远程历史被重写过的典型症状）"
else
    ok "本地是远程的后代或一致（无分叉）"
fi

if [ "$AHEAD" -gt 0 ]; then
    warn "本地有 ${AHEAD} 个未推提交——搬回前必须逐个查 SN："
    _sn_hits=$(sn_scan "origin/main..HEAD")
    if [ -n "$_sn_hits" ]; then
        echo -e "${RED}  ⚠️ 命中疑似 SN（真实采集数据标识），这些提交禁止搬回远程历史：${NC}"
        echo "$_sn_hits" | sed 's/^/    /'
    else
        ok "  未在提交内容/消息中发现疑似 SN 特征"
    fi
fi

if [ "$DIRTY" -eq 0 ] && [ "$AHEAD" -eq 0 ] && [ "$DIVERGED" -eq 0 ]; then
    ok "仓库已与远程一致，无需操作"
    exit 0
fi

# ─── 动作 ───
case "$MODE" in
    check)
        echo ""
        info "仅体检模式。要执行对齐："
        if [ "$DIRTY" -eq 0 ] && [ "$AHEAD" -eq 0 ]; then
            echo "    bash tools/agent/repo_realign.sh --sync      # 纯同步机（无本地改动，安全）"
        else
            echo "    bash tools/agent/repo_realign.sh --protect   # 有本地改动/提交（自动备份保护）"
        fi
        [ "$DIVERGED" -eq 1 ] && exit 1 || exit 0
        ;;

    sync)
        if [ "$DIRTY" -ne 0 ] || [ "$AHEAD" -ne 0 ]; then
            err "--sync 仅用于无本地改动的纯同步机（当前 未提交=${DIRTY} 未推=${AHEAD}）"
            echo "    请改用: bash tools/agent/repo_realign.sh --protect"
            exit 1
        fi
        info "对齐远程（reset --hard origin/main）..."
        git reset --hard origin/main 2>&1 | tail -1
        ok "已对齐: $(git log --oneline -1)"
        exit 0
        ;;

    protect)
        BK="backup-$(date +%Y%m%d%H%M%S)"
        info "① 备份当前分支为 ${BK}（本地提交/改动随时可回溯）"
        git branch "$BK" 2>/dev/null && ok "  已创建分支 ${BK}"

        STASHED=0
        if [ "$DIRTY" -ne 0 ]; then
            info "② 暂存未提交改动（stash push -u）"
            git stash push -u -m "repo_realign ${BK}" >/dev/null 2>&1 && STASHED=1 && ok "  已 stash"
        else
            info "② 无未提交改动，跳过 stash"
        fi

        info "③ 对齐远程（reset --hard origin/main）"
        git reset --hard origin/main 2>&1 | tail -1
        ok "  已对齐: $(git log --oneline -1)"

        BACKLOG=$(git log --oneline "${BK}" --not origin/main 2>/dev/null | wc -l | tr -d ' ')
        if [ "$BACKLOG" -eq 0 ]; then
            [ "$STASHED" -eq 1 ] && { info "④ 恢复未提交改动（stash pop）"; git stash pop 2>&1 | tail -2; }
            ok "完成（无本地独有提交需搬回）"
            exit 0
        fi

        echo ""
        info "④ 本地独有提交 ${BACKLOG} 个，需逐个搬回（先查 SN——禁止搬回含真实 SN 的提交）"
        git log --oneline "${BK}" --not origin/main 2>/dev/null | sed 's/^/    /'
        echo ""
        for sha in $(git rev-list --reverse "${BK}" --not origin/main 2>/dev/null); do
            hits=$(git show "$sha" --format="%s%n%b" --name-only 2>/dev/null | grep -nE "[A-Z]{2,}[0-9]{5,}|[0-9]{11,}" | head -3)
            if [ -n "$hits" ]; then
                echo -e "${RED}    SKIP ${sha:0:8}（命中疑似 SN，禁止搬回）:${NC}"
                echo "$hits" | sed 's/^/      /'
                continue
            fi
            if [ "$AUTO" -eq 1 ]; then
                if git cherry-pick "$sha" >/dev/null 2>&1; then
                    ok "    已搬回 ${sha:0:8}"
                else
                    warn "    ${sha:0:8} cherry-pick 冲突——已中止，请手动处理"
                    git cherry-pick --abort >/dev/null 2>&1
                fi
            else
                echo "    git cherry-pick ${sha:0:8}      # 确认无 SN 后执行"
            fi
        done
        if [ "$AUTO" -eq 0 ]; then
            echo ""
            info "确认上述提交均无 SN 后，逐条执行 cherry-pick；或加 --auto 自动执行"
        fi
        [ "$STASHED" -eq 1 ] && { info "⑤ 恢复未提交改动（stash pop）"; git stash pop 2>&1 | tail -2; }
        exit 0
        ;;
esac
