#!/bin/bash
# =============================================================================
# HwScope — 通过 SSH 将本机时间同步到目标机
# tools/sync_time.sh
# 用法: bash tools/sync_time.sh root@10.0.0.1 [root@10.0.0.2 ...]
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
    echo "示例:"
    echo "  bash $0 root@10.0.0.1                        # 单台"
    echo "  bash $0 root@192.168.22.196 root@192.168.22.156  # 多台"
    echo ""
}

[ $# -eq 0 ] && { usage; exit 1; }

SSH_OPTS="-o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h -o ControlPersist=300"
rm -f /tmp/ssh_hwscope_mux_* 2>/dev/null || true

EPOCH=$(date +%s)
LOCAL_HMS=$(date '+%Y-%m-%d %H:%M:%S %Z')
echo "============================================"
echo "  本机时间: ${LOCAL_HMS} (epoch=${EPOCH})"
echo "============================================"

cleanup() {
    ssh -O exit -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h "${1:-x}" >/dev/null 2>&1 || true
    rm -f /tmp/ssh_hwscope_mux_* 2>/dev/null || true
}
trap 'cleanup "${HOSTS[0]:-}"' EXIT INT TERM

HOSTS=("$@")
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
    if ssh $SSH_OPTS $TTY_OPTS "$HOST" "${SUDO} timedatectl set-ntp false 2>/dev/null; ${SUDO} date -s @${EPOCH} && ${SUDO} hwclock -w 2>/dev/null; _rc=\$?; echo '  目标机时间: '; date '+%Y-%m-%d %H:%M:%S %Z'; exit \$_rc"; then
        echo "[OK] ${HOST} 时间已同步（与运维机一致）"
    else
        echo -e "\033[0;31m[ERROR] ${HOST} 同步失败\033[0m"
    fi
done
echo ""
echo "完成。目标机时钟偏差已消除（本机时间基准：${LOCAL_HMS}）"
