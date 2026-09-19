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

# ─── 选盘（参数优先 → 交互 lsblk；v1.45.1 默认屏蔽系统盘——fio 写测试会压垮系统盘/影响数据安全） ───
DISK="${1:-}"
# 系统盘识别：根挂载所在物理盘（如 / 在 /dev/sda2 → 系统盘 sda；NVMe /dev/nvme0n1p2 → nvme0n1）
SYS_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | head -1)
# fallback 剥分区号：p?[0-9]*$ 同时覆盖 SATA（sda12→sda）与 NVMe（nvme0n1p2→nvme0n1，v1.45.7）
[ -z "$SYS_DISK" ] && SYS_DISK=$(df / 2>/dev/null | awk 'NR==2 {print $1}' | sed 's|p\?[0-9]*$||;s|/dev/||')
if [ -z "$DISK" ]; then
    echo "可用磁盘（已排除系统盘 ${SYS_DISK:-?}）:"
    lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -v "loop\|NAME" | grep -v "^${SYS_DISK} " | head -10
    read -p "输入设备名 (如 sdb): " -r disk_sel
    [ -z "$disk_sel" ] && echo "已取消" && exit 1
    DISK="/dev/${disk_sel}"
fi
[ -b "$DISK" ] || { echo -e "${RED}[ERROR] $DISK 不是块设备${NC}"; exit 1; }
# v1.49.21：参数直接给盘时（bash disk_fio.sh /dev/sdb）原来不会设置 disk_sel，
#   日志名退化成 disk_fio_.log —— 多盘测试互相覆盖，事后无法区分是哪块盘。
[ -z "$disk_sel" ] && disk_sel=$(basename "$DISK")
# 参数指定的盘是系统盘 → 警告确认（fio 写测试有风险；--force 跳过）
if [ "$(basename "$DISK")" = "$SYS_DISK" ]; then
    echo -e "${YELLOW}[WARN] $DISK 是系统盘！fio 写测试会压垮系统盘并影响数据安全${NC}"
    if [ "$2" != "--force" ]; then
        read -p "确认继续测试系统盘？输入 YES: " -r confirm
        [ "$confirm" != "YES" ] && echo "已取消" && exit 1
    fi
fi

# ─── fio 测试文件位置：必须落在**被选中的盘**上 ───
# v1.49.21：原来取不到挂载点就静默回落 /tmp —— "测盘"实际测的是系统盘（或 tmpfs 内存盘），
#   既拿不到目标盘数据，又绕过本脚本的系统盘保护。裸设备直写（--filename=/dev/xxx）会破坏数据，
#   故这里**明确跳过**并说明，而不是给出一个错盘的漂亮数字。
mount_point=$(findmnt -no TARGET "$DISK" 2>/dev/null | head -1)
if [ -z "$mount_point" ]; then
    echo -e "${YELLOW}[SKIP] $(basename "$DISK") 未挂载（findmnt 无挂载点），fio 无法在目标盘建立测试文件${NC}"
    echo "  说明: 本工具以文件方式压测（不直写裸设备，避免破坏数据）；请先挂载该盘或用已挂载的分区重试。"
    exit 2
fi
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
