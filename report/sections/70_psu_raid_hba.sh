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
    # v1.49.17：除条数外**字段完整性**也要判——实测 psu/ipmi_psu_fru.log 的输出不含
    #   "Product Manufacturer"（bmc/ipmi_fru_all.log 才有），两者条数相同时旧逻辑总选前者
    #   → 厂商信息永远取不到（AMD 机 12 颗厂商列全空即此）。同条数下优先字段更全的一份。
    _m_psu=$(grep -c "Product Manufacturer" "$_fru_src" 2>/dev/null)
    _m_full=$(grep -c "Product Manufacturer" "${ipmi_fru_all}" 2>/dev/null)
    if [ "${_n_full:-0}" -gt "${_n_psu:-0}" ] || { [ "${_n_full:-0}" -ge "${_n_psu:-0}" ] && [ "${_m_full:-0}" -gt "${_m_psu:-0}" ]; }; then
        _fru_src="${ipmi_fru_all}"
    fi
fi
PSU_DETAILS=""
PSU_PLATFORM_NOTE=""
# 电源冗余状态（PS_Redundant：0x01/ok=冗余满足，0x00=冗余失效；无数据=N/A）
PSU_REDUNDANT="N/A"
load_manifest "${BMC_DIR}" ipmi_sdr "ipmi_sdr.log"
if [ -f "${ipmi_sdr}" ]; then
    _red_line=$(grep -iE "^PS_Redundant|PSU.*Redundant" "${ipmi_sdr}" 2>/dev/null | head -1)
    if [ -n "$_red_line" ]; then
        # v1.49.18：改为**只判数值列**。原 `*ok*` 通配会把 `PS_Redundant | 0x00 | ok`
        #   （0x00=冗余失效）也判成「冗余满足」——第三列 ok 只是"读取成功"，不是冗余状态。
        #   这正是 v1.49.0 为 FAN_Redundancy 修掉的 `*ok*` 同类 bug（见 gen_acceptance.sh 注释），
        #   PSU 侧当时漏修。实测该行格式：`PS_Redundant     | 0x01              | ok`。
        #   数值列（0xNN）→ 按值判；非数值（旧格式/纯文本）→ 退回文本判定。
        _red_val=$(printf '%s\n' "$_red_line" | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}')
        case "$_red_val" in
            0[xX]1|0[xX]01) PSU_REDUNDANT="冗余满足（N+N）" ;;
            0[xX]0|0[xX]00) PSU_REDUNDANT="⚠️ 冗余失效" ;;
            *) case "$_red_line" in
                   *ok*|*OK*|*Ok*) PSU_REDUNDANT="冗余满足（N+N）" ;;
                   *) PSU_REDUNDANT="⚠️ 冗余失效" ;;
               esac ;;
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
    # v1.49.18：去掉 `|| echo 0`——`grep -c` 无匹配时**既打印 0 又退出 1**，
    #   原写法会把结果变成两行 "0\n0"（实测 len=3），渲染成断行文案，
    #   且 `[ "0\n0" -ge 2 ]` 报错被 2>/dev/null 吞掉 → 验收的 SMBIOS 数量分支被跳过。
    PSU_COUNT_DMI=$(grep -ci "System Power Supply" "${dmidecode_psu}" 2>/dev/null)
    [ -n "$PSU_COUNT_DMI" ] || PSU_COUNT_DMI=0
fi
# ─── 每颗电源状态传感器（PS*_Status / PS* Status，v1.49.18）───
# 为什么必须有：gen_acceptance.sh 的「电源状态」项（v1.49.17 取代「电源冗余（N+N）」）
#   读的是 PSU_STATUS_OK/BAD/BAD_D/TEMP/PWR，但**全项目从未有任何代码给它们赋值**
#   → FAIL 分支不可达（坏电源会被下面的 SMBIOS 在位数量分支判 PASS）、
#     「N 颗电源状态正常（IPMI PS*_Status=0x1…）」分支永不执行、文案可能失真。
#   本节是那五个变量的**唯一生产者**。
# 命名实测两种形式（必须都认）：
#   `PS1 Status | 0x01 | ok`                    （bmc/ipmi_sdr.log，空格式）
#   `PS6_Status | 0x01 | ok`                    （psu/ipmi_sdr_psu.log，下划线式）
#   `PS1 Status | 0x1 | discrete | 0x0100 | …`   （bmc/ipmi_sensors.log，sensor list）
# 判定：数值列（0xNN）存在即按值判（0x01/0x1=正常，其余=异常）；数值列缺失时才退回状态列文本。
#   注意**不能只匹配 ok**——`PS_Redundant | 0x00 | ok` 的教训（v1.49.18 同批修复）。
PSU_STATUS_OK=0
PSU_STATUS_BAD=0
PSU_STATUS_BAD_D=""
PSU_STATUS_TEMP=""
PSU_STATUS_PWR=""
_psu_st_src=""
for _cand in "${PSU_DIR}/ipmi_sdr_psu.log" "${BMC_DIR}/ipmi_sdr.log" "${BMC_DIR}/ipmi_sensors.log" "${PSU_DIR}/ipmi_psu_sensors.log"; do
    [ -f "$_cand" ] || continue
    if grep -qE '^PS[0-9]+[ _]?Status' "$_cand" 2>/dev/null; then _psu_st_src="$_cand"; break; fi
done
if [ -n "$_psu_st_src" ]; then
    _psu_st_out=$(grep -v "^#" "$_psu_st_src" 2>/dev/null | awk -F'|' '
        $1 ~ /^PS[0-9]+[ _]?Status/ {
            n=$1; gsub(/[^0-9]/, "", n); sub(/^0+([0-9])/, "\1", n)
            if (n == "") next
            v=$2; gsub(/^[ \t]+|[ \t]+$/, "", v); vv=tolower(v)
            s=$3; gsub(/^[ \t]+|[ \t]+$/, "", s); ss=tolower(s)
            if (vv ~ /^0x[0-9a-f]+$/) { ok = (vv == "0x1" || vv == "0x01") }
            else if (vv == "")        { ok = (ss ~ /ok/) ? 1 : ((ss ~ /^(nc|cr|nr)$/) ? 0 : -1) }
            else                      { ok = (vv ~ /^ok$/) ? 1 : 0 }
            # 同一颗电源在同一份日志里出现多行时（sdr list 与 sensor list 混排等）**坏值优先**：
            # 健康判定宁可报不可漏；ok=1 只在从未见过坏值时成立，ok=-1（无法判定）不覆盖已知结果。
            if (!(n in st) || ok == 0) st[n] = ok
            if (!(n in ord)) { ord[n] = ++c; seq[c] = n }
        }
        END {
            for (i = 1; i <= c; i++) {
                n = seq[i]; k = st[n]
                if (k == 1) o++
                else if (k == 0) { b++; bd = bd (bd ? " " : "") "PS" n }
            }
            printf "%d|%d|%s\n", o+0, b+0, bd
        }
    ')
    PSU_STATUS_OK=$(printf '%s' "$_psu_st_out" | cut -d'|' -f1)
    PSU_STATUS_BAD=$(printf '%s' "$_psu_st_out" | cut -d'|' -f2)
    PSU_STATUS_BAD_D=$(printf '%s' "$_psu_st_out" | cut -d'|' -f3)
    [ -n "$PSU_STATUS_OK" ] || PSU_STATUS_OK=0
    [ -n "$PSU_STATUS_BAD" ] || PSU_STATUS_BAD=0
    # 温度佐证（PS*_Temp 最高值）；功耗佐证（PSU* Power In / PS*_Pin / PWR_PSU* 合计）
    _psu_temp_max=$(grep -vh "^#" "${PSU_DIR}/ipmi_psu_sensors.log" "${BMC_DIR}/ipmi_sensors_temp.log" 2>/dev/null \
        | awk -F'|' 'tolower($1) ~ /^psu?[0-9]+[ _]?temp/ { v=$2; gsub(/ /,"",v); if (v ~ /^[0-9]+(\.[0-9]+)?$/) { if (v+0 > m) m = v+0 } } END { if (m > 0) printf "%.0f", m }')
    [ -n "$_psu_temp_max" ] && PSU_STATUS_TEMP="最高 ${_psu_temp_max}°C"
    _psu_pwr_sum=$(grep -vh "^#" "${PSU_DIR}/ipmi_psu_sensors.log" "${BMC_DIR}/ipmi_sensors_power.log" 2>/dev/null \
        | awk -F'|' 'tolower($1) ~ /^psu?[0-9]+[ _]?pin$|^psu[0-9]+ power in|^pwr_psu[0-9]+[ _]?in/ { v=$2; gsub(/ /,"",v); if (v ~ /^[0-9]+(\.[0-9]+)?$/) { s += v+0; c++ } } END { if (c > 0 && s > 0) printf "%.0f", s }')
    [ -n "$_psu_pwr_sum" ] && PSU_STATUS_PWR="输入合计 ${_psu_pwr_sum}W"
fi
# 「在位但无明细」的真实化（v1.49.18，v1.48.88「0 条 ≠ 没有」同源）：
#   实测 B200 机头（B200-sample-c）：psu/ 无 PSU FRU、无 dmidecode Type 39 → PSU_DETAILS 为空，
#   生成器原来写「无 PSU 数据…可能采集时 BMC 传感器不可读」，但 bmc/ipmi_sdr.log 明明有
#   PS1..PS6 Status=0x01 → 6 颗电源在位且正常。把「没采到明细」说成「可能没数据」会让客户
#   以为平台无电源或采集坏了。这里给出在位颗数，供生成器在无明细时改用如实文案。
PSU_SENSOR_SEEN=$(( ${PSU_STATUS_OK:-0} + ${PSU_STATUS_BAD:-0} ))
if [ -z "$PSU_DETAILS" ] && [ "${PSU_SENSOR_SEEN:-0}" -gt 0 ] 2>/dev/null; then
    PSU_PLATFORM_NOTE="未取到单电源 FRU 与 SMBIOS Type 39 明细（型号/SN/额定容量缺），但 IPMI 电源状态传感器可见 ${PSU_SENSOR_SEEN} 颗在位${PSU_STATUS_BAD:+（其中 ${PSU_STATUS_BAD} 颗异常）}"
fi
if [ -f "$_fru_src" ]; then
    pdesc=""; pmfr=""; pmodel=""; ppn=""; psn=""; pending=""
    while IFS= read -r pline; do
        case "$pline" in
            *"FRU Device Description"*)
                [ -n "$pending" ] && PSU_DETAILS="${PSU_DETAILS}${pending}${ppn:-N/A}|${psn:-N/A}"$'\n'
                pdesc=$(echo "$pline" | cut -d: -f2- | xargs)
                # v1.48.24：PSU_FRU_N (ID x) → PSU N 行首规范化（显示与 pin 功耗映射对齐）
                # v1.48.97：实测 B300（B300-sample-a）FRU 描述为 "PSU6_FRU (ID 1)"（下划线在 N 前、
                #   且带 "(ID n)" 后缀），原 `^PSU_FRU_[0-9]+` 规则不匹配 → 该行 $1 保留为
                #   "PSU6_FRU (ID 1)"，而下方按 dmidecode 补字段时要求 $1 精确等于 "PSU6"，
                #   导致 FRU 行永远拿不到 SMBIOS 的容量/型号补齐。改为把两种写法统一归一到 PSU<N>。
                if echo "$pdesc" | grep -qE "^PSU_FRU_[0-9]+|^PSU[0-9]+_FRU"; then
                    pdesc=$(echo "$pdesc" | sed -E 's/^PSU_FRU_([0-9]+).*/PSU\1/; s/^PSU([0-9]+)_FRU.*/PSU\1/')
                fi
                pmfr=""; pmodel=""; ppn=""; psn=""; pending="" ;;
            *"Product Name"*)          pmodel=$(echo "$pline" | cut -d: -f2- | xargs); [ -n "$pdesc" ] && pending="${pdesc}|${pmfr:+${pmfr} }${pmodel}|" ;;
            # v1.49.17：厂商一直都在 FRU 里（Product Manufacturer: APLUSPOWER），旧解析只取
            #   Product Name → 型号列看不出厂商（实测 AMD 机 12 颗）。此处并入型号列而非新增字段
            #   （加字段会牵动 10+ 处硬编码字段位，漏一处即全表错位）。
            *"Product Manufacturer"*)  pmfr=$(echo "$pline" | cut -d: -f2- | xargs) ;;
            *"Product Part Number"*)   ppn=$(echo "$pline" | cut -d: -f2- | xargs) ;;
            *"Product Serial"*)        psn=$(echo "$pline" | cut -d: -f2- | xargs) ;;
        esac
    done < <(grep -v "^#" "$_fru_src" 2>/dev/null)
    [ -n "$pending" ] && PSU_DETAILS="${PSU_DETAILS}${pending}${ppn:-N/A}|${psn:-N/A}"$'\n'
    # 只保留 PSU 行（PSU 描述含 PSU 编号或 Power Supply）
    # v1.48.24：加 PSU_FRU[0-9] 匹配——"PSU_FRU_1"（下划线）此前被 PSU[0-9] 滤掉 → 8 电源显示 0（真机 G7768 M6 实测）
    PSU_DETAILS=$(echo "$PSU_DETAILS" | grep -iE "PSU[0-9]|PSU_FRU[0-9]|Power Supply")
    # v1.48.97：记录 PSU 明细来源（供「平台限制标注」按实际来源出文案）——fru / fru+dmi / dmi / sensor。
    #   此处 FRU 解析已完成（含 pending 收尾与 PSU 行过滤），有内容即来自 IPMI FRU。
    [ -n "$PSU_DETAILS" ] && _psu_src="fru"
    # v1.48.30：FRU 有 PSU 条目时功耗列也补全（原功耗补全仅在 76 行 FRU 空占位路径跑——
    # FRU 路径（PSU_FRU_1 描述）功耗恒 N/A；数据源同为 ipmi_psu_sensors.log 的 PSU_PIN_0N/PS*_Pin）
    psu_power_csv="${PSU_DIR}/ipmi_psu_sensors.log"
    psu_power_csv2="${BMC_DIR}/ipmi_sensors_power.log"
    load_manifest "${PSU_DIR}" ipmi_psu_sensors "ipmi_psu_sensors.log"
    load_manifest "${BMC_DIR}" ipmi_sensors_power "ipmi_sensors_power.log"
    [ -f "${ipmi_psu_sensors}" ] && psu_power_csv="${ipmi_psu_sensors}"
    [ -f "${ipmi_sensors_power}" ] && psu_power_csv2="${ipmi_sensors_power}"
    _pin_src=""
    # v1.49.8：加 DGX 平台的 `PWR_PSU<N>` 命名（实测 DGX A100：PWR_PSU0~5，值列 273.000 W）。
    #   注意 awk 正则默认大小写敏感，PWR_ 是全大写，必须单独列一条。
    [ -f "$psu_power_csv" ] && grep -qiE "ps[0-9]+_pin|psu[0-9]+_pin|psu[0-9]+ power in|psu_pin_[0-9]+|pwr_psu[0-9]+" "$psu_power_csv" 2>/dev/null && _pin_src="$psu_power_csv"
    [ -z "$_pin_src" ] && [ -f "$psu_power_csv2" ] && grep -qiE "ps[0-9]+_pin|psu[0-9]+_pin|psu_pin_[0-9]+|pwr_psu[0-9]+" "$psu_power_csv2" 2>/dev/null && _pin_src="$psu_power_csv2"
    if [ -n "$_pin_src" ] && [ -n "$PSU_DETAILS" ]; then
        _pin_map=$(grep -v "^#" "$_pin_src" 2>/dev/null | awk -F'|' '$1 ~ /^PS[0-9]+_Pin|^PSU[0-9]+_Pin|^PSU[0-9]+ Power In|^PSU_PIN_[0-9]+|^PWR_PSU[0-9]+[ \t]*$/ { n=$1; sub(/^[ \t]+/, "", n); sub(/[ \t]+$/, "", n); gsub(/[^0-9]/, "", n); sub(/^0+/, "", n); v=$2; gsub(/ /, "", v); if (v ~ /\./) sub(/\.?0+$/, "", v); printf "%s:%sW ", n, v }')
        if [ -n "$_pin_map" ]; then
            PSU_DETAILS=$(while IFS= read -r _pline; do
                [ -z "$_pline" ] && continue
                # 编号：PSU_FRU_1 / PSU1 / PSU01 → 1（grep -oE 提取 + 去前导零）
                _pnum=$(echo "$_pline" | cut -d'|' -f1 | grep -oE '[0-9]+' | head -1 | sed 's/^0*//')
                _pval=$(echo "$_pin_map" | tr ' ' '\n' | grep -E "^${_pnum}:" | cut -d: -f2)
                if [ -n "$_pval" ]; then
                    echo "$_pline" | awk -v val="$_pval" -F'|' 'BEGIN{OFS="|"} { if (NF < 6) $5="N/A"; $6=val; print }'
                else
                    echo "$_pline"
                fi
            done < <(printf '%s\n' "$PSU_DETAILS"))
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
    # v1.49.8：**DGX 平台**两头都没有——FRU 只有 Builtin/MID/IOEL/IOER/PDB/GB/M.2/SW 八个（无 PSU），
    #   dmidecode 无 Type 39；但 ipmi_sensors_power.log 有 PWR_PSU0~5（各 234~286W）。
    #   不补这一步，整块电源显示「N/A（无 PSU 数据）」而电源实际在位并有功耗读数——
    #   属「有数据却说没有」，与「0 条 ≠ 没有」同源。故用传感器编号生成占位行。
    if [ -z "$PSU_DETAILS" ] && [ -f "$psu_power_csv2" ] && grep -qE '^PWR_PSU[0-9]+' "$psu_power_csv2" 2>/dev/null; then
        PSU_DETAILS=$(grep -E '^PWR_PSU[0-9]+' "$psu_power_csv2" 2>/dev/null | awk -F'|' '{
            k=$1; sub(/^[ \t]+/,"",k); sub(/[ \t]+$/,"",k)
            n=k; sub(/^PWR_PSU/, "", n)
            v=$2; gsub(/ /,"",v); if (v ~ /\./) sub(/\.?0+$/,"",v)
            # 额定容量取第 8 列（该平台传感器格式：Name|Reading|Unit|Status|LNC|LNC|LNC|UNC|UNC|...）
            c=$8; gsub(/ /,"",c); if (c ~ /\./) sub(/\.?0+$/,"",c)
            if (c ~ /^[0-9]+$/) c=c"W"; else c="N/A"
            printf "PSU%s||||%s|%sW\n", n, c, v
        }')
    fi

    # dmidecode Type 39 补充源（v1.44.0 立，v1.48.97 由「兜底」改为「补充」）
    #   v1.44.0 原逻辑 `-z "$PSU_DETAILS"`（只在 FRU **完全没有** PSU 条目时才用 dmidecode），
    #   对「FRU 只暴露部分电源」的平台会**漏报**。实测 B300（B300-sample-a）：
    #     IPMI FRU 只枚举出 PSU6_FRU / PSU7_FRU 两个（ID 1/2），而 SMBIOS Type 39 有完整 8 条
    #     （A_PSU0/1/2 与 B_PSU3/4/5 各为 CR68-3300TO5R2I 3300W、PSU6/7 为 CRPS2000D2W 2000W）
    #     → 报告只显示 2 颗，客户看到的电源数量是错的（该机实为 6×3300W + 2×2000W 混插）。
    #   改为：dmidecode 里**FRU 未覆盖的编号**追加为占位行，交由下方字段补全逻辑填型号/SN/容量。
    #   FRU 已覆盖的编号保持不动（FRU 是带内更权威的来源）。编号取 Location 去掉 A_/B_ 槽位前缀。
    if [ -f "${dmidecode_psu}" ] && grep -q "System Power Supply" "${dmidecode_psu}" 2>/dev/null; then
        _dmi_nums=$(grep -v "^#" "${dmidecode_psu}" 2>/dev/null | awk '
            /System Power Supply/ { idx++ }
            /Location:/ {
                loc=$NF
                gsub(/^[A-Za-z][A-Za-z]*_/, "", loc)     # A_PSU0 / B_PSU3 → PSU0 / PSU3
                split(loc, a, "PSU")
                n = (a[2] != "" ? a[2] : idx)
                if (n != "") print n
            }')
        _have_nums=$(printf '%s\n' "$PSU_DETAILS" | grep -oE "^PSU[0-9]+" | sed 's/^PSU//')
        # v1.48.97：上游（FRU 解析 → 功耗补全）用 $( ) 接管道，末尾换行会被剥掉；
        #   若不补回来，本循环第一次追加的 "PSU0|..." 会拼到上一行 SN 之后
        #   （实测出现 "2Q040329508PSU0"）。这里统一保证以换行结尾。
        case "$PSU_DETAILS" in
            *$'\n') ;;
            *) PSU_DETAILS="${PSU_DETAILS}"$'\n' ;;
        esac
        _dmi_added=0
        for _dn in $_dmi_nums; do
            printf '%s\n' "$_have_nums" | grep -qx "$_dn" && continue
            _dmi_added=$(( _dmi_added + 1 ))
            PSU_DETAILS="${PSU_DETAILS}PSU${_dn}|N/A|N/A|N/A|N/A|N/A"$'\n'
        done
        # 按编号排序（dmidecode 用的是物理槽位序，FRU 追加顺序可能与之交错）
        # 用 awk 抽出编号作排序键，避免 `sort -t'U'` 被后面的 `|` 干扰
        if [ -n "$PSU_DETAILS" ]; then
            PSU_DETAILS=$(printf '%s\n' "$PSU_DETAILS" | grep -v '^$' \
                | awk -F'|' '{n=$1; sub(/^PSU/,"",n); if(n=="")n=9999; printf "%06d\t%s\n", n, $0}' \
                | sort -k1,1n | cut -f2-)$'\n'
        fi
    fi
    # v1.48.97：dmidecode 参与后升级来源标记（供「平台限制标注」区分文案）
    if [ -f "${dmidecode_psu}" ] && grep -q "System Power Supply" "${dmidecode_psu}" 2>/dev/null; then
        if [ -n "${_psu_src:-}" ]; then _psu_src="fru+dmi"; else _psu_src="dmi"; fi
        [ "${_dmi_added:-0}" -gt 0 ] 2>/dev/null && _psu_dmi_added="${_dmi_added}"
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
                        # v1.48.97：原 `PSU*` 匹配不到带槽位前缀的 Location（实测 B300 为
                        #   "A_PSU0".."B_PSU5"），全部落到 *) 分支取段序号 → 编号整体错位
                        #   （A_PSU0 被当成 PSU1，且真正的 PSU0 占位行补不上字段）。
                        #   改为取最后一个 "PSU" 之后的数字；前导零只在前方还有数字时剥离
                        #   （否则 "PSU0" 会被 sed 's/^0*//' 变成空串）。
                        case "$_dloc" in
                            *PSU*) _dnum=$(echo "$_dloc" | sed -E 's/.*PSU//; s/^0+([0-9])/\1/') ;;
                            *)     _dnum="${_didx:-1}" ;;
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
                *PSU*) _dnum=$(echo "$_dloc" | sed -E 's/.*PSU//; s/^0+([0-9])/\1/') ;;
                *)     _dnum="${_didx:-1}" ;;
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
    if [ -z "$PSU_DETAILS" ]; then
        # 编号识别源：psu sensors 的 PSU*_Temp（优先）→ PSU* Power In → bmc power 的 PS*_Pin
        _temp_src=""
        [ -f "$psu_power_csv" ] && grep -qiE "psu[0-9]+_temp" "$psu_power_csv" 2>/dev/null && _temp_src="$psu_power_csv"
        [ -z "$_temp_src" ] && [ -f "$psu_power_csv" ] && grep -qiE "psu[0-9]+ power in|psu_pin_[0-9]+" "$psu_power_csv" 2>/dev/null && _temp_src="$psu_power_csv"
        [ -z "$_temp_src" ] && [ -f "$psu_power_csv2" ] && grep -qiE "ps[0-9]+_pin|psu_pin_[0-9]+" "$psu_power_csv2" 2>/dev/null && _temp_src="$psu_power_csv2"
        # 功耗补全源：psu sensors 的 PS*_Pin / PSU* Power In → bmc power 的 PS*_Pin（v1.48.24 加 PSU_PIN_0N 下划线式）
        _pin_src=""
        [ -f "$psu_power_csv" ] && grep -qiE "ps[0-9]+_pin|psu[0-9]+_pin|psu[0-9]+ power in|psu_pin_[0-9]+" "$psu_power_csv" 2>/dev/null && _pin_src="$psu_power_csv"
        [ -z "$_pin_src" ] && [ -f "$psu_power_csv2" ] && grep -qiE "ps[0-9]+_pin|psu[0-9]+_pin|psu_pin_[0-9]+" "$psu_power_csv2" 2>/dev/null && _pin_src="$psu_power_csv2"
        if [ -n "$_temp_src" ]; then
            _psu_src="sensor"
            # v1.50.8：本段是**整体重建** PSU_DETAILS（`PSU%s|N/A|...`），会把此前（:209 传感器
            #   占位行）已从传感器第 8 列取到的额定容量抹成 N/A——实测 DGX A100：源数据
            #   PWR_PSU0~5 第 8 列 = 3315.000，报告却渲染成「—」。故先抽出现有「编号→容量」，
            #   重建时按编号回填；无既有值仍为 N/A。
            _prev_cap=$(printf '%s\n' "${PSU_DETAILS:-}" | awk -F'|' '
                $1 ~ /^PSU[0-9]+$/ {
                    n=$1; sub(/^PSU/,"",n)
                    c=$5; gsub(/^[ \t]+|[ \t]+$/,"",c)
                    if (c != "" && c != "N/A") printf "%s:%s ", n, c
                }')
            PSU_DETAILS=$(grep -v "^#" "$_temp_src" 2>/dev/null | awk -F'|' -v prev="$_prev_cap" '
                BEGIN {
                    nf = split(prev, _a, " ")
                    for (i = 1; i <= nf; i++) { m = split(_a[i], _b, ":"); if (m >= 2 && _b[1] != "") P[_b[1]] = _b[2] }
                }
                tolower($1) ~ /psu[0-9]+_temp|psu_pin_[0-9]+|ps[0-9]+_pin|psu[0-9]+ power in/ {
                    num=$1; gsub(/[^0-9]/, "", num); sub(/^0+/, "", num)
                    if(num!="" && !seen[num]++) {
                        c = (num in P) ? P[num] : "N/A"
                        printf "PSU%s|N/A|N/A|N/A|%s|N/A\n", num, c
                    }
                }' )
            # 功耗补全（PS*_Pin / PSU* Power In → PSU 行当前功耗）：先收集 pin 映射，再逐行追加
            if [ -n "$_pin_src" ] && [ -n "$PSU_DETAILS" ]; then
                # 构建 "编号:功耗" 列表（如 "6:427W 7:448W"）
                _pin_map=$(grep -v "^#" "$_pin_src" 2>/dev/null | awk -F'|' '
                    $1 ~ /^PS[0-9]+_Pin|^PSU[0-9]+ Power In|^PSU_PIN_[0-9]+|^PWR_PSU[0-9]+[ \t]*$/ { n=$1; sub(/^[ \t]+/, "", n); sub(/[ \t]+$/, "", n); gsub(/[^0-9]/, "", n); sub(/^0+/, "", n); v=$2; gsub(/ /, "", v); if (v ~ /\./) sub(/\.?0+$/, "", v); printf "%s:%sW ", n, v }')
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
                    done < <(printf '%s\n' "$PSU_DETAILS"))
                fi
            fi
        fi
        # v1.48.97：来源标记（提示块已移出本分支，见下方「平台限制标注」）
    fi

    # 平台限制标注：说明 PSU 明细的实际来源，避免客户误以为漏采（v1.44.0 立；v1.48.97 按 _psu_src 分类）
    #   v1.48.97：本块原先嵌在 `if [ -z "$PSU_DETAILS" ]` 内；dmidecode 补充块移出该分支后，
    #   「FRU 非空但只列部分电源」的机器不再进入该分支，提示整条丢失
    #   （回归实测 B200 B200-sample-b html −197B 即此）。故移出并按来源出文案。
    if [ -n "$PSU_DETAILS" ]; then
        case "${_psu_src:-}" in
            fru) ;;    # 全部来自 IPMI FRU，无需平台限制说明
            fru+dmi)
                # v1.49.18：原 `${_ps_ok:+；PS 状态传感器均 ok}` 是**恒真**的——
                #   `_ps_ok` 由 awk `END{print n+0}` 产出，无匹配时是字符串 "0"（非空），
                #   而 `:+` 判"非空"不判"非零"，于是没有状态传感器的机器也照写"均 ok"。
                #   现改用上面真正统计出的 PSU_STATUS_OK（>0 才写），数值来源于同一份日志。
                [ "${PSU_STATUS_OK:-0}" -gt 0 ] 2>/dev/null && _ps_st_note="；PS 状态传感器 ${PSU_STATUS_OK} 颗均 ok" || _ps_st_note=""
                PSU_PLATFORM_NOTE="部分 PSU 未暴露单电源 FRU（SMBIOS Type 39 确认 ${PSU_COUNT_DMI} 颗在位，其中 ${_psu_dmi_added:-?} 颗的型号/SN/额定容量取自 dmidecode${_ps_st_note}）"
                ;;
            sensor*)
                PSU_PLATFORM_NOTE="平台未暴露单电源 FRU（传感器+SMBIOS 确认存在与功耗）"
                ;;
            *)
                [ "${PSU_STATUS_OK:-0}" -gt 0 ] 2>/dev/null && _ps_st_note="，PS 状态传感器 ${PSU_STATUS_OK} 颗均 ok" || _ps_st_note=""
                PSU_PLATFORM_NOTE="平台未暴露单电源 FRU 与单 PSU 功率传感器（SMBIOS Type 39 确认 ${PSU_COUNT_DMI} 颗在位${PSU_EMPTY_FRU:+，其中 ${PSU_EMPTY_FRU} 条记录的 FRU 字段未填充（BIOS 未读到该颗 PSU 的型号/SN，供电状态不受影响）}，型号/SN/额定容量为 dmidecode 数据${_ps_st_note})"
                ;;
        esac
        # v1.49.0：PSU「当前功耗」列的 N/A 说明（区别于「平台无该传感器」）。
        #   实测 B300（B300-sample-a，22.224）8 颗电源中仅 PSU6/7 有带内输入功率读数（_Pin），
        #   其余由 SMBIOS/dmidecode 枚举；BMC 另有一组 B_PSU0~B_PSU5_Pout（输出功率）采用
        #   不同编号体系，与 SMBIOS 槽位编号无法一一对应，故不做映射、只在表下如实说明，
        #   避免客户对着 6 个裸 N/A 猜「是不是电源坏了」。
        _psu_nopwr=0; _psu_has_pout=0
        if [ -n "${PSU_DETAILS:-}" ]; then
            _psu_nopwr=$(printf '%s\n' "$PSU_DETAILS" | awk -F'|' 'NF>=6 && ($6=="" || $6=="N/A"){c++} END{print c+0}')
            _psu_has_pout=$(grep -v "^#" "${BMC_DIR}/ipmi_sensors_power.log" 2>/dev/null \
                | awk -F'|' 'tolower($1) ~ /_pout/ {n++} END{print n+0}')
        fi
        if [ "${_psu_nopwr:-0}" -gt 0 ] 2>/dev/null; then
            _ppn="当前功耗列有 ${_psu_nopwr} 颗显示 N/A：带内（IPMI）仅部分电源提供输入功率读数（_Pin），其余由 SMBIOS(dmidecode) 枚举、无带内功率读数"
            [ "${_psu_has_pout:-0}" -gt 0 ] 2>/dev/null && _ppn="${_ppn}；BMC 另提供一组 _Pout（输出功率）以不同编号体系命名，与 SMBIOS 槽位编号无法一一对应，故未做映射"
            PSU_PLATFORM_NOTE="${PSU_PLATFORM_NOTE:+${PSU_PLATFORM_NOTE}；}${_ppn}"
        fi
    fi    # 整机功耗（Total_Power 行首精确匹配，避免误取 CPU_Total_Power/MEM_Total_Power 等分段功耗）
    # 独立展示（不放 PSU 表内：语义是整机级而非单电源，且避免 N/A 占位列突兀）
    PSU_EXTRA=""
    total_pwr=$(grep -v "^#" "${PSU_DIR}/ipmi_psu_power.log" 2>/dev/null | awk -F'|' 'tolower($1) ~ /^total_power/{gsub(/ /,"",$2); if ($2 ~ /\./) sub(/\.?0+$/,"",$2); print $2"W"; exit}')
    # v1.48.98：兜底 bmc/ipmi_sensors_power.log 的 H_Total_Power——实测 B300（B300-sample-a，22.224）
    #   该机 psu/ipmi_psu_power.log 为空（命令超时），而 bmc/ipmi_sensors_power.log 有
    #   `H_Total_Power | 750.000 | Watts | ok`（整机功耗）。原实现只读前者 → 报告整机功耗空白。
    #   H_ 前缀是该平台（Inventec）的命名习惯，与 psu 日志的 Total_Power 同义（同处 PSU 输入口径）。
    if [ -z "$total_pwr" ]; then
        total_pwr=$(grep -v "^#" "${BMC_DIR}/ipmi_sensors_power.log" 2>/dev/null \
            | awk -F'|' 'tolower($1) ~ /^h_total_power|^total_power/{gsub(/ /,"",$2); if ($2 ~ /\./) sub(/\.?0+$/,"",$2); print $2"W"; exit}')
    fi
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
            # v1.48.97：原文案把「瞬时」与「窗口统计」并排成「当前 X · 最小 Y · 最大 Z」，
            #   实测该机 min=max=750 而瞬时=770 → 读起来像「电源最高只有 750W 却跑了 770W」，
            #   是展示误导。根因：DCMI 的 Min/Max/Average 是 **BMC 内部采样窗口内** 的统计，
            #   与 Instantaneous（此刻）不同步，且窗口长度仅数秒（该机 "Sampling period: 5 Seconds"）。
            #   故解析窗口长度并在文案中点明口径，再把瞬时与窗口统计分段，避免误读。
            dcmi_win=$(grep -iE "Sampling period" "${PSU_DIR}/ipmi_dcmi_power.log" 2>/dev/null \
                       | grep -oE "Sampling period:[[:space:]]*[0-9]+" | grep -oE "[0-9]+" \
                       | head -1 | awk '{print $1+0}')      # 去掉 BMC 补的前导零（00000005 → 5）
            _win_txt=""; [ -n "$dcmi_win" ] && _win_txt="（BMC 内部 ${dcmi_win}s 采样窗口）"
            _win_stat=""
            [ -n "$dcmi_min" ] && _win_stat="窗口内 最小 ${dcmi_min}W"
            [ -n "$dcmi_max" ] && _win_stat="${_win_stat}${_win_stat:+ / }最大 ${dcmi_max}W"
            [ -n "$dcmi_avg" ] && _win_stat="${_win_stat}${_win_stat:+ / }平均 ${dcmi_avg}W"
            PSU_DCMI="DCMI 平台功耗读数（ipmitool dcmi power reading）: 瞬时 ${dcmi_cur}W"
            [ -n "$_win_stat" ] && PSU_DCMI="${PSU_DCMI} ｜ ${_win_stat}${_win_txt}"
        fi
    fi
    # ─── CPU 功耗（RAPL 两次采样，v1.48.88）——独立信源，可与 DCMI 交叉验证 ───
    # 为什么值得单列：DCMI 给的是平台总功耗读数，厂际口径不一（有的只报主板域）；
    #   RAPL 是 CPU 自己的能量计数器，两个数对不上时就说明 DCMI 口径有问题——
    #   这正是我们之前**不该**替客户断言「DCMI 含/不含 GPU」的原因。
    PSU_CPU_RAPL=""
    if [ -f "${PSU_DIR}/rapl_power.log" ]; then
        _rapl_out=$(grep -vE "^#|^[[:space:]]*$" "${PSU_DIR}/rapl_power.log" 2>/dev/null | grep -E "W[[:space:]]*\(" | sed 's/^[[:space:]]*//' | head -8)
        # v1.48.97：括号里的 "E1=… uJ, E2=… uJ, 间隔 3.0 s" 是采集端为算功率取的两个能量计读数，
        #   属中间量，客户不需要（原始值在 rapl_power.log 里可追溯）——报告只留功率。
        _rapl_out_s=$(printf '%s\n' "$_rapl_out" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//')
        # v1.48.97：`paste -d' · '` 是**多字符**分隔符，paste 会按字符轮转使用（第1个分隔用空格、
        #   第2个用 ·），导致两个 package 之间只出现空格。改用单字符分隔后再替换，保证分隔一致。
        _rapl_pkg=$(printf '%s\n' "$_rapl_out_s" | grep -iE "^package" | paste -sd'|' - | sed 's/|/ · /g')
        # v1.48.97：非 package 域按 CPU 各有一个（该机两个 dram 域），原实现直接取域名拼 "/" 会出现
        #   "dram/dram"。改为域名去重后列出功率值（同域多值以 / 分隔），信息不丢也不重复。
        _rapl_other=$(printf '%s\n' "$_rapl_out_s" | grep -viE "^package" | awk -F: '
            { v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); sub(/[[:space:]]*W.*/,"",v);
              n=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",n);
              if(n=="")next; if(!(n in seen)){seen[n]=v; ord[++c]=n} else {seen[n]=seen[n]"/"v} }
            END{ for(i=1;i<=c;i++) printf "%s %sW%s", ord[i], seen[ord[i]], (i<c?" / ":"") }')
        if [ -n "$_rapl_pkg" ]; then
            PSU_CPU_RAPL="CPU 功耗（RAPL）: ${_rapl_pkg}"
            [ -n "$_rapl_other" ] && PSU_CPU_RAPL="${PSU_CPU_RAPL}（另有 ${_rapl_other}）"
        else
            PSU_CPU_RAPL="CPU 功耗（RAPL）: $(printf '%s\n' "$_rapl_out_s" | paste -sd' · ' -)"
        fi
    fi
    # PSU 尾注文本（变量拼接，避免 $( ) 命令替换剥离尾换行导致排版空行堆积）
    PSU_NOTE_TXT=""
    [ "$PSU_REDUNDANT" != "N/A" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  电源冗余: ${PSU_REDUNDANT}"$'\n'
    [ -n "$PSU_EXTRA" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ${PSU_EXTRA}"$'\n'
    [ -n "$PSU_DCMI" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ${PSU_DCMI}"$'\n'
    [ -n "$PSU_CPU_RAPL" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ${PSU_CPU_RAPL}"$'\n'
    [ -n "$PSU_PLATFORM_NOTE" ] && PSU_NOTE_TXT="${PSU_NOTE_TXT}  ⚠️ ${PSU_PLATFORM_NOTE}"$'\n'
    # 每只 PSU 当前输入功率（Pwr_PSU<N>_In / PS<N>_Pin / PWR_PSU<N> / PSU<N> Power In，| W |），按编号匹配追加
    # v1.49.18：补 `PSU<N> Power In` 命名——实测 HGX 机头（headless-sample-a，AMAX 机箱，
    #   6×DELTA 3000W）的
    #   psu/ipmi_psu_sensors.log 只有 `PSU1 Power In | 144.000 | Watts | ok` 这一种写法，
    #   原守卫（大小写敏感且无该分支）整体跳过 → **整列功耗丢失显示 —**，
    #   而同一文件 96/99 与 273/277/282 行的另一份同名逻辑是认这个命名的（同源实现漂移）。
    #   归档报告（v1.33.4）同输入显示 144/160/256/176/160/176 W，即回归点。
    if [ -f "$psu_power_csv" ] && [ -n "$PSU_DETAILS" ] && grep -qiE "Pwr_PSU[0-9]|PS[0-9]_Pin|PWR_PSU[0-9]|psu[0-9]+ power in" "$psu_power_csv" 2>/dev/null; then
        # 一次性构建 编号→功率 映射，再一次性追加（避免逐行 echo|awk 嵌套性能灾难）
        PSU_DETAILS=$(awk -v psu_detail="$PSU_DETAILS" '
            BEGIN { FS="|"; OFS="|" }
            /Pwr_PSU[0-9]+_In|PS[0-9]+_Pin|PWR_PSU[0-9]+[ \t]*\||^PSU[0-9]+ Power In/ {
                # 编号提取取"所有数字"（`PSU1 Power In` 用旧的 sub(/.*PS/) 会得到空串）
                num=$1; gsub(/[^0-9]/, "", num)
                val=$2; gsub(/ /, "", val)
                if (val ~ /\./) sub(/\.?0+$/, "", val)
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
                    # 额定容量：优先沿用既有 cap 字段（传感器占位行已从第 8 列取到容量，
                    #   v1.50.8 修复：旧实现只看 model 提取，把占位行填好的容量覆盖成 N/A）；
                    #   无既有值才从型号提取 3-4 位容量数字（锚定边界，防 "PS-2800" 被 /800/ 误配）
                    model=f[2]
                    cap=""
                    # v1.50.8：**必须用 split() 的返回值判字段数，绝不能用 NF**——此行位于 END 块，
                    #   NF 指的是「最后读入的记录（$0）」的字段数，而 $0 是日志末尾的注释行
                    #   `# --- output end ---`（按 FS="|" 只有 1 段）→ NF 恒为 1 → 守卫恒假
                    #   → 容量回落到空型号提取 → N/A。实测 DGX：源数据第 8 列 3315.000 明明在 f[5] 里。
                    _nf = split(line, f, "|")
                    if (_nf >= 5) cap=f[5]
                    if (cap == "" || cap == "N/A") {
                        cap="N/A"
                        if (match(model, /(^|[^0-9])[0-9]{3,4}([^0-9]|$)/)) {
                            _capstr = substr(model, RSTART, RLENGTH)
                            gsub(/[^0-9]/, "", _capstr)
                            cap = _capstr "W"
                        }
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

# ─── v1.50.0：电源槽位总数（BMC SDR 里 PSn_Status 编号最大值）───
#   用途：交付验收时场地供电可能不满配（机柜单路供电等），报告如实标注「在位/槽位」，
#         由验收人对照采购配置单确认；不做"必须插满"硬判定——机型槽位数差异大（8/12 槽等），
#         硬判会把出厂即部分配置的机器误报为故障。
PSU_SLOT_TOTAL=""
for _psf in "${BMC_DIR}/ipmi_sensors.log" "${BMC_DIR}/ipmi_sensors_power.log" "${PSU_DIR}/ipmi_psu_sensors.log"; do
    [ -f "$_psf" ] || continue
    _slot=$(grep -oE "PS[0-9]+_Status" "$_psf" 2>/dev/null | grep -oE "[0-9]+" | sort -n | tail -1)
    [ -n "$_slot" ] && { PSU_SLOT_TOTAL="$_slot"; break; }
done
