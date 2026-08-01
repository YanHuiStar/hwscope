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

    # 1. 内存完整 DMI 信息
    run_and_log "dmidecode -t memory" "${dir}/dmidecode_memory_full.log"

    # 2. 内存插槽摘要（每槽一行：位置/容量/速率/制造商/SN/部件号）
    run_and_log "dmidecode -t memory 2>/dev/null | grep -E 'Locator|Size|Type:|Speed|Manufacturer|Serial Number|Part Number|Rank|Configured Clock'" \
        "${dir}/memory_slot_fields.log"
    # 每槽完整的段落输出
    run_and_log "dmidecode -t memory 2>/dev/null | awk '/^[[:space:]]*Locator:/{if(seg) print seg; seg=\$0; next} /^[[:space:]]/{seg=seg ORS \$0} END{print seg}'" \
        "${dir}/memory_slot_blocks.log"

    # 3. 内存容量统计
    run_and_log "echo 'Total Memory Modules:' && dmidecode -t memory 2>/dev/null | grep -c 'Size:' && \
        echo 'Total Capacity (GB):' && dmidecode -t memory 2>/dev/null | grep 'Size:' | grep -v 'No Module' | awk '{sum+=\$2} END{print sum}'" \
        "${dir}/memory_capacity.log"

    # 4. 每个插槽单独记录（用简单 while 循环分段，避免复杂 eval）
    # 先把完整的内存信息存到临时变量，用 shell 逐段拆分
    local mem_dump_file="${dir}/.dmidecode_memory_raw.tmp"
    dmidecode -t memory > "$mem_dump_file" 2>/dev/null || true
    # 按空行切分段落，查找每个 Locator 段落写入独立文件
    awk 'BEGIN {RS=""; FS="\n"} /Locator:/ && !/Bank Locator/ {
        f="'"${dir}"'/slot_" $1
        gsub(/.*Locator: |[ \t\/]/, "_", f)
        gsub(/__+/, "_", f)
        print > f
    }' "$mem_dump_file" 2>/dev/null
    rm -f "$mem_dump_file"

    # 5. 系统内存总览
    run_and_log "free -h" "${dir}/free_h.log"
    run_and_log "cat /proc/meminfo" "${dir}/proc_meminfo.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_memory "$1"
fi
