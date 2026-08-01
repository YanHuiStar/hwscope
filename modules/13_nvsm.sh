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

    # 1. 系统配置 dump
    run_and_log "nvsm dump system 2>&1" "${dir}/nvsm_dump_system.log"

    # 2. 健康状态 dump
    run_and_log "nvsm dump health 2>&1" "${dir}/nvsm_dump_health.log"

    # 3. 组件清单
    run_and_log "nvsm list components 2>&1" "${dir}/nvsm_components.log"

    # 4. 传感器
    run_and_log "nvsm list sensors 2>&1" "${dir}/nvsm_sensors.log"

    # 5. 资产信息
    run_and_log "nvsm show asset 2>&1" "${dir}/nvsm_asset.log"

    # 6. 每个 GPU 组件（SXM 槽位）
    for slot in 1 2 3 4 5 6 7 8; do
        run_and_log "nvsm show component GPU_SXM_${slot} 2>&1" "${dir}/nvsm_gpu_sxm_${slot}.log"
    done

    # 7. 每个 NVSwitch
    for sw in 1 2 3 4; do
        run_and_log "nvsm show component NVSwitch_${sw} 2>&1" "${dir}/nvsm_nvswitch_${sw}.log"
    done

    # 8. NIC / 内存 / PSU / 风扇
    for comp in NIC MEMORY PSU FAN; do
        run_and_log "nvsm show component ${comp} 2>&1" "${dir}/nvsm_${comp,,}.log"
    done

    # 9. 版本信息
    run_and_log "nvsm --version 2>&1" "${dir}/nvsm_version.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_nvsm "$1"
fi
