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
    local cpu_arch
    cpu_arch=$(uname -m 2>/dev/null || echo "unknown")

    # 1. CPU FRU 信息（dmidecode，条件执行）
    if check_cmd dmidecode; then
        run_and_log "dmidecode -t processor" "${dir}/dmidecode_processor.log"
        run_and_log "dmidecode -t processor 2>/dev/null | grep -E 'Manufacturer|Family|Version|Max Speed|Core Count|Thread Count'" \
            "${dir}/dmidecode_processor_summary.log"
    else
        echo -e "${YELLOW}[SKIP] dmidecode not found, skipping FRU view${NC}"
    fi

    # 2. CPU OS 视角 + 拓扑 + 频率（独立命令，并行采集）
    # 架构相关命令串行执行（条件分支）
    if [ "$cpu_arch" = "aarch64" ]; then
        run_and_log "cat /proc/cpuinfo | grep -E 'CPU implementer|CPU part|CPU variant|CPU revision|CPU architecture|Features' | sort -u" \
            "${dir}/cpu_summary.log"
    else
        run_and_log "cat /proc/cpuinfo | grep -E 'model name|physical id|siblings|core id|cpu cores' | sort -u" \
            "${dir}/cpu_summary.log"
    fi

    # 其余独立命令并行
    run_and_log_parallel 8 \
        "lscpu" "${dir}/lscpu.log" \
        "nproc" "${dir}/cpu_core_count.log" \
        "lscpu | grep -E 'Stepping|CPU(s)|Model name' | head -5" "${dir}/cpu_stepping.log" \
        "cat /proc/cpuinfo" "${dir}/proc_cpuinfo_full.log" \
        "lscpu -e" "${dir}/lscpu_extended.log" \
        "cat /sys/devices/system/cpu/smt/active 2>/dev/null" "${dir}/smt_status.log" \
        "awk -F':[ \\t]*' '/cpu MHz/{s+=\$2; c++} END{if(c>0) printf \"Average: %.0f MHz, Total CPUs: %d\\n\", s/c, c; else print \"N/A (no cpu MHz in cpuinfo)\"}' /proc/cpuinfo 2>/dev/null" "${dir}/cpu_freq.log" \
        "LANG=C lscpu | grep -E 'CPU MHz|CPU max MHz|CPU min MHz'" "${dir}/cpu_freq_range.log"

write_manifest "${dir}/manifest.txt" \
        "dmidecode_processor" "dmidecode_processor.log" \
        "dmidecode_processor_summary" "dmidecode_processor_summary.log" \
        "cpu_summary" "cpu_summary.log" \
        "lscpu" "lscpu.log" \
        "cpu_core_count" "cpu_core_count.log" \
        "cpu_stepping" "cpu_stepping.log" \
        "proc_cpuinfo_full" "proc_cpuinfo_full.log" \
        "lscpu_extended" "lscpu_extended.log" \
        "smt_status" "smt_status.log" \
        "cpu_freq" "cpu_freq.log" \
        "cpu_freq_range" "cpu_freq_range.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_cpu "$1"
fi
