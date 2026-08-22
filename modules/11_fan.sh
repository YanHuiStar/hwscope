#!/bin/bash
# =============================================================================
# 模块: 11_fan.sh — 风扇 (FAN) 信息采集
# 输出目录: <OUTPUT_DIR>/fan/
#
# 采集来源：
#   - IPMI 风扇传感器（转速/占空比/阈值）
#   - lm-sensors（sensors 命令）
#   - hwmon sysfs
# =============================================================================

MODULE_NAME="FAN"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_fan() {
    local output_dir="$1"
    local dir="${output_dir}/fan"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # ─── 1. IPMI 风扇传感器 ───
    if check_cmd ipmitool; then
        run_and_log_parallel 4 \
            "ipmitool sensor list 2>/dev/null | grep -iE 'FAN|RPM|PWM|Duty'" "${dir}/ipmi_fan_sensors.log" \
            "ipmitool sensor list 2>/dev/null | grep -iE 'FAN.*Status|FAN.*Mode'" "${dir}/ipmi_fan_status.log" \
            "ipmitool sdr list 2>/dev/null | grep -iE 'Fan.*Redundancy|FAN.*Cable|Fan.*PG|Redundancy'" "${dir}/ipmi_fan_redundancy.log"
        # 冗余三态兜底：sdr 无匹配时从 sensor list 再抓（Dell/标准服务器传感器名变体，v1.36.0）
        if [ ! -s "${dir}/ipmi_fan_redundancy.log" ]; then
            run_and_log "ipmitool sensor list 2>/dev/null | grep -iE 'Fan.*Redundancy|FAN.*Cable|Fan.*PG'" "${dir}/ipmi_fan_redundancy.log"
        fi
    else
        echo -e "${YELLOW}[SKIP] ipmitool not found${NC}"
    fi

    # ─── 2. lm-sensors ───
    if check_cmd sensors; then
        run_and_log_parallel 4 \
            "sensors 2>/dev/null" "${dir}/sensors_all.log" \
            "sensors 2>/dev/null | grep -iE 'fan|FAN'" "${dir}/sensors_fan.log"
    else
        echo -e "${YELLOW}[SKIP] sensors (lm-sensors) not found${NC}"
    fi

    # ─── 3. hwmon sysfs ───
    if [ -d /sys/class/hwmon ]; then
        for hwmon in /sys/class/hwmon/hwmon*; do
            local hwmon_name
            hwmon_name=$(basename "$hwmon")
            [ "$hwmon_name" = "hwmon*" ] && continue

            # 读取设备名称
            local dev_name=""
            [ -f "${hwmon}/name" ] && dev_name=$(cat "${hwmon}/name" 2>/dev/null)

            # 只采集含风扇的设备（直接判 ls 退出码——管道取 head 退出码恒 0 导致守卫恒真，每个 hwmon 目录都建空目录）
            if ls "${hwmon}"/fan*_input >/dev/null 2>&1; then
                local fan_dir="${dir}/hwmon_${hwmon_name}_${dev_name}"
                mkdir -p "$fan_dir"

                for fanfile in "${hwmon}"/fan*_input "${hwmon}"/fan*_min "${hwmon}"/fan*_max "${hwmon}"/fan*_target "${hwmon}"/pwm* "${hwmon}"/pwm*_enable; do
                    [ -f "$fanfile" ] && echo "$(basename "$fanfile"): $(cat "$fanfile" 2>/dev/null)" >> "${fan_dir}/fan_values.log"
                done
            fi
        done
    fi

    # ─── 4. /proc 风扇信息（ACPI） ───
    if [ -d /proc/acpi/fan ]; then
        run_and_log "cat /proc/acpi/fan/*/state 2>/dev/null" "${dir}/acpi_fan.log"
    fi

# NOTE: hwmon_*/fan_values.log per hwmon device with fan inputs (conditional)
    write_manifest "${dir}/manifest.txt" \
        "ipmi_fan_sensors" "ipmi_fan_sensors.log" \
        "ipmi_fan_status" "ipmi_fan_status.log" \
        "ipmi_fan_redundancy" "ipmi_fan_redundancy.log" \
        "sensors_all" "sensors_all.log" \
        "sensors_fan" "sensors_fan.log" \
        "acpi_fan" "acpi_fan.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_fan "$1"
fi
