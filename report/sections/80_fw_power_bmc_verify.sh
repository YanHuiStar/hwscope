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
# v1.48.25：固件合规"功能启用"判定——fw_required.txt 有真实基线（判定含 合规/落后/较新）才有展示意义；
# 默认全注释基线 → 全"未知"行 → 报告固件合规段隐藏（避免每份报告带"无基线"噪音），录入基线后自动显示
FW_COMPLIANCE_ACTIVE=0
if [ -n "$FW_COMPLIANCE_DETAILS" ]; then
    if printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -qE "\|(合规|落后|较新)\|"; then
        FW_COMPLIANCE_ACTIVE=1
    fi
fi

# ─── v1.53.38：固件清单**报告端兜底**（旧采集 / 15_firmware 无产出时）───
# 背景：15_firmware 的清单与合规 csv 是**采集时**生成的；旧采集（或 v1.53.34~37 那版
#   续行符 bug 期间）firmware/ 里没有 fw_compliance.csv 行，报告固件段整段消失——
#   客户以为没采，其实 BIOS/GPU/网卡/硬盘固件数据都在别的日志里。
#   此处用**已有日志**汇总一份最小清单（BIOS / GPU VBIOS / 网卡 / 硬盘），全部标「未知（无基线）」，
#   并在说明里注明来源是报告端兜底，提示重采可拿到完整清单（含 BMC / NVSwitch / 微码）。
if [ -z "$FW_COMPLIANCE_DETAILS" ]; then
    _fw_fb=""
    # BIOS
    _fw_bios=$(grep -iE "^[[:space:]]*Version:" "${OUT}/motherboard/dmidecode_bios.log" 2>/dev/null | head -1 | cut -d: -f2- | xargs)
    [ -n "$_fw_bios" ] && _fw_fb="${_fw_fb}BIOS|主板 BIOS|${_fw_bios}|—|未知|无基线（报告端兜底汇总）"$'\n'
    # GPU VBIOS
    if [ -f "${OUT}/gpu/gpu_amd_full.log" ]; then
        for _fw_v in $(grep -oE '"VBIOS version":[[:space:]]*"[^"]*"' "${OUT}/gpu/gpu_amd_full.log" 2>/dev/null | cut -d'"' -f4 | sort -u); do
            _fw_fb="${_fw_fb}GPU_VBIOS|AMD GPU（rocm-smi）|${_fw_v}|—|未知|无基线（报告端兜底汇总）"$'\n'
        done
    fi
    # 网卡（nic_inventory.csv 固件列）
    if [ -f "${OUT}/network/nic_inventory.csv" ]; then
        _fw_nic=$(grep -v "^#" "${OUT}/network/nic_inventory.csv" 2>/dev/null | awk -F'|' '!seen[$5"|"$6]++' \
            | while IFS='|' read -r _d _b _m _s _pn _fw _r; do
                  _pn=$(printf '%s' "$_pn" | xargs); _fw=$(printf '%s' "$_fw" | xargs)
                  [ -z "$_fw" ] || [ "$_fw" = "N/A" ] && continue
                  case "$_pn" in ""|"N/A") _pn="$_d" ;; esac
                  printf '%s|%s|%s|—|未知|无基线（报告端兜底汇总）\n' "NIC" "$_pn" "$_fw"
              done)
        [ -n "$_fw_nic" ] && _fw_fb="${_fw_fb}${_fw_nic}"$'\n'
    fi
    # 硬盘
    for _fw_sf in "${OUT}/storage"/smart_*.log "${OUT}/storage"/nvme_*_health.log; do
        [ -f "$_fw_sf" ] || continue
        _fw_dev=$(basename "$_fw_sf" | sed 's/^smart_//; s/_health\.log$//; s/\.log$//')
        _fw_sv=$(grep -m1 -E "^Firmware Version|^Firmware Revision" "$_fw_sf" 2>/dev/null | cut -d: -f2- | xargs)
        [ -n "$_fw_sv" ] && _fw_fb="${_fw_fb}STORAGE|${_fw_dev}|${_fw_sv}|—|未知|无基线（报告端兜底汇总）"$'\n'
    done
    FW_COMPLIANCE_DETAILS=$(printf '%s' "$_fw_fb" | grep -v "^$")
    FW_SUMMARY="报告端兜底汇总（旧采集缺 firmware/fw_compliance.csv）：共 $(printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -c .) 项，重建采集可获得 BMC/NVSwitch/GPU 微码等完整清单"
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
# v1.52.1 修复：原 `BMC_PRESENT=0` 无条件重置 40 段（40_network_bmc.sh :312-317）基于
#   ipmi_*.log 的判定——40 判 1（ipmi 日志有有效数据）而本段三条判据（fru_summary/mc/redfish）
#   恰好都不命中时会被覆盖回 0，验收项误判"无 BMC"。改为**只升不降**：
#   保留 40 的判定结果，本段三条判据作为补充证据源（redfish/mc 更丰富）仅做 0→1 升级。
BMC_PRESENT="${BMC_PRESENT:-0}"
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
