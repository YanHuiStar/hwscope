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
    local amd_smi_cmd="" amd_tool_kind="" JOPT="--json" new_smi_bin=""
    # ─── v1.53.35：工具探测三档 + 版本落盘（amd-smi 新旧版兼容）───
    # 报告端解析的是 **rocm-smi 风格平铺 JSON**（{"card0":{"Device Name":…,"Unique ID":…}}）：
    #   · amd-smi **旧版**（扁平参数时代）输出同构 JSON → 可直用；
    #   · amd-smi **新版**（ROCm 7+ 子命令 static/metric）JSON 结构完全不同 → 现有解析器读不了，
    #     若让它顶掉 rocm-smi，报告会凭空变空 → 故新式只**留档原始 JSON 并标注待支持**，不抢主路径；
    #   · 旧实现只试 `--showproductname --json` 一档：早期 amd-smi/rocm-smi 只认 `-j` 短选项时会误判不可用。
    _amd_try() {  # $1=可执行文件 $2=json 选项
        "$1" --showproductname "$2" 2>/dev/null | grep -qiE '"card[0-9]+"'
    }
    local _cand=""
    if check_cmd_flex amd-smi /opt/rocm/bin /usr/local/bin /opt/amdgpu/bin; then
        _cand="${CMD_FLEX_PATH:-amd-smi}"
        if _amd_try "$_cand" --json; then
            amd_smi_cmd="$_cand"; amd_tool_kind="amd-smi（扁平参数）"; JOPT="--json"
        elif _amd_try "$_cand" -j; then
            amd_smi_cmd="$_cand"; amd_tool_kind="amd-smi（扁平参数/短选项）"; JOPT="-j"
        else
            new_smi_bin="$_cand"      # 新版 amd-smi 候选（可能是 ROCm 7+，也可能参数不兼容）
        fi
    fi
    if [ -z "$amd_smi_cmd" ] && check_cmd_flex rocm-smi /opt/rocm/bin /usr/local/bin /opt/amdgpu/bin; then
        _cand="${CMD_FLEX_PATH:-rocm-smi}"
        if _amd_try "$_cand" --json; then
            amd_smi_cmd="$_cand"; amd_tool_kind="rocm-smi"; JOPT="--json"
        elif _amd_try "$_cand" -j; then
            amd_smi_cmd="$_cand"; amd_tool_kind="rocm-smi（短选项）"; JOPT="-j"
        fi
    fi
    if [ -z "$amd_smi_cmd" ]; then
        # 没有「能出平铺 JSON」的工具：① 若存在新版 amd-smi，把它的原始 JSON 留档（后续做新 schema 解析）
        #   ② 仍产基础 PCI 清单，报告至少能列出卡与 BDF
        if [ -n "$new_smi_bin" ]; then
            echo -e "${YELLOW}[WARN] 仅检测到新版 amd-smi（子命令式），其 JSON 结构与当前解析器不兼容；原始输出留档待支持${NC}"
            { echo "# 新版 amd-smi 原始输出（schema 与 rocm-smi 平铺 JSON 不同，报告端暂不解析）"; \
              echo "# --- amd-smi static ---"; "$new_smi_bin" static --json 2>&1; \
              echo "# --- amd-smi metric ---"; "$new_smi_bin" metric --json 2>&1; } \
                > "${dir}/gpu_amd_new_schema.log"
            { echo "# AMD GPU 采集工具"; echo "tool: amd-smi（新版子命令，未适配解析）"; echo "path: ${new_smi_bin}"; \
              echo "version:"; "$new_smi_bin" --version 2>&1 | head -3; } > "${dir}/gpu_amd_tool.log"
        else
            echo -e "${YELLOW}[SKIP] AMD GPU 已检测但 rocm-smi/amd-smi 均未找到（无 ROCm 环境；装 /opt/rocm 或配好环境后重试）${NC}"
            echo "# AMD GPU detected but no ROCm tool" > "${dir}/gpu_amd_pci_only.log"
            { echo "# AMD GPU 采集工具"; echo "tool: (none)"; } > "${dir}/gpu_amd_tool.log"
        fi
        gpu_fallback_pci "$dir" "$prefix" "amd-smi/rocm-smi" "Advanced Micro Devices|AMD|ATI"
        gpu_adapter_manifest "$dir" "gpu_amd_tool" "gpu_amd_tool.log" "gpu_amd_pci_only" "gpu_amd_pci_only.log"
        return 1
    fi

    # 工具与版本落盘（事后判断「旧版/新版兼容性」的唯一依据；此前只有屏幕上一行 INFO，不落盘）
    { echo "# AMD GPU 采集工具"; echo "tool: ${amd_tool_kind}"; echo "path: ${amd_smi_cmd}"; \
      echo "json_option: ${JOPT}"; echo "version:"; "${amd_smi_cmd}" --version 2>&1 | head -3; } \
        > "${dir}/gpu_amd_tool.log"
    echo -e "${CYAN}[INFO] 检测到 AMD GPU（${amd_smi_cmd} · ${amd_tool_kind} · $("${amd_smi_cmd}" --version 2>&1 | head -1)），走 ROCm 采集路径${NC}"

    # 全量落盘（并行）
    local amd_jobs=()
    amd_jobs+=(
        "${amd_smi_cmd} --showallinfo ${JOPT}"        "${dir}/gpu_amd_full.log"
        "${amd_smi_cmd} --showproductname --showuniqueid --showmeminfo vram --showtemp --showpower --showuse --showclocks --showpids ${JOPT}" "${dir}/gpu_amd_inventory.json"
        "${amd_smi_cmd} --showmeminfo all ${JOPT}"    "${dir}/gpu_amd_meminfo.log"
        "${amd_smi_cmd} --showtemp ${JOPT}"           "${dir}/gpu_amd_temp.log"
        "${amd_smi_cmd} --showpower ${JOPT}"          "${dir}/gpu_amd_power.log"
        "${amd_smi_cmd} --showuse ${JOPT}"            "${dir}/gpu_amd_use.log"
        "${amd_smi_cmd} --showclocks ${JOPT}"         "${dir}/gpu_amd_clocks.log"
        "${amd_smi_cmd} --showfwinfo ${JOPT}"         "${dir}/gpu_amd_fw.log"
        "${amd_smi_cmd} --showrasinfo ${JOPT}"        "${dir}/gpu_amd_ras.log"
        "${amd_smi_cmd} --showtopo ${JOPT}"           "${dir}/gpu_amd_topo.log"
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
            # v1.48.38：裸 check_cmd 只查 PATH——rocm-smi 常装 /opt/rocm/bin 非标准目录（v1.48.16 场景），
            # 与 61 行 amd-smi 探测一致用 check_cmd_flex 三阶降级
            if check_cmd_flex rocm-smi /opt/rocm/bin /usr/local/bin /opt/amdgpu/bin; then
                "${CMD_FLEX_PATH:-rocm-smi}" --query-ecc > "${dir}/gpu_amd_ras.log" 2>&1 || true
            fi
        fi
    fi

    # 每卡明细（按卡数循环）
    local amd_count
    amd_count=$("${amd_smi_cmd}" --showuniqueid ${JOPT} 2>/dev/null | grep -c "unique_id\|uniqueid" || true)
    [ "$amd_count" -lt 1 ] 2>/dev/null && amd_count=0
    local _ai=0
    while [ "$_ai" -lt "$amd_count" ]; do
        run_and_log "${amd_smi_cmd} -d $_ai --showallinfo ${JOPT}" "${dir}/gpu_amd_${_ai}_detail.json"
        _ai=$((_ai + 1))
    done

    # mixed 模式：从 JSON 提取统一 CSV（单厂商模式不写，报告走 AMD JSON 解析分支）
    if [ -n "$prefix" ]; then
        _amd_csv_from_json "$dir" "$prefix"
    fi

    # v1.52.4（D8）：manifest 与实际产出对齐。原来注册的 gpu_amd_pci_only.log 只在
    #   「检测到 AMD 卡但 rocm-smi/amd-smi 都没有」的 fallback 分支生成，而那条分支在
    #   写 manifest 之前就 return 了——所以这个 key 在任何路径下都指不到真实文件
    #   （有 ROCm 的机器上文件不存在，无 ROCm 的机器上 manifest 压根没写）。
    #   同时补齐常态落盘的 6 个全量日志（此前落盘了却没进 manifest）。
    gpu_adapter_manifest "$dir" \
        "gpu_amd_tool" "gpu_amd_tool.log" \
        "gpu_amd_full" "gpu_amd_full.log" \
        "gpu_amd_inventory" "gpu_amd_inventory.json" \
        "gpu_amd_rocminfo" "gpu_amd_rocminfo.log" \
        "gpu_amd_ras" "gpu_amd_ras.log" \
        "gpu_amd_topo" "gpu_amd_topo.log" \
        "gpu_amd_meminfo" "gpu_amd_meminfo.log" \
        "gpu_amd_temp" "gpu_amd_temp.log" \
        "gpu_amd_power" "gpu_amd_power.log" \
        "gpu_amd_use" "gpu_amd_use.log" \
        "gpu_amd_clocks" "gpu_amd_clocks.log" \
        "gpu_amd_fw" "gpu_amd_fw.log"
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
