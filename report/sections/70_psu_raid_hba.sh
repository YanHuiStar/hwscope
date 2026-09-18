#!/bin/bash
# =============================================================================
# HwScope - 变量解析：PSU + RAID + HBA
# report/sections/70_psu_raid_hba.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# ─── PSU 清单（ipmi_psu_fru.log：FRU 描述/型号/PN/SN） ───
# 状态机：desc 行出现时输出上一个 FRU（PN/SN 在 Name 之后，须延迟一行）；
# 只保留 PSU 行（PSU1_FRU/PSU4_FRU/Power Supply），过滤风扇/背板/PDB 等其他 FRU
PSU_DIR="${OUT}/psu"
load_manifest "${PSU_DIR}" ipmi_psu_fru "ipmi_psu_fru.log"
load_manifest "${BMC_DIR}" ipmi_fru_all "ipmi_fru_all.log"
# 采集端 head -80 可能截断 FRU 列表（B300 23+ FRU，PSU9 排末尾被切）：
# psu 目录日志 PSU 数 < BMC 完整日志时，fallback 用 bmc/ipmi_fru_all.log（无截断）
_fru_src="${ipmi_psu_fru}"
if [ -f "$_fru_src" ] && [ -f "${ipmi_fru_all}" ]; then
    _n_psu=$(grep -c "FRU Device Description : PSU" "$_fru_src" 2>/dev/null)
    _n_full=$(grep -c "FRU Device Description : PSU" "${ipmi_fru_all}" 2>/dev/null)
    [ "${_n_full:-0}" -gt "${_n_psu:-0}" ] && _fru_src="${ipmi_fru_all}"
fi
PSU_DETAILS=""
PSU_PLATFORM_NOTE=""
# 电源冗余状态（PS_Redundant：0x01/ok=冗余满足，0x00=冗余失效；无数据=N/A）
PSU_REDUNDANT="N/A"
load_manifest "${BMC_DIR}" ipmi_sdr "ipmi_sdr.log"
if [ -f "${ipmi_sdr}" ]; then
    _red_line=$(grep -iE "^PS_Redundant|PSU.*Redundant" "${ipmi_sdr}" 2>/dev/null | head -1)
    if [ -n "$_red_line" ]; then
        case "$_red_line" in
            *"| 0x01"*|*"| 0x1"*|*ok*) PSU_REDUNDANT="冗余满足（N+N）" ;;
            *) PSU_REDUNDANT="⚠️ 冗余失效" ;;
        esac
    fi
fi
# 平台无 PSU 冗余传感器判定（v1.43.9）：SDR 有 PSU 供电传感器但无冗余等级 → 平台固有不计数（验收用）
PSU_SENSOR_PRESENT=0
if [ -f "${ipmi_sdr}" ] && grep -qiE "PSU|Power|Pwr" "${ipmi_sdr}" 2>/dev/null; then
    PSU_SENSOR_PRESENT=1
fi
# dmidecode PSU 数量 fallback（IPMI 无 PSU FRU 时，验收冗余判定兜底用）
PSU_COUNT_DMI=0
load_manifest "${PSU_DIR}" dmidecode_psu "dmidecode_psu.log"
if [ -f "${dmidecode_psu}" ]; then
    PSU_COUNT_DMI=$(grep -ci "System Power Supply" "${dmidecode_psu}" 2>/dev/null || echo 0)
fi
if [ -f "$_fru_src" ]; then
    pdesc=""; pmodel=""; ppn=""; psn=""; pending=""
    while IFS= read -r pline; do
        case "$pline" in
            *"FRU Device Description"*)
                [ -n "$pending" ] && PSU_DETAILS="${PSU_DETAILS}${pending}${ppn:-N/A}|${psn:-N/A}"$'\n'
                pdesc=$(echo "$pline" | cut -d: -f2- | xargs)
                # v1.48.24：PSU_FRU_N (ID x) → PSU N 行首规范化（显示与 pin 功耗映射对齐）
                if echo "$pdesc" | grep -qE "^PSU_FRU_[0-9]+"; then
                    pdesc=$(echo "$pdesc" | sed -E 's/^PSU_FRU_([0-9]+).*/PSU\1/')
                fi
                pmodel=""; ppn=""; psn=""; pending="" ;;
            *"Product Name"*)          pmodel=$(echo "$pline" | cut -d: -f2- | xargs); [ -n "$pdesc" ] && pending="${pdesc}|${pmodel}|" ;;
            *"Product Part Number"*)   ppn=$(echo "$pline" | cut -d: -f2- | xargs) ;;
            *"Product Serial"*)        psn=$(echo "$pline" | cut -d: -f2- | xargs) ;;
        esac
    done < <(grep -v "^#" "$_fru_src" 2>/dev/null)
    [ -n "$pending" ] && PSU_DETAILS="${PSU_DETAILS}${pending}${ppn:-N/A}|${psn:-N/A}"$'\n'
    # 只保留 PSU 行（PSU 描述含 PSU 编号或 Power Supply）
    # v1.48.24：加 PSU_FRU[0-9] 匹配——"PSU_FRU_1"（下划线）此前被 PSU[0-9] 滤掉 → 8 电源显示 0（真机 G7768 M6 实测）
    PSU_DETAILS=$(echo "$PSU_DETAILS" | grep -iE "PSU[0-9]|PSU_FRU[0-9]|Power Supply")
    # v1.48.30：FRU 有 PSU 条目时功耗列也补全（原功耗补全仅在 76 行 FRU 空占位路径跑——
    # FRU 路径（PSU_FRU_1 描述）功耗恒 N/A；数据源同为 ipmi_psu_sensors.log 的 PSU_PIN_0N/PS*_Pin）
    psu_power_csv="${PSU_DIR}/ipmi_psu_sensors.log"
    psu_power_csv2="${BMC_DIR}/ipmi_sensors_power.log"
    load_manifest "${PSU_DIR}" ipmi_psu_sensors "ipmi_psu_sensors.log"
    load_manifest "${BMC_DIR}" ipmi_sensors_power "ipmi_sensors_power.log"
    [ -f "${ipmi_psu_sensors}" ] && psu_power_csv="${ipmi_psu_sensors}"
    [ -f "${ipmi_sensors_power}" ] && psu_power_csv2="${ipmi_sensors_power}"
    _pin_src=""
    [ -f "$psu_power_csv" ] && grep -qiE "ps[0-9]+_pin|psu[0-9]+ power in|psu_pin_[0-9]+" "$psu_power_csv" 2>/dev/null && _pin_src="$psu_power_csv"
    [ -z "$_pin_src" ] && [ -f "$psu_power_csv2" ] && grep -qiE "ps[0-9]+_pin|psu_pin_[0-9]+" "$psu_power_csv2" 2>/dev/null && _pin_src="$psu_power_csv2"
    if [ -n "$_pin_src" ] && [ -n "$PSU_DETAILS" ]; then
        _pin_map=$(grep -v "^#" "$_pin_src" 2>/dev/null | awk -F'|' '$1 ~ /^PS[0-9]+_Pin|^PSU[0-9]+ Power In|^PSU_PIN_[0-9]+/ { n=$1; gsub(/[^0-9]/, "", n); sub(/^0+/, "", n); v=$2; gsub(/ /, "", v); printf "%s:%sW ", n, v }')
        if [ -n "$_pin_map" ]; then
            PSU_DETAILS=$(while IFS= read -r _pline; do
                [ -z "$_pline" ] && continue
                # 编号：PSU_FRU_1 / PSU1 / PSU01 → 1（grep -oE 提取 + 去前导零）
                _pnum=$(echo "$_pline" | cut -d'|' -f1 | grep -oE '[0-9]+' | head -1 | sed 's/^0*//')
                _pval=$(echo "$_pin_map" | tr ' ' '\n' | grep -E "^${_pnum}:" | cut -d: -f2)
                if [ -n "$_pval" ]; then
                    # 行补到 6 字段（额定列 N/A + 当前功耗=val）；已 6 字段则只覆盖 $6
                    echo "$_pline" | awk -v val="$_pval" -F'|' 'BEGIN{OFS="|"} { if (NF < 6) $5="N/A"; $6=val; print }'
                else
                    echo "$_pline"
                fi
            done <<< "$PSU_DETAILS")
        fi
    fi
    # 辅助日志走 manifest 解耦（模块 10 已声明 ipmi_psu_sensors/dmidecode_psu；BMC 模块声明 ipmi_sensors_power）
    psu_power_csv="${PSU_DIR}/ipmi_psu_sensors.log"
    psu_power_csv2="${BMC_DIR}/ipmi_sensors_power.log"   # 含 PS*_Pin（Inventec 等平台，psu 日志可能只有 Temp）
    load_manifest "${PSU_DIR}" ipmi_psu_sensors "ipmi_psu_sensors.log"
    load_manifest "${PSU_DIR}" dmidecode_psu "dmidecode_psu.log"
    load_manifest "${BMC_DIR}" ipmi_sensors_power "ipmi_sensors_power.log"
    [ -f "${ipmi_psu_sensors}" ] && psu_power_csv="${ipmi_psu_sensors}"
    [ -f "${ipmi_sensors_power}" ] && psu_power_csv2="${ipmi_sensors_power}"
    # 回退：部分平台（如 Inventec）FRU 不暴露 PSU 条目，但传感器有 PSU*_Temp / PS*_Pin / PSU* Power In —— 用传感器生成占位行
    if [ -z "$PSU_DETAILS" ]; then
        # 编号识别源：psu sensors 的 PSU*_Temp（优先）→ PSU* Power In → bmc power 的 PS*_Pin
        _temp_src=""
        [ -f "$psu_power_csv" ] && grep -qiE "psu[0-9]+_temp" "$psu_power_csv" 2>/dev/null && _temp_src="$psu_power_csv"
        [ -z "$_temp_src" ] && [ -f "$psu_power_csv" ] && grep -qiE "psu[0-9]+ power in|psu_pin_[0-9]+" "$psu_power_csv" 2>/dev/null && _temp_src="$psu_power_csv"
        [ -z "$_temp_src" ] && [ -f "$psu_power_csv2" ] && grep -qiE "ps[0-9]+_pin|psu_pin_[0-9]+" "$psu_power_csv2" 2>/dev/null && _temp_src="$psu_power_csv2"
        # 功耗补全源：psu sensors 的 PS*_Pin / PSU* Power In → bmc power 的 PS*_Pin（v1.48.24 加 PSU_PIN_0N 下划线式）
        _pin_src=""
        [ -f "$psu_power_csv" ] && grep -qiE "ps[0-9]+_pin|psu[0-9]+ power in|psu_pin_[0-9]+" "$psu_power_csv" 2>/dev/null && _pin_src="$psu_power_csv"
        [ -z "$_pin_src" ] && [ -f "$psu_power_csv2" ] && grep -qiE "ps[0-9]+_pin|psu_pin_[0-9]+" "$psu_power_csv2" 2>/dev/null && _pin_src="$psu_power_csv2"
        if [ -n "$_temp_src" ]; then
            PSU_DETAILS=$(grep -v "^#" "$_temp_src" 2>/dev/null | awk -F'|' '
                tolower($1) ~ /psu[0-9]+_temp|psu_pin_[0-9]+|ps[0-9]+_pin|psu[0-9]+ power in/ {
                    num=$1; gsub(/[^0-9]/, "", num); sub(/^0+/, "", num)
                    if(num!="" && !seen[num]++) printf "PSU%s|N/A|N/A|N/A|N/A|N/A\n", num
                }' )
            # 功耗补全（PS*_Pin / PSU* Power In → PSU 行当前功耗）：先收集 pin 映射，再逐行追加
            if [ -n "$_pin_src" ] && [ -n "$PSU_DETAILS" ]; then
                # 构建 "编号:功耗" 列表（如 "6:427W 7:448W"）
                _pin_map=$(grep -v "^#" "$_pin_src" 2>/dev/null | awk -F'|' '
                    $1 ~ /^PS[0-9]+_Pin|^PSU[0-9]+ Power In|^PSU_PIN_[0-9]+/ { n=$1; gsub(/[^0-9]/, "", n); sub(/^0+/, "", n); v=$2; gsub(/ /, "", v); printf "%s:%sW ", n, v }')
                # 占位行逐行替换功耗（PSU6 → 6 → 查 _pin_map）
                if [ -n "$_pin_map" ]; then
                    PSU_DETAILS=$(while IFS= read -r _pline; do
                        [ -z "$_pline" ] && continue
                        _pnum=$(echo "$_pline" | cut -d'|' -f1 | sed 's/^PSU//; s/^0*//')
                        _pval=$(echo "$_pin_map" | tr ' ' '\n' | grep -E "^${_pnum}:" | cut -d: -f2)
                        if [ -n "$_pval" ]; then
                            echo "$_pline" | awk -v val="$_pval" -F'|' 'BEGIN{OFS="|"} {$6=val; print}'
                        else
                            echo "$_pline"
                        fi
                    done <<< "$PSU_DETAILS")
                fi
            fi
        fi
        # dmidecode Type 39 独立生成源（v1.44.0）：Supermicro 等平台 FRU 无 PSU 条目、传感器仅离散
        # PS<N> Status（无 PSU*_Temp/PS*_Pin 模拟量）——占位行与传感器占位均失败时，SMBIOS Type 39
        # 是唯一 PSU 明细来源（Location/型号/厂商/SN/PN/容量/状态全有），生成占位行交由下方补全逻辑填字段
        if [ -z "$PSU_DETAILS" ] && [ -f "${dmidecode_psu}" ] && grep -q "System Power Supply" "${dmidecode_psu}" 2>/dev/null; then
            PSU_DETAILS=$(grep -v "^#" "${dmidecode_psu}" 2>/dev/null | awk '
                /System Power Supply/ { idx++ }
                /Location:/ {
                    if (n != "") print "PSU" n "|N/A|N/A|N/A|N/A|N/A"
                    split($NF, a, "PSU")
                    # v1.48.54：新平台 Location 为 "Not Specified"（无 PSU 编号）——回退段序号 idx
                    n = (a[2] != "" ? a[2] : idx)
                }
                END { if (n != "") print "PSU" n "|N/A|N/A|N/A|N/A|N/A" }
            ')
        fi
        # dmidecode type39 补型号/SN/PN/容量（按 Location 匹配槽位；无 FRU 平台用 SMBIOS 补齐）
        if [ -n "$PSU_DETAILS" ] && [ -f "${dmidecode_psu}" ]; then
            # 构建 "Location→型号|厂商|SN|PN|容量|Revision" 映射（dmidecode type39 每个 PSU 一段）
            while IFS= read -r _dl; do
                case "$_dl" in
                    *"System Power Supply"*) _didx=$(( ${_didx:-0} + 1 )) ;;
                    *Location:*) _dloc=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *Name:*)     _dname=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *Manufacturer:*) _dmfr=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *"Serial Number:"*) _dsn=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *"Model Part Number:"*) _dpn=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *"Max Power Capacity:"*) _dcap=$(echo "$_dl" | cut -d: -f2- | xargs | tr -d ' ') ;;
                    *Revision:*) _drev=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *Handle*)
                        # 段落结束（下一个 Handle 行）——此时 Location/Name/PN/容量/Revision 已读全
                        if [ -n "$_dloc" ] && [ -n "$_dname" ]; then
                            # v1.48.54：Location 含 PSU<num> 用其编号；"Not Specified" 等新平台回退段序号
                            case "$_dloc" in
                                PSU*) _dnum=$(echo "$_dloc" | sed 's/^PSU//; s/^0*//') ;;
                                *)    _dnum="${_didx:-1}" ;;
                            esac
                            # v1.48.94：识别「BIOS 未填充 FRU」的记录——Name/厂商/SN/PN 全为
                            #   "Not Specified" 时，说明 BIOS 这次没读到该颗 PSU 的 FRU。
                            #   实证：Gigabyte B200 NVL8（B200-sample-a）12 条 Type 39 中恰有 1 条字段全空，
                            #   而同机 IPMI 侧 PS1..PS12_Status 全为 ok，且其余 4 台同 BIOS/BMC 版本的机器无此空记录
                            #   → 属该颗 PSU 的 FRU 读取失败（BIOS 经 PMBus 读，BMC 另走一路）。
                            #   原实现直接按「厂商+Name+Rev+Revision」拼接，会渲染成
                            #   "Not Specified Not Specified Rev Not Specified"，看着像采集坏了。
                            #   注意容量不改：Max Power Capacity 是真实字段（该空记录也带 3000 W），不能丢。
                            _dempty=0
                            case "$_dname" in
                                "Not Specified"|"")
                                    case "$_dmfr" in
                                        "Not Specified"|"")
                                            case "$_dsn" in
                                                "Not Specified"|"") _dempty=1 ;;
                                            esac ;;
                                    esac ;;
                            esac
                            if [ "$_dempty" -eq 1 ]; then
                                _dfull="（FRU 未读到——BIOS 未填充该条记录，供电状态见下方 IPMI 传感器）"
                                _dpn="—"; _dsn="—"
                            else
                                # 型号列合并厂商+Revision（如 "DELTA DPS-3000AB-25 C Rev 01F"），PN/SN/容量独立列
                                _dfull="${_dmfr:+${_dmfr} }${_dname}${_drev:+ Rev ${_drev}}"
                            fi
                            PSU_DETAILS=$(echo "$PSU_DETAILS" | awk -v num="$_dnum" -v name="$_dfull" -v pn="${_dpn:-N/A}" -v sn="${_dsn:-N/A}" -v cap="${_dcap:-N/A}" -F'|' 'BEGIN{OFS="|"} $1=="PSU"num {$2=name; $3=pn; $4=sn; $5=cap} {print}')
                            [ "$_dempty" -eq 1 ] && PSU_EMPTY_FRU=$(( ${PSU_EMPTY_FRU:-0} + 1 ))
                        fi
                        _dloc=""; _dname=""; _dmfr=""; _dsn=""; _dpn=""; _dcap=""; _drev=""
                        ;;
                esac
            done < <(grep -v "^#" "${dmidecode_psu}" 2>/dev/null)
            # 最后一段（文件尾无空行）
            if [ -n "$_dloc" ] && [ -n "$_dname" ]; then
                case "$_dloc" in
                    PSU*) _dnum=$(echo "$_dloc" | sed 's/^PSU//; s/^0*//') ;;
                    *)    _dnum="${_didx:-1}" ;;
                esac
                # v1.48.94：与 Handle 分支同一判据（见上）——最后一条记录若也是空字段，同样友好渲染
                _dempty=0
                case "$_dname" in
                    "Not Specified"|"")
                        case "$_dmfr" in
                            "Not Specified"|"")
                                case "$_dsn" in
                                    "Not Specified"|"") _dempty=1 ;;
                                esac ;;
                        esac ;;
                esac
                if [ "$_dempty" -eq 1 ]; then
                    _dfull="（FRU 未读到——BIOS 未填充该条记录，供电状态见下方 IPMI 传感器）"
                    _dpn="—"; _dsn="—"
                else
                    _dfull="${_dmfr:+${_dmfr} }${_dname}${_drev:+ Rev ${_drev}}"
                fi
                PSU_DETAILS=$(echo "$PSU_DETAILS" | awk -v num="$_dnum" -v name="$_dfull" -v pn="${_dpn:-N/A}" -v sn="${_dsn:-N/A}" -v cap="${_dcap:-N/A}" -F'|' 'BEGIN{OFS="|"} $1=="PSU"num {$2=name; $3=pn; $4=sn; $5=cap} {print}')
                [ "$_dempty" -eq 1 ] && PSU_EMPTY_FRU=$(( ${PSU_EMPTY_FRU:-0} + 1 ))
            fi
        fi
        # 平台限制标注：FRU 无 PSU 条目时说明（避免客户误以为漏采）——按明细行来源区分文案（v1.44.0）
        if [ -n "$PSU_DETAILS" ]; then
            if [ -n "$_temp_src" ]; then
                PSU_PLATFORM_NOTE="平台未暴露单电源 FRU（传感器+SMBIOS 确认存在与功耗）"
            else
                # PS<N> Status 传感器佐证（0x1/ok = 在位正常）：sdr list 带 ok 状态列，有则注明增强可信度
                _ps_ok=$(grep -v "^#" "${PSU_DIR}/ipmi_sdr_psu.log" 2>/dev/null | awk -F'|' '$1 ~ /^PS[0-9]+ Status/ && $3 ~ /ok/ {n++} END{print n+0}')
                [ "${_ps_ok:-0}" -gt 0 ] 2>/dev/null || _ps_ok=$(grep -v "^#" "${PSU_DIR}/ipmi_psu_sensors.log" 2>/dev/null | awk -F'|' '$1 ~ /^PS[0-9]+ Status/ && $2 ~ /^0x1$/ {n++} END{print n+0}')
                PSU_PLATFORM_NOTE="平台未暴露单电源 FRU 与单 PSU 功率传感器（SMBIOS Type 39 确认 ${PSU_COUNT_DMI} 颗在位${PSU_EMPTY_FRU:+，其中 ${PSU_EMPTY_FRU} 条记录的 FRU 字段未填充（BIOS 未读到该颗 PSU 的型号/SN，供电状态不受影响）}，型号/SN/额定容量为 dmidecode 数据${_ps_ok:+，PS 状态传感器均 ok})"
            fi
        fi
    fi
    # 整机功耗（Total_Power 行首精确匹配，避免误取 CPU_Total_Power/MEM_Total_Power 等分段功耗）
    # 独立展示（不放 PSU 表内：语义是整机级而非单电源，且避免 N/A 占位列突兀）
    PSU_EXTRA=""
    total_pwr=$(grep -v "^#" "${PSU_DIR}/ipmi_psu_power.log" 2>/dev/null | awk -F'|' 'tolower($1) ~ /^total_power/{gsub(/ /,"",$2); print $2"W"; exit}')
    # v1.48.24：分口径标注——TOTAL_POWER=PSU 输入总功率（含 GPU），DCMI=主板侧（不含 GPU）；此前都叫"整机功耗"易误读
    [ -n "$total_pwr" ] && PSU_EXTRA="整机功耗（PSU 输入，含 GPU）: ${total_pwr}"
    # DCMI 功耗统计（dcmi power reading：Instantaneous/Minimum/Maximum/Average，标准 IPMI 功耗统计）
    # v1.48.88：去掉「主板侧，不含 GPU」这个未经证实的口径标注——
    #   DCMI 规范的 power reading 定义是**平台总功耗**，但各厂 BMC 实现不一（有的只上报主板域）。
    #   报告不该替客户断言口径，如实写「DCMI 平台功耗读数」并给出读数字段来源即可。
    PSU_DCMI=""
    if [ -f "${PSU_DIR}/ipmi_dcmi_power.log" ]; then
        dcmi_cur=$(grep -iE "Instantaneous power reading|Current Power|Current Reading" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1)
        dcmi_min=$(grep -iE "Minimum" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1)
        dcmi_max=$(grep -iE "Maximum" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1)
        dcmi_avg=$(grep -iE "Average power reading" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1)
        if [ -n "$dcmi_cur" ]; then
            PSU_DCMI="DCMI 平台功耗读数（ipmitool dcmi power reading）: 当前 ${dcmi_cur}W${dcmi_min:+ · 最小 ${dcmi_min}W}${dcmi_max:+ · 最大 ${dcmi_max}W}${dcmi_avg:+ · 平均 ${dcmi_avg}W}"
        fi
    fi
    # ─── CPU 功耗（RAPL 两次采样，v1.48.88）——独立信源，可与 DCMI 交叉验证 ───
    # 为什么值得单列：DCMI 给的是平台总功耗读数，厂际口径不一（有的只报主板域）；
    #   RAPL 是 CPU 自己的能量计数器，两个数对不上时就说明 DCMI 口径有问题——
    #   这正是我们之前**不该**替客户断言「DCMI 含/不含 GPU」的原因。
    PSU_CPU_RAPL=""
    if [ -f "${PSU_DIR}/rapl_power.log" ]; then
        _rapl_out=$(grep -vE "^#|^[[:space:]]*$" "${PSU_DIR}/rapl_power.log" 2>/dev/null | grep -E "W[[:space:]]*\(" | sed 's/^[[:space:]]*//' | head -4)
        _rapl_pkg=$(printf '%s\n' "$_rapl_out" | grep -iE "^package" | paste -sd' · ' -)
        _rapl_other=$(printf '%s\n' "$_rapl_out" | grep -viE "^package" | head -3 | awk -F: '{print $1}' | paste -sd'/' -)
        if [ -n "$_rapl_pkg" ]; then
            PSU_CPU_RAPL="CPU 功耗（RAPL）: ${_rapl_pkg}"
            [ -n "$_rapl_other" ] && PSU_CPU_RAPL="${PSU_CPU_RAPL}（另有 ${_rapl_other} 域）"
        elif [ -n "$_rapl_out" ]; then
            PSU_CPU_RAPL="CPU 功耗（RAPL）: $(printf '%s\n' "$_rapl_out" | paste -sd' · ' -)"
        fi
    fi
    # PSU 尾注文本（变量拼接，避免 $( ) 命令替换剥离尾换行导致排版空行堆积）
    PSU_NOTE_TXT=""
    [ "$PSU_REDUNDANT" != "N/A" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  电源冗余: ${PSU_REDUNDANT}"$'\n'
    [ -n "$PSU_EXTRA" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ${PSU_EXTRA}"$'\n'
    [ -n "$PSU_DCMI" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ${PSU_DCMI}"$'\n'
    [ -n "$PSU_CPU_RAPL" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ${PSU_CPU_RAPL}"$'\n'
    [ -n "$PSU_PLATFORM_NOTE" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ⚠️ ${PSU_PLATFORM_NOTE}"$'\n'
    # 每只 PSU 当前输入功率（Pwr_PSU<N>_In 或 PS<N>_Pin，| W |），按编号匹配追加
    if [ -f "$psu_power_csv" ] && [ -n "$PSU_DETAILS" ] && grep -qE "Pwr_PSU[0-9]|PS[0-9]_Pin" "$psu_power_csv" 2>/dev/null; then
        # 一次性构建 编号→功率 映射，再一次性追加（避免逐行 echo|awk 嵌套性能灾难）
        PSU_DETAILS=$(awk -v psu_detail="$PSU_DETAILS" '
            BEGIN { FS="|"; OFS="|" }
            /Pwr_PSU[0-9]+_In|PS[0-9]+_Pin/ {
                num=$1; sub(/.*Pwr_PSU/, "", num); sub(/.*PS/, "", num); sub(/[^0-9].*/, "", num)
                val=$2; gsub(/ /, "", val)
                power[num]=val "W"
            }
            END {
                n=split(psu_detail, lines, "\n")
                for(i=1; i<=n; i++) {
                    line=lines[i]
                    if(line=="") continue
                    split(line, f, "|")
                    desc=f[1]
                    pnum=""
                    if(desc ~ /PSU[0-9]+/) { pnum=desc; sub(/.*PSU/, "", pnum); sub(/[^0-9].*/, "", pnum) }
                    # 额定容量：从型号提取 3-4 位容量数字（锚定边界，防 "PS-2800" 被 /800/ 误配为 800W；3000W 也覆盖）
                    model=f[2]
                    cap="N/A"
                    if (match(model, /(^|[^0-9])[0-9]{3,4}([^0-9]|$)/)) {
                        _capstr = substr(model, RSTART, RLENGTH)
                        gsub(/[^0-9]/, "", _capstr)
                        cap = _capstr "W"
                    }
                    cur_power="N/A"
                    if(pnum!="" && (pnum in power)) cur_power=power[pnum]
                    # 恒 6 字段重建（desc|model|pn|sn|cap|power）——直接追加会把行撑到 8 字段，
                    # 下游 6 变量 read 时 ppower 被挤成 "N/A|cap|power" 含 | 破坏表格（v1.33.3 修复）
                    print desc "|" f[2] "|" f[3] "|" f[4] "|" cap "|" cur_power
                }
            }' "$psu_power_csv")
    fi
fi

# ─── RAID 控制器（storcli_controllers.log：有卡才显示，无卡段隐藏） ───
RAID_DIR="${OUT}/raid"
RAID_DETAILS=""
load_manifest "${RAID_DIR}" storcli_controllers "storcli_controllers.log"
if [ -f "${storcli_controllers}" ] && grep -q "Controller = " "${storcli_controllers}" 2>/dev/null; then
    # 每个控制器：从 ctrl<N>_summary.log 提取 Model/SN/Firmware；虚拟盘数从 ctrl<N>_info.log 统计
    raidx=0
    while [ -f "${RAID_DIR}/ctrl${raidx}_summary.log" ]; do
        rmodel=$(grep -m1 -iE "^Model|Product Name" "${RAID_DIR}/ctrl${raidx}_summary.log" 2>/dev/null | awk -F'= ' '{print $2}' | xargs)
        rsn=$(grep -m1 -iE "Serial Number" "${RAID_DIR}/ctrl${raidx}_summary.log" 2>/dev/null | awk -F'= ' '{print $2}' | xargs)
        rfw=$(grep -m1 -iE "Firmware" "${RAID_DIR}/ctrl${raidx}_summary.log" 2>/dev/null | awk -F'= ' '{print $2}' | xargs)
        rvd=$(grep -cE "Virtual Drive: [0-9]+" "${RAID_DIR}/ctrl${raidx}_vd_all.log" 2>/dev/null)
        [ -z "$rvd" ] && rvd=0
        # 虚拟盘明细（编号/RAID级别/容量/状态）——数据安全核心，客户必看
        rvd_list=""
        if [ -f "${RAID_DIR}/ctrl${raidx}_vd_all.log" ]; then
            rvd_list=$(awk '
                /Virtual Drive: [0-9]+/ {
                    vd=$3; sub(/\(.*/, "", vd)
                    level=""; size=""; state=""
                    getline
                    while ($0 !~ /Virtual Drive:/ && $0 != "") {
                        if ($1=="RAID" && $2=="Level") { level=$4; sub(/,.*/, "", level); sub(/^Primary-/, "RAID", level) }
                        if ($1=="Size") size=$3" "$4
                        if ($1=="State") state=$3
                        if (!getline) break
                    }
                    printf "VD%s:%s/%s/%s;", vd, level, size, state
                }
            ' "${RAID_DIR}/ctrl${raidx}_vd_all.log" 2>/dev/null)
        fi
        RAID_DETAILS="${RAID_DETAILS}c${raidx}|${rmodel:-N/A}|${rsn:-N/A}|${rfw:-N/A}|${rvd}|${rvd_list}"$'\n'
        raidx=$((raidx + 1))
    done
fi

# ─── RAID 缓存电池（BBU/超级电容）与写缓存策略（v1.48.90）───
# 为什么必需：RAID 卡在掉电时能否保住缓存数据全靠 BBU/超级电容。**「Write Back 写缓存 +
#   电池失效」是真实的数据丢失风险**——卡会继续宣称缓存开启，但掉电时数据直接丢。
#   验收时这一对必须一起看：只报 WriteBack 不报电池状态，等于漏掉了风险。
# 数据来源：storcli /cN/bbu show all（电池详情）+ /cN/cv show all（虚盘缓存策略）。
RAID_BBU_SUMMARY=""; RAID_BBU_WARN=0
_bbu_parts=""
for _bf in "${RAID_DIR}"/storcli_c*_bbu.log; do
    [ -f "$_bf" ] || continue
    _bci=$(basename "$_bf" | sed -E 's/^storcli_c([0-9]+)_bbu\.log$/\1/')
    # 电池状态字段名随 storcli 版本/型号变化：State / Battery State / Health
    _bstate=$(grep -iE "^[[:space:]]*(State|Battery State|Health)[[:space:]]*[:=]" "$_bf" 2>/dev/null \
        | head -1 | sed -E 's/.*[:=][[:space:]]*//' | sed 's/[[:space:]]*$//')
    # 部分型号走表格输出（EID State ... / 0 Optimal ...）
    [ -z "$_bstate" ] && _bstate=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+(Optimal|Good|Failed|Degraded|Charging|Missing)/ {print $2; exit}' "$_bf" 2>/dev/null)
    # 无 BBU 的卡：storcli 会回 "Controller has no BBU / not present"
    _nobbu=$(grep -ciE "no BBU|BBU.*not present|not equipped" "$_bf" 2>/dev/null)
    if [ "${_nobbu:-0}" -gt 0 ]; then
        _bbu_parts="${_bbu_parts}c${_bci}:无BBU "
    elif [ -n "$_bstate" ]; then
        _bbu_parts="${_bbu_parts}c${_bci}:${_bstate} "
        case "$_bstate" in
            *Optimal*|*optimal*|*Good*|*good*|*OK*|*ok*) ;;
            *) RAID_BBU_WARN=1 ;;
        esac
    fi
done
[ -n "$_bbu_parts" ] && RAID_BBU_SUMMARY="缓存电池: $(echo "$_bbu_parts" | sed 's/ *$//')"

# 虚盘写缓存策略（WriteBack 且电池异常 = 数据丢失风险）
RAID_CACHE_POLICY=""
for _cf in "${RAID_DIR}"/storcli_c*_cv.log; do
    [ -f "$_cf" ] || continue
    _cp=$(grep -iE "Current Cache Policy|Cache Policy" "$_cf" 2>/dev/null | head -2 \
        | sed -E 's/.*[:=][[:space:]]*//' | sed 's/[[:space:]]*$//' | paste -sd' / ' -)
    [ -n "$_cp" ] && RAID_CACHE_POLICY="${RAID_CACHE_POLICY}${_cp}; "
done
[ -n "$RAID_CACHE_POLICY" ] && RAID_CACHE_POLICY=$(echo "$RAID_CACHE_POLICY" | sed 's/; *$//')
# RAID 硬件存在性（lspci 仅匹配 RAID bus controller 类目——SAS controller/Serial Attached SCSI 是
# HBA 直通卡类目，归 HBA_PCI_PRESENT；排除 Intel VMD 虚拟 RAID 与 PCIe Switch 管理端点——
# PEX89/97 交换机管理端点被 lspci 分类为 Serial Attached SCSI controller，非 RAID/HBA 卡）
RAID_PCI_PRESENT=$(grep -iE "RAID bus controller" "${lspci_all}" 2>/dev/null | grep -viE "Intel.*VMD|Volume Management|PCIe Switch management endpoint|PEX89|PEX97" | head -1)
RAID_VMD_PRESENT=$(grep -icE "RAID bus controller.*Intel.*VMD|Volume Management Device NVMe RAID" "${lspci_all}" 2>/dev/null)
# Linux 软件 RAID（mdadm /proc/mdstat：md 设备列表，如 "md0 : active raid1 sda1 sdb1"）
MD_RAID_LIST=""
if [ -f "${RAID_DIR}/mdstat.log" ]; then
    MD_RAID_LIST=$(grep -E "^md[0-9]+ : active" "${RAID_DIR}/mdstat.log" 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
fi

# ─── HBA 直通卡（sas3_hba*.log / sas2_hba*.log：有卡才显示，无卡段隐藏） ───
# sas3ircu display / sas2ircu display 输出含 Controller Type / Firmware / Status
HBA_DETAILS=""
for hf in "${RAID_DIR}"/sas3_hba*.log "${RAID_DIR}"/sas2_hba*.log; do
    [ -f "$hf" ] || continue
    hname=$(basename "$hf" .log)
    htype=$(grep -m1 -iE "Controller Type|SAS.*Adapter|Product Name" "$hf" 2>/dev/null | awk -F': ' '{print $2}' | xargs)
    hfw=$(grep -m1 -iE "Firmware Version|Firmware" "$hf" 2>/dev/null | awk -F': ' '{print $2}' | xargs)
    hsn=$(grep -m1 -iE "Serial Number|SAS Address" "$hf" 2>/dev/null | awk -F': ' '{print $2}' | xargs)
    hstat=$(grep -m1 -iE "^Status" "$hf" 2>/dev/null | awk -F': ' '{print $2}' | xargs)
    # SAS 地址（sas3ircu display 的 SAS Address，独立于 SN）+ 端口数（SAS Address 行数）
    hsas=$(grep -m1 -iE "SAS Address" "$hf" 2>/dev/null | awk -F': ' '{print $2}' | xargs)
    hports=$(grep -ciE "SAS Address" "$hf" 2>/dev/null)
    HBA_DETAILS="${HBA_DETAILS}${hname}|${htype:-N/A}|${hfw:-N/A}|${hsn:-N/A}|${hstat:-N/A}|${hsas:-N/A}|${hports:-0}"$'\n'
done
# HBA 硬件存在性（lspci SAS controller，排除 MegaRAID 已计入 RAID_PCI_PRESENT、Intel VMD 与 PCIe Switch 管理端点）
HBA_PCI_PRESENT=$(grep -iE "SAS controller|Serial Attached SCSI|SAS3008|SAS3108|SAS3508" "${lspci_all}" 2>/dev/null | grep -viE "MegaRAID|VMD|Volume Management|PCIe Switch management endpoint|PEX89|PEX97" | head -1)
