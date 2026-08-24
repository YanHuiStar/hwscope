#!/bin/bash
# =============================================================================
# disk_hdparm.sh — 缓存/盘面读取速度（hdparm）
# test/disk/disk_hdparm.sh
# 用法: bash test/disk/disk_hdparm.sh            # 交互选盘
#       bash test/disk/disk_hdparm.sh /dev/sdb   # 直接指定盘
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

# ─── 选盘（参数优先 → 交互 lsblk） ───
DISK="${1:-}"
if [ -z "$DISK" ]; then
    echo "可用磁盘:"
    lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -v "loop\|NAME" | head -10
    read -p "输入设备名 (如 sdb): " -r disk_sel
    [ -z "$disk_sel" ] && echo "已取消" && exit 1
    DISK="/dev/${disk_sel}"
fi
[ -b "$DISK" ] || { echo -e "${RED}[ERROR] $DISK 不是块设备${NC}"; exit 1; }

# ─── fio 测试文件位置：挂载点或 /tmp ───
mount_point=$(findmnt -no TARGET "$DISK" 2>/dev/null | head -1)
[ -z "$mount_point" ] && mount_point="/tmp"
FIO_DIR="${mount_point}/hwscope_fio_$$"
mkdir -p "$FIO_DIR" 2>/dev/null

test_init "disk_hdparm"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/disk_hdparm_${disk_sel}.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ 缓存/盘面读取速度（hdparm） ($DISK) ━━━${NC}" | tee -a "$REPORT_LOG"
run_and_log "hdparm -Tt ${DISK} 2>&1" "$LOGFILE"
rc=$?
rm -rf "$FIO_DIR" 2>/dev/null
test_record "disk_hdparm" "$LOGFILE" "$start_ts" "$rc"
test_finish "disk_hdparm"
