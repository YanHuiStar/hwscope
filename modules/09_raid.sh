#!/bin/bash
# =============================================================================
# 模块: 09_raid.sh — RAID/HBA 卡控制器信息采集
# 输出目录: <OUTPUT_DIR>/raid/
#
# 覆盖的硬件：
#   - Broadcom MegaRAID (storcli64)
#   - Broadcom HBA (sas3ircu / sas2ircu)
#   - 其他 RAID 卡（通过 lspci 兜底识别）
#
# 注意：硬盘本身的信息（lsblk / smartctl / lsscsi）在 08_storage.sh
# =============================================================================

MODULE_NAME="RAID-HBA"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_raid() {
    local output_dir="$1"
    local dir="${output_dir}/raid"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # 检测硬件：有哪些 RAID / HBA / SAS 控制器
    run_and_log "lspci 2>/dev/null | grep -iE 'RAID|SAS|SATA|MegaRAID|Broadcom|LSI|AVAGO|MR'" \
        "${dir}/pci_raid_hba_list.log"

    # ─── Broadcom MegaRAID — storcli64 ───
    if check_cmd storcli64; then
        # 列出所有控制器
        run_and_log "storcli64 show all 2>&1" "${dir}/storcli_controllers.log"

        # 自动发现控制器数量，逐卡采集（grep -c 无匹配时输出 0，勿加 || echo 兜底会拼出多行）
        local ctrl_count=$(storcli64 show all 2>/dev/null | grep -c "Controller = ")
        for ((c=0; c<ctrl_count; c++)); do
            # 控制器基本信息
            run_and_log "storcli64 /c${c} show all 2>&1" "${dir}/ctrl${c}_info.log"

            # 控制器固件 / SN / 型号摘要
            run_and_log "storcli64 /c${c} show all 2>&1 | grep -iE 'Model|Serial|Firmware|BIOS|Boot|Board Type|Ctrl Rate|ROC temperature|Product Name'" \
                "${dir}/ctrl${c}_summary.log"

            # Virtual Drive 信息
            local vd_count=$(storcli64 /c${c} /vx show all 2>/dev/null | grep -c "^Virtual Drives")
            if [ "$vd_count" -gt 0 ]; then
                run_and_log "storcli64 /c${c} /vx show all 2>&1" "${dir}/ctrl${c}_vd_all.log"
                for ((v=0; v<vd_count; v++)); do
                    run_and_log "storcli64 /c${c} /v${v} show all 2>&1" "${dir}/ctrl${c}_vd${v}.log"
                done
            fi

            # BBU 信息
            run_and_log "storcli64 /c${c} /bbu show all 2>&1" "${dir}/ctrl${c}_bbu.log"

            # 卡事件日志
            run_and_log "storcli64 /c${c} show event 2>&1 | tail -100" "${dir}/ctrl${c}_events.log"
        done
    else
        echo -e "${YELLOW}[SKIP] storcli64 not found (install from Broadcom)${NC}"
    fi

    # ─── Broadcom SAS3 HBA — sas3ircu ───
    if check_cmd sas3ircu; then
        local hba_count=$(sas3ircu list 2>/dev/null | grep -cE "^[0-9]+\.|^Index")
        if [ "$hba_count" -eq 0 ]; then
            run_and_log "sas3ircu 0 display 2>&1" "${dir}/sas3_hba0.log"
            run_and_log "sas3ircu 0 status 2>&1" "${dir}/sas3_hba0_status.log"
        else
            for ((h=0; h<hba_count; h++)); do
                run_and_log "sas3ircu ${h} display 2>&1" "${dir}/sas3_hba${h}.log"
                run_and_log "sas3ircu ${h} status 2>&1" "${dir}/sas3_hba${h}_status.log"
            done
        fi
    else
        echo -e "${YELLOW}[SKIP] sas3ircu not found (for HBA cards)${NC}"
    fi

    # ─── Broadcom SAS2 HBA — sas2ircu（旧平台兜底） ───
    if check_cmd sas2ircu; then
        local hba2_count=$(sas2ircu list 2>/dev/null | grep -c "^Index" || echo 0)
        for ((h=0; h<hba2_count; h++)); do
            run_and_log "sas2ircu ${h} display 2>&1" "${dir}/sas2_hba${h}.log"
            run_and_log "sas2ircu ${h} status 2>&1" "${dir}/sas2_hba${h}_status.log"
        done
    fi

    # ─── lspci 深度：确认检测到的 RAID/HBA 详细信息 ───
    local raid_buses=$(lspci -D 2>/dev/null | grep -iE 'RAID|SAS|MegaRAID|Broadcom.*SAS' | awk '{print $1}')
    if [ -n "$raid_buses" ]; then
        local count=0
        while IFS= read -r bus; do
            run_and_log "lspci -vvv -s '$bus' 2>/dev/null | head -60" "${dir}/lspci_raid_${count}.log"
            ((count++))
        done <<< "$raid_buses"
    fi

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_raid "$1"
fi
