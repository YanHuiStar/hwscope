#!/bin/bash
# =============================================================================
# HwScope — SSH 远程采集
# tools/remote_collect.sh
# 用法: bash tools/remote_collect.sh -H root@10.0.0.1 [hwscope 参数...]
#       bash tools/remote_collect.sh -H user@host --no-sudo --modules gpu,cpu -o ./out
# 功能: 从运维机 SSH 到目标机执行 hwscope 采集（无需登录服务器手动跑），结果回拉本地。
#
# 实现说明（v1.29.0 设计修正）：
#   原方案"ssh 'bash -s' < hwscope.sh 流式执行（远程零落盘）"不可行——hwscope.sh 按
#   $0 相对路径 source lib/ 与 modules/（多文件结构），bash -s 时 $0="bash" 无法定位。
#   改为：tar 临时推送项目（排除 output/logs/.git）→ 远端执行 → 结果 tar 回拉 → 清理远端。
#   同样"零持久占用"（执行后即删），密码不落盘（交互式密码或 SSH key，禁 sshpass 明文密码）。
#
# 凭据（安全立场）: 默认交互式密码（每次登录输入，不落盘）——生产环境标准做法；
#   SSH key 免密仅建议受信内部网络使用（私钥泄露=所有配置了公钥的主机失守，风险扩散）。
# 依赖: ssh/scp/tar（系统自带，零新依赖）
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "用法: $0 -H user@host [hwscope 参数...]"
    echo "选项:"
    echo "  -H user@host       目标机（SSH 用户@主机）"
    echo "  --no-sudo          目标机以当前用户直接执行（默认 sudo bash hwscope.sh）"
    echo "  -o <目录>          本地回拉目录（默认 ./output）"
    echo "  --interactive      保留兼容（默认已支持交互式密码，无需该参数）"
    echo "  -h, --help         帮助"
    echo ""
    echo "透传: 其余参数原样传给远端 hwscope.sh（--modules/--serial/--quiet/--skip/--no-module 等）"
    echo ""
    echo "示例:"
    echo "  bash $0 -H root@10.0.0.1                      # 全量采集并回拉"
    echo "  bash $0 -H root@10.0.0.1 --modules gpu,cpu -o ./out  # 只采部分"
}

HOST=""; SUDO="sudo"; LOCAL_OUT=""; SSH_OPTS="-o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h -o ControlPersist=300"
while [ $# -gt 0 ]; do
    case "$1" in
        -H) HOST="$2"; shift 2 ;;
        --no-sudo) SUDO=""; shift ;;
        -o) LOCAL_OUT="$2"; shift 2 ;;
        --interactive) : ;;   # 默认已支持交互密码（v1.31.4 起），保留参数兼容
        -h|--help) usage; exit 0 ;;
        *) HWARGS="${HWARGS:-} $1"; shift ;;
    esac
done

[ -z "$HOST" ] && { echo -e "\033[0;31m[ERROR] 缺少 -H user@host\033[0m"; usage; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] 未安装 ssh\033[0m"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] 未安装 tar\033[0m"; exit 1; }

TS=$(date '+%Y%m%d%H%M%S')
REMOTE_DIR="/tmp/hwscope_remote_${TS}"
REMOTE_OUT="${REMOTE_DIR}/remote_output"
[ -z "$LOCAL_OUT" ] && LOCAL_OUT="${SCRIPT_DIR}/output"

echo -e "\033[0;36m========================================\033[0m"
echo -e "\033[0;36m  HwScope 远程采集 → ${HOST}\033[0m"
echo -e "\033[0;36m========================================\033[0m"

cleanup() {
    # 远端清理（临时目录 + 采集输出），中断/失败也执行
    ssh $SSH_OPTS "$HOST" "rm -rf ${REMOTE_DIR}" >/dev/null 2>&1
    # 关闭 ControlMaster 复用连接（避免残留）
    ssh -O exit -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h "$HOST" >/dev/null 2>&1
    echo -e "\033[0;33m[INFO] 已清理远端临时目录: ${REMOTE_DIR}\033[0m"
}
trap cleanup EXIT INT TERM

# ─── 1. 连通性 + 权限检查（默认交互式：有 key 自动 key 认证，无 key 提示输密码；ControlMaster 复用后续 ssh） ───
echo -e "\033[0;33m[INFO] 检查 SSH 连通性（无 key 时将提示输入密码）...\033[0m"
if ! ssh $SSH_OPTS "$HOST" "echo ok" >/dev/null 2>&1; then
    echo -e "\033[0;31m[ERROR] SSH 连接失败：请检查目标机用户名/密码/key 配置或网络可达性\033[0m"
    exit 1
fi

# ─── 2. 推送项目（排除 output/logs/.git；conf 含 BMC 凭据会随包到远端，执行后即清理） ───
echo -e "\033[0;33m[INFO] 推送项目到远端 ${REMOTE_DIR} ...\033[0m"
tar czf - --exclude=output --exclude=logs --exclude=.git --exclude='*.tmp' -C "${SCRIPT_DIR}" . \
    | ssh $SSH_OPTS "$HOST" "mkdir -p ${REMOTE_DIR} && tar xzf - -C ${REMOTE_DIR}" \
    || { echo -e "\033[0;31m[ERROR] 项目推送失败\033[0m"; exit 1; }

# ─── 3. 远端执行采集 ───
echo -e "\033[0;33m[INFO] 远端执行: ${SUDO:-} bash hwscope.sh${HWARGS:-} --output ${REMOTE_OUT}\033[0m"
ssh $SSH_OPTS "$HOST" "cd ${REMOTE_DIR} && ${SUDO} bash hwscope.sh${HWARGS:-} --output ${REMOTE_OUT}"
RC=$?
if [ "$RC" -ne 0 ]; then
    echo -e "\033[0;31m[ERROR] 远端采集失败（exit=$RC）\033[0m"
    exit $RC
fi

# ─── 4. 回拉结果（远端 tar → 本地解包；root 归属文件用 sudo tar 读） ───
echo -e "\033[0;33m[INFO] 回拉采集结果 → ${LOCAL_OUT}/\033[0m"
mkdir -p "$LOCAL_OUT"
REMOTE_PARENT=$(dirname "$REMOTE_OUT")
REMOTE_NAME=$(basename "$REMOTE_OUT")
if ! ssh $SSH_OPTS "$HOST" "${SUDO} tar czf - -C ${REMOTE_PARENT} ${REMOTE_NAME}" > "/tmp/hwscope_pull_${TS}.tgz" 2>/dev/null; then
    echo -e "\033[0;31m[ERROR] 结果回拉失败\033[0m"; exit 1
fi
tar xzf "/tmp/hwscope_pull_${TS}.tgz" -C "$LOCAL_OUT"
rm -f "/tmp/hwscope_pull_${TS}.tgz"

# ─── 5. 本地定位采集目录（优先回拉目录名 remote_output，避免 ls -dt 误取本地其他新目录；v1.33.2） ───
PULLED_DIR="${LOCAL_OUT}/${REMOTE_NAME}"
[ ! -d "$PULLED_DIR" ] && PULLED_DIR=$(ls -dt "${LOCAL_OUT}"/*/ 2>/dev/null | head -1 | sed 's|/$||')
echo ""
echo -e "\033[0;32m========================================\033[0m"
echo -e "\033[0;32m  远程采集完成\033[0m"
echo "  采集目录: ${PULLED_DIR}"
echo "  报告: $(ls "${PULLED_DIR}"/hwscope_report.* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
echo -e "\033[0;32m========================================\033[0m"
