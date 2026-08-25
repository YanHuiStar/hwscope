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

    # ─── 通用块设备总览 + 分类汇总 + 类型标签（并行采集） ───
    if check_cmd lsblk; then
        run_and_log_parallel 4 \
            "lsblk -o NAME,MODEL,SERIAL,SIZE,TRAN,ROTA,MOUNTPOINT,FSTYPE,TYPE 2>/dev/null" "${dir}/block_devices_all.log" \
            "lsblk -o NAME,TRAN,SIZE,ROTA,MODEL 2>/dev/null | grep -v 'loop' | grep -v 'rom'" "${dir}/block_devices_summary.log" \
            "echo '=== SATA ==='; lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA 2>/dev/null | grep 'sata' || true; echo '=== SAS ==='; lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA 2>/dev/null | grep 'sas' || true; echo '=== NVMe ==='; lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA 2>/dev/null | grep 'nvme' || true; echo '=== USB ==='; lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA 2>/dev/null | grep 'usb' || true" "${dir}/block_devices_by_type.log" \
            "echo '=== ROTA=1 (HDD) ==='; lsblk -d -o NAME,MODEL,SIZE,TRAN 2>/dev/null | grep -v 'NAME' | while read n m s t; do rota=\$(cat /sys/block/\$n/queue/rotational 2>/dev/null); [ \"\$rota\" = \"1\" ] && echo \"\$n \$m \$s \$t (HDD)\"; done; echo '=== ROTA=0 (SSD/NVMe) ==='; lsblk -d -o NAME,MODEL,SIZE,TRAN 2>/dev/null | grep -v 'NAME' | while read n m s t; do rota=\$(cat /sys/block/\$n/queue/rotational 2>/dev/null); [ \"\$rota\" = \"0\" ] && echo \"\$n \$m \$s \$t (SSD)\"; done; true" "${dir}/drive_type_ssd_hdd.log"
    else
        run_and_log "lsblk -o NAME,MODEL,SERIAL,SIZE,TRAN,ROTA,MOUNTPOINT,FSTYPE,TYPE 2>/dev/null" "${dir}/block_devices_all.log"
    fi

    # ─── SMART 信息（smartctl 覆盖所有支持 SMART 的盘） ───
    if check_cmd smartctl; then
        if [ "$IS_WSL" -eq 1 ]; then
            # WSL 虚拟磁盘（ext4.vhdx）不支持 SMART，跳过避免误报 WARN
            echo "[SKIP] WSL 虚拟磁盘不支持 SMART，跳过 smartctl 详细检测" > "${dir}/00_skip_smart_wsl.log"
        else
        run_and_log "smartctl --scan 2>&1" "${dir}/smart_scan.log"

        # 找出所有物理盘（非分区、非 dm、非 loop）
        local smart_devs
        smart_devs=$(smartctl --scan 2>/dev/null | grep -vE 'dm-|loop|/dev/disk' | awk '{print $1}' | sort -u)
        if [ -z "$smart_devs" ]; then
            # 回退：从 lsblk 取物理盘
            smart_devs=$(lsblk -d -o NAME 2>/dev/null | grep -vE 'loop|rom' | grep -v 'NAME' | sed 's|^|/dev/|')
        fi

        if [ -n "$smart_devs" ]; then
            local smart_jobs=()
            while IFS= read -r dev; do
                [ -z "$dev" ] && continue
                # smartctl --scan 对 NVMe 输出控制器设备（/dev/nvme0，字符设备），
                # 对 SATA/SAS 输出块设备（/dev/sda）——两者都要接受，否则 NVMe 全被跳过
                [ ! -b "$dev" ] && [ ! -c "$dev" ] && continue
                local dev_short
                dev_short=$(basename "$dev")

                case "$dev_short" in
                    nvme*)
                        smart_jobs+=("smartctl -a '$dev' 2>&1" "${dir}/smart_${dev_short}.log")
                        smart_jobs+=("smartctl -a '$dev' 2>/dev/null | grep -E 'Temperature|Percentage Used|Power On Hours|Data Units|Media Errors|Warning'" "${dir}/smart_${dev_short}_health.log")
                        ;;
                    sd*)
                        smart_jobs+=("smartctl -a '$dev' 2>&1" "${dir}/smart_${dev_short}.log")
                        smart_jobs+=("smartctl -a -d scsi '$dev' 2>&1" "${dir}/smart_${dev_short}_scsi.log")
                        smart_jobs+=("smartctl -a '$dev' 2>/dev/null | grep -iE 'Temperature|Reallocated|Pending|Offline|Current|Read Error|Write Error|Spin_Up|Hours|Power_Cycle|SAS'" "${dir}/smart_${dev_short}_health.log")
                        ;;
                    hd*|vd*)
                        smart_jobs+=("smartctl -a '$dev' 2>&1" "${dir}/smart_${dev_short}.log")
                        ;;
                esac
            done < <(printf '%s\n' "$smart_devs")
            [ "${#smart_jobs[@]}" -gt 0 ] && run_and_log_parallel 8 "${smart_jobs[@]}"
        fi
        fi  # IS_WSL
    else
        echo -e "${YELLOW}[SKIP] smartctl not found (install smartmontools)${NC}"
    fi

    # ─── SCSI/SAS 设备链路 + 磁盘分区和挂载（并行） ───
    local storage_tail_jobs=()
    if check_cmd lsscsi; then
        storage_tail_jobs+=("lsscsi -v 2>&1" "${dir}/lsscsi_all.log")
        storage_tail_jobs+=("lsscsi --long 2>&1" "${dir}/lsscsi_detail.log")
    fi
    storage_tail_jobs+=("df -h" "${dir}/df_h.log")
    storage_tail_jobs+=("mount" "${dir}/mount.log")
    storage_tail_jobs+=("cat /proc/partitions" "${dir}/proc_partitions.log")
    run_and_log_parallel 5 "${storage_tail_jobs[@]}"
    local storage_ret=$?
    [ "$storage_ret" -ne 0 ] && echo -e "${YELLOW}[WARN] 存储采集部分失败，请检查日志${NC}" >&2 

    # ─── 盘一览清单（name|type|size|model|sn|fw|bdf|power_on|power_cyc|spare）───
    {
        echo "# disk inventory: name|type|size|model|serial|firmware|bdf|power_on_hours|power_cycles|spare_percent"
        # NVMe
        for ndev in /dev/nvme*n1; do
            [ -b "$ndev" ] || continue
            local nname
            nname=$(basename "$ndev")
            local ctrl="${nname%n1}"
            local nsize
            nsize=$(lsblk -d -n -o SIZE "$ndev" 2>/dev/null | tr -d ' ')
            local nmodel
            nmodel=$(cat "/sys/block/${nname}/device/model" 2>/dev/null | xargs)
            local nsn
            nsn=$(cat "/sys/block/${nname}/device/serial" 2>/dev/null | xargs)
            local nfw
            nfw=$(cat "/sys/block/${nname}/device/firmware_rev" 2>/dev/null | xargs)
            local nbdf
            nbdf=$(basename "$(readlink -f "/sys/class/nvme/${ctrl}/device" 2>/dev/null)" 2>/dev/null | sed 's/^0000://')
            local npo="" npc="" nspare=""
            if check_cmd nvme; then
                local nsmart
                nsmart=$(nvme smart-log "$ndev" 2>/dev/null)
                npo=$(echo "$nsmart" | grep "power_on_hours" | awk '{print $3}')
                npc=$(echo "$nsmart" | grep "power_cycles" | awk '{print $3}')
                # v1.43.7 修复：nvme smart-log 字段是 percentage_used（非 percent_used——少 age 子串匹配不到）
                nspare=$(echo "$nsmart" | grep "percentage_used" | awk '{print $3}')
                # percentage_used 是已用百分比，Spare% = 100 - used（先去 % 再算术，防 "3%" 语法错误）
                if [ -n "$nspare" ]; then
                    nspare=$(echo "$nspare" | tr -d '%')
                    if [[ "$nspare" =~ ^[0-9]+$ ]]; then nspare=$((100 - nspare)); else nspare="N/A"; fi
                fi
            fi
            # nvme 命令缺失时 fallback smartctl（smart_<dev>_health.log 的 "Percentage Used"）
            if [ -z "$nspare" ] && [ -f "${dir}/smart_${nname}_health.log" ]; then
                nspare=$(grep -i "Percentage Used" "${dir}/smart_${nname}_health.log" | awk '{print $3}' | tr -d '%')
                if [[ "$nspare" =~ ^[0-9]+$ ]]; then nspare=$((100 - nspare)); else nspare=""; fi
            fi
            [ -z "$npo" ] && npo="0"; [ -z "$npc" ] && npc="0"; [ -z "$nspare" ] && nspare="N/A"
            echo "${nname}|NVMe|${nsize:-N/A}|${nmodel:-N/A}|${nsn:-N/A}|${nfw:-N/A}|${nbdf:-N/A}|${npo}|${npc}|${nspare}%"
        done
        # SATA/SAS（sd[a-z] + sd[a-z][a-z] 覆盖 >26 盘场景；分区号过滤：仅 /sys/block 下的物理盘）
        for sdev in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
            [ -b "$sdev" ] || continue
            local sname
            sname=$(basename "$sdev")
            # 排除分区（sda1 等）：物理盘在 /sys/block 有直接条目
            [ -d "/sys/block/${sname}" ] || continue
            local sz
            sz=$(blockdev --getsize64 "$sdev" 2>/dev/null)
            # blockdev 缺失时回退 lsblk 字节数（防极简系统/容器静默丢盘）
            if [ -z "$sz" ] && check_cmd lsblk; then
                sz=$(lsblk -b -d -n -o SIZE "$sdev" 2>/dev/null | tr -d ' ')
            fi
            [ -z "$sz" ] || [ "$sz" = "0" ] && continue
            local ssize
            ssize=$(lsblk -d -n -o SIZE "$sdev" 2>/dev/null | tr -d ' ')
            local smodel="" ssn="" sfw="" stype="SATA"
            if check_cmd smartctl; then
                local sinfo
                sinfo=$(smartctl -i "$sdev" 2>/dev/null)
                ssn=$(echo "$sinfo" | grep "Serial Number:" | awk '{print $3}')
                smodel=$(echo "$sinfo" | grep "Device Model:" | cut -d':' -f2- | xargs)
                sfw=$(echo "$sinfo" | grep "Firmware Version:" | awk '{print $3}')
                # SCSI 格式回退（RAID 逻辑盘/SAS：Serial number:/Product:/Revision:，ATA 关键字匹配不到）
                [ -z "$ssn" ] && ssn=$(echo "$sinfo" | grep -iE "^Serial number:" | cut -d: -f2- | xargs)
                [ -z "$smodel" ] && smodel=$(echo "$sinfo" | grep -iE "^Product:" | cut -d: -f2- | xargs)
                [ -z "$sfw" ] && sfw=$(echo "$sinfo" | grep -iE "^Revision:" | cut -d: -f2- | xargs)
                # 类型区分：SATA 盘有 "SATA Version is"；SAS 盘走 SCSI 格式（Product:/Serial number:）或 Transport protocol 明确为 SAS
                # （注意：Transport protocol 行对 SATA 盘也输出 "Transport protocol: SATA"，必须值判断，勿无条件判 SAS）
                if echo "$sinfo" | grep -qi "SATA Version is"; then stype="SATA"
                elif echo "$sinfo" | grep -qiE "^Product:|^Serial number:" || echo "$sinfo" | grep -qi "Transport protocol:.*SAS"; then stype="SAS"; fi
            fi
            [ -z "$smodel" ] && smodel=$(cat "/sys/block/${sname}/device/model" 2>/dev/null | xargs)
            [ -z "$ssn" ] && ssn=$(cat "/sys/block/${sname}/device/serial" 2>/dev/null | xargs)
            # SMART 属性只查一次缓存到变量（原实现每盘 4 次 smartctl -A，24 盘阵列显著拖慢）
            local sattrs=""
            check_cmd smartctl && sattrs=$(smartctl -A "$sdev" 2>/dev/null)
            local spo
            spo=$(echo "$sattrs" | grep -i "Power_On_Hours" | awk '{print $NF; exit}')
            if [ -z "$spo" ] || ! echo "$spo" | grep -qE "^[0-9]+$"; then spo="0"; fi
            local spc
            spc=$(echo "$sattrs" | grep -i "Power_Cycle" | awk '{print $NF; exit}')
            if [ -z "$spc" ] || ! echo "$spc" | grep -qE "^[0-9]+$"; then spc="0"; fi
            echo "${sname}|${stype}|${ssize:-N/A}|${smodel:-N/A}|${ssn:-N/A}|${sfw:-N/A}|N/A|${spo}|${spc}|N/A"
        done
    } > "${dir}/disk_inventory.csv" 2>/dev/null || true

# NOTE: smart_N.log, smart_N_health.log, smart_N_scsi.log are generated per disk
    # NOTE: sysfs_*/info.log, sysfs_*/all_fields.log are generated per PSU (conditional)
    write_manifest "${dir}/manifest.txt" \
        "block_devices_all" "block_devices_all.log" \
        "block_devices_summary" "block_devices_summary.log" \
        "block_devices_by_type" "block_devices_by_type.log" \
        "drive_type_ssd_hdd" "drive_type_ssd_hdd.log" \
        "smart_scan" "smart_scan.log" \
        "skip_smart_wsl" "00_skip_smart_wsl.log" \
        "lsscsi_all" "lsscsi_all.log" \
        "lsscsi_detail" "lsscsi_detail.log" \
        "df_h" "df_h.log" \
        "mount" "mount.log" \
        "proc_partitions" "proc_partitions.log" \
        "disk_inventory" "disk_inventory.csv"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_storage "$1"
fi
