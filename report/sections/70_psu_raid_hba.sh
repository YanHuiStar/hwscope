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
if [ -f "$_fru_src" ]; then
    pdesc=""; pmodel=""; ppn=""; psn=""; pending=""
    while IFS= read -r pline; do
        case "$pline" in
            *"FRU Device Description"*)
                [ -n "$pending" ] && PSU_DETAILS="${PSU_DETAILS}${pending}${ppn:-N/A}|${psn:-N/A}"$'\n'
                pdesc=$(echo "$pline" | cut -d: -f2- | xargs); pmodel=""; ppn=""; psn=""; pending="" ;;
            *"Product Name"*)          pmodel=$(echo "$pline" | cut -d: -f2- | xargs); [ -n "$pdesc" ] && pending="${pdesc}|${pmodel}|" ;;
            *"Product Part Number"*)   ppn=$(echo "$pline" | cut -d: -f2- | xargs) ;;
            *"Product Serial"*)        psn=$(echo "$pline" | cut -d: -f2- | xargs) ;;
        esac
    done < <(grep -v "^#" "$_fru_src" 2>/dev/null)
    [ -n "$pending" ] && PSU_DETAILS="${PSU_DETAILS}${pending}${ppn:-N/A}|${psn:-N/A}"$'\n'
    # 只保留 PSU 行（PSU 描述含 PSU 编号或 Power Supply）
    PSU_DETAILS=$(echo "$PSU_DETAILS" | grep -iE "PSU[0-9]|Power Supply")
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
        [ -z "$_temp_src" ] && [ -f "$psu_power_csv" ] && grep -qiE "psu[0-9]+ power in" "$psu_power_csv" 2>/dev/null && _temp_src="$psu_power_csv"
        [ -z "$_temp_src" ] && [ -f "$psu_power_csv2" ] && grep -qiE "ps[0-9]+_pin" "$psu_power_csv2" 2>/dev/null && _temp_src="$psu_power_csv2"
        # 功耗补全源：psu sensors 的 PS*_Pin / PSU* Power In → bmc power 的 PS*_Pin
        _pin_src=""
        [ -f "$psu_power_csv" ] && grep -qiE "ps[0-9]+_pin|psu[0-9]+ power in" "$psu_power_csv" 2>/dev/null && _pin_src="$psu_power_csv"
        [ -z "$_pin_src" ] && [ -f "$psu_power_csv2" ] && grep -qiE "ps[0-9]+_pin" "$psu_power_csv2" 2>/dev/null && _pin_src="$psu_power_csv2"
        if [ -n "$_temp_src" ]; then
            PSU_DETAILS=$(grep -v "^#" "$_temp_src" 2>/dev/null | awk -F'|' '
                tolower($1) ~ /psu[0-9]+_temp|ps[0-9]+_pin|psu[0-9]+ power in/ {
                    num=$1; gsub(/[^0-9]/, "", num)
                    if(num!="" && !seen[num]++) printf "PSU%s|N/A|N/A|N/A|N/A|N/A\n", num
                }')
            # 功耗补全（PS*_Pin / PSU* Power In → PSU 行当前功耗）：先收集 pin 映射，再逐行追加
            if [ -n "$_pin_src" ] && [ -n "$PSU_DETAILS" ]; then
                # 构建 "编号:功耗" 列表（如 "6:427W 7:448W"）
                _pin_map=$(grep -v "^#" "$_pin_src" 2>/dev/null | awk -F'|' '
                    $1 ~ /^PS[0-9]+_Pin|^PSU[0-9]+ Power In/ { n=$1; sub(/^PSU?/, "", n); sub(/[^0-9].*/, "", n); v=$2; gsub(/ /, "", v); printf "%s:%sW ", n, v }')
                # 占位行逐行替换功耗（PSU6 → 6 → 查 _pin_map）
                if [ -n "$_pin_map" ]; then
                    PSU_DETAILS=$(while IFS= read -r _pline; do
                        [ -z "$_pline" ] && continue
                        _pnum=$(echo "$_pline" | cut -d'|' -f1 | sed 's/^PSU//')
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
        # dmidecode type39 补型号/SN/PN/容量（按 Location 匹配槽位；无 FRU 平台用 SMBIOS 补齐）
        if [ -n "$PSU_DETAILS" ] && [ -f "${dmidecode_psu}" ]; then
            # 构建 "Location→型号|厂商|SN|PN|容量|Revision" 映射（dmidecode type39 每个 PSU 一段）
            while IFS= read -r _dl; do
                case "$_dl" in
                    *Location:*) _dloc=$(echo "$_dl" | awk '{print $NF}') ;;
                    *Name:*)     _dname=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *Manufacturer:*) _dmfr=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *"Serial Number:"*) _dsn=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *"Model Part Number:"*) _dpn=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *"Max Power Capacity:"*) _dcap=$(echo "$_dl" | cut -d: -f2- | xargs | tr -d ' ') ;;
                    *Revision:*) _drev=$(echo "$_dl" | cut -d: -f2- | xargs) ;;
                    *Handle*)
                        # 段落结束（下一个 Handle 行）——此时 Location/Name/PN/容量/Revision 已读全
                        if [ -n "$_dloc" ] && [ -n "$_dname" ]; then
                            _dnum=$(echo "$_dloc" | sed 's/^PSU//')
                            # 型号列合并厂商+Revision（如 "DELTA DPS-3000AB-25 C Rev 01F"），PN/SN/容量独立列
                            _dfull="${_dmfr:+${_dmfr} }${_dname}${_drev:+ Rev ${_drev}}"
                            PSU_DETAILS=$(echo "$PSU_DETAILS" | awk -v num="$_dnum" -v name="$_dfull" -v pn="${_dpn:-N/A}" -v sn="${_dsn:-N/A}" -v cap="${_dcap:-N/A}" -F'|' 'BEGIN{OFS="|"} $1=="PSU"num {$2=name; $3=pn; $4=sn; $5=cap} {print}')
                        fi
                        _dloc=""; _dname=""; _dmfr=""; _dsn=""; _dpn=""; _dcap=""; _drev=""
                        ;;
                esac
            done < <(grep -v "^#" "${dmidecode_psu}" 2>/dev/null)
            # 最后一段（文件尾无空行）
            if [ -n "$_dloc" ] && [ -n "$_dname" ]; then
                _dnum=$(echo "$_dloc" | sed 's/^PSU//')
                _dfull="${_dmfr:+${_dmfr} }${_dname}${_drev:+ Rev ${_drev}}"
                PSU_DETAILS=$(echo "$PSU_DETAILS" | awk -v num="$_dnum" -v name="$_dfull" -v pn="${_dpn:-N/A}" -v sn="${_dsn:-N/A}" -v cap="${_dcap:-N/A}" -F'|' 'BEGIN{OFS="|"} $1=="PSU"num {$2=name; $3=pn; $4=sn; $5=cap} {print}')
            fi
        fi
        # 平台限制标注：FRU 无 PSU 条目时说明（避免客户误以为漏采）
        if [ -n "$PSU_DETAILS" ]; then
            PSU_PLATFORM_NOTE="平台未暴露单电源 FRU（传感器+SMBIOS 确认存在与功耗）"
        fi
    fi
    # 整机功耗（Total_Power 行首精确匹配，避免误取 CPU_Total_Power/MEM_Total_Power 等分段功耗）
    # 独立展示（不放 PSU 表内：语义是整机级而非单电源，且避免 N/A 占位列突兀）
    PSU_EXTRA=""
    total_pwr=$(grep -v "^#" "${PSU_DIR}/ipmi_psu_power.log" 2>/dev/null | awk -F'|' 'tolower($1) ~ /^total_power/{gsub(/ /,"",$2); print $2"W"; exit}')
    [ -n "$total_pwr" ] && PSU_EXTRA="整机功耗: ${total_pwr}"
    # DCMI 功耗统计（dcmi power reading：Instantaneous/Minimum/Maximum/Average，标准 IPMI 功耗统计）
    PSU_DCMI=""
    if [ -f "${PSU_DIR}/ipmi_dcmi_power.log" ]; then
        dcmi_cur=$(grep -iE "Instantaneous power reading|Current Power|Current Reading" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1)
        dcmi_min=$(grep -iE "Minimum" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1)
        dcmi_max=$(grep -iE "Maximum" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1)
        dcmi_avg=$(grep -iE "Average power reading" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1)
        if [ -n "$dcmi_cur" ]; then
            PSU_DCMI="DCMI 整机功耗: 当前 ${dcmi_cur}W${dcmi_min:+ · 最小 ${dcmi_min}W}${dcmi_max:+ · 最大 ${dcmi_max}W}${dcmi_avg:+ · 平均 ${dcmi_avg}W}"
        fi
    fi
    # PSU 尾注文本（变量拼接，避免 $( ) 命令替换剥离尾换行导致排版空行堆积）
    PSU_NOTE_TXT=""
    [ "$PSU_REDUNDANT" != "N/A" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  电源冗余: ${PSU_REDUNDANT}"$'\n'
    [ -n "$PSU_EXTRA" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ${PSU_EXTRA}"$'\n'
    [ -n "$PSU_DCMI" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ${PSU_DCMI}"$'\n'
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
