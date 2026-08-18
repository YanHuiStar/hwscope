#!/bin/bash
# =============================================================================
# HwScope — SSH 批量运维
# tools/remote_batch.sh
# 用法:
#   bash tools/remote_batch.sh -H "root@h1 root@h2" -c "dmidecode -t system | head -20"
#   bash tools/remote_batch.sh -H root@h1 -H root@h2 --push ./script.sh /tmp/script.sh
#   bash tools/remote_batch.sh -H "root@h1 root@h2" -c "bash hwscope.sh --modules gpu"
# 功能: 对 N 台机器执行同一命令/推送同一文件并收集输出（逐机一个文件 + 汇总）。
# 场景: 集群巡检、批量运维（配合 remote_collect.sh 单机远程采集）。
# 凭据（安全立场）: 默认交互式密码（每次登录输入，不落盘）——生产环境标准做法；
#   SSH key 免密仅建议受信内部网络使用（私钥泄露=所有配置了公钥的主机失守，风险扩散）；
#   禁 sshpass 明文密码。
# 依赖: ssh/scp（系统自带，零新依赖）
# 输出: <outdir>/<host>.out（每机输出）+ <outdir>/summary.txt（exit code 汇总）
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "用法: $0 -H \"user@host1 user@host2\" -c \"命令\" [-o 输出目录]"
    echo "      $0 -H user@host --push <本地文件> <远端路径>"
    echo "选项:"
    echo "  -H host           目标机（可多次，或空格分隔列表）"
    echo "  -c 'cmd'          批量执行命令（原样传给远端 shell）"
    echo "  --push 本地 远端   推送文件到各机（scp）"
    echo "  -o <dir>          输出目录（默认 ./batch_output）"
    echo "  --interactive     保留兼容（默认已支持交互式密码，无需该参数）"
    echo "  -h, --help        帮助"
    echo ""
    echo "示例:"
    echo "  $0 -H \"root@10.0.0.1 root@10.0.0.2\" -c 'uptime && nvidia-smi -L'"
    echo "  $0 -H root@10.0.0.1 --push fixcrlf.sh /tmp/fixcrlf.sh"
}

HOSTS=(); CMD=""; PUSH_LOCAL=""; PUSH_REMOTE=""; OUT_DIR=""; SSH_OPTS="-o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/tmp/ssh_hwscope_batch_%r@%h -o ControlPersist=300"
while [ $# -gt 0 ]; do
    case "$1" in
        -H) for h in $2; do HOSTS+=("$h"); done; shift 2 ;;
        -c) CMD="$2"; shift 2 ;;
        --push) PUSH_LOCAL="$2"; PUSH_REMOTE="$3"; shift 3 ;;
        -o) OUT_DIR="$2"; shift 2 ;;
        --interactive) : ;;   # 默认已支持交互式密码（v1.31.5 起），保留参数兼容
        -h|--help) usage; exit 0 ;;
        *) echo "[WARN] 未知参数: $1"; shift ;;
    esac
done

[ "${#HOSTS[@]}" -eq 0 ] && { echo -e "\033[0;31m[ERROR] 缺少 -H 目标机\033[0m"; usage; exit 1; }
[ -z "$CMD" ] && [ -z "$PUSH_LOCAL" ] && { echo -e "\033[0;31m[ERROR] 需要 -c 命令 或 --push 文件\033[0m"; usage; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] 未安装 ssh\033[0m"; exit 1; }
[ -z "$OUT_DIR" ] && OUT_DIR="${SCRIPT_DIR}/batch_output"
mkdir -p "$OUT_DIR"

echo -e "\033[0;36m========================================\033[0m"
echo -e "\033[0;36m  SSH 批量运维: ${#HOSTS[@]} 台机器\033[0m"
if [ -n "$CMD" ]; then echo -e "\033[0;36m  命令: ${CMD}\033[0m"; fi
if [ -n "$PUSH_LOCAL" ]; then echo -e "\033[0;36m  推送: ${PUSH_LOCAL} → ${PUSH_REMOTE}\033[0m"; fi
echo -e "\033[0;36m========================================\033[0m"

ok=0; fail=0
for host in "${HOSTS[@]}"; do
    outfile="${OUT_DIR}/${host//[:\/@]/_}.out"
    echo "────────────────────────────────────────"
    echo "▶ ${host}"
    if [ -n "$PUSH_LOCAL" ]; then
        [ ! -f "$PUSH_LOCAL" ] && { echo -e "  \033[0;31m[ERROR] 本地文件不存在: ${PUSH_LOCAL}\033[0m"; fail=$((fail+1)); continue; }
        scp $SSH_OPTS "$PUSH_LOCAL" "${host}:${PUSH_REMOTE}" > "$outfile" 2>&1
    else
        ssh $SSH_OPTS "$host" "$CMD" > "$outfile" 2>&1
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then ok=$((ok+1)); echo -e "  \033[0;32m[OK] exit=0 (输出: $(basename "$outfile"))\033[0m"
    else fail=$((fail+1)); echo -e "  \033[0;31m[FAIL] exit=$rc (输出: $(basename "$outfile"))\033[0m"; fi
done

# 汇总
{
    echo "SSH 批量运维汇总 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "机器数: ${#HOSTS[@]}  成功: ${ok}  失败: ${fail}"
    echo "命令/推送: ${CMD:-push ${PUSH_LOCAL} -> ${PUSH_REMOTE}}"
    for host in "${HOSTS[@]}"; do
        outfile="${OUT_DIR}/${host//[:\/@]/_}.out"
        rc="?"
        [ -f "$outfile" ] && rc=$(grep -c "^" "$outfile" 2>/dev/null)
        echo "  ${host}: 输出文件 $(basename "$outfile")（$( [ "$rc" = "?" ] && echo 无输出 || echo "${rc} 行" )）"
    done
} > "${OUT_DIR}/summary.txt"
# 关闭 ControlMaster 复用连接（避免残留）
for host in "${HOSTS[@]}"; do
    ssh -O exit -o ControlPath=/tmp/ssh_hwscope_batch_%r@%h "$host" >/dev/null 2>&1
done
echo ""
echo -e "\033[0;32m[OK] 输出目录: ${OUT_DIR}/（每机 .out + summary.txt）\033[0m"
[ "$fail" -gt 0 ] && exit 1
exit 0
