#!/bin/bash
# =============================================================================
# 模块: 08_storage.sh — 存储设备（硬盘）信息采集
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

    # ─── 盘一览清单（name|type|size|model|sn|fw|bdf|power_on|power_cyc|spare）───
    {
        echo "# disk inventory: name|type|size|model|serial|firmware|bdf|power_on_hours|power_cycles|spare_percent"
        # NVMe
        for ndev in /dev/nvme*n1; do
            [ -b "$ndev" ] || continue
            local nname=$(basename "$ndev")
            local ctrl="${nname%n1}"
            local nsize=$(lsblk -d -n -o SIZE "$ndev" 2>/dev/null)
            local nmodel=$(cat "/sys/block/${nname}/device/model" 2>/dev/null | xargs)
            local nsn=$(cat "/sys/block/${nname}/device/serial" 2>/dev/null | xargs)
            local nfw=$(cat "/sys/block/${nname}/device/firmware_rev" 2>/dev/null | xargs)
            local nbdf=$(basename "$(readlink -f "/sys/class/nvme/${ctrl}/device" 2>/dev/null)" 2>/dev/null | sed 's/^0000://')
            local npo="" npc="" nspare=""
            if check_cmd nvme; then
                local nsmart=$(nvme smart-log "$ndev" 2>/dev/null)
                npo=$(echo "$nsmart" | grep "power_on_hours" | awk '{print $3}')
                npc=$(echo "$nsmart" | grep "power_cycles" | awk '{print $3}')
                nspare=$(echo "$nsmart" | grep "percent_used" | awk '{print $3}')
                # percent_used 是已用百分比，Spare% = 100 - used
                [ -n "$nspare" ] && nspare=$((100 - nspare))
            fi
            [ -z "$npo" ] && npo="0"; [ -z "$npc" ] && npc="0"; [ -z "$nspare" ] && nspare="N/A"
            echo "${nname}|NVMe|${nsize:-N/A}|${nmodel:-N/A}|${nsn:-N/A}|${nfw:-N/A}|${nbdf:-N/A}|${npo}|${npc}|${nspare}%"
        done
        # SATA/SAS
        for sdev in /dev/sd[a-z]; do
            [ -b "$sdev" ] || continue
            local sz=$(blockdev --getsize64 "$sdev" 2>/dev/null)
            [ -z "$sz" ] || [ "$sz" = "0" ] && continue
            local sname=$(basename "$sdev")
            local ssize=$(lsblk -d -n -o SIZE "$sdev" 2>/dev/null)
            local smodel="" ssn="" sfw="" sinter="SATA"
            if check_cmd smartctl; then
                local sinfo=$(smartctl -i "$sdev" 2>/dev/null)
                ssn=$(echo "$sinfo" | grep "Serial Number:" | awk '{print $3}')
                smodel=$(echo "$sinfo" | grep "Device Model:" | cut -d':' -f2- | xargs)
                sfw=$(echo "$sinfo" | grep "Firmware Version:" | awk '{print $3}')
                sinter=$(echo "$sinfo" | grep "SATA Version is" | cut -d':' -f2- | xargs | sed 's/ *(current:.*//')
                [ -z "$sinter" ] && sinter="SATA"
            fi
            [ -z "$smodel" ] && smodel=$(cat "/sys/block/${sname}/device/model" 2>/dev/null | xargs)
            [ -z "$ssn" ] && ssn=$(cat "/sys/block/${sname}/device/serial" 2>/dev/null | xargs)
            local spo=$(smartctl -A "$sdev" 2>/dev/null | grep -i "Power_On_Hours" | awk '{print $10}')
            [ -z "$spo" ] && spo=$(smartctl -A "$sdev" 2>/dev/null | grep -i "Power_On_Hours" | awk '{print $4}')
            [ -z "$spo" ] && spo="0"
            local spc=$(smartctl -A "$sdev" 2>/dev/null | grep -i "Power_Cycle" | awk '{print $10}')
            [ -z "$spc" ] && spc="0"
            echo "${sname}|SATA|${ssize:-N/A}|${smodel:-N/A}|${ssn:-N/A}|${sfw:-N/A}|${sinter}|${spo}|${spc}|N/A"
        done
    } > "${dir}/disk_inventory.csv" 2>/dev/null || true

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_storage "$1"
fi
