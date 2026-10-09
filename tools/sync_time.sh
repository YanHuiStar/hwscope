#!/bin/bash
# =============================================================================
# HwScope — 通过 SSH 将本机时间同步到目标机
# tools/sync_time.sh
# 用法: bash tools/sync_time.sh root@10.0.0.1 [root@10.0.0.2 ...]
#       bash tools/sync_time.sh -h                     # 显示帮助
# 功能: 以本机（运维机）时间为基准，SSH 设置目标机系统时间 + 硬件时钟（RTC）。
#       解决目标机时钟偏差（NTP 不可达内网场景）——采集时间戳可信度依赖时钟。
# 实现要点:
#   - epoch 秒传递（date -s @<epoch>）：无时区歧义，目标机按自身时区显示正确时间
#   - 先停 NTP（timedatectl set-ntp false 防冲突），设完 hwclock -w 写硬件时钟（重启不丢）
#   - 交互式密码默认（与 remote_collect.sh 一致安全立场），ControlMaster 复用输一次密码
# 依赖: ssh/date/hwclock（目标机 timedatectl + hwclock；系统自带）
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "用法: $0 <user@host> [user@host2 ...]"
    echo "功能: 将本机时间通过 SSH 同步到目标机（系统时间 + 硬件时钟）"
    echo "选项:"
    echo "  -h, --help    显示本帮助"
    echo "  --dry-run     只显示目标机当前时间与偏差，不做修改（对前先看一眼）"
    echo "示例:"
    echo "  bash $0 root@10.0.0.1                        # 单台"
    echo "  bash $0 root@<test-host> root@<test-host>  # 多台"
    echo ""
}

# v1.50.5：-h/--help 先于 HOST 解析（此前仅判 $# -eq 0，`-h` 会被当目标机去 `ssh -h`）；
#   同时拒绝其他未知 - 开头参数，避免误当成主机名
# v1.52.28：加 --dry-run（对齐 Windows 版 tools/win/sync_time.ps1 的 -DryRun）
DRY_RUN=0
HOSTS=()
for _arg in "$@"; do
    case "$_arg" in
        -h|--help)   usage; exit 0 ;;
        --dry-run)   DRY_RUN=1 ;;
        -*)          echo -e "\033[0;31m[ERROR] 未知参数: ${_arg}\033[0m"; usage; exit 1 ;;
        *)           HOSTS+=("$_arg") ;;
    esac
done
[ ${#HOSTS[@]} -eq 0 ] && { usage; exit 1; }

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ControlMaster=auto -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h -o ControlPersist=300"
rm -f /tmp/ssh_hwscope_mux_* 2>/dev/null || true

EPOCH=$(date +%s)
LOCAL_HMS=$(date '+%Y-%m-%d %H:%M:%S %Z')
echo "============================================"
echo "  本机时间: ${LOCAL_HMS} (epoch=${EPOCH})"
[ "$DRY_RUN" -eq 1 ] && echo "  [DryRun] 只检查偏差，不做修改"
echo "============================================"

cleanup() {
    ssh -O exit -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h "${1:-x}" >/dev/null 2>&1 || true
    rm -f /tmp/ssh_hwscope_mux_* 2>/dev/null || true
}
trap 'cleanup "${HOSTS[0]:-}"' EXIT INT TERM

for HOST in "${HOSTS[@]}"; do
    echo ""
    echo "── 同步 → ${HOST}"
    # root 免 sudo；普通用户带 -t 供 sudo 交互输密码
    SUDO="sudo"
    case "$HOST" in
        root@*) SUDO="" ;;
    esac
    TTY_OPTS=""
    [ -n "$SUDO" ] && TTY_OPTS="-t"
    # v1.48.13 修复：远程命令序列的退出码取最后一条（date 打印必然成功）→ 设置失败也报 [OK]。
    #   改为捕获设置链（date -s && hwclock -w）的退出码并以它 exit（\$?/exit 转义交给远程展开）
    # 先回显目标机当前时间与相对本机的偏差（v1.52.28，对齐 Windows 版）
    if [ "$DRY_RUN" -eq 1 ]; then
        REMOTE_CMD="_old=\$(date +%s); echo \"  目标机当前: \$(date '+%Y-%m-%d %H:%M:%S %Z')  (epoch=\$_old, 与本机差 \$((_old - ${EPOCH})) 秒)\""
    else
        REMOTE_CMD="_old=\$(date +%s); echo \"  目标机当前: \$(date '+%Y-%m-%d %H:%M:%S %Z')  (epoch=\$_old, 与本机差 \$((_old - ${EPOCH})) 秒)\"; ${SUDO} timedatectl set-ntp false 2>/dev/null; ${SUDO} date -s @${EPOCH} && ${SUDO} hwclock -w 2>/dev/null; _rc=\$?; echo \"  目标机新时间: \$(date '+%Y-%m-%d %H:%M:%S %Z')\"; exit \$_rc"
    fi
    if ssh $SSH_OPTS $TTY_OPTS "$HOST" "$REMOTE_CMD"; then
        [ "$DRY_RUN" -eq 1 ] && echo "[OK] ${HOST} 已检查（未修改）" || echo "[OK] ${HOST} 时间已同步（与运维机一致）"
    else
        echo -e "\033[0;31m[ERROR] ${HOST} 同步失败\033[0m"
    fi
done
echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "完成。本次为 DryRun，未做任何修改（本机时间基准：${LOCAL_HMS}）"
else
    echo "完成。目标机时钟偏差已消除（本机时间基准：${LOCAL_HMS}）"
fi
