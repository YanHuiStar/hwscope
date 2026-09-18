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

    # 1b. USB 设备列表（佐证 USB 网卡/外设/板载 USB 设备）
    if check_cmd lsusb; then
        run_and_log "lsusb" "${dir}/lsusb.log"
    fi

    # 2. OS 发行版（需逐文件检查，条件执行）
    for f in /etc/os-release /etc/redhat-release /etc/debian_version /etc/SuSE-release /etc/centos-release; do
        if [ -f "$f" ]; then
            run_and_log "cat '$f'" "${dir}/$(basename "$f").log"
        fi
    done

    # 3~4. 系统负载（独立于上面的并行批次，串行执行）
    run_and_log "cat /proc/loadavg" "${dir}/loadavg.log"

    # 5. 系统日志中的硬件相关（条件执行：需 dmesg；v1.41.0 全量原则：全量落盘 + grep 专项提取）
    if check_cmd dmesg; then
        run_and_log_parallel 4 \
            "dmesg" "${dir}/dmesg_full.log" \
            "dmesg | grep -iE 'nvidia|nvswitch|mlx5|pcie|error|fail|temp|throttle'" \
                "${dir}/dmesg_hardware.log" \
            "dmesg | grep -i nvidia" "${dir}/dmesg_nvidia.log" \
            "dmesg | grep -iE 'nvswitch|fabric'" "${dir}/dmesg_nvswitch.log"
    fi

    # 5b. 持久化内核日志（v1.48.90）——dmesg 是**环形缓冲，重启即丢**，而 XID 这类
    #   GPU 故障码往往是重启之后才被翻出来定位的（现场「机器曾经掉过卡」这种结论，
    #   只能靠持久化日志）。journal 里同时能捞到 MCE（CPU 机器检查异常）与 AER。
    # 范围限制：仅内核消息（-k）+ 最近 7 天（--since），避免 journal 巨大时拖慢采集；
    #   各取 tail 截断，保证单文件可读（全量在 e2e 场景无意义，定位只需要最近若干条）。
    if check_cmd journalctl; then
        run_and_log_parallel 3 \
            "journalctl -k --no-pager --since '7 days ago' 2>/dev/null | grep -iE 'Xid|NVRM|nvswitch|fabric|pcieport|AER|MCA: ' | tail -500" \
                "${dir}/journal_kernel_hw.log" \
            "journalctl -k --no-pager --since '7 days ago' 2>/dev/null | grep -iE 'Xid *(\(PCI|:)|NVRM: Xid' | tail -200" \
                "${dir}/journal_xid.log" \
            "journalctl -k --no-pager --since '7 days ago' 2>/dev/null | grep -iE 'machine check|Hardware Error|mce:|MCA: |EDAC MC[0-9]+: [0-9]+ (CE|UE)' | tail -200" \
                "${dir}/journal_mce.log"
    fi

    # 6. 服务状态（条件执行：需 systemctl；v1.41.0 全量原则：status 全量落盘不截断）
    if check_cmd systemctl; then
        for svc in nvidia-fabricmanager nvidia-persistenced; do
            # v1.48.69：systemd 中无该 unit 时 `systemctl status` 返回 4 → run_and_log 记 WARN 误报。
            # nvidia-persistenced 在部分驱动安装方式下压根没有 unit（persistence mode 由运行时
            # `nvidia-smi -pm 1` 开启），属安装/平台形态而非故障（22.84 实测 exit=4）。
            # 先判 unit 是否存在：不存在 → 落盘说明文件（不计数）；存在 → 正常采集。
            if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
                run_and_log "systemctl status $svc 2>&1" "${dir}/service_${svc}.log"
            else
                { echo "# --- N/A: 系统未安装 ${svc}.service（unit 不存在，属安装方式/平台形态，非故障）---"
                  echo "# 注：nvidia-persistenced 缺失时，可用 'nvidia-smi -pm 1' 运行时开启 persistence mode（重启失效）"; } \
                    > "${dir}/service_${svc}.log"
                echo -e "${YELLOW}[N/A] ${svc}.service 未安装（unit 不存在），跳过${NC}"
            fi
        done
        # nvsmd 仅 MGX 平台（nvsm 命令存在）才查——A100/PCIe 平台无此服务，not-found 报 WARN 属误报（v1.43.7）
        if command -v nvsm >/dev/null 2>&1; then
            run_and_log "systemctl status nvsmd 2>&1" "${dir}/service_nvsmd.log"
        fi
    fi

    # 7. NUMA 拓扑（部分条件执行）
    if check_cmd numactl; then
        run_and_log "numactl --hardware" "${dir}/numa_hardware.log"
    fi
    run_and_log "cat /sys/devices/system/node/online 2>/dev/null" "${dir}/numa_nodes.log"
    for node in /sys/devices/system/node/node*; do
        if [ -d "$node" ]; then
            local node_name
            node_name=$(basename "$node")
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
            local safe_name
            safe_name=$(echo "$sysfs_path" | tr '/' '_')
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
        "lsusb" "lsusb.log" \
        "loadavg" "loadavg.log" \
        "dmesg_hardware" "dmesg_hardware.log" \
        "dmesg_full" "dmesg_full.log" \
        "dmesg_nvidia" "dmesg_nvidia.log" \
        "dmesg_nvswitch" "dmesg_nvswitch.log" \
        "numa_hardware" "numa_hardware.log" \
        "numa_nodes" "numa_nodes.log" \
        "pcie_aer" "pcie_aer.log" \
        "journal_kernel_hw" "journal_kernel_hw.log" \
        "journal_xid" "journal_xid.log" \
        "journal_mce" "journal_mce.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_os "$1"
fi
