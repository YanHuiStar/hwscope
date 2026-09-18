#!/bin/bash
# =============================================================================
# 模块: 01_motherboard.sh — 主板/BIOS/机箱 信息采集
# 输出目录: <OUTPUT_DIR>/motherboard/
# =============================================================================

MODULE_NAME="Motherboard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_motherboard() {
    local output_dir="$1"
    local dir="${output_dir}/motherboard"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    if ! check_cmd dmidecode; then
        echo -e "${YELLOW}[SKIP] dmidecode not found, try installing dmidecode${NC}"
        module_end "$MODULE_NAME"
        return 0
    fi

    # 1~6. 主板/BIOS/机箱信息（全部独立，并行采集；串行模式自动降级）
    run_and_log_parallel 6 \
        "dmidecode -t system" "${dir}/dmidecode_system.log" \
        "dmidecode -t baseboard" "${dir}/dmidecode_baseboard.log" \
        "dmidecode -t bios" "${dir}/dmidecode_bios.log" \
        "dmidecode -t chassis" "${dir}/dmidecode_chassis.log" \
        "dmidecode -t system 2>/dev/null | grep -E 'Manufacturer|Product Name|Serial Number|UUID|Family'" "${dir}/system_summary.log" \
        "dmidecode -t baseboard 2>/dev/null | grep -E 'Manufacturer|Product Name|Serial Number|Version|Asset Tag'" "${dir}/baseboard_summary.log"

    # 7. 补充硬件表（缓存/槽位/TPM，独立并行）
    run_and_log_parallel 3 \
        "dmidecode -t cache 2>/dev/null" "${dir}/dmidecode_cache.log" \
        "dmidecode -t slot 2>/dev/null" "${dir}/dmidecode_slot.log" \
        "dmidecode -t 43 2>/dev/null" "${dir}/dmidecode_tpm.log"

    # 7a. 全量 DMI 表（v1.48.88）——裸 dmidecode 覆盖全部 DMI type，补齐此前未采的类型：
    #   Type 27 Cooling Device（风扇）、26 Voltage Probe、28 Temperature Probe、
    #   29 Electrical Current Probe（电流，可与 DCMI 功耗交叉验证）、11 OEM Strings（厂商自定义）、
    #   38 IPMI Device、42 Management Controller Host Interface、8 Port Connector、
    #   10 On Board Devices、32 System Boot、22 Portable Battery 等。
    #   单条命令、零额外依赖，是「一次性补全」成本最低的做法。各 type 的专用文件仍保留
    #   （报告端按专用文件解析；全量文件用于兜底、溯源与后续按需扩展）。
    run_and_log "dmidecode 2>/dev/null" "${dir}/dmidecode_full.log"

    # 7b. 板载设备表（Type 41 Onboard Devices Extended Information）——条件执行
    # v1.48.69：多数服务器平台未实现 Type 41，`dmidecode -t onboard` 输出为空且 exit=2 → run_and_log 记 WARN 误报
    #（22.84 实测：日志 output 区 0 字节 / exit=2）。属平台固有能力缺失，非采集失败。
    # 判据用「输出中是否含 Type 41 条目」而非「输出非空」——dmidecode 在部分环境（如 WSL）
    # 即使无该类型也会打印版本头 2 行（"# dmidecode 3.5" + "Scanning /dev/mem ..."），按非空判断会误采。
    local _ob_probe
    _ob_probe=$(dmidecode -t 41 2>/dev/null | grep -c "DMI type 41")
    if [ "${_ob_probe:-0}" -gt 0 ]; then
        run_and_log "dmidecode -t onboard 2>/dev/null" "${dir}/dmidecode_onboard.log"
    else
        { echo "# --- N/A: 平台未实现 SMBIOS Type 41（Onboard Devices Extended Information）---"
          echo "# 该平台 dmidecode -t onboard 无输出且 exit=2，属固有能力缺失，非采集失败（不计 WARN）"; } \
            > "${dir}/dmidecode_onboard.log"
        echo -e "${YELLOW}[N/A] SMBIOS Type 41 未实现（平台固有），跳过 onboard 表${NC}"
    fi

write_manifest "${dir}/manifest.txt" \
        "dmidecode_system" "dmidecode_system.log" \
        "dmidecode_baseboard" "dmidecode_baseboard.log" \
        "dmidecode_bios" "dmidecode_bios.log" \
        "dmidecode_chassis" "dmidecode_chassis.log" \
        "system_summary" "system_summary.log" \
        "baseboard_summary" "baseboard_summary.log" \
        "dmidecode_cache" "dmidecode_cache.log" \
        "dmidecode_slot" "dmidecode_slot.log" \
        "dmidecode_onboard" "dmidecode_onboard.log" \
        "dmidecode_tpm" "dmidecode_tpm.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_motherboard "$1"
fi
