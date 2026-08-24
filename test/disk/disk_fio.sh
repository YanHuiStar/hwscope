#!/bin/bash
# =============================================================================
# disk_fio.sh — 随机/顺序 IOPS 与延迟（fio）
# test/disk/disk_fio.sh
# 用法: bash test/disk/disk_fio.sh            # 交互选盘
#       bash test/disk/disk_fio.sh /dev/sdb   # 直接指定盘
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

test_init "disk_fio"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/disk_fio_${disk_sel}.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ 随机/顺序 IOPS 与延迟（fio） ($DISK) ━━━${NC}" | tee -a "$REPORT_LOG"
run_and_log "fio --name=hwscope --directory=${FIO_DIR} --size=1G --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4 --runtime=20 --time_based --group_reporting 2>&1" "$LOGFILE"
rc=$?
rm -rf "$FIO_DIR" 2>/dev/null
test_record "disk_fio" "$LOGFILE" "$start_ts" "$rc"
test_finish "disk_fio"
