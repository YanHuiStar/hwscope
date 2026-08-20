#!/bin/bash
# =============================================================================
# 模块: 06_pcie.sh — PCIe 拓扑/速率信息采集
# 输出目录: <OUTPUT_DIR>/pcie/
# =============================================================================

MODULE_NAME="PCIe"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_pcie() {
    local output_dir="$1"
    local dir="${output_dir}/pcie"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    if ! check_cmd lspci; then
        echo -e "${YELLOW}[SKIP] lspci not found, install pciutils${NC}"
        echo "[SKIP] lspci not found (install pciutils) — PCIe 模块跳过" > "${dir}/00_skip_lspci.log"
        write_manifest "${dir}/manifest.txt" "skip_lspci" "00_skip_lspci.log"
        module_end "$MODULE_NAME"
        return 0
    fi

    # 1~5. 基础 PCIe 信息（独立命令，并行采集；串行模式自动降级）
    run_and_log_parallel 5 \
        "lspci" "${dir}/lspci_all.log" \
        "lspci -t -vv" "${dir}/lspci_tree.log" \
        "lspci -v | grep -A 30 'NVIDIA'" "${dir}/lspci_nvidia.log" \
        "lspci | grep -E 'PCI bridge|Host Bridge|PCIe'" "${dir}/pcie_bridge.log" \
        "lspci -vvv 2>/dev/null | grep -E 'LnkSta:|LnkCap:'" \
            "${dir}/pcie_speed_width.log"

    # 6. 按 GPU 提取 PCIe 速率（需先获取 GPU 总线列表，串行执行）
    local gpu_buses
    gpu_buses=$(lspci -D 2>/dev/null | grep 'NVIDIA' | grep -v 'NVSwitch' | awk '{print $1}')
    if [ -n "$gpu_buses" ]; then
        local count=0
        while IFS= read -r bus; do
            run_and_log "lspci -vvv -s '$bus' 2>/dev/null | grep -E 'Region|LnkSta:|LnkCap:|LnkSta2:'" \
                "${dir}/gpu_pcie_${count}.log"
            ((count++))
        done < <(printf '%s\n' "$gpu_buses")
        # 汇总 GPU PCIe 位置（用 cat -n 避免 awk $0 逃脱引号的问题）
        run_and_log "lspci -D 2>/dev/null | grep NVIDIA | grep -v NVSwitch | cat -n" \
            "${dir}/gpu_pcie_bus_map.log"
    fi

    # 7~8. NUMA 拓扑 + IOMMU 分组（独立命令，并行采集；IOMMU 未启用时 glob 不匹配，输出说明而非垃圾行）
    run_and_log_parallel 2 \
        "if [ -d /sys/bus/pci/devices ]; then for d in /sys/bus/pci/devices/*/numa_node; do [ -e \"\$d\" ] || continue; echo \"\$(basename \$(dirname \$d)) -> node \$(cat \$d)\"; done 2>/dev/null; fi" \
            "${dir}/pci_numa_map.log" \
        "if [ -d /sys/kernel/iommu_groups ]; then for g in /sys/kernel/iommu_groups/*; do echo \"IOMMU Group \$(basename \$g):\"; for d in \$g/devices/*; do echo \"  \$(basename \$d) - \$(lspci -n -s \$(basename \$d) 2>/dev/null)\"; done; done 2>/dev/null; else echo 'IOMMU not enabled (BIOS VT-d off)'; fi" \
            "${dir}/iommu_groups.log"

# NOTE: gpu_pcie_N.log are generated per GPU bus (N=0,1,...)
    write_manifest "${dir}/manifest.txt" \
        "skip_lspci" "00_skip_lspci.log" \
        "lspci_all" "lspci_all.log" \
        "lspci_tree" "lspci_tree.log" \
        "lspci_nvidia" "lspci_nvidia.log" \
        "pcie_bridge" "pcie_bridge.log" \
        "pcie_speed_width" "pcie_speed_width.log" \
        "gpu_pcie_bus_map" "gpu_pcie_bus_map.log" \
        "pci_numa_map" "pci_numa_map.log" \
        "iommu_groups" "iommu_groups.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_pcie "$1"
fi
