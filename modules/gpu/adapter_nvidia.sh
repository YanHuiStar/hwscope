#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：NVIDIA（nvidia-smi，金标准路径）
# modules/gpu/adapter_nvidia.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_nvidia <gpu_dir> [prefix]
#   prefix 用于 mixed 模式：per-card 日志 gpu_<prefix>_<i>_detail.log、清单 gpu_inventory_<prefix>.csv
# =============================================================================

run_gpu_nvidia() {
    local dir="$1" prefix="${2:-}"
    if ! check_cmd nvidia-smi; then
        gpu_fallback_pci "$dir" "$prefix" "nvidia-smi" "NVIDIA"
        return 1
    fi
    local _p=""
    [ -n "$prefix" ] && _p="${prefix}_"

    # Phase 1: 串行获取 GPU 数量（后续命令依赖此值）
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)

    # Phase 2: 构建并行任务数组
    local gpu_jobs=()
    # 每 GPU 的 detail + ECC（mixed 模式带 prefix，与合并 CSV 行内 index 对应）
    local i
    for ((i=0; i<gpu_count; i++)); do
        gpu_jobs+=("nvidia-smi -i $i -q" "${dir}/gpu_${_p}${i}_detail.log")
        gpu_jobs+=("nvidia-smi -i $i -q -d ECC" "${dir}/gpu_${_p}${i}_ecc.log")
    done
    # 独立命令（不分设备）
    local inv_csv="gpu_inventory.csv"
    [ -n "$prefix" ] && inv_csv="gpu_inventory_${prefix}.csv"
    gpu_jobs+=(
        "nvidia-smi -q"                                                              "${dir}/gpu_full.log"
        "nvidia-smi --query-gpu=index,name,serial,pci.bus_id,gpu_uuid,memory.total,memory.used,power.limit,power.draw,temperature.gpu,utilization.gpu,clocks.current.graphics,clocks.current.memory,ecc.mode.current,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv" "${dir}/${inv_csv}"
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
    gpu_adapter_manifest "$dir" \
        "gpu_full" "gpu_full.log" \
        "gpu_inventory" "${inv_csv}" \
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
}
