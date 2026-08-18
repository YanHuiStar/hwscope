#!/bin/bash
# =============================================================================
# HwScope — 硬盘测试
# test/disk_test.sh
# 用法: sudo bash test/disk_test.sh
# 功能: fio 随机/顺序 IOPS / hdparm 缓存读取 / dd 简单吞吐
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

# ─── 选择目标盘 ───
echo -e "${CYAN}可用磁盘:${NC}"
lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -vE 'loop|rom' | head -10
echo ""
read -p "输入测试磁盘设备名 (如 nvme0n1, sda): " -r disk_dev
[ -z "$disk_dev" ] && echo "跳过" && exit 0
DISK="/dev/${disk_dev}"
[ ! -b "$DISK" ] && echo -e "${RED}[ERROR] ${DISK} 不是块设备${NC}" && exit 1

# ─── 工具菜单 ───
TOOLS=(
    "fio:fio:随机/顺序 IOPS 与延迟 (fio)"
    "hdparm:hdparm:缓存/盘面读取速度"
    "dd:dd:简单顺序写入吞吐"
)

test_menu TOOLS || exit 0
test_init "disk"

# ─── fio 测试文件位置：挂载点或 /tmp ───
mount_point=$(findmnt -no TARGET "$DISK" 2>/dev/null | head -1)
[ -z "$mount_point" ] && mount_point="/tmp"
FIO_DIR="${mount_point}/hwscope_fio_$$"
mkdir -p "$FIO_DIR" 2>/dev/null

IFS=',' read -ra SELECTED <<< "$TEST_CHOICES"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for entry in "${TEST_AVAILABLE[@]}"; do
        IFS='|' read -r idx name desc cmd <<< "$entry"
        [ "$sel" != "$idx" ] && continue
        echo "" | tee -a "$REPORT_LOG"
        echo -e "${CYAN}━━━ ${name} 测试 (${disk_dev}) ━━━${NC}" | tee -a "$REPORT_LOG"
        start_ts=$(date +%s)
        LOGFILE="${REPORT_DIR}/${name}_${disk_dev}.log"

        case "$name" in
            fio)
                run_and_log "fio --name=hwscope --directory=${FIO_DIR} --size=1G --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4 --runtime=20 --time_based --group_reporting 2>&1" "$LOGFILE"
                ;;
            hdparm)
                run_and_log "hdparm -Tt ${DISK} 2>&1" "$LOGFILE"
                ;;
            dd)
                run_and_log "dd if=${DISK} of=/dev/null bs=1M count=1024 2>&1" "$LOGFILE"
                ;;
        esac
        test_record "$name" "$LOGFILE" "$start_ts" "$?"
    done
done

# ─── 清理 fio 临时文件 ───
rm -rf "$FIO_DIR" 2>/dev/null

test_finish "disk"
