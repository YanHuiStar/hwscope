#!/bin/bash
# =============================================================================
# 模块: 16_power.sh — 能耗台账模块
# 输出目录: <OUTPUT_DIR>/power/
# 功能: 采集 BMC 功耗计累计读数（IPMI SDR Energy / DCMI / Redfish Power），
#       核算整机累计能耗（kWh），输出能耗台账。
# 场景: 交付后供电核算、机房容量规划。
# 说明: 单点功耗无法核算累计能耗——累计读数依赖 BMC 暴露 Energy/电量计传感器；
#       无累计传感器时明确注明"需持续采样"，不伪造台账（防误读）。
# =============================================================================

MODULE_NAME="Power"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_power() {
    local output_dir="$1"
    # 加载配置（BMC_IP/BMC_USER/BMC_PASS）
    local conf_file="${SCRIPT_DIR}/../conf/hwscope.conf"
    [ -f "$conf_file" ] && source "$conf_file"

    local dir="${output_dir}/power"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # ─── 1. IPMI 本地：累计能耗传感器（Pwr_Energy / *Energy* / kWh / Joules） ───
    if check_cmd ipmitool; then
        run_and_log_parallel 3 \
            "ipmitool sdr list 2>&1 | grep -iE 'energy|kwh|joule'" "${dir}/energy_sdr.log" \
            "ipmitool dcmi power reading 2>&1" "${dir}/dcmi_power.log" \
            "ipmitool sensor list 2>&1 | grep -iE 'power|watt|total'" "${dir}/sensors_power.log"
    else
        echo -e "${YELLOW}[SKIP] ipmitool not found（能耗台账依赖 BMC 传感器）${NC}"
    fi

    # ─── 2. Redfish Power（配置了 BMC_IP 且装了 curl；密码走 netrc 临时文件不落盘） ───
    if [ -n "$BMC_IP" ] && check_cmd curl; then
        NETRC_TMP=$(mktemp)
        chmod 600 "$NETRC_TMP"
        printf 'machine %s login %s password %s\n' "$BMC_IP" "$BMC_USER" "$BMC_PASS" > "$NETRC_TMP"
        # 先取 Chassis 集合，解析首个成员，再取该成员 /Power（含 PowerConsumedWatts/EnergykWh）
        run_and_log "curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}/redfish/v1/Chassis 2>&1 | head -100" "${dir}/redfish_chassis.log"
        local _member
        _member=$(grep -oE '"@odata\.id"[[:space:]]*:[[:space:]]*"[^"]*"' "${dir}/redfish_chassis.log" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
        if [ -n "$_member" ]; then
            run_and_log "curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}${_member}/Power 2>&1 | head -100" "${dir}/redfish_power.log"
        fi
        rm -f "$NETRC_TMP"
    else
        echo -e "${YELLOW}[SKIP] Redfish Power 未采集（BMC_IP 未配置或无 curl）${NC}"
    fi

    # ─── 3. 能耗核算 ───
    local cur_w="" min_w="" max_w="" avg_w="" en_val="" en_unit="" en_kwh="" en_src="" ledger_note=""

    # DCMI 整机功耗（当前/最小/最大/平均）
    if [ -f "${dir}/dcmi_power.log" ]; then
        cur_w=$(grep -im1 "Instantaneous power reading" "${dir}/dcmi_power.log" | grep -oE "[0-9.]+" | head -1)
        min_w=$(grep -im1 "Minimum during sampling" "${dir}/dcmi_power.log" | grep -oE "[0-9.]+" | head -1)
        max_w=$(grep -im1 "Maximum during sampling" "${dir}/dcmi_power.log" | grep -oE "[0-9.]+" | head -1)
        avg_w=$(grep -im1 "Average power reading" "${dir}/dcmi_power.log" | grep -oE "[0-9.]+" | head -1)
    fi

    # Redfish PowerConsumedWatts（DCMI 无数据时回退）
    [ -z "$cur_w" ] && [ -f "${dir}/redfish_power.log" ] && \
        cur_w=$(grep -oE '"PowerConsumedWatts"[^0-9]*[0-9.]+' "${dir}/redfish_power.log" | grep -oE "[0-9.]+" | head -1)

    # 累计能耗：IPMI SDR Energy 传感器优先（Joules/Wh/kWh），Redfish EnergykWh 兜底
    if [ -f "${dir}/energy_sdr.log" ]; then
        local _eline
        _eline=$(grep -v "^#" "${dir}/energy_sdr.log" | grep -iE 'energy|kwh|joule' | head -1)
        if [ -n "$_eline" ]; then
            en_val=$(echo "$_eline" | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -oE "[0-9.]+" | head -1)
            en_unit=$(echo "$_eline" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
            en_src="IPMI SDR"
            case "$en_unit" in
                *Joule*|*joule*) en_kwh=$(awk -v j="$en_val" 'BEGIN{printf "%.4f", j/3600000}' < /dev/null) ;;
                *Wh*|*wh*|*Watt*Hour*) en_kwh=$(awk -v w="$en_val" 'BEGIN{printf "%.4f", w/1000}' < /dev/null) ;;
                *kWh*|*KWH*) en_kwh=$(awk -v k="$en_val" 'BEGIN{printf "%.4f", k}' < /dev/null) ;;
                *) en_kwh="" ;;   # 未知单位不猜测（曾兜底按 kWh 换算，Joules 变体差 360 万倍——v1.33.2 修复）
            esac
            # 未知单位 → en_kwh 保持空，走 Redfish 兜底或"需持续采样"文案，不生成错误台账
        fi
    fi
    if [ -z "$en_kwh" ] && [ -f "${dir}/redfish_power.log" ]; then
        en_val=$(grep -oE '"EnergykWh"[^0-9]*[0-9.]+' "${dir}/redfish_power.log" | grep -oE "[0-9.]+" | head -1)
        if [ -n "$en_val" ]; then
            en_kwh=$(awk -v k="$en_val" 'BEGIN{printf "%.4f", k}' < /dev/null)
            en_unit="kWh"; en_src="Redfish Power"
        fi
    fi

    if [ -n "$en_kwh" ]; then
        ledger_note="累计能耗 ${en_kwh} kWh（${en_src}${en_unit:+ ${en_unit}}）"
    elif [ -n "$cur_w" ]; then
        ledger_note="BMC 未暴露累计能耗传感器（Energy/电量计），当前功耗 ${cur_w}W 为单点快照，无法核算累计能耗——如需台账请持续采样"
    else
        ledger_note="无能耗/功耗数据（ipmitool 不可用或 BMC 传感器不可读）"
    fi

    # ─── 台账输出 ───
    {
        echo "# HwScope 能耗台账 $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "## 整机功耗（DCMI/Redfish 单点快照）"
        [ -n "$cur_w" ] && echo "  当前功耗: ${cur_w} W"
        [ -n "$min_w" ] && echo "  采样最小 : ${min_w} W"
        [ -n "$max_w" ] && echo "  采样最大 : ${max_w} W"
        [ -n "$avg_w" ] && echo "  采样平均 : ${avg_w} W"
        [ -z "$cur_w" ] && echo "  无功耗数据"
        echo ""
        echo "## 累计能耗（供电核算/机房容量规划）"
        echo "  ${ledger_note}"
        echo ""
        echo "## 能耗传感器原始行（如有）"
        grep -v "^#" "${dir}/energy_sdr.log" 2>/dev/null | sed 's/^/  /'
    } > "${dir}/power_energy.log"

    # 机器可读台账 CSV（metric|value|unit|source）
    {
        echo "# HwScope 能耗台账 $(date '+%Y-%m-%d %H:%M:%S')"
        echo "metric|value|unit|source"
        [ -n "$cur_w" ] && echo "current_power|${cur_w}|W|dcmi"
        [ -n "$min_w" ] && echo "power_min|${min_w}|W|dcmi"
        [ -n "$max_w" ] && echo "power_max|${max_w}|W|dcmi"
        [ -n "$avg_w" ] && echo "power_avg|${avg_w}|W|dcmi"
        [ -n "$en_kwh" ] && echo "cumulative_energy|${en_kwh}|kWh|${en_src}"
    } > "${dir}/energy_inventory.csv"

    write_manifest "${dir}/manifest.txt" \
        "power_energy" "power_energy.log" \
        "energy_inventory" "energy_inventory.csv" \
        "energy_sdr" "energy_sdr.log" \
        "dcmi_power" "dcmi_power.log" \
        "redfish_power" "redfish_power.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_power "$1"
fi
