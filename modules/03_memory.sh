#!/bin/bash
# =============================================================================
# 模块: 03_memory.sh — 内存信息采集
# 输出目录: <OUTPUT_DIR>/memory/
# =============================================================================

MODULE_NAME="Memory"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_memory() {
    local output_dir="$1"
    local dir="${output_dir}/memory"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    if ! check_cmd dmidecode; then
        echo -e "${YELLOW}[SKIP] dmidecode not found${NC}"
        module_end "$MODULE_NAME"
        return 0
    fi

    # 1~3+5. 独立的内存信息采集命令（并行采集；串行模式自动降级）
    run_and_log_parallel 4 \
        "dmidecode -t memory" "${dir}/dmidecode_memory_full.log" \
        "dmidecode -t memory 2>/dev/null | grep -E 'Locator|Size|Type:|Speed|Manufacturer|Serial Number|Part Number|Rank|Configured Clock'" \
            "${dir}/memory_slot_fields.log" \
        "free -h" "${dir}/free_h.log" \
        "cat /proc/meminfo" "${dir}/proc_meminfo.log"

    # 1b. 内存阵列信息（type 16：总数/最大容量/错误修正；dmidecode 不接受 "memory-array" 关键字，须用数字）
    run_and_log "dmidecode -t 16 2>/dev/null" "${dir}/dmidecode_memory_array.log"

    # 2b. 每槽完整的段落输出（awk 复杂转义，串行执行；空行结束当前段，防下一 DIMM 块前置行混入）
    run_and_log "dmidecode -t memory 2>/dev/null | awk '/^[[:space:]]*Locator:/{if(seg) print seg; seg=\$0; next} /^[[:space:]]*\$/{if(seg) print seg; seg=\"\"; next} /^[[:space:]]/{seg=seg ORS \$0} END{if(seg) print seg}'" \
        "${dir}/memory_slot_blocks.log"

    # 3. 内存容量统计（先剔除 No Module 空槽再计数；段间用 ; 分隔防 grep 无匹配断链）
    run_and_log "echo 'Total Memory Modules:'; dmidecode -t memory 2>/dev/null | grep 'Size:' | grep -vc 'No Module'; echo 'Total Capacity (GB):'; dmidecode -t memory 2>/dev/null | grep 'Size:' | grep -v 'No Module' | awk '{sum+=\$2} END{print sum+0}'" \
        "${dir}/memory_capacity.log"

    # 4. EDAC 内存错误计数（Linux 内核 EDAC 子系统；只读，无权限时跳过）
    run_and_log "if [ -d /sys/devices/system/edac ]; then ls /sys/devices/system/edac/mc/ 2>/dev/null; \
        for mc in /sys/devices/system/edac/mc/mc*; do [ -d \"\$mc\" ] || continue; \
        echo \"== \$(basename \$mc) ==\"; \
        echo \"CE_count: \$(cat \$mc/ce_count 2>/dev/null || echo N/A)\"; \
        echo \"UE_count: \$(cat \$mc/ue_count 2>/dev/null || echo N/A)\"; \
        echo \"CE_noinfo: \$(cat \$mc/ce_noinfo_count 2>/dev/null || echo N/A)\"; \
        echo \"UE_noinfo: \$(cat \$mc/ue_noinfo_count 2>/dev/null || echo N/A)\"; \
        echo \"MC size: \$(cat \$mc/size_mb 2>/dev/null || echo N/A) MB\"; done; \
        else echo 'EDAC not available (no /sys/devices/system/edac)'; fi" \
        "${dir}/edac_errors.log"

    # 5. 每个插槽单独记录（逐行状态机；段落模式 RS="" 会把含 "Bank Locator" 的标准块整体排除，实测 0 文件）
    # 先把完整的内存信息存到临时变量，用 shell 逐段拆分
    local mem_dump_file="${dir}/.dmidecode_memory_raw.tmp"
    dmidecode -t memory > "$mem_dump_file" 2>/dev/null || true
    # 逐行扫描：Locator（非 Bank）行开启新槽文件；空行关闭；遇到下一个 Locator 切换文件
    awk -v dir="${dir}" '
        /^[[:space:]]*Locator:/ && $0 !~ /Bank Locator/ {
            if (out != "") close(out)
            f = $0
            sub(/^[[:space:]]*Locator:[[:space:]]*/, "", f)
            gsub(/[ \t\/]/, "_", f)
            gsub(/__+/, "_", f)
            out = dir "/slot_" f
            print > out
            next
        }
        out != "" && /^[[:space:]]/ {
            print >> out
            next
        }
        out != "" && /^$/ { close(out); out = "" }
    ' "$mem_dump_file" 2>/dev/null
    rm -f "$mem_dump_file"

# NOTE: slot_* files are generated dynamically per DIMM slot (e.g. slot_DIMM_A1.log)
    write_manifest "${dir}/manifest.txt" \
        "dmidecode_memory_full" "dmidecode_memory_full.log" \
        "memory_slot_fields" "memory_slot_fields.log" \
        "free_h" "free_h.log" \
        "proc_meminfo" "proc_meminfo.log" \
        "dmidecode_memory_array" "dmidecode_memory_array.log" \
        "memory_slot_blocks" "memory_slot_blocks.log" \
        "memory_capacity" "memory_capacity.log" \
        "edac_errors" "edac_errors.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_memory "$1"
fi
