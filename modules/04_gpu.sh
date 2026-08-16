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

    # Phase 1: 串行获取 GPU 数量（后续命令依赖此值）
    local gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)

    # Phase 2: 构建并行任务数组
    local gpu_jobs=()
    # 每 GPU 的 detail + ECC
    for ((i=0; i<gpu_count; i++)); do
        gpu_jobs+=("nvidia-smi -i $i -q" "${dir}/gpu_${i}_detail.log")
        gpu_jobs+=("nvidia-smi -i $i -q -d ECC" "${dir}/gpu_${i}_ecc.log")
    done
    # 独立命令（不分设备）
    gpu_jobs+=(
        "nvidia-smi -q"                                                              "${dir}/gpu_full.log"
        "nvidia-smi --query-gpu=index,name,serial,pci.bus_id,gpu_uuid,memory.total,memory.used,power.limit,power.draw,temperature.gpu,utilization.gpu,clocks.current.graphics,clocks.current.memory,ecc.mode.current,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv" "${dir}/gpu_inventory.csv"
        "nvidia-smi nvlink --status"                                                  "${dir}/gpu_nvlink_status.log"
        "nvidia-smi nvlink --capabilities"                                            "${dir}/gpu_nvlink_cap.log"
        "nvidia-smi -q -d ECC"                                                        "${dir}/gpu_ecc_full.log"
        "nvidia-smi --query-gpu=index,name,ecc.mode.current,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total --format=csv" "${dir}/gpu_ecc_inventory.csv"
        "nvidia-smi pmon -c 1"                                                        "${dir}/gpu_pmon.log"
        "nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_bus_id --format=csv" "${dir}/gpu_processes.csv"
        "nvidia-smi --query-gpu=driver_version --format=csv"                          "${dir}/gpu_driver_version.log"
        "nvidia-smi topo -m"                                                          "${dir}/gpu_topo.log"
        "nvidia-smi --query-remapped-rows=remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure --format=csv" "${dir}/gpu_remapped_rows.csv"
    )

    run_and_log_parallel 8 "${gpu_jobs[@]}"
    local parallel_ret=$?
    # gpu_topo_nic.log 与 gpu_topo.log 同命令（v1.26.27 起新版 topo -m 已含 NIC 列），
    # 并行采集完成后复制（须在 run_and_log_parallel 之后：此时 gpu_topo.log 已生成）
    cp "${dir}/gpu_topo.log" "${dir}/gpu_topo_nic.log" 2>/dev/null || true
    if [ "$parallel_ret" -ne 0 ]; then
        echo -e "${YELLOW}[WARN] GPU 采集部分失败，请检查 nvidia-smi 可用性及日志文件${NC}" >&2
    fi 

# NOTE: gpu_N_detail.log and gpu_N_ecc.log are generated per GPU (N=0,1,...)
    write_manifest "${dir}/manifest.txt" \
        "gpu_full" "gpu_full.log" \
        "gpu_inventory" "gpu_inventory.csv" \
        "gpu_nvlink_status" "gpu_nvlink_status.log" \
        "gpu_nvlink_cap" "gpu_nvlink_cap.log" \
        "gpu_ecc_full" "gpu_ecc_full.log" \
        "gpu_ecc_inventory" "gpu_ecc_inventory.csv" \
        "gpu_pmon" "gpu_pmon.log" \
        "gpu_processes" "gpu_processes.csv" \
        "gpu_driver_version" "gpu_driver_version.log" \
        "gpu_topo" "gpu_topo.log" \
        "gpu_topo_nic" "gpu_topo_nic.log" \
        "gpu_remapped_rows" "gpu_remapped_rows.csv"

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
