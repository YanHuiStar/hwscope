#!/bin/bash
# =============================================================================
# 模块: 10_dcgm.sh — DCGM (Data Center GPU Manager) 诊断
# 输出目录: <OUTPUT_DIR>/dcgm/
# 说明：需要安装 datacenter-gpu-manager，无则静默跳过
# =============================================================================

MODULE_NAME="DCGM"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_dcgm() {
    local output_dir="$1"
    local dir="${output_dir}/dcgm"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    if ! check_cmd dcgmi; then
        echo -e "${YELLOW}[SKIP] dcgmi not found (install datacenter-gpu-manager)${NC}"
        module_end "$MODULE_NAME"
        return 0
    fi

    # 1. 发现所有 GPU
    run_and_log "dcgmi discovery -l 2>&1" "${dir}/dcgmi_discovery.log"

    # 2. GPU 统计信息
    run_and_log "dcgmi stats -v 2>&1" "${dir}/dcgmi_stats.log"

    # 3. GPU 配置
    run_and_log "dcgmi config --list 2>&1" "${dir}/dcgmi_config.log"

    # 4. 快速健康检查（Level 1，纯获取，不产生负载）
    run_and_log "dcgmi diag -r 1 2>&1" "${dir}/dcgmi_diag_level1.log"

    # 5. 每个 GPU 单独诊断（dcgmi 输出格式：GPU ID / GPU Index / gpu_id 等）
    local gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
    if [ "$gpu_count" -gt 0 ]; then
        for ((i=0; i<gpu_count; i++)); do
            run_and_log "dcgmi diag -r 1 -i $i 2>&1" "${dir}/dcgmi_diag_gpu${i}.log"
        done
    fi

    # 6. dcgm 版本
    run_and_log "dcgmi --version 2>&1" "${dir}/dcgmi_version.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_dcgm "$1"
fi
