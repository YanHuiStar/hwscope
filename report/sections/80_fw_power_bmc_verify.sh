#!/bin/bash
# =============================================================================
# HwScope - 变量解析：固件合规 + 能耗 + BMC 存在性 + OS-BMC 一致性
# report/sections/80_fw_power_bmc_verify.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# ─── 固件合规（15_firmware 模块输出；无数据段隐藏） ───
FW_DIR="${OUT}/firmware"
load_manifest "${FW_DIR}" fw_compliance "fw_compliance.csv"
FW_COMPLIANCE_DETAILS=""; FW_SUMMARY=""
if [ -f "${fw_compliance}" ]; then
    FW_COMPLIANCE_DETAILS=$(grep -v "^#" "${fw_compliance}" 2>/dev/null | grep -v "^$" | grep -v "^summary:" | awk -F'|' '{
        for(i=1;i<=6;i++){gsub(/^ +| +$/,"",$i)}
        if($1!="" && $1!="component") printf "%s|%s|%s|%s|%s|%s\n", $1,$2,$3,$4,$5,$6
    }')
    FW_SUMMARY=$(grep "^summary:" "${fw_compliance}" 2>/dev/null | sed 's/^summary:[[:space:]]*//')
fi

# ─── 能耗台账（16_power 模块输出；无数据段隐藏） ───
PWR_DIR="${OUT}/power"
load_manifest "${PWR_DIR}" energy_inventory "energy_inventory.csv"
load_manifest "${PWR_DIR}" power_energy "power_energy.log"
PWR_CUR=""; PWR_MIN=""; PWR_MAX=""; PWR_AVG=""; PWR_ENERGY=""; PWR_ENERGY_SRC=""
if [ -f "${energy_inventory}" ]; then
    while IFS='|' read -r _pm _pv _pu _ps; do
        case "$_pm" in
            current_power)      PWR_CUR="${_pv} ${_pu}" ;;
            power_min)          PWR_MIN="${_pv} ${_pu}" ;;
            power_max)          PWR_MAX="${_pv} ${_pu}" ;;
            power_avg)          PWR_AVG="${_pv} ${_pu}" ;;
            cumulative_energy)  PWR_ENERGY="${_pv} ${_pu}"; PWR_ENERGY_SRC="$_ps" ;;
        esac
    done < <(grep -v "^#" "${energy_inventory}" 2>/dev/null | grep -v "^metric|")
fi
PWR_NOTE=""
[ -f "${power_energy}" ] && PWR_NOTE=$(grep -m1 -E "累计能耗 [0-9]|BMC 未暴露累计能耗|无能耗/功耗数据" "${power_energy}" 2>/dev/null | sed 's/^[[:space:]]*//')

# ─── BMC 存在性检测（无 BMC 平台处理：IPMI 日志全为错误输出 = 机器无 BMC，
#      交叉校验与验收按"平台固有形态"判 N/A 不计入数据不足，避免误判 WARN） ───
BMC_PRESENT=0
if [ -f "${ipmi_fru_summary}" ] \
    && grep -qiE "Product (Name|Manufacturer|Serial)|Board Mfg|Chassis Serial" "${ipmi_fru_summary}" 2>/dev/null \
    && ! grep -qiE "Could not open|Unable to establish|No such (file|device)|Get Device ID command failed|command failed" "${ipmi_fru_summary}" 2>/dev/null; then
    BMC_PRESENT=1
fi
if [ "$BMC_PRESENT" -eq 0 ] && [ -f "${ipmi_mc}" ] && grep -qi "Firmware Revision" "${ipmi_mc}" 2>/dev/null; then
    BMC_PRESENT=1
fi
if [ "$BMC_PRESENT" -eq 0 ] && [ -f "${redfish_system}" ] && grep -qE '"BiosVersion"|"TotalSystemMemoryGiB"|"ProcessorSummary"' "${redfish_system}" 2>/dev/null; then
    BMC_PRESENT=1
fi

# ─── BMC 数据一致性校验（OS 层 vs BMC 层；零新采集，只读既有日志） ───
# 对比项：整机 SN（dmidecode vs IPMI FRU）、BIOS（dmidecode vs Redfish BiosVersion）、
# 内存容量（OS MemTotal vs Redfish TotalSystemMemoryGiB）、CPU 型号（lscpu vs Redfish ProcessorSummary）
# 判定：一致 ✓ / 不一致 ⚠️（潜在刷 SN/换件/固件不匹配风险）/ 单侧无数据（信息项，不判错）
# 注意：默认关闭（--bmc-verify 开启）——对比项与单侧数据判定仍在完善，避免旧采集数据带噪音 WARN
redfish_val() {   # Redfish JSON 字符串字段
    grep -m1 -oE "\"${1}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "${redfish_system}" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}
redfish_num() {   # Redfish JSON 数值字段
    grep -m1 -oE "\"${1}\"[[:space:]]*:[[:space:]]*[0-9.]+" "${redfish_system}" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1
}
BMC_CONSISTENCY=""
if [ "$BMC_VERIFY" -eq 1 ] && [ "$BMC_PRESENT" -eq 1 ]; then
    _os_v=""; _bmc_v=""; _res=""   # 主流程禁止 local（bash 报 local: can only be used in a function）
    consistency_verdict() {   # $1=OS侧 $2=BMC侧 $3=num(数值容差比较)
        local ov="$1" bv="$2" on bn
        if [ -z "$ov" ] || [ "$ov" = "N/A" ] || [ -z "$bv" ] || [ "$bv" = "N/A" ]; then
            if [ -z "$ov" ] || [ "$ov" = "N/A" ]; then echo "仅BMC侧数据"; else echo "仅OS侧数据"; fi
            return
        fi
        if [ "$3" = "num" ]; then
            on=$(echo "$ov" | grep -oE "[0-9.]+" | head -1); bn=$(echo "$bv" | grep -oE "[0-9.]+" | head -1)
            if [ -z "$on" ] || [ -z "$bn" ]; then echo "无法比较"; return; fi
            if awk -v a="$on" -v b="$bn" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=1)}' < /dev/null; then echo "✓ 一致"; else echo "⚠️ 不一致"; fi
        else
            if [ "$ov" = "$bv" ]; then echo "✓ 一致"; else echo "⚠️ 不一致"; fi
        fi
    }
    # 1. 整机 SN（OS dmidecode system vs BMC IPMI FRU Product Serial）
    # 注意：fru_summary 头部 # Command 注释含 grep 模式文本（"Product Serial"），必须排除注释行再匹配数据行
    _os_v="${MB_SN:-N/A}"; _bmc_v=$(grep -v "^#" "${ipmi_fru_summary}" 2>/dev/null | grep -m1 "Product Serial" | cut -d: -f2- | xargs); [ -z "$_bmc_v" ] && _bmc_v="N/A"
    _res=$(consistency_verdict "$_os_v" "$_bmc_v" ""); BMC_CONSISTENCY="${BMC_CONSISTENCY}整机SN|${_os_v}|${_bmc_v}|${_res}"$'\n'
    # 2. BIOS 版本（OS dmidecode vs Redfish BiosVersion）
    _os_v="${BIOS_VERSION:-N/A}"; _bmc_v=$(redfish_val "BiosVersion"); [ -z "$_bmc_v" ] && _bmc_v="N/A"
    _res=$(consistency_verdict "$_os_v" "$_bmc_v" ""); BMC_CONSISTENCY="${BMC_CONSISTENCY}BIOS版本|${_os_v}|${_bmc_v}|${_res}"$'\n'
    # 3. 内存容量（OS MemTotal GiB vs Redfish TotalSystemMemoryGiB，±1 GiB 容差）
    _os_v="${MEM_TOTAL:-N/A}"; _bmc_v=$(redfish_num "TotalSystemMemoryGiB"); [ -n "$_bmc_v" ] && _bmc_v="${_bmc_v} GiB"; [ -z "$_bmc_v" ] && _bmc_v="N/A"
    _res=$(consistency_verdict "$_os_v" "$_bmc_v" "num"); BMC_CONSISTENCY="${BMC_CONSISTENCY}内存容量|${_os_v}|${_bmc_v}|${_res}"$'\n'
    # 4. CPU 型号（OS lscpu vs Redfish ProcessorSummary.Model）
    _os_v="${CPU_MODEL:-N/A}"; _bmc_v=$(redfish_val "Model"); [ -z "$_bmc_v" ] && _bmc_v="N/A"
    _res=$(consistency_verdict "$_os_v" "$_bmc_v" ""); BMC_CONSISTENCY="${BMC_CONSISTENCY}CPU型号|${_os_v}|${_bmc_v}|${_res}"$'\n'
    BMC_CONSISTENCY=$(printf '%b' "$BMC_CONSISTENCY")
fi
