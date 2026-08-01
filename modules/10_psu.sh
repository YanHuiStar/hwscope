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
        run_and_log "ipmitool sensor list 2>/dev/null | grep -iE 'PSU|Pwr|PSC|PSU.*Status'" \
            "${dir}/ipmi_psu_sensors.log"
        run_and_log "ipmitool sensor list 2>/dev/null | grep -iE 'PSU.*Temp'" \
            "${dir}/ipmi_psu_temp.log"
        run_and_log "ipmitool sensor list 2>/dev/null | grep -iE 'PSU.*Power|PSU.*In|PSU.*Out|Total.*Power|Pwr Cons'" \
            "${dir}/ipmi_psu_power.log"
    else
        echo -e "${YELLOW}[SKIP] ipmitool not found${NC}"
    fi

    # ─── 2. sysfs power_supply ───
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

    # ─── 3. pmbus / i2c 工具 ───
    if check_cmd i2cdetect; then
        for bus in /dev/i2c-*; do
            local bus_num=$(echo "$bus" | grep -oE '[0-9]+$')
            run_and_log "i2cdetect -y $bus_num 2>/dev/null" "${dir}/i2c_bus${bus_num}.log"
        done
    fi

    # ─── 4. 电源系统总览 ───
    run_and_log "cat /sys/class/power_supply/*/present 2>/dev/null" "${dir}/psu_present.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_psu "$1"
fi
