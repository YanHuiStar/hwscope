#!/bin/bash
# =============================================================================
# 模块: 02_cpu.sh — CPU 信息采集（FRU + OS 双视角）
# 输出目录: <OUTPUT_DIR>/cpu/
# =============================================================================

MODULE_NAME="CPU"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_cpu() {
    local output_dir="$1"
    local dir="${output_dir}/cpu"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # 检测 CPU 架构（x86_64 vs aarch64 解析逻辑不同）
    local cpu_arch=$(uname -m 2>/dev/null || echo "unknown")

    # 1. CPU FRU 信息（dmidecode）
    if check_cmd dmidecode; then
        run_and_log "dmidecode -t processor" "${dir}/dmidecode_processor.log"
        run_and_log "dmidecode -t processor 2>/dev/null | grep -E 'Manufacturer|Family|Version|Max Speed|Core Count|Thread Count'" \
            "${dir}/dmidecode_processor_summary.log"
    else
        echo -e "${YELLOW}[SKIP] dmidecode not found, skipping FRU view${NC}"
    fi

    # 2. CPU OS 视角（lscpu / /proc/cpuinfo）
    run_and_log "lscpu" "${dir}/lscpu.log"
    run_and_log "nproc" "${dir}/cpu_core_count.log"

    if [ "$cpu_arch" = "aarch64" ]; then
        run_and_log "cat /proc/cpuinfo | grep -E 'CPU implementer|CPU part|CPU variant|CPU revision|CPU architecture|Features' | sort -u" \
            "${dir}/cpu_summary.log"
    else
        run_and_log "cat /proc/cpuinfo | grep -E 'model name|physical id|siblings|core id|cpu cores' | sort -u" \
            "${dir}/cpu_summary.log"
    fi
    run_and_log "cat /proc/cpuinfo" "${dir}/proc_cpuinfo_full.log"

    # 3. CPU 拓扑
    run_and_log "lscpu -e" "${dir}/lscpu_extended.log"
    run_and_log "cat /sys/devices/system/cpu/smt/active 2>/dev/null" "${dir}/smt_status.log"

    # 4. CPU 频率（避免 awk field 引用，改用 awk 内置变量）
    run_and_log "awk -F':[ \t]*' '/cpu MHz/{s+=\$2; c++} END{printf \"Average: %.0f MHz, Total CPUs: %d\n\", s/c, c}' /proc/cpuinfo 2>/dev/null" \
        "${dir}/cpu_freq.log"
    run_and_log "LANG=C lscpu | grep -E 'CPU MHz|CPU max MHz|CPU min MHz'" "${dir}/cpu_freq_range.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_cpu "$1"
fi
