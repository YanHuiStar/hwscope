#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：AMD（amd-smi/rocm-smi + rocminfo，ROCm 生态）
# modules/gpu/adapter_amd.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_amd <gpu_dir> [prefix]
# 单厂商模式：输出与 v1.46.x 完全一致（JSON + 全量日志，报告走 AMD JSON 解析分支）
# mixed 模式：额外从 JSON 提取生成 gpu_inventory_amd.csv（供合并统一 CSV，AMD 卡数据不丢）
# =============================================================================

run_gpu_amd() {
    local dir="$1" prefix="${2:-}"
    local amd_smi_cmd=""
    if check_cmd amd-smi; then
        amd_smi_cmd="amd-smi"
    elif check_cmd rocm-smi; then
        amd_smi_cmd="rocm-smi"
    else
        echo -e "${YELLOW}[SKIP] AMD GPU 已检测但 rocm-smi/amd-smi 均未安装（无 ROCm 环境）${NC}"
        echo "# AMD GPU detected but no ROCm tool" > "${dir}/gpu_amd_pci_only.log"
        gpu_fallback_pci "$dir" "$prefix" "amd-smi/rocm-smi" "Advanced Micro Devices|AMD|ATI"
        return 1
    fi

    echo -e "${CYAN}[INFO] 检测到 AMD GPU（${amd_smi_cmd}），走 ROCm 采集路径${NC}"

    # 全量落盘（并行）
    local amd_jobs=()
    amd_jobs+=(
        "${amd_smi_cmd} --showallinfo --json"        "${dir}/gpu_amd_full.log"
        "${amd_smi_cmd} --showproductname --showuniqueid --showmeminfo vram --showtemp --showpower --showuse --showclocks --showpids --json" "${dir}/gpu_amd_inventory.json"
        "${amd_smi_cmd} --showmeminfo all --json"    "${dir}/gpu_amd_meminfo.log"
        "${amd_smi_cmd} --showtemp --json"           "${dir}/gpu_amd_temp.log"
        "${amd_smi_cmd} --showpower --json"          "${dir}/gpu_amd_power.log"
        "${amd_smi_cmd} --showuse --json"            "${dir}/gpu_amd_use.log"
        "${amd_smi_cmd} --showclocks --json"         "${dir}/gpu_amd_clocks.log"
        "${amd_smi_cmd} --showfwinfo --json"         "${dir}/gpu_amd_fw.log"
        "${amd_smi_cmd} --showrasinfo --json"        "${dir}/gpu_amd_ras.log"
        "${amd_smi_cmd} --showtopo --json"           "${dir}/gpu_amd_topo.log"
    )
    # rocminfo 型号/架构（对标 nvidia-smi -q）
    if check_cmd rocminfo; then
        amd_jobs+=("rocminfo" "${dir}/gpu_amd_rocminfo.log")
    fi
    run_and_log_parallel 6 "${amd_jobs[@]}"

    # 每卡明细（按卡数循环）
    local amd_count
    amd_count=$("${amd_smi_cmd}" --showuniqueid --json 2>/dev/null | grep -c "unique_id\|uniqueid" || true)
    [ "$amd_count" -lt 1 ] 2>/dev/null && amd_count=0
    local _ai=0
    while [ "$_ai" -lt "$amd_count" ]; do
        run_and_log "${amd_smi_cmd} -d $_ai --showallinfo --json" "${dir}/gpu_amd_${_ai}_detail.json"
        _ai=$((_ai + 1))
    done

    # mixed 模式：从 JSON 提取统一 CSV（单厂商模式不写，报告走 AMD JSON 解析分支）
    if [ -n "$prefix" ]; then
        _amd_csv_from_json "$dir" "$prefix"
    fi

    gpu_adapter_manifest "$dir" \
        "gpu_amd_full" "gpu_amd_full.log" \
        "gpu_amd_inventory" "gpu_amd_inventory.json" \
        "gpu_amd_rocminfo" "gpu_amd_rocminfo.log" \
        "gpu_amd_ras" "gpu_amd_ras.log" \
        "gpu_amd_topo" "gpu_amd_topo.log" \
        "gpu_amd_pci_only" "gpu_amd_pci_only.log"
}

# ─── AMD JSON → 统一 CSV（mixed 模式；解析逻辑与报告 20_gpu.sh AMD 分支一致）───
_amd_csv_from_json() {
    local dir="$1" prefix="$2" json="${dir}/gpu_amd_inventory.json"
    local csv="${dir}/gpu_inventory_${prefix}.csv"
    [ -f "$json" ] || { gpu_csv_from_lspci "$dir" "$prefix" "Advanced Micro Devices|AMD|ATI"; return 1; }
    local _cards
    _cards=$(grep -oE '"card[0-9]+"' "$json" 2>/dev/null | sort -u)
    if [ -z "$_cards" ]; then
        gpu_csv_from_lspci "$dir" "$prefix" "Advanced Micro Devices|AMD|ATI"
        return 1
    fi
    gpu_csv_header > "$csv"
    local _i=0
    while IFS='|' read -r _cardn _an _auid _amem _atmp _apwr _autl; do
        [ -z "$_cardn" ] && continue
        # 显存 B → MiB（报告口径）
        local _mib="N/A"
        if [ -n "$_amem" ] && [ "$_amem" != "0" ] && [[ "$_amem" =~ ^[0-9]+$ ]]; then
            _mib=$(awk -v b="$_amem" 'BEGIN{printf "%.0f MiB", b/1048576}')
        fi
        gpu_csv_row "${prefix}_${_i}" "${_an:-N/A}" "${_auid:-N/A}" "N/A" "${_auid:-N/A}" \
            "$_mib" "N/A" "N/A" "${_apwr:-N/A}" "${_atmp:-N/A}" "${_autl:-N/A}" "N/A" "N/A" "N/A" \
            "N/A" "N/A" "N/A" "N/A" >> "$csv"
        _i=$((_i + 1))
    done < <(awk '
        /"card[0-9]+"/ {
            cn=$0; sub(/.*"card/,"",cn); sub(/".*/,"",cn)
            an=$0; sub(/.*"Product Name":[[:space:]]*"/,"",an); sub(/".*/,"",an)
            uid=$0; sub(/.*"Unique ID":[[:space:]]*"/,"",uid); sub(/".*/,"",uid)
            mem=$0; sub(/.*"VRAM Total Memory \(B\)":[[:space:]]*"/,"",mem); sub(/".*/,"",mem)
            tmp=$0; sub(/.*"Temperature \(Sensor edge\) \(C\)":[[:space:]]*"/,"",tmp); sub(/".*/,"",tmp)
            pwr=$0; sub(/.*"Average Graphics Package Power Consumption \(W\)":[[:space:]]*"/,"",pwr); sub(/".*/,"",pwr)
            utl=$0; sub(/.*"GPU use \(%\)":[[:space:]]*"/,"",utl); sub(/".*/,"",utl)
            printf "%s|%s|%s|%s|%s|%s|%s\n", cn, an, uid, mem, tmp, pwr, utl
        }
    ' "$json")
}
