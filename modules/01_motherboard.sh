#!/bin/bash
# =============================================================================
# 模块: 01_motherboard.sh — 主板/BIOS/机箱 信息采集
# 输出目录: <OUTPUT_DIR>/motherboard/
# =============================================================================

MODULE_NAME="Motherboard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_motherboard() {
    local output_dir="$1"
    local dir="${output_dir}/motherboard"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    if ! check_cmd dmidecode; then
        echo -e "${YELLOW}[SKIP] dmidecode not found, try installing dmidecode${NC}"
        module_end "$MODULE_NAME"
        return 0
    fi

    # 1~6. 主板/BIOS/机箱信息（全部独立，并行采集；串行模式自动降级）
    run_and_log_parallel 6 \
        "dmidecode -t system" "${dir}/dmidecode_system.log" \
        "dmidecode -t baseboard" "${dir}/dmidecode_baseboard.log" \
        "dmidecode -t bios" "${dir}/dmidecode_bios.log" \
        "dmidecode -t chassis" "${dir}/dmidecode_chassis.log" \
        "dmidecode -t system 2>/dev/null | grep -E 'Manufacturer|Product Name|Serial Number|UUID|Family'" "${dir}/system_summary.log" \
        "dmidecode -t baseboard 2>/dev/null | grep -E 'Manufacturer|Product Name|Serial Number|Version|Asset Tag'" "${dir}/baseboard_summary.log"

write_manifest "${dir}/manifest.txt" \
        "dmidecode_system" "dmidecode_system.log" \
        "dmidecode_baseboard" "dmidecode_baseboard.log" \
        "dmidecode_bios" "dmidecode_bios.log" \
        "dmidecode_chassis" "dmidecode_chassis.log" \
        "system_summary" "system_summary.log" \
        "baseboard_summary" "baseboard_summary.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_motherboard "$1"
fi
