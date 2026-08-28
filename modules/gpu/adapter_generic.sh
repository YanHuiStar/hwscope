#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：通用兜底（lspci -vvv + sysfs，零厂商工具依赖）
# modules/gpu/adapter_generic.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_generic <gpu_dir> [prefix]
# v1.47.0：任何已识别但无对应厂商工具的加速卡（含 unknown/other 厂商）走此路径——
#   每卡 lspci -vvv 全量落盘（PCIe LnkCap/LnkSta 链路数据，验收"GPU PCIe 链路完整"可判），
#   统一 CSV 含 名称/BDF/PCIe 链路，显存/温度/利用率等 N/A（无工具可读）
# =============================================================================

run_gpu_generic() {
    local dir="$1" prefix="${2:-}"
    local _i=0 _row _bdf _name _did

    # 每卡 lspci -vvv 全量（PCIe 链路/固件信息，v1.41.1 全量原则）
    while IFS='|' read -r _bdf _name _did; do
        [ -z "$_bdf" ] && continue
        run_and_log "lspci -vvv -s $_bdf" "${dir}/gpu_generic_${_i}_pcie.log"
        _i=$((_i + 1))
    done < <(gpu_lspci_accel_rows)

    if [ "${GPU_PLATFORM:-}" = "other" ]; then
        echo -e "${YELLOW}[WARN] 检测到 ${GPU_PCI_PRESENT:-0} 个未知/未适配厂商加速卡（${GPU_PCI_VENDORS:-other}），无对应管理工具——仅 lspci 层采集（PCIe 链路可判）${NC}"
    fi

    # 统一 CSV（lspci 层）
    gpu_csv_from_lspci "$dir" "$prefix" ""

    local inv_csv="gpu_inventory.csv"
    [ -n "$prefix" ] && inv_csv="gpu_inventory_${prefix}.csv"
    gpu_adapter_manifest "$dir" "gpu_inventory" "${inv_csv}"
}
