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

    # Phase 1: 串行获取所有设备数量 / 列表（后续命令依赖这些值）
    run_and_log "lspci 2>/dev/null | grep --line-buffered -iE 'RAID|SAS|SATA|MegaRAID|Broadcom|LSI|AVAGO'" \
        "${dir}/pci_raid_hba_list.log"

    # v1.48.69：storcli64 探测带固定路径——Broadcom 官方包装到 /opt/MegaRAID/storcli/ 且不建 PATH 软链
    # （与 v1.48.38 修的 /opt/rocm/bin 同类问题）。22.84 实证：仅按 PATH 判定"未安装"→ 报告写
    #  "storcli64 未安装"，实际该路径下可执行，且能读到控制器/物理盘/虚拟盘全部信息。
    #  perccli 为 Dell 版同类工具，同样落 /opt/MegaRAID/perccli/。
    local STORCLI_BIN="" _cand=""
    if check_cmd storcli64; then
        STORCLI_BIN="storcli64"
    else
        for _cand in /opt/MegaRAID/storcli/storcli64 /opt/MegaRAID/perccli/perccli64 /usr/local/bin/storcli64; do
            [ -x "$_cand" ] && { STORCLI_BIN="$_cand"; break; }
        done
        [ -n "$STORCLI_BIN" ] && echo -e "${YELLOW}[INFO] storcli64 不在 PATH，改用固定路径 ${STORCLI_BIN}${NC}"
    fi

    local ctrl_count=0 hba_count=0 hba2_count=0 raid_buses=""
    if [ -n "$STORCLI_BIN" ]; then
        run_and_log "$STORCLI_BIN show all 2>&1" "${dir}/storcli_controllers.log"
        ctrl_count=$("$STORCLI_BIN" show all 2>/dev/null | grep -c "Controller = ")
        # v1.48.90：BBU/缓存电池健康 + 虚盘缓存策略——RAID 卡在断电时能否保住缓存数据全靠它，
        #   且「Write Back 写缓存 + 电池失效」是真实的数据丢失风险点（验收常见关注项）。
        #   show all 只给控制器/磁盘摘要，BBU 与虚盘缓存详情必须逐控制器单独查询。
        if [ "${ctrl_count:-0}" -gt 0 ] 2>/dev/null; then
            local _bbu_jobs=()
            local _ci
            for ((_ci=0; _ci<ctrl_count; _ci++)); do
                _bbu_jobs+=("$STORCLI_BIN /c${_ci}/bbu show all 2>&1" "${dir}/storcli_c${_ci}_bbu.log")
                _bbu_jobs+=("$STORCLI_BIN /c${_ci}/cv show all 2>&1" "${dir}/storcli_c${_ci}_cv.log")
            done
            run_and_log_parallel $(( ${#_bbu_jobs[@]} / 2 )) "${_bbu_jobs[@]}"
        fi
    fi
    if check_cmd sas3ircu; then
        hba_count=$(sas3ircu list 2>/dev/null | grep -cE "^[0-9]+\\.|^Index" || true)
    fi
    if check_cmd sas2ircu; then
        hba2_count=$(sas2ircu list 2>/dev/null | grep -c "^Index" || true)
    fi
    raid_buses=$(lspci -D 2>/dev/null | grep --line-buffered -iE 'RAID|SAS|MegaRAID|Broadcom.*SAS' | awk '{print $1}')

    # Phase 2: 构建并行任务数组
    local raid_jobs=()

    # MegaRAID 每控制器（v1.48.69：统一走 $STORCLI_BIN，兼容 /opt/MegaRAID 下的非 PATH 安装）
    if [ -n "$STORCLI_BIN" ]; then
        for ((c=0; c<ctrl_count; c++)); do
            raid_jobs+=("$STORCLI_BIN /c${c} show all 2>&1" "${dir}/ctrl${c}_info.log")
            raid_jobs+=("$STORCLI_BIN /c${c} show all 2>&1 | grep --line-buffered -iE 'Model|Serial|Firmware|BIOS|Boot|Board Type|Ctrl Rate|ROC temperature|Product Name'" "${dir}/ctrl${c}_summary.log")
            raid_jobs+=("$STORCLI_BIN /c${c} /bbu show all 2>&1" "${dir}/ctrl${c}_bbu.log")
            raid_jobs+=("$STORCLI_BIN /c${c} show event 2>&1" "${dir}/ctrl${c}_events.log")
            # 虚拟盘数：统计 VD 表数据行（段头 "Virtual Drives :" 恒 1 次，按段头计数多 VD 时只采 v0——改按表行统计）
            local vd_count
            vd_count=$("$STORCLI_BIN" /c${c} /vx show all 2>/dev/null | grep -cE "^[0-9]+/[0-9]+[[:space:]]+" || true)
            if [ "${vd_count:-0}" -gt 0 ]; then
                raid_jobs+=("$STORCLI_BIN /c${c} /vx show all 2>&1" "${dir}/ctrl${c}_vd_all.log")
                for ((v=0; v<vd_count; v++)); do
                    raid_jobs+=("$STORCLI_BIN /c${c} /v${v} show all 2>&1" "${dir}/ctrl${c}_vd${v}.log")
                done
            fi
        done
    fi

    # SAS3 HBA（count=0 时无 HBA，不入队 sas3ircu 任务防失败 WARN）
    if check_cmd sas3ircu && [ "$hba_count" -gt 0 ]; then
        for ((h=0; h<hba_count; h++)); do
            raid_jobs+=("sas3ircu ${h} display 2>&1" "${dir}/sas3_hba${h}.log")
            raid_jobs+=("sas3ircu ${h} status 2>&1" "${dir}/sas3_hba${h}_status.log")
        done
    fi

    # SAS2 HBA
    if check_cmd sas2ircu; then
        for ((h=0; h<hba2_count; h++)); do
            raid_jobs+=("sas2ircu ${h} display 2>&1" "${dir}/sas2_hba${h}.log")
            raid_jobs+=("sas2ircu ${h} status 2>&1" "${dir}/sas2_hba${h}_status.log")
        done
    fi

    # lspci 深度
    if [ -n "$raid_buses" ]; then
        local lspci_count=0
        while IFS= read -r bus; do
            raid_jobs+=("lspci -vvv -s '$bus' 2>/dev/null" "${dir}/lspci_raid_${lspci_count}.log")
            ((lspci_count++))
        done < <(printf '%s\n' "$raid_buses")
    fi

    # Linux 软件 RAID（mdadm /proc/mdstat：检测 md 设备，无则空文件）
    raid_jobs+=("cat /proc/mdstat 2>/dev/null" "${dir}/mdstat.log")

    # Phase 3: 并行执行所有采集任务
    [ "${#raid_jobs[@]}" -gt 0 ] && run_and_log_parallel 8 "${raid_jobs[@]}" 

# NOTE: ctrlC_info.log, ctrlC_summary.log, ctrlC_bbu.log, ctrlC_events.log,
    #       ctrlC_vd_all.log, ctrlC_vdV.log, sas3_hbaH.log, sas3_hbaH_status.log,
    #       sas2_hbaH.log, sas2_hbaH_status.log, lspci_raid_N.log are generated per controller/device
    write_manifest "${dir}/manifest.txt" \
        "pci_raid_hba_list" "pci_raid_hba_list.log" \
        "storcli_controllers" "storcli_controllers.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_raid "$1"
fi
