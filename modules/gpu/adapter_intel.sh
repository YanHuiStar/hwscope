#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：Intel（xpu-smi，Intel Data Center GPU / Arc 生态）
# modules/gpu/adapter_intel.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_intel <gpu_dir> [prefix]
# v1.47.0：xpu-smi 全量落盘；统一 CSV 取 lspci 层（PCIe 链路可判）——
#   xpu-smi discovery/stats 输出解析标注【待真机校准】
# =============================================================================

run_gpu_intel() {
    local dir="$1" prefix="${2:-}"
    if ! check_cmd xpu-smi; then
        gpu_fallback_pci "$dir" "$prefix" "xpu-smi" "Intel"
        return 1
    fi

    echo -e "${CYAN}[INFO] 检测到 Intel GPU（xpu-smi），走 Intel XPU 采集路径${NC}"

    local int_jobs=(
        "xpu-smi discovery"           "${dir}/gpu_intel_discovery.log"
        "xpu-smi stats"               "${dir}/gpu_intel_stats.log"
        "xpu-smi dump"                "${dir}/gpu_intel_dump.log"
    )
    run_and_log_parallel 3 "${int_jobs[@]}"

    # 每卡明细（按 lspci 加速卡数；待真机校准按 discovery 的 device id 细分）
    local _cnt=${GPU_PCI_PRESENT:-0}
    local _ii=0
    while [ "$_ii" -lt "$_cnt" ]; do
        run_and_log "xpu-smi stats -d $_ii" "${dir}/gpu_intel_${_ii}_detail.log"
        _ii=$((_ii + 1))
    done

    gpu_csv_from_lspci "$dir" "$prefix" "Intel"
    local inv_csv="gpu_inventory.csv"
    [ -n "$prefix" ] && inv_csv="gpu_inventory_${prefix}.csv"

    gpu_adapter_manifest "$dir" \
        "gpu_intel_discovery" "gpu_intel_discovery.log" \
        "gpu_intel_stats" "gpu_intel_stats.log" \
        "gpu_inventory" "${inv_csv}"
}
