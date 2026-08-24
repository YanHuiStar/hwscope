#!/bin/bash
# =============================================================================
# HwScope — SSH 远程执行
# tools/remote_run.sh
# 用法:
#   bash tools/remote_run.sh -H "root@h1 root@h2" -c "dmidecode -t system | head -20"
#   bash tools/remote_run.sh -H root@h1 --push ./fixcrlf.sh /tmp/fixcrlf.sh
#   bash tools/remote_run.sh -H "root@h1 root@h2" --script ./diag.sh            # 推送+执行本地脚本
#   bash tools/remote_run.sh -H root@h1 --script ./diag.sh --pull-logs /tmp/diag # 执行并拉回过程日志
# 功能: 对 N 台机器执行同一命令 / 推送文件 / 推送并执行本地脚本，逐机收集输出；
#       --pull-logs 把脚本运行产生的日志目录/文件完整拉回（tar-over-ssh，复用 remote_collect 回拉范式）。
# 场景: 集群巡检、批量运维、远程执行诊断/部署脚本并回收过程日志
#       （配合 remote_collect.sh 单机远程采集）。
# 历史: v1.43.0 由 remote_batch.sh 改名（批量运维 → 远程执行，能力扩展：脚本推送执行 + 日志回拉）。
# 凭据（安全立场）: 默认交互式密码（每次登录输入，不落盘）——生产环境标准做法；
#   SSH key 免密仅建议受信内部网络使用（私钥泄露=所有配置了公钥的主机失守，风险扩散）；
#   禁 sshpass 明文密码。
# 依赖: ssh/scp/tar（系统自带，零新依赖）
# 输出: <outdir>/<host>.out（每机输出）+ <outdir>/<host>_logs/（--pull-logs 回拉的日志）+ summary.txt
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "用法: $0 -H \"user@host1 user@host2\" -c \"命令\" [-o 输出目录]"
    echo "      $0 -H user@host --push <本地文件> <远端路径>"
    echo "      $0 -H \"h1 h2\" --script <本地脚本> [--pull-logs <远端日志路径>]"
    echo "选项:"
    echo "  -H host            目标机（可多次，或空格分隔列表）"
    echo "  -c 'cmd'           远程执行命令（原样传给远端 shell）"
    echo "  --push 本地 远端    推送文件到各机（scp）"
    echo "  --script 本地脚本   推送并远程执行本地脚本（自动 scp + bash，v1.43.0）"
    echo "  --pull-logs <路径>  执行后把远端日志目录/文件拉回 outdir/<host>_logs/（tar-over-ssh，v1.43.0）"
    echo "  -o <dir>           输出目录（默认 ./run_output）"
    echo "  --interactive      保留兼容（默认已支持交互式密码，无需该参数）"
    echo "  -h, --help         帮助"
    echo ""
    echo "示例:"
    echo "  $0 -H \"root@10.0.0.1 root@10.0.0.2\" -c 'uptime && nvidia-smi -L'"
    echo "  $0 -H root@10.0.0.1 --script ./diag.sh --pull-logs /tmp/diag   # 远程跑诊断脚本并拉回日志"
}

HOSTS=(); CMD=""; PUSH_LOCAL=""; PUSH_REMOTE=""; SCRIPT_FILE=""; PULL_LOGS=""; OUT_DIR=""
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ControlMaster=auto -o ControlPath=/tmp/ssh_hwscope_run_%r@%h -o ControlPersist=300"
while [ $# -gt 0 ]; do
    case "$1" in
        -H) [ $# -ge 2 ] || { echo -e "\033[0;31m[ERROR] -H 缺少主机列表\033[0m"; exit 1; }; for h in $2; do HOSTS+=("$h"); done; shift 2 ;;
        -c) [ $# -ge 2 ] || { echo -e "\033[0;31m[ERROR] -c 缺少命令\033[0m"; exit 1; }; CMD="$2"; shift 2 ;;
        --push) [ $# -ge 3 ] || { echo -e "\033[0;31m[ERROR] --push 需要 本地文件 与 远端路径\033[0m"; exit 1; }; PUSH_LOCAL="$2"; PUSH_REMOTE="$3"; shift 3 ;;
        --script) [ $# -ge 2 ] || { echo -e "\033[0;31m[ERROR] --script 需要本地脚本路径\033[0m"; exit 1; }; SCRIPT_FILE="$2"; shift 2 ;;
        --pull-logs) [ $# -ge 2 ] || { echo -e "\033[0;31m[ERROR] --pull-logs 需要远端日志路径\033[0m"; exit 1; }; PULL_LOGS="$2"; shift 2 ;;
        -o) [ $# -ge 2 ] || { echo -e "\033[0;31m[ERROR] -o 缺少目录\033[0m"; exit 1; }; OUT_DIR="$2"; shift 2 ;;
        --interactive) : ;;   # 默认已支持交互式密码（v1.31.5 起），保留参数兼容
        -h|--help) usage; exit 0 ;;
        *) echo "[WARN] 未知参数: $1"; shift ;;
    esac
done

[ "${#HOSTS[@]}" -eq 0 ] && { echo -e "\033[0;31m[ERROR] 缺少 -H 目标机\033[0m"; usage; exit 1; }
# 三种执行方式（-c / --push / --script）至少一种且互斥（防命令被静默忽略，v1.33.3 规则扩展）
EXEC_MODE=0
[ -n "$CMD" ] && EXEC_MODE=$((EXEC_MODE+1))
[ -n "$PUSH_LOCAL" ] && EXEC_MODE=$((EXEC_MODE+1))
[ -n "$SCRIPT_FILE" ] && EXEC_MODE=$((EXEC_MODE+1))
[ "$EXEC_MODE" -eq 0 ] && { echo -e "\033[0;31m[ERROR] 需要 -c 命令 / --push 文件 / --script 脚本 之一\033[0m"; usage; exit 1; }
[ "$EXEC_MODE" -gt 1 ] && { echo -e "\033[0;31m[ERROR] -c / --push / --script 互斥，只能选一种（否则命令被静默忽略）\033[0m"; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] 未安装 ssh\033[0m"; exit 1; }
[ -z "$OUT_DIR" ] && OUT_DIR="${SCRIPT_DIR}/run_output"
mkdir -p "$OUT_DIR"

echo -e "\033[0;36m========================================\033[0m"
echo -e "\033[0;36m  SSH 远程执行: ${#HOSTS[@]} 台机器\033[0m"
if [ -n "$CMD" ]; then echo -e "\033[0;36m  命令: ${CMD}\033[0m"; fi
if [ -n "$PUSH_LOCAL" ]; then echo -e "\033[0;36m  推送: ${PUSH_LOCAL} → ${PUSH_REMOTE}\033[0m"; fi
if [ -n "$SCRIPT_FILE" ]; then echo -e "\033[0;36m  脚本: ${SCRIPT_FILE} → /tmp/hwscope_run_<TS>/\033[0m"; fi
if [ -n "$PULL_LOGS" ]; then echo -e "\033[0;36m  日志回拉: ${PULL_LOGS} → <outdir>/<host>_logs/\033[0m"; fi
echo -e "\033[0;36m========================================\033[0m"

TS=$(date '+%Y%m%d%H%M%S')
ok=0; fail=0
for host in "${HOSTS[@]}"; do
    safe="${host//[:\/@]/_}"
    outfile="${OUT_DIR}/${safe}.out"
    echo "────────────────────────────────────────"
    echo "▶ ${host}"
    if [ -n "$SCRIPT_FILE" ]; then
        [ ! -f "$SCRIPT_FILE" ] && { echo -e "  \033[0;31m[ERROR] 本地脚本不存在: ${SCRIPT_FILE}\033[0m"; fail=$((fail+1)); continue; }
        remote_dir="/tmp/hwscope_run_${TS}"
        remote_script="${remote_dir}/$(basename "$SCRIPT_FILE")"
        ssh $SSH_OPTS "$host" "mkdir -p ${remote_dir}" >/dev/null 2>&1   # ControlMaster 复用，不额外提示密码
        scp $SSH_OPTS "$SCRIPT_FILE" "${host}:${remote_script}" > "$outfile" 2>&1 && \
            ssh $SSH_OPTS "$host" "bash ${remote_script}" >> "$outfile" 2>&1
    elif [ -n "$PUSH_LOCAL" ]; then
        [ ! -f "$PUSH_LOCAL" ] && { echo -e "  \033[0;31m[ERROR] 本地文件不存在: ${PUSH_LOCAL}\033[0m"; fail=$((fail+1)); continue; }
        # 远端路径含空白/通配符会被远端 shell 二次拆分——校验拒绝（v1.33.3）
        if echo "$PUSH_REMOTE" | grep -q '[[:space:]]'; then
            echo -e "  \033[0;31m[ERROR] 远端路径不能含空格: ${PUSH_REMOTE}\033[0m"; fail=$((fail+1)); continue
        fi
        scp $SSH_OPTS "$PUSH_LOCAL" "${host}:${PUSH_REMOTE}" > "$outfile" 2>&1
    else
        ssh $SSH_OPTS "$host" "$CMD" > "$outfile" 2>&1
    fi
    rc=$?
    # --pull-logs：执行成功后把远端日志目录/文件完整拉回（tar-over-ssh，复用 remote_collect 回拉范式）
    if [ -n "$PULL_LOGS" ] && [ "$rc" -eq 0 ]; then
        pull_target="${PULL_LOGS%/}"
        pull_parent=$(dirname "$pull_target")
        pull_name=$(basename "$pull_target")
        pull_tgz="${OUT_DIR}/${safe}_logs.tgz"
        if ssh $SSH_OPTS "$host" "cd ${pull_parent} && tar czf - ${pull_name}" > "$pull_tgz" 2>/dev/null && [ -s "$pull_tgz" ]; then
            mkdir -p "${OUT_DIR}/${safe}_logs"
            tar xzf "$pull_tgz" -C "${OUT_DIR}/${safe}_logs" 2>/dev/null
            rm -f "$pull_tgz"
            echo -e "  \033[0;32m[OK] 日志已回拉: ${OUT_DIR}/${safe}_logs/\033[0m"
        else
            rm -f "$pull_tgz"
            echo -e "  \033[1;33m[WARN] 远端日志不存在: ${PULL_LOGS}（脚本可能未生成日志）\033[0m"
        fi
    fi
    if [ "$rc" -eq 0 ]; then ok=$((ok+1)); echo -e "  \033[0;32m[OK] exit=0 (输出: $(basename "$outfile"))\033[0m"
    else fail=$((fail+1)); echo -e "  \033[0;31m[FAIL] exit=$rc (输出: $(basename "$outfile"))\033[0m"; fi
done

# 汇总
exec_desc="$CMD"
[ -n "$SCRIPT_FILE" ] && exec_desc="script ${SCRIPT_FILE}"
[ -n "$PUSH_LOCAL" ] && exec_desc="push ${PUSH_LOCAL} -> ${PUSH_REMOTE}"
{
    echo "SSH 远程执行汇总 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "机器数: ${#HOSTS[@]}  成功: ${ok}  失败: ${fail}"
    echo "执行: ${exec_desc}"
    [ -n "$PULL_LOGS" ] && echo "日志回拉: ${PULL_LOGS}"
    for host in "${HOSTS[@]}"; do
        outfile="${OUT_DIR}/${host//[:\/@]/_}.out"
        rc="?"
        [ -f "$outfile" ] && rc=$(grep -c "^" "$outfile" 2>/dev/null)
        echo "  ${host}: 输出文件 $(basename "$outfile")（$( [ "$rc" = "?" ] && echo 无输出 || echo "${rc} 行" )）"
    done
} > "${OUT_DIR}/summary.txt"
# 关闭 ControlMaster 复用连接（避免残留）
for host in "${HOSTS[@]}"; do
    ssh -O exit -o ControlPath=/tmp/ssh_hwscope_run_%r@%h "$host" >/dev/null 2>&1
done
echo ""
echo -e "\033[0;32m[OK] 输出目录: ${OUT_DIR}/（每机 .out + summary.txt${PULL_LOGS:++ <host>_logs/}）\033[0m"
[ "$fail" -gt 0 ] && exit 1
exit 0
