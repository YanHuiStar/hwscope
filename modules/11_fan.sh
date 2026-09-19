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
        # v1.48.57：IPMI 命令统一加超时——BMC 慢/无响应时单命令无限挂起会拖垮整模块（曾致 PSU/FAN/BMC/Power 4 模块 300s 超时）
        # v1.49.20：删除原 `local ipmi_to=...`——它定义了 `ipmi_to`，下面用的却是 `${ipmi_fast}`
        #   （本模块从未定义该变量，展开为空）→ 两条 sensor list **完全没有超时保护**。
        #   现改为走共享 IPMI 快照（SLOW 级超时在 lib/common.sh 内统一给足 240s），见下。
        # v1.49.0 删除 fan redundancy 采集（原 3 命令 → 现 2，并发数 4→2）：原为 sdr list 主采 +
        #   sensor list 兜底（v1.36.0）。实测 22 台样本无一提供有效信息——6 台采到
        #   `FAN_Redundancy | 0x00 | ok`（0x00 在 IPMI discrete 语义里是「无该状态」，不是「有冗余」），
        #   另 16 台为空；报告端原 `*ok*` 分支还会误判成「冗余满足」。而这两个命令在慢 BMC 上
        #   各自跑满超时（实测该机 exit=124 / 30s 一个），等于每轮白等 30~60 秒换一个无人用的空文件。
        # v1.49.20：从共享快照派生（原为并发两条无超时的 `sensor list`）。sensor list 是全项目
        #   最贵的命令（逐条读 SDR，慢机 200s+），且 IPMI 走 KCS 单通道——并发只会在 BMC 侧排队
        #   互相拖慢，所以快照只采一次、各模块共用（12_bmc/10_psu/16_power 同源）。
        local _fan_snap="" _fan_ok=0
        _fan_snap=$(ipmi_snapshot sensors 2>/dev/null)
        if [ -n "$_fan_snap" ] && [ -f "$_fan_snap" ]; then
            ipmi_snapshot_derive "$_fan_snap" "${dir}/ipmi_fan_sensors.log" 'FAN|RPM|PWM|Duty' 2>/dev/null && _fan_ok=1
            ipmi_snapshot_derive "$_fan_snap" "${dir}/ipmi_fan_status.log" 'FAN.*Status|FAN.*Mode' 2>/dev/null || true
        fi
        if [ "$_fan_ok" -ne 1 ]; then
            # v1.49.20：不可用时写**说明性占位**而非 0 字节文件——0 字节与「平台无风扇传感器」在报告端
            #   无法区分（AGENTS v1.48.88「采集失败必须与平台固有形态区分」）。报告端 FAN_DATA_OK 只认
            #   非注释数据行，故该占位会如实落成「N/A（未取到数据）」并计入数据不足。
            printf '# --- N/A: IPMI 快照不可用（ipmitool 缺失或 sensor list 超时）---\n' > "${dir}/ipmi_fan_sensors.log"
            printf '# --- N/A: IPMI 快照不可用（ipmitool 缺失或 sensor list 超时）---\n' > "${dir}/ipmi_fan_status.log"
            echo -e "${YELLOW}[WARN] IPMI 风扇传感器未取到（快照不可用/超时），已写占位说明${NC}"
        fi
    else
        echo -e "${YELLOW}[SKIP] ipmitool not found${NC}"
    fi

    # ─── 2. lm-sensors ───
    if check_cmd sensors; then
        run_and_log_parallel 4 \
            "sensors 2>/dev/null" "${dir}/sensors_all.log" \
            "sensors 2>/dev/null | grep --line-buffered -iE 'fan|FAN'" "${dir}/sensors_fan.log"
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
