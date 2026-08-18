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
    # GPU/NVSwitch 组件动态枚举：GPU 按 nvidia-smi 数量（无 nvidia-smi 保持 8）；
    # NVSwitch 逐个探测至不存在即停（B300 无独立 NVSwitch/4-GPU MGX 机型自动适配，避免硬编码报错噪音）
    local nvsm_jobs=()
    nvsm_jobs+=("nvsm dump system 2>&1" "${dir}/nvsm_dump_system.log")
    nvsm_jobs+=("nvsm dump health 2>&1" "${dir}/nvsm_dump_health.log")
    nvsm_jobs+=("nvsm list components 2>&1" "${dir}/nvsm_components.log")
    nvsm_jobs+=("nvsm list sensors 2>&1" "${dir}/nvsm_sensors.log")
    nvsm_jobs+=("nvsm show asset 2>&1" "${dir}/nvsm_asset.log")
    local ns_gpu_max=8 _i
    if check_cmd nvidia-smi; then
        _ng=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
        [ "${_ng:-0}" -gt 0 ] 2>/dev/null && ns_gpu_max=$_ng
    fi
    for ((_i=1; _i<=ns_gpu_max; _i++)); do
        nvsm_jobs+=("nvsm show component GPU_SXM_${_i} 2>&1" "${dir}/nvsm_gpu_sxm_${_i}.log")
    done
    local _ns=1 _nso
    while [ "$_ns" -le 8 ]; do
        _nso=$(nvsm show component NVSwitch_${_ns} 2>&1)
        if [ $? -ne 0 ] || echo "$_nso" | grep -qiE "not found|invalid|does not exist"; then break; fi
        nvsm_jobs+=("nvsm show component NVSwitch_${_ns} 2>&1" "${dir}/nvsm_nvswitch_${_ns}.log")
        ((_ns++))
    done
    nvsm_jobs+=("nvsm show component NIC 2>&1" "${dir}/nvsm_nic.log")
    nvsm_jobs+=("nvsm show component MEMORY 2>&1" "${dir}/nvsm_memory.log")
    nvsm_jobs+=("nvsm show component PSU 2>&1" "${dir}/nvsm_psu.log")
    nvsm_jobs+=("nvsm show component FAN 2>&1" "${dir}/nvsm_fan.log")
    nvsm_jobs+=("nvsm --version 2>&1" "${dir}/nvsm_version.log")
    run_and_log_parallel 22 "${nvsm_jobs[@]}"

    # manifest 动态声明（GPU/NVSwitch 数量随探测结果）
    local mf=("${dir}/manifest.txt"
        "nvsm_dump_system" "nvsm_dump_system.log"
        "nvsm_dump_health" "nvsm_dump_health.log"
        "nvsm_components" "nvsm_components.log"
        "nvsm_sensors" "nvsm_sensors.log"
        "nvsm_asset" "nvsm_asset.log")
    for ((_i=1; _i<=ns_gpu_max; _i++)); do
        mf+=("nvsm_gpu_sxm_${_i}" "nvsm_gpu_sxm_${_i}.log")
    done
    for ((_j=1; _j<_ns; _j++)); do
        mf+=("nvsm_nvswitch_${_j}" "nvsm_nvswitch_${_j}.log")
    done
    mf+=("nvsm_nic" "nvsm_nic.log" "nvsm_memory" "nvsm_memory.log"
        "nvsm_psu" "nvsm_psu.log" "nvsm_fan" "nvsm_fan.log" "nvsm_version" "nvsm_version.log")
    write_manifest "${mf[@]}"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_nvsm "$1"
fi
