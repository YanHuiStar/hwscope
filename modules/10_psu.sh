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
        # v1.48.57：IPMI 命令统一加超时——BMC 慢/无响应时单命令无限挂起会拖垮整模块
        # v1.49.9：三条 sensor list 改从**全项目共享快照**派生（原为各跑一次，慢机每次 200s+
        #   → 本模块就吃掉 600s），并发 4 → 2（KCS 单通道，并发只会互相排队）。
        local ipmi_fast="timeout ${IPMI_TIMEOUT_FAST:-30}"; check_cmd timeout || ipmi_fast=""
        local ipmi_to="timeout ${IPMI_TIMEOUT:-90}"; check_cmd timeout || ipmi_to=""
        _pss=$(ipmi_snapshot sensors 2>/dev/null)
        ipmi_snapshot_derive "$_pss" "${dir}/ipmi_psu_sensors.log" 'PSU|Pwr|PSC|PS[0-9]|PSU.*Status' 2>/dev/null || snapshot_na 'IPMI 快照不可用（ipmitool 缺失或 sensor/sdr 命令超时）' "${dir}/ipmi_psu_sensors.log"
        ipmi_snapshot_derive "$_pss" "${dir}/ipmi_psu_temp.log" 'PSU.*Temp|PS[0-9].*Temp' 2>/dev/null || snapshot_na 'IPMI 快照不可用（ipmitool 缺失或 sensor/sdr 命令超时）' "${dir}/ipmi_psu_temp.log"
        ipmi_snapshot_derive "$_pss" "${dir}/ipmi_psu_power.log" 'PSU.*Power|PSU.*In|PSU.*Out|Total.*Power|Pwr Cons|PS[0-9]_Pin|PS[0-9]_Pout' 2>/dev/null || snapshot_na 'IPMI 快照不可用（ipmitool 缺失或 sensor/sdr 命令超时）' "${dir}/ipmi_psu_power.log"
        _psd=$(ipmi_snapshot sdr 2>/dev/null)
        ipmi_snapshot_derive "$_psd" "${dir}/ipmi_sdr_psu.log" 'PSU|PS[0-9]|Power' 2>/dev/null || snapshot_na 'IPMI 快照不可用（ipmitool 缺失或 sensor/sdr 命令超时）' "${dir}/ipmi_sdr_psu.log"
        run_and_log_parallel 2 \
            "${ipmi_to} bash -c \"ipmitool fru print 2>/dev/null | grep --line-buffered -iE 'FRU Device Description|Product Name|Product Part Number|Product Serial|Power Supply'\"" "${dir}/ipmi_psu_fru.log" \
            "${ipmi_fast} bash -c \"ipmitool dcmi power reading 2>&1\"" "${dir}/ipmi_dcmi_power.log"
    else
        echo -e "${YELLOW}[SKIP] ipmitool not found${NC}"
    fi

    # ─── 2. dmidecode type 39 Power Supply（独立信源：Name/Manufacturer/SN/Max Capacity/Status） ───
    if check_cmd dmidecode; then
        run_and_log "dmidecode -t 39 2>/dev/null" "${dir}/dmidecode_psu.log"
    fi

    # ─── 3b. CPU 功耗（Intel RAPL / AMD energy driver）——只读 sysfs，零额外依赖（v1.48.88） ───
    # 为什么需要两次采样：sysfs 暴露的 energy_uj 是**自开机累积的能量计数器**，
    #   单次读取没有功率含义，必须取差值再除以时间：
    #     P(W) = ΔE(uJ) × 10⁻⁶ / Δt(s) = ΔE / Δt(ns) × 1000
    #   采样间隔取 3s（RAPL 计数器刷新粒度通常 1ms~1s，3s 足够稳且不至于明显拖慢采集）。
    # 典型域名：package-0（整 CPU）、core、uncore、dram。平台无 /sys/class/powercap → 跳过，
    #   报告端按「平台固有 N/A」处理（虚拟机/部分 AMD 平台确实没有）。
    if [ -d /sys/class/powercap ]; then
        _rapl_cmd='D=$(ls -d /sys/class/powercap/*/ 2>/dev/null); [ -n "$D" ] || exit 0; for d in $D; do [ -f "${d}name" ] || continue; echo "$(cat ${d}name 2>/dev/null)|$(cat ${d}energy_uj 2>/dev/null)"; done > /tmp/.hw_rapl1; t1=$(date +%s%N); sleep 3; for d in $D; do [ -f "${d}name" ] || continue; echo "$(cat ${d}name 2>/dev/null)|$(cat ${d}energy_uj 2>/dev/null)"; done > /tmp/.hw_rapl2; t2=$(date +%s%N); dt_ns=$((t2-t1)); paste -d"|" /tmp/.hw_rapl1 /tmp/.hw_rapl2 | awk -F"|" -v dt="$dt_ns" "{ if (\$2!=\"\" && \$4!=\"\" && \$4>=\$2 && dt>0) printf \"%s: %.1f W  (E1=%s uJ, E2=%s uJ, 间隔 %.1f s)\\n\", \$1, (\$4-\$2)*1000/dt, \$2, \$4, dt/1000000000 }"; rm -f /tmp/.hw_rapl1 /tmp/.hw_rapl2'
        run_and_log "$_rapl_cmd" "${dir}/rapl_power.log"
    fi

    # ─── 4. sysfs power_supply ───
    if [ -d /sys/class/power_supply ]; then
        for psu in /sys/class/power_supply/*; do
            local psu_name
            psu_name=$(basename "$psu")
            [ "$psu_name" = "*" ] && continue

            local psu_dir="${dir}/sysfs_${psu_name}"
            mkdir -p "$psu_dir"

            # 逐个字段采集
            for field in model_name manufacturer serial_number capacity capacity_level health status online type voltage_now current_now power_now temp temp_ambient temp_max alarm; do
                if [ -f "${psu}/${field}" ]; then
                    local val
                    val=$(cat "${psu}/${field}" 2>/dev/null)
                    echo "${field}: ${val}" >> "${psu_dir}/info.log"
                fi
            done

            # 也做一个汇总
            run_and_log "for f in ${psu}/*; do echo \"\$(basename \$f): \$(cat \$f 2>/dev/null)\"; done 2>/dev/null" \
                "${psu_dir}/all_fields.log"
        done
    else
        echo -e "${YELLOW}[SKIP] /sys/class/power_supply not found${NC}"
    fi

    # ─── 4. pmbus / i2c 工具 ───
    # 只读探测原则：i2cdetect 默认 SMBus quick command 是写探针，会扰动在线 PSU/VRM/EEPROM——
    # 必须 -r（SMBus read-byte 只读）；i2cget 本身是读，但 -f 强读仅限探测总线（保持只读无害约定）
    if check_cmd i2cdetect; then
        for bus in /dev/i2c-*; do
            [ -e "$bus" ] || continue
            local bus_num
            bus_num=$(echo "$bus" | grep -oE '[0-9]+$')
            [ -n "$bus_num" ] && run_and_log "i2cdetect -y -r $bus_num 2>/dev/null" "${dir}/i2c_bus${bus_num}.log"
        done
    fi
    # PMBus 直读（i2cget）：扫描常见 PSU 地址读 PMBus 标识寄存器（部分平台 IPMI 无 FRU，型号在 PMBus 芯片里）
    # 标准 PMBus: MFR_ID(0x99)/MFR_MODEL(0x9A)/MFR_SERIAL(0x9E)/MFR_REVISION(0x9B)
    # 常见 PSU I2C 地址: 0x58-0x5F（AC/DC 电源通常 0x58），0x20-0x23
    if check_cmd i2cget; then
        for bus in /dev/i2c-*; do
            [ -e "$bus" ] || continue
            local bus_num
            bus_num=$(echo "$bus" | grep -oE '[0-9]+$')
            [ -z "$bus_num" ] && continue
            for addr in 0x58 0x59 0x5a 0x5b 0x5c 0x5d 0x5e 0x5f 0x20 0x21 0x22 0x23; do
                # 文件名含 bus 号：多 i2c bus 时同地址不同 bus 的数据互不覆盖
                run_and_log "i2cget -y -f $bus_num $addr 0x9a 2>/dev/null; i2cget -y -f $bus_num $addr 0x99 2>/dev/null; i2cget -y -f $bus_num $addr 0x9e 2>/dev/null" "${dir}/pmbus_bus${bus_num}_${addr#0x}.log"
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
