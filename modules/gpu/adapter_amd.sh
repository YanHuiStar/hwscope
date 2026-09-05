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
    # v1.48.16：统一 check_cmd_flex（PATH → /opt/rocm/bin 全路径试跑 → ~/.bashrc 环境重试）
    # OFED 冲突场景：amd-smi/rocm-smi 装 /opt/rocm 非标准目录 + 环境变量写 ~/.bashrc（登录才生效），
    # 脚本/非交互执行默认找不到——check_cmd_flex 三阶降级兜底（替代 v1.48.14 的裸 source 逻辑）
    if check_cmd_flex amd-smi /opt/rocm/bin /usr/local/bin /opt/amdgpu/bin; then
        amd_smi_cmd="${CMD_FLEX_PATH:-amd-smi}"
        # v1.48.22：amd-smi 新版（ROCm 7+）改子命令格式（list/static/metric/...），老式扁平参数被拒
        # （AmdSmiInvalidSubcommandException）→ 探测老式参数；失败降级 rocm-smi（老式参数仍兼容平铺 JSON）
        if ! "${amd_smi_cmd}" --showproductname --json 2>/dev/null | grep -qiE '"card[0-9]+"'; then
            amd_smi_cmd=""
            check_cmd_flex rocm-smi /opt/rocm/bin /usr/local/bin /opt/amdgpu/bin && amd_smi_cmd="${CMD_FLEX_PATH:-rocm-smi}"
        fi
    elif check_cmd_flex rocm-smi /opt/rocm/bin /usr/local/bin /opt/amdgpu/bin; then
        amd_smi_cmd="${CMD_FLEX_PATH:-rocm-smi}"
    else
        echo -e "${YELLOW}[SKIP] AMD GPU 已检测但 rocm-smi/amd-smi 均未找到（无 ROCm 环境；装 /opt/rocm 或配好环境后重试）${NC}"
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

    # v1.48.37：RAS/ECC 专项兜底——rocm-smi --showrasinfo 在 MI300X 常空（"No JSON data to report"，
    # deprecated 工具支持不全）；ROCm 7+ 的 amd-smi 新版用子命令 metric -e -P（表格：
    # GPU/XCP/SINGLE_ECC/DOUBLE_ECC/PCIE_REPLAY），rocm-smi 有效参数为 --query-ecc。先探测是否已拿到
    # 有效 RAS 数据，无则逐候选覆盖落盘（全量日志保留为 .ras_orig，专项提取并存不截断）
    if ! grep -qiE "SINGLE_ECC|DOUBLE_ECC|Correctable|Uncorrectable|corr_err|total_err" "${dir}/gpu_amd_ras.log" 2>/dev/null; then
        [ -f "${dir}/gpu_amd_ras.log" ] && cp "${dir}/gpu_amd_ras.log" "${dir}/gpu_amd_ras.orig.log" 2>/dev/null
        if check_cmd_flex amd-smi /opt/rocm/bin /usr/local/bin /opt/amdgpu/bin; then
            "${CMD_FLEX_PATH:-amd-smi}" metric -e -P > "${dir}/gpu_amd_ras.log" 2>&1 || true
        fi
        if ! grep -qiE "SINGLE_ECC|DOUBLE_ECC|Correctable|Uncorrectable" "${dir}/gpu_amd_ras.log" 2>/dev/null; then
            if check_cmd rocm-smi; then
                rocm-smi --query-ecc > "${dir}/gpu_amd_ras.log" 2>&1 || true
            fi
        fi
    fi

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
