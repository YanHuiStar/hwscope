#!/bin/bash
# =============================================================================
# HwScope — SSH 远程采集
# tools/remote_collect.sh
# 用法: bash tools/remote_collect.sh -H root@10.0.0.1 [hwscope 参数...]
#       bash tools/remote_collect.sh -H user@host --no-sudo --modules gpu,cpu -o ./out
# 功能: 从运维机 SSH 到目标机执行 hwscope 采集（无需登录服务器手动跑），结果回拉本地。
#       --install <1,2,...> 可先远端非交互安装依赖（install_tool -c/-y）再采集——远程冷启动一条龙（v1.42.0）。
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
    echo "  --install <1,2,...> 推送后先远端安装依赖（install_tool -c/-y 非交互）再采集——冷启动装基础环境"
    echo "  -o <目录>          本地回拉目录（默认 ./output）"
    echo "  --interactive      保留兼容（默认已支持交互式密码，无需该参数）"
    echo "  -h, --help         帮助"
    echo ""
    echo "透传: 其余参数原样传给远端 hwscope.sh（--modules/--serial/--quiet/--skip/--no-module 等）"
    echo ""
    echo "示例:"
    echo "  bash $0 -H root@10.0.0.1                      # 全量采集并回拉"
    echo "  bash $0 -H root@10.0.0.1 --modules gpu,cpu -o ./out  # 只采部分"
    echo "  bash $0 -H root@10.0.0.1 --install 1,2         # 先装基础+压测依赖再采集"
}

HOST=""; SUDO="sudo"; LOCAL_OUT=""; INSTALL_ITEMS=""; SSH_OPTS="-o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h -o ControlPersist=300"
# 清理残留 ControlMaster socket：上次运行 ssh -O exit 后 socket 文件可能残留，
# 新 ssh 尝试复用已死 master → "Shared connection closed" / 回拉非 gzip（v1.43.4 实测）
rm -f /tmp/ssh_hwscope_mux_* 2>/dev/null || true
while [ $# -gt 0 ]; do
    case "$1" in
        -H) HOST="$2"; shift 2 ;;
        --no-sudo) SUDO=""; shift ;;
        -o) LOCAL_OUT="$2"; shift 2 ;;
        --install) INSTALL_ITEMS="$2"; shift 2 ;;   # 注意：必须在 *) 透传之前匹配，否则会被当 hwscope 参数
        --interactive) : ;;   # 默认已支持交互密码（v1.31.4 起），保留参数兼容
        -h|--help) usage; exit 0 ;;
        *) HWARGS="${HWARGS:-} $1"; shift ;;
    esac
done

[ -z "$HOST" ] && { echo -e "\033[0;31m[ERROR] 缺少 -H user@host\033[0m"; usage; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] 未安装 ssh\033[0m"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] 未安装 tar\033[0m"; exit 1; }

# root 用户自动免 sudo（root 登录无需提权）；普通用户 + sudo 步骤用 -t 分配 tty 供 sudo 交互输密码
case "$HOST" in
    root@*) SUDO="" ;;
esac
SSH_TTY_OPTS="$SSH_OPTS -t"

TS=$(date '+%Y%m%d%H%M%S')
REMOTE_DIR="/tmp/hwscope_remote_${TS}"
REMOTE_OUT="${REMOTE_DIR}/remote_output"
[ -z "$LOCAL_OUT" ] && LOCAL_OUT="${SCRIPT_DIR}/output"

echo -e "\033[0;36m========================================\033[0m"
echo -e "\033[0;36m  HwScope 远程采集 → ${HOST}\033[0m"
echo -e "\033[0;36m========================================\033[0m"

cleanup() {
    # 远端清理（回拉命令内已 rm -rf，此处为中断/失败时的兜底幂等清理；打印在横幅前由主流程完成，避免顺序错乱）
    ssh $SSH_OPTS "$HOST" "rm -rf ${REMOTE_DIR}" >/dev/null 2>&1
    # 关闭 ControlMaster 复用连接（避免残留）并删除 socket 文件（防下次复用已死 master）
    ssh -O exit -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h "$HOST" >/dev/null 2>&1
    rm -f /tmp/ssh_hwscope_mux_* 2>/dev/null || true
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

# ─── 3. 远端安装依赖（--install 时）+ 执行采集 ───
# --install：推送后先跑 install_tool -c/-y 非交互装依赖，再采集。
# 普通用户 + sudo 时把安装+采集合并为一条 -t 命令（同一 tty 内 sudo 密码缓存，只输一次）；
# root 免 sudo 直接执行。安装失败（&& 短路）→ 采集不跑，退出码非零报错。
if [ -n "$INSTALL_ITEMS" ]; then
    echo -e "\033[0;33m[INFO] 远端安装依赖: install_tool -c ${INSTALL_ITEMS} -y（非交互）→ 采集 hwscope.sh${HWARGS:-}\033[0m"
    # ${SUDO:+${SUDO} }：root 免 sudo 时为空（命令干净），普通用户时补 "sudo "（同一 -t 会话 sudo 密码只输一次）
    REMOTE_CMD="cd ${REMOTE_DIR} && ${SUDO:+${SUDO} }bash tools/install_tool.sh -c ${INSTALL_ITEMS} -y && ${SUDO:+${SUDO} }bash hwscope.sh${HWARGS:-}"
else
    echo -e "\033[0;33m[INFO] 远端执行: ${SUDO:+${SUDO} }bash hwscope.sh${HWARGS:-}（默认输出 output/<MACHINE_ID>/）\033[0m"
    REMOTE_CMD="cd ${REMOTE_DIR} && ${SUDO:+${SUDO} }bash hwscope.sh${HWARGS:-}"
fi
ssh $([ -n "$SUDO" ] && echo "$SSH_TTY_OPTS" || echo "$SSH_OPTS") "$HOST" "$REMOTE_CMD"
RC=$?
if [ "$RC" -ne 0 ]; then
    if [ -n "$INSTALL_ITEMS" ]; then
        echo -e "\033[0;31m[ERROR] 远端安装/采集失败（exit=$RC；安装失败请检查目标机包源网络可达性）\033[0m"
    else
        echo -e "\033[0;31m[ERROR] 远端采集失败（exit=$RC）\033[0m"
    fi
    exit $RC
fi

# ─── 4. 回拉结果（-C 切换打包 output/<MACHINE_ID>/ 内容 + logs/；解包到 output/remote_output/ 固定层，对标本地结构；归档包落 logs/remote_logs/） ───
echo -e "\033[0;33m[INFO] 回拉采集结果 + 归档包 → ${LOCAL_OUT}/remote_output/\033[0m"
mkdir -p "${LOCAL_OUT}/remote_output"
# 回拉：2>/dev/null 丢弃 stderr（旧版 tar 无 --warning=no-timestamp 支持时 future 时间戳警告刷屏；
# 警告无害——tar 失败有 exit code 检查 + 本地解包校验双重兜底）
if ! ssh $([ -n "$SUDO" ] && echo "$SSH_TTY_OPTS" || echo "$SSH_OPTS") "$HOST" "${SUDO} tar czf - --warning=no-timestamp -C ${REMOTE_DIR}/output . -C ${REMOTE_DIR} logs; rm -rf ${REMOTE_DIR}" > "/tmp/hwscope_pull_${TS}.tgz" 2>/dev/null; then
    echo -e "\033[0;31m[ERROR] 结果回拉失败\033[0m"; exit 1
fi
# 本地解包同样丢弃 stderr：旧版 tar 对未来时间戳（目标机时钟偏差）解包也警告刷屏——v1.43.5 实测根因
tar xzf "/tmp/hwscope_pull_${TS}.tgz" -C "${LOCAL_OUT}/remote_output" 2>/dev/null || { echo -e "\033[0;31m[ERROR] 回拉数据损坏或为空（远端打包失败？）\033[0m"; exit 1; }
rm -f "/tmp/hwscope_pull_${TS}.tgz"

# 归档包移到 logs/remote_logs/（与本地采集日志区分；远端 logs/ 解包到了 LOCAL_OUT/remote_output/logs）
# 合并逻辑：report 子目录目标已存在时逐个文件移入（mv 目录到非空目录会 Directory not empty 失败——重复跑场景）
if [ -d "${LOCAL_OUT}/remote_output/logs" ] && [ -n "$(ls -A "${LOCAL_OUT}/remote_output/logs" 2>/dev/null)" ]; then
    mkdir -p "${SCRIPT_DIR}/logs/remote_logs"
    for _item in "${LOCAL_OUT}/remote_output/logs"/*; do
        [ -e "$_item" ] || continue
        _b=$(basename "$_item")
        if [ -d "$_item" ]; then
            mkdir -p "${SCRIPT_DIR}/logs/remote_logs/${_b}"
            mv "$_item"/* "${SCRIPT_DIR}/logs/remote_logs/${_b}/" 2>/dev/null
        else
            mv "$_item" "${SCRIPT_DIR}/logs/remote_logs/" 2>/dev/null
        fi
    done
    rmdir "${LOCAL_OUT}/remote_output/logs" 2>/dev/null
fi

# ─── 5. 完成信息（find 报告文件定位——不依赖时间排序，logs 残留不会误选；远端已在回拉命令内清理，此处主动提示——与 Windows 版排版一致：清理信息在横幅前） ───
PULLED_DIR=$(find "${LOCAL_OUT}/remote_output" -maxdepth 2 -name hwscope_report.json 2>/dev/null | head -1 | xargs -r dirname)
echo -e "\033[0;33m[INFO] 已清理远端临时目录: ${REMOTE_DIR}\033[0m"
echo ""
echo -e "\033[0;32m========================================\033[0m"
echo -e "\033[0;32m  远程采集完成\033[0m"
echo "  采集目录: ${PULLED_DIR}"
echo "  报告: $(ls "${PULLED_DIR}"/hwscope_report.* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
echo -e "\033[0;32m========================================\033[0m"
