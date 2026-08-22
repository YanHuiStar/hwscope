#!/bin/bash
# =============================================================================
# agent_sync.sh — 多机器/多 Agent 协作同步检查（v1.37.2）
#
# 背景: 同一仓库可能被多个机器/多个 Agent 会话（DeepSeek Harness / Hermes 等）
#       先后修改提交推送。各会话凭记忆操作易导致版本号回退/跳号、推送交叉。
#       本脚本强制"以远程 origin/main 为真相"同步认知，防止此类问题。
#
# 用法:
#   bash tools/agent_sync.sh            # 开工前：fetch + 展示 远程/本地 HEAD/版本/未推送 + 版本对比；更新本地状态文件
#   bash tools/agent_sync.sh --mark     # 提交后：标记"未推送提交"到本地状态文件（自动取 HEAD hash/版本）
#   bash tools/agent_sync.sh --clear    # 推送成功后：清空本地状态文件的未推送标记
#   bash tools/agent_sync.sh --help
#
# 设计:
#   - 跨机器状态以远程为准：fetch 后 origin/main 的 HEAD 与 HWSCOPE_VERSION 即真相
#   - 本地 AGENT_STATE.md（gitignore）仅协调单机多会话"进行中/未推送"，不承担跨机器
#   - 版本号只升不降：本地 < 远程时明确告警（git_push.sh 另有硬拦截）
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # tools/
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"          # 项目根
STATE_FILE="${PROJECT_DIR}/AGENT_STATE.md"
BRANCH="main"
REMOTE="origin"
# MSYS/git-bash 下 git -C <msys路径> 会 chdir 失败（v1.37.2 实测），统一 cd 后再跑 git
cd "$PROJECT_DIR" || { echo "[SYNC] 无法进入项目目录 ${PROJECT_DIR}" >&2; exit 1; }

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
info() { echo -e "${C_CYAN}[SYNC]${C_NC} $*"; }
ok()   { echo -e "${C_GREEN}[SYNC]${C_NC} $*"; }
warn() { echo -e "${C_YELLOW}[SYNC]${C_NC} $*"; }
fail() { echo -e "${C_RED}[SYNC]${C_NC} $*"; }

ACTION="${1:-show}"

# ─── 版本比较（分段数值比较，支持 vX.Y.Z） ───
ver_lt() {   # $1 < $2 → 0
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | head -1)" = "$1" ]
}

get_local_ver() { grep '^HWSCOPE_VERSION=' "${PROJECT_DIR}/hwscope.sh" 2>/dev/null | head -1 | sed 's/.*"v\(.*\)".*/\1/'; }

# ─── 更新状态文件某一行（key 前缀替换，保留文件其余） ───
init_state() {   # 文件不存在时生成基础模板（新机器 clone 后首次运行）
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" <<'EOF'
# Agent 状态文件（本地协调用，已 gitignore，勿提交到 git）

> 用途：协调**同一台机器**上多个 Agent 会话的"进行中/未推送"状态（git 看不到的部分）。
> 跨机器状态以远程为准（`git fetch origin` 后 origin/main 的 HEAD/版本即真相）。
> 操作统一走 `bash tools/agent_sync.sh`（查看/--mark 提交后标记/--clear 推送成功后清空），勿手改。

## 本机当前状态（每次开工/提交/推送后更新）

- 最新本地提交: （未初始化）
- 当前版本: v?
- 未推送提交: （无）

## 操作记录（滚动保留最近 10 条，旧行可删）

| 时间 | 动作 | 提交 | 版本 | 备注 |
|------|------|------|------|------|
EOF
        ok "已初始化本地状态文件（AGENT_STATE.md）"
    fi
}

update_state() {   # $1=行前缀 $2=新值
    local key="$1" val="$2"
    [ -f "$STATE_FILE" ] || return 0
    sed -i "s|^\\(${key}:\\).*|\\1 ${val}|" "$STATE_FILE" 2>/dev/null || true
}

case "$ACTION" in
    -h|--help)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac

# ─── 提交后标记：取 HEAD hash/版本，写状态文件 ───
if [ "$ACTION" = "--mark" ]; then
    init_state
    HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
    SUBJ=$(git log -1 --pretty=%s 2>/dev/null | cut -c1-60)
    VER=$(get_local_ver)
    update_state "- 未推送提交" "${HASH} ${SUBJ}（版本 v${VER:-?}）"
    update_state "- 最新本地提交" "${HASH} ${SUBJ}"
    ok "已标记未推送: ${HASH} ${SUBJ}"
    exit 0
fi

# ─── 推送成功后清空 ───
if [ "$ACTION" = "--clear" ]; then
    init_state
    update_state "- 未推送提交" "（无——推送成功后已清空）"
    ok "已清空未推送标记（确认 ${REMOTE}/${BRANCH} 已更新）"
    exit 0
fi

# ─── 默认：show（开工检查） ───
if [ "$ACTION" != "show" ]; then
    warn "未知参数: $ACTION（支持: 无参数/--mark/--clear/--help）"
    exit 1
fi

info "fetch ${REMOTE}（以远程为真相）..."
git fetch "$REMOTE" "$BRANCH" 2>&1 | tail -1

# 远程状态
R_HASH=$(git rev-parse --short "${REMOTE}/${BRANCH}" 2>/dev/null || echo "?")
R_VER=$(git show "${REMOTE}/${BRANCH}:hwscope.sh" 2>/dev/null | grep '^HWSCOPE_VERSION=' | head -1 | sed 's/.*"v\(.*\)".*/\1/')
# 本地状态
L_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
L_VER=$(get_local_ver)
AHEAD=$(git rev-list --count "${REMOTE}/${BRANCH}"..HEAD 2>/dev/null || echo 0)
BEHIND=$(git rev-list --count HEAD.."${REMOTE}/${BRANCH}" 2>/dev/null || echo 0)
DIRTY=$(git status --short 2>/dev/null | wc -l)

echo ""
info "远程 ${REMOTE}/${BRANCH} : ${R_HASH}${R_VER:+ v${R_VER}}"
info "本地 HEAD           : ${L_HASH}${L_VER:+ v${L_VER}}"
info "未推送/落后          : ahead ${AHEAD} · behind ${BEHIND} · 工作区改动 ${DIRTY} 个文件"
if [ "${AHEAD:-0}" -gt 0 ] || [ "${DIRTY:-0}" -gt 0 ]; then
    echo -e "${C_YELLOW}  ↳ 有未推送/未提交内容：提交后运行 'bash tools/agent_sync.sh --mark'；推送用 'bash tools/git_push.sh -y'${C_NC}"
fi
if [ "${BEHIND:-0}" -gt 0 ]; then
    warn "本地落后远程 ${BEHIND} 个提交（其他会话/机器已推送）——推送前需 rebase（git_push 会自动处理）"
fi

# 版本对比（防凭记忆升错版本）
if [ -n "$R_VER" ] && [ -n "$L_VER" ] && [ "$L_VER" != "$R_VER" ]; then
    if ver_lt "$L_VER" "$R_VER"; then
        fail "版本回退风险: 本地 v${L_VER} < 远程 v${R_VER}"
        echo -e "${C_YELLOW}  ↳ 禁止在本地版本基础上升号；请 fetch 后在远程 v${R_VER} 基础上升级（sync_version 前先确认）${C_NC}"
    else
        ok "版本领先: 本地 v${L_VER} > 远程 v${R_VER}（正常，推送后远程将更新）"
    fi
else
    info "版本: 本地 v${L_VER:-?} / 远程 v${R_VER:-?}"
fi

# 更新状态文件（未推送标记由 --mark/--clear 维护，此处只刷新最新提交/版本）
init_state
update_state "- 最新本地提交" "${L_HASH} $(git log -1 --pretty=%s 2>/dev/null | cut -c1-60)"
update_state "- 当前版本" "v${L_VER:-?}"
if [ "${AHEAD:-0}" -eq 0 ]; then
    update_state "- 未推送提交" "（无）"
fi
ok "本地状态文件已刷新（AGENT_STATE.md，gitignore）"
