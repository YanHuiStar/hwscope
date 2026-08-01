#!/bin/bash
# =============================================================================
# 模块: 12_storage.sh — 存储设备（硬盘）信息采集
# 输出目录: <OUTPUT_DIR>/storage/
#
# 覆盖范围：
#   - SATA/SAS/NVMe 全部物理盘
#   - lsblk 设备清单 + 传输类型分类
#   - SMART 健康信息（smartctl）
#   - HDD vs SSD 区分
#   - 分区/挂载情况
#   - SCSI 链路（lsscsi）
# =============================================================================

MODULE_NAME="Storage"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_storage() {
    local output_dir="$1"
    local dir="${output_dir}/storage"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # WSL 环境检测（虚拟磁盘 ext4.vhdx 不支持 SMART）
    local IS_WSL=0
    grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1

    # ─── 通用块设备总览（覆盖所有类型：SATA/SAS/NVMe/HDD/SSD） ───
    run_and_log "lsblk -o NAME,MODEL,SERIAL,SIZE,TRAN,ROTA,MOUNTPOINT,FSTYPE,TYPE 2>/dev/null" \
        "${dir}/block_devices_all.log"

    # 按传输类型分类汇总
    if check_cmd lsblk; then
        run_and_log "lsblk -o NAME,TRAN,SIZE,ROTA,MODEL 2>/dev/null | grep -v 'loop' | grep -v 'rom'" \
            "${dir}/block_devices_summary.log"
        run_and_log "echo '=== SATA ===' && lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA 2>/dev/null | grep 'sata' && echo '=== SAS ===' && lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA 2>/dev/null | grep 'sas' && echo '=== NVMe ===' && lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA 2>/dev/null | grep 'nvme' && echo '=== USB ===' && lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA 2>/dev/null | grep 'usb'" \
            "${dir}/block_devices_by_type.log"
    fi

    # ─── 硬盘类型标签：区分 SSD 和 HDD（rotational=1 为机械盘） ───
    if check_cmd lsblk; then
        run_and_log "echo '=== ROTA=1 (HDD) ===' && lsblk -d -o NAME,MODEL,SIZE,TRAN 2>/dev/null | grep -v 'NAME' | while read n m s t; do rota=$\$(cat /sys/block/$\$n/queue/rotational 2>/dev/null); [ \"$\$rota\" = \"1\" ] && echo \"$\$n $\$m $\$s $\$t (HDD)\"; done && echo '=== ROTA=0 (SSD/NVMe) ===' && lsblk -d -o NAME,MODEL,SIZE,TRAN 2>/dev/null | grep -v 'NAME' | while read n m s t; do rota=$\$(cat /sys/block/$\$n/queue/rotational 2>/dev/null); [ \"$\$rota\" = \"0\" ] && echo \"$\$n $\$m $\$s $\$t (SSD)\"; done" \
            "${dir}/drive_type_ssd_hdd.log"
    fi

    # ─── SMART 信息（smartctl 覆盖所有支持 SMART 的盘） ───
    if check_cmd smartctl; then
        if [ "$IS_WSL" -eq 1 ]; then
            # WSL 虚拟磁盘（ext4.vhdx）不支持 SMART，跳过避免误报 WARN
            echo "[SKIP] WSL 虚拟磁盘不支持 SMART，跳过 smartctl 详细检测" > "${dir}/00_skip_smart_wsl.log"
        else
        run_and_log "smartctl --scan 2>&1" "${dir}/smart_scan.log"

        # 找出所有物理盘（非分区、非 dm、非 loop）
        local smart_devs=$(smartctl --scan 2>/dev/null | grep -vE 'dm-|loop|/dev/disk' | awk '{print $1}' | sort -u)
        if [ -z "$smart_devs" ]; then
            # 回退：从 lsblk 取物理盘
            smart_devs=$(lsblk -d -o NAME 2>/dev/null | grep -vE 'loop|rom' | grep -v 'NAME' | sed 's|^|/dev/|')
        fi

        if [ -n "$smart_devs" ]; then
            while IFS= read -r dev; do
                [ -z "$dev" ] && continue
                [ ! -b "$dev" ] && continue
                local dev_short=$(basename "$dev")

                case "$dev_short" in
                    nvme*)
                        run_and_log "smartctl -a '$dev' 2>&1" "${dir}/smart_${dev_short}.log"
                        # NVMe 特有：温度、寿命、写入量
                        run_and_log "smartctl -a '$dev' 2>/dev/null | grep -E 'Temperature|Percentage Used|Power On Hours|Data Units|Media Errors|Warning'" \
                            "${dir}/smart_${dev_short}_health.log"
                        ;;
                    sd*)
                        # SATA 模式 SMART
                        run_and_log "smartctl -a '$dev' 2>&1" "${dir}/smart_${dev_short}.log"
                        # SAS 兜底 SCSI 模式
                        run_and_log "smartctl -a -d scsi '$dev' 2>&1" "${dir}/smart_${dev_short}_scsi.log"
                        # 关键健康字段摘要
                        run_and_log "smartctl -a '$dev' 2>/dev/null | grep -iE 'Temperature|Reallocated|Pending|Offline|Current|Read Error|Write Error|Spin_Up|Hours|Power_Cycle|SAS'" \
                            "${dir}/smart_${dev_short}_health.log" 2>/dev/null || true
                        ;;
                    hd*|vd*)
                        run_and_log "smartctl -a '$dev' 2>&1" "${dir}/smart_${dev_short}.log"
                        ;;
                esac
            done <<< "$smart_devs"
        fi
        fi  # IS_WSL
    else
        echo -e "${YELLOW}[SKIP] smartctl not found (install smartmontools)${NC}"
    fi

    # ─── SCSI/SAS 设备链路 ───
    if check_cmd lsscsi; then
        run_and_log "lsscsi -v 2>&1" "${dir}/lsscsi_all.log"
        run_and_log "lsscsi --long 2>&1" "${dir}/lsscsi_detail.log"
    fi

    # ─── 磁盘分区和挂载 ───
    run_and_log "df -h" "${dir}/df_h.log"
    run_and_log "mount" "${dir}/mount.log"
    run_and_log "cat /proc/partitions" "${dir}/proc_partitions.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_storage "$1"
fi
