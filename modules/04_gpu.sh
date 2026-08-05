#!/bin/bash
# =============================================================================
# 模块: 04_gpu.sh — GPU 信息采集
# 输出目录: <OUTPUT_DIR>/gpu/
# =============================================================================

MODULE_NAME="GPU"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_gpu() {
    local output_dir="$1"
    local dir="${output_dir}/gpu"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # 检查 nvidia-smi 是否存在
    if ! check_cmd nvidia-smi; then
        echo -e "${YELLOW}[SKIP] nvidia-smi not found, skipping GPU module${NC}"
        module_end "$MODULE_NAME"
        return 0
    fi

    # 1. GPU 全量信息
    run_and_log "nvidia-smi -q" "${dir}/gpu_full.log"

    # 2. GPU 资产清单（CSV格式，方便后续导入；含 PCIe 链路与利用率供降级检测）
    run_and_log "nvidia-smi --query-gpu=index,name,serial,pci.bus_id,gpu_uuid,memory.total,memory.used,power.limit,power.draw,temperature.gpu,utilization.gpu,clocks.current.graphics,clocks.current.memory,ecc.mode.current,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv" \
        "${dir}/gpu_inventory.csv"

    # 3. 每个 GPU 的详细信息（按索引拆分，方便定位单个 GPU）
    local gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
    for ((i=0; i<gpu_count; i++)); do
        run_and_log "nvidia-smi -i $i -q" "${dir}/gpu_${i}_detail.log"
    done

    # 4. NVLink 状态
    run_and_log "nvidia-smi nvlink --status" "${dir}/gpu_nvlink_status.log"
    run_and_log "nvidia-smi nvlink --capabilities" "${dir}/gpu_nvlink_cap.log"

    # 5. ECC 信息（HBM 显存 ECC 状态和错误计数）
    run_and_log "nvidia-smi -q -d ECC" "${dir}/gpu_ecc_full.log"
    run_and_log "nvidia-smi --query-gpu=index,name,ecc.mode.current,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total --format=csv" \
        "${dir}/gpu_ecc_inventory.csv"
    for ((i=0; i<gpu_count; i++)); do
        run_and_log "nvidia-smi -i $i -q -d ECC" "${dir}/gpu_${i}_ecc.log"
    done

    # 6. GPU 进程占用
    run_and_log "nvidia-smi pmon -c 1" "${dir}/gpu_pmon.log"
    run_and_log "nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_bus_id --format=csv" \
        "${dir}/gpu_processes.csv"

    # 7. 驱动版本
    run_and_log "nvidia-smi --query-gpu=driver_version --format=csv" "${dir}/gpu_driver_version.log"

    # 8. GPU topology
    run_and_log "nvidia-smi topo -m" "${dir}/gpu_topo.log"

    module_end "$MODULE_NAME"
}

# 允许单独执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_gpu "$1"
fi
