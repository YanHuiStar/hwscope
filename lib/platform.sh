#!/bin/bash
# =============================================================================
# HwScope 平台检测函数库
# lib/platform.sh
# 功能：机器标识、平台架构检测、GPU 计数、IPMI 预热
# =============================================================================

# ─── 机器标识（SN/UUID，fallback 时间戳）───
detect_machine_id() {
    local mid=""
    if check_cmd dmidecode; then
        mid=$(dmidecode -t system 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        [ -z "$mid" ] && mid=$(dmidecode -t baseboard 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        [ -z "$mid" ] && mid=$(dmidecode -t system 2>/dev/null | grep -i 'UUID' | head -1 | awk -F': ' '{print $2}' | tr -d ' -')
    fi
    [ -z "$mid" ] && mid=$(date '+%Y%m%d_%H%M%S')
    echo "$mid"
}

# ─── 平台架构检测（x86_64_SXM / x86_64_PCIe / x86_64_none / aarch64_SXM ...）───
# 设置全局变量：GPU_COUNT, PLATFORM
detect_platform() {
    local hw_arch=$(uname -m 2>/dev/null || echo "unknown")
    PLATFORM="${hw_arch}"
    GPU_COUNT=0

    if check_cmd nvidia-smi; then
        GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l || echo 0)
        # SXM 四重检测：nvswitch CLI → lspci NVSwitch → nv-fabricmanager 进程(需 NVLink 交叉验证) → nvidia-smi topo
        local _sxm=0
        if check_cmd nvswitch && nvswitch -q 2>/dev/null | grep -qi "Switch Name"; then
            _sxm=1
        elif check_cmd lspci && lspci 2>/dev/null | grep -qi "NVSwitch\|SXM.*Bridge"; then
            _sxm=1
        elif pgrep -f nv-fabricmanager >/dev/null 2>&1; then
            # 进程检测有误判风险：交叉验证 NVLink 是否存在（SXM 机器必有 NVLink）
            if nvidia-smi nvlink --status 2>/dev/null | grep -qi "GPU\|active\|link"; then
                _sxm=1
            fi
        fi
        if [ "$_sxm" -eq 1 ]; then
            PLATFORM="${hw_arch}_SXM"
        elif [ "$GPU_COUNT" -gt 0 ]; then
            PLATFORM="${hw_arch}_PCIe"
        else
            PLATFORM="${hw_arch}_none"
        fi
    else
        PLATFORM="${hw_arch}_none"
    fi
}

# ─── IPMI 预热（虚空跑一次 mc info，触发驱动加载，避免首次命令失败）───
ipmi_preheat() {
    if [ "${IPMI_PREHEAT:-1}" -ne 1 ] 2>/dev/null || ! check_cmd ipmitool; then
        return 0
    fi
    ipmitool mc info >/dev/null 2>&1
}
