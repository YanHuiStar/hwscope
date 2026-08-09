#!/bin/bash
# =============================================================================
# 模块: 13_nvsm.sh — NVSM (NVIDIA System Management) 信息采集
# 输出目录: <OUTPUT_DIR>/nvsm/
# 说明：仅 NVIDIA MGX 认证整机预装，无 NVSM 则静默跳过
# =============================================================================

MODULE_NAME="NVSM"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_nvsm() {
    local output_dir="$1"
    local dir="${output_dir}/nvsm"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    if ! check_cmd nvsm; then
        echo -e "${YELLOW}[SKIP] nvsm not found (only on MGX certified systems)${NC}"
        module_end "$MODULE_NAME"
        return 0
    fi

    # 1~5 + 6~9. 全部独立 NVSM 查询命令（并行采集；串行模式自动降级）
    run_and_log_parallel 22 \
        "nvsm dump system 2>&1" "${dir}/nvsm_dump_system.log" \
        "nvsm dump health 2>&1" "${dir}/nvsm_dump_health.log" \
        "nvsm list components 2>&1" "${dir}/nvsm_components.log" \
        "nvsm list sensors 2>&1" "${dir}/nvsm_sensors.log" \
        "nvsm show asset 2>&1" "${dir}/nvsm_asset.log" \
        "nvsm show component GPU_SXM_1 2>&1" "${dir}/nvsm_gpu_sxm_1.log" \
        "nvsm show component GPU_SXM_2 2>&1" "${dir}/nvsm_gpu_sxm_2.log" \
        "nvsm show component GPU_SXM_3 2>&1" "${dir}/nvsm_gpu_sxm_3.log" \
        "nvsm show component GPU_SXM_4 2>&1" "${dir}/nvsm_gpu_sxm_4.log" \
        "nvsm show component GPU_SXM_5 2>&1" "${dir}/nvsm_gpu_sxm_5.log" \
        "nvsm show component GPU_SXM_6 2>&1" "${dir}/nvsm_gpu_sxm_6.log" \
        "nvsm show component GPU_SXM_7 2>&1" "${dir}/nvsm_gpu_sxm_7.log" \
        "nvsm show component GPU_SXM_8 2>&1" "${dir}/nvsm_gpu_sxm_8.log" \
        "nvsm show component NVSwitch_1 2>&1" "${dir}/nvsm_nvswitch_1.log" \
        "nvsm show component NVSwitch_2 2>&1" "${dir}/nvsm_nvswitch_2.log" \
        "nvsm show component NVSwitch_3 2>&1" "${dir}/nvsm_nvswitch_3.log" \
        "nvsm show component NVSwitch_4 2>&1" "${dir}/nvsm_nvswitch_4.log" \
        "nvsm show component NIC 2>&1" "${dir}/nvsm_nic.log" \
        "nvsm show component MEMORY 2>&1" "${dir}/nvsm_memory.log" \
        "nvsm show component PSU 2>&1" "${dir}/nvsm_psu.log" \
        "nvsm show component FAN 2>&1" "${dir}/nvsm_fan.log" \
        "nvsm --version 2>&1" "${dir}/nvsm_version.log"

write_manifest "${dir}/manifest.txt" \
        "nvsm_dump_system" "nvsm_dump_system.log" \
        "nvsm_dump_health" "nvsm_dump_health.log" \
        "nvsm_components" "nvsm_components.log" \
        "nvsm_sensors" "nvsm_sensors.log" \
        "nvsm_asset" "nvsm_asset.log" \
        "nvsm_gpu_sxm_1" "nvsm_gpu_sxm_1.log" \
        "nvsm_gpu_sxm_2" "nvsm_gpu_sxm_2.log" \
        "nvsm_gpu_sxm_3" "nvsm_gpu_sxm_3.log" \
        "nvsm_gpu_sxm_4" "nvsm_gpu_sxm_4.log" \
        "nvsm_gpu_sxm_5" "nvsm_gpu_sxm_5.log" \
        "nvsm_gpu_sxm_6" "nvsm_gpu_sxm_6.log" \
        "nvsm_gpu_sxm_7" "nvsm_gpu_sxm_7.log" \
        "nvsm_gpu_sxm_8" "nvsm_gpu_sxm_8.log" \
        "nvsm_nvswitch_1" "nvsm_nvswitch_1.log" \
        "nvsm_nvswitch_2" "nvsm_nvswitch_2.log" \
        "nvsm_nvswitch_3" "nvsm_nvswitch_3.log" \
        "nvsm_nvswitch_4" "nvsm_nvswitch_4.log" \
        "nvsm_nic" "nvsm_nic.log" \
        "nvsm_memory" "nvsm_memory.log" \
        "nvsm_psu" "nvsm_psu.log" \
        "nvsm_fan" "nvsm_fan.log" \
        "nvsm_version" "nvsm_version.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_nvsm "$1"
fi
