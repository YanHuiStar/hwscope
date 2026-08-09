#!/bin/bash
# =============================================================================
# 模块: 99_os.sh — OS 基础信息采集
# 输出目录: <OUTPUT_DIR>/os/
# =============================================================================

MODULE_NAME="OS-Info"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_os() {
    local output_dir="$1"
    local dir="${output_dir}/os"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # 1. 独立的 OS 基础信息命令（并行采集；串行模式自动降级）
    run_and_log_parallel 4 \
        "uname -a" "${dir}/uname.log" \
        "lsmod | grep -E 'nvidia|mlx5|mlx4|ipmi|i2c'" "${dir}/kernel_modules_gpu_net.log" \
        "lsmod" "${dir}/lsmod_all.log" \
        "uptime" "${dir}/uptime.log"

    # 2. OS 发行版（需逐文件检查，条件执行）
    for f in /etc/os-release /etc/redhat-release /etc/debian_version /etc/SuSE-release /etc/centos-release; do
        if [ -f "$f" ]; then
            run_and_log "cat '$f'" "${dir}/$(basename "$f").log"
        fi
    done

    # 3~4. 系统负载（独立于上面的并行批次，串行执行）
    run_and_log "cat /proc/loadavg" "${dir}/loadavg.log"

    # 5. 系统日志中的硬件相关（条件执行：需 dmesg）
    if check_cmd dmesg; then
        run_and_log_parallel 3 \
            "dmesg | grep -iE 'nvidia|nvswitch|mlx5|pcie|error|fail|temp|throttle' | tail -200" \
                "${dir}/dmesg_hardware.log" \
            "dmesg | grep -i nvidia | tail -100" "${dir}/dmesg_nvidia.log" \
            "dmesg | grep -iE 'nvswitch|fabric' | tail -100" "${dir}/dmesg_nvswitch.log"
    fi

    # 6. 服务状态（条件执行：需 systemctl）
    if check_cmd systemctl; then
        for svc in nvidia-fabricmanager nvsmd nvidia-persistenced; do
            run_and_log "systemctl status $svc 2>&1 | head -30" "${dir}/service_${svc}.log"
        done
    fi

    # 7. NUMA 拓扑（部分条件执行）
    if check_cmd numactl; then
        run_and_log "numactl --hardware" "${dir}/numa_hardware.log"
    fi
    run_and_log "cat /sys/devices/system/node/online 2>/dev/null" "${dir}/numa_nodes.log"
    for node in /sys/devices/system/node/node*; do
        if [ -d "$node" ]; then
            local node_name=$(basename "$node")
            run_and_log "cat '${node}/cpulist' 2>/dev/null" "${dir}/${node_name}_cpus.log"
        fi
    done

    # 8. PCIe AER 错误统计（条件执行）
    if [ -d /sys/kernel/debug/pci ]; then
        run_and_log "cat /sys/kernel/debug/pci/*/aer_stats 2>/dev/null" "${dir}/pcie_aer.log"
    fi

    # 9. NVIDIA 相关 sysfs（条件执行：需逐目录检查）
    for sysfs_path in /sys/bus/pci/drivers/nvidia /sys/module/nvidia /sys/module/nvidia_uvm /sys/module/nvidia_drm; do
        if [ -d "$sysfs_path" ]; then
            local safe_name=$(echo "$sysfs_path" | tr '/' '_')
            run_and_log "ls -la '$sysfs_path'" "${dir}/sysfs_${safe_name}.log"
        fi
    done

# NOTE: os-release.log, redhat-release.log, etc. are conditional (file existence)
    # NOTE: service_*.log per nvidia service (conditional - systemctl)
    # NOTE: nodeN_cpus.log per NUMA node (loop)
    # NOTE: sysfs_*.log per nvidia sysfs path (loop, conditional)
    write_manifest "${dir}/manifest.txt" \
        "uname" "uname.log" \
        "kernel_modules_gpu_net" "kernel_modules_gpu_net.log" \
        "lsmod_all" "lsmod_all.log" \
        "uptime" "uptime.log" \
        "loadavg" "loadavg.log" \
        "dmesg_hardware" "dmesg_hardware.log" \
        "dmesg_nvidia" "dmesg_nvidia.log" \
        "dmesg_nvswitch" "dmesg_nvswitch.log" \
        "numa_hardware" "numa_hardware.log" \
        "numa_nodes" "numa_nodes.log" \
        "pcie_aer" "pcie_aer.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_os "$1"
fi
