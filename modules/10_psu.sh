#!/bin/bash
# =============================================================================
# 模块: 10_psu.sh — 电源 (PSU) 信息采集
# 输出目录: <OUTPUT_DIR>/psu/
#
# 采集来源：
#   - IPMI 传感器（功率/温度/状态）
#   - sysfs power_supply
#   - pmbus/i2c 工具（如果可用）
# =============================================================================

MODULE_NAME="PSU"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_psu() {
    local output_dir="$1"
    local dir="${output_dir}/psu"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # ─── 1. IPMI PSU 传感器 ───
    if check_cmd ipmitool; then
        run_and_log_parallel 4 \
            "ipmitool sensor list 2>/dev/null | grep -iE 'PSU|Pwr|PSC|PS[0-9]|PSU.*Status'" "${dir}/ipmi_psu_sensors.log" \
            "ipmitool sensor list 2>/dev/null | grep -iE 'PSU.*Temp|PS[0-9].*Temp'" "${dir}/ipmi_psu_temp.log" \
            "ipmitool sensor list 2>/dev/null | grep -iE 'PSU.*Power|PSU.*In|PSU.*Out|Total.*Power|Pwr Cons|PS[0-9]_Pin|PS[0-9]_Pout'" "${dir}/ipmi_psu_power.log" \
            "ipmitool fru print 2>/dev/null | grep -iE 'FRU Device Description|Product Name|Product Part Number|Product Serial|Power Supply'" "${dir}/ipmi_psu_fru.log" \
            "ipmitool dcmi power reading 2>&1" "${dir}/ipmi_dcmi_power.log" \
            "ipmitool sdr list 2>/dev/null | grep -iE 'PSU|PS[0-9]|Power' " "${dir}/ipmi_sdr_psu.log"
    else
        echo -e "${YELLOW}[SKIP] ipmitool not found${NC}"
    fi

    # ─── 2. dmidecode type 39 Power Supply（独立信源：Name/Manufacturer/SN/Max Capacity/Status） ───
    if check_cmd dmidecode; then
        run_and_log "dmidecode -t 39 2>/dev/null" "${dir}/dmidecode_psu.log"
    fi

    # ─── 3. sysfs power_supply ───
    if [ -d /sys/class/power_supply ]; then
        for psu in /sys/class/power_supply/*; do
            local psu_name=$(basename "$psu")
            [ "$psu_name" = "*" ] && continue

            local psu_dir="${dir}/sysfs_${psu_name}"
            mkdir -p "$psu_dir"

            # 逐个字段采集
            for field in model_name manufacturer serial_number capacity capacity_level health status online type voltage_now current_now power_now temp temp_ambient temp_max alarm; do
                if [ -f "${psu}/${field}" ]; then
                    local val=$(cat "${psu}/${field}" 2>/dev/null)
                    echo "${field}: ${val}" >> "${psu_dir}/info.log"
                fi
            done

            # 也做一个汇总
            run_and_log "for f in ${psu}/*; do echo \"$\$(basename $\$f): $\$(cat $\$f 2>/dev/null)\"; done 2>/dev/null" \
                "${psu_dir}/all_fields.log"
        done
    else
        echo -e "${YELLOW}[SKIP] /sys/class/power_supply not found${NC}"
    fi

    # ─── 4. pmbus / i2c 工具 ───
    if check_cmd i2cdetect; then
        for bus in /dev/i2c-*; do
            [ -e "$bus" ] || continue
            local bus_num=$(echo "$bus" | grep -oE '[0-9]+$')
            [ -n "$bus_num" ] && run_and_log "i2cdetect -y $bus_num 2>/dev/null" "${dir}/i2c_bus${bus_num}.log"
        done
    fi
    # PMBus 直读（i2cget）：扫描常见 PSU 地址读 PMBus 标识寄存器（部分平台 IPMI 无 FRU，型号在 PMBus 芯片里）
    # 标准 PMBus: MFR_ID(0x99)/MFR_MODEL(0x9A)/MFR_SERIAL(0x9E)/MFR_REVISION(0x9B)
    # 常见 PSU I2C 地址: 0x58-0x5F（AC/DC 电源通常 0x58），0x20-0x23
    if check_cmd i2cget; then
        for bus in /dev/i2c-*; do
            [ -e "$bus" ] || continue
            local bus_num=$(echo "$bus" | grep -oE '[0-9]+$')
            [ -z "$bus_num" ] && continue
            for addr in 0x58 0x59 0x5a 0x5b 0x5c 0x5d 0x5e 0x5f 0x20 0x21 0x22 0x23; do
                run_and_log "i2cget -y -f $bus_num $addr 0x9a 2>/dev/null; i2cget -y -f $bus_num $addr 0x99 2>/dev/null; i2cget -y -f $bus_num $addr 0x9e 2>/dev/null" "${dir}/pmbus_${addr#0x}.log"
            done
        done
    fi

    # ─── 5. 电源系统总览 ───
    run_and_log "cat /sys/class/power_supply/*/present 2>/dev/null" "${dir}/psu_present.log"

# NOTE: sysfs_PSU_NAME/info.log, sysfs_PSU_NAME/all_fields.log per PSU
    # NOTE: i2c_busN.log per i2c bus (conditional)
    write_manifest "${dir}/manifest.txt" \
        "ipmi_psu_sensors" "ipmi_psu_sensors.log" \
        "ipmi_psu_temp" "ipmi_psu_temp.log" \
        "ipmi_psu_power" "ipmi_psu_power.log" \
        "ipmi_psu_fru" "ipmi_psu_fru.log" \
        "ipmi_dcmi_power" "ipmi_dcmi_power.log" \
        "ipmi_sdr_psu" "ipmi_sdr_psu.log" \
        "dmidecode_psu" "dmidecode_psu.log" \
        "psu_present" "psu_present.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_psu "$1"
fi
