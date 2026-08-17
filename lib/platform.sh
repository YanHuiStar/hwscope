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
    [ -z "$mid" ] && mid=$(date '+%Y%m%d%H%M%S')
    echo "$mid"
}

# ─── 平台架构检测（x86_64_SXM / x86_64_PCIe / x86_64_head / x86_64_none / aarch64_SXM ...）───
# 设置全局变量：GPU_COUNT, PLATFORM
# head（HGX 机头）：PCIe Gen5 Fabric Switch（PEX89xxx/PEX97xxx/Switchtec）+ 非 SXM + 无 GPU。
#   机头无本地 GPU，经 Switch 接 HGX 模组；裸机采集稳定判 head。模组接入后 GPU 透传可见 → 按事实判 PCIe
#   （报告含模组 GPU 数据）；SXM 一体化主机（B300 等主板也带 PEX89）因有 GPU 不受 head 判定影响。
detect_platform() {
    local hw_arch=$(uname -m 2>/dev/null || echo "unknown")
    PLATFORM="${hw_arch}"
    GPU_COUNT=0

    if check_cmd nvidia-smi; then
        # 注意：pipefail 下 nvidia-smi 非零退出时 `| wc -l || echo 0` 会双输出（wc 的计数 + echo 的 0），
        # 产生 "2\n0" 多行值 → 后续 -gt 比较报 integer expression expected、PLATFORM 误判 none（v1.26.53 真机踩坑）
        # wc 空输入必输出 0（exit 0），无需 || 兜底；再清洗为纯数字防御多行
        GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
        GPU_COUNT=$(echo "$GPU_COUNT" | head -1 | tr -dc '0-9')
        [ -z "$GPU_COUNT" ] && GPU_COUNT=0
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
        # HGX 机头检测：PCIe Gen5 Fabric Switch（Broadcom PEX89xxx / PLX PEX97xxx / Microchip Switchtec）+ 无 GPU
        # 注意必须叠加"无 GPU"条件：SXM 一体化主机（如华硕 HGX B300）主板也带 PEX89xxx Switch，
        # 若 SXM 检测失效且有 GPU，仍按 PCIe 事实判定，避免整机漂移为 head
        local _head=0
        if [ "$GPU_COUNT" -eq 0 ] && check_cmd lspci && lspci 2>/dev/null | grep -qiE "PEX89|PEX97|Switchtec"; then
            _head=1
        fi
        if [ "$_sxm" -eq 1 ]; then
            PLATFORM="${hw_arch}_SXM"
        elif [ "$_head" -eq 1 ]; then
            PLATFORM="${hw_arch}_head"
        elif [ "$GPU_COUNT" -gt 0 ]; then
            PLATFORM="${hw_arch}_PCIe"
        else
            PLATFORM="${hw_arch}_none"
        fi
    else
        # 无 nvidia-smi 也可能有机头（仅 Fabric Switch 可见）
        if check_cmd lspci && lspci 2>/dev/null | grep -qiE "PEX89|PEX97|Switchtec"; then
            PLATFORM="${hw_arch}_head"
        else
            PLATFORM="${hw_arch}_none"
        fi
    fi
}

# ─── IPMI 预热（虚空跑一次 mc info，触发驱动加载，避免首次命令失败）───
ipmi_preheat() {
    if [ "${IPMI_PREHEAT:-1}" -ne 1 ] 2>/dev/null || ! check_cmd ipmitool; then
        return 0
    fi
    ipmitool mc info >/dev/null 2>&1
}
