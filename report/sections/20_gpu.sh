#!/bin/bash
# =============================================================================
# HwScope - 变量解析：GPU 主区（规格库调用/明细/魔改/ECC/序列号）
# report/sections/20_gpu.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# ─── GPU（解析 inventory.csv；列: 1=idx 2=name 3=serial 4=bdf 5=uuid 6=mem.total 7=mem.used 8=power.limit 9=power.draw 10=temp 11=util 12-13=clocks 14=ecc.mode 15=gen.cur 16=width.cur 17=gen.max 18=width.max） ───
load_manifest "${GPU_DIR}" gpu_inventory "gpu_inventory.csv"
load_manifest "${GPU_DIR}" gpu_ecc_inventory "gpu_ecc_inventory.csv"
GPU_CSV="${gpu_inventory}"
GPU_ECC_CSV="${gpu_ecc_inventory}"
GPU_COUNT=0; GPU_NAMES=""; GPU_MEM=""; GPU_POWER=""; GPU_TEMP=""; GPU_ECC=""; GPU_DETAILS=""; GPU_DEGRADED=""; GPU_AMD_SUSPECT=""
if [ -f "$GPU_CSV" ]; then
    # 有效性守卫：nvidia-smi 失败时 csv 只有报错行（如 "NVIDIA-SMI has failed..."），不算 GPU 数据
    if grep -v "^#" "$GPU_CSV" | grep -qiE "NVIDIA-SMI has failed|couldn't communicate|No devices were found"; then
        GPU_CSV=""
    fi
fi
# GPU 硬件存在性（lspci 3D controller，v1.46.2 起调 detect_gpu_vendors 单一实现——报告端传 lspci_all 日志）
# 输出：GPU_PCI_PRESENT / GPU_PCI_VENDORS（厂商分组）/ GPU_PCI_VENDOR / GPU_PLATFORM（nvidia/amd/mixed/...）
if command -v detect_gpu_vendors >/dev/null 2>&1; then
    detect_gpu_vendors "${lspci_all}"
else
    # 兜底（函数缺失时）：仅基础存在性
    GPU_PCI_PRESENT=$(grep -cE "3D controller|Processing accelerators" "${lspci_all}" 2>/dev/null)
    GPU_PCI_VENDOR=""; GPU_PCI_VENDORS=""; GPU_PLATFORM="none"
fi
if [ -n "$GPU_CSV" ] && [ -f "$GPU_CSV" ]; then
    GPU_COUNT=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | wc -l)
    GPU_NAMES=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -F',' '{print $2}' | sed 's/^ *//;s/ *$//' | sort -u | tr '\n' ',' | sed 's/,$//')
    # 显存总量 / 功耗上限 / 温度
    # 显存总量（nvidia-smi memory.total，MiB→GiB 二进制换算，为可见值含 ECC 预留）
    # 动态匹配列名，避免硬编码位置
    mem_col=$(get_csv_col_index "$GPU_CSV" "memory.total [MiB]")
    power_col=$(get_csv_col_index "$GPU_CSV" "power.limit [W]")
    temp_col=$(get_csv_col_index "$GPU_CSV" "temperature.gpu")

    GPU_MEM=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -v col="${mem_col:-6}" -F',' '{
        v = $col; gsub(/ MiB/, "", v); gsub(/^ +| +$/, "", v)
        if (v ~ /^[0-9]+$/) sum += v; else na++
    } END{if (sum > 0) printf "%.0f GiB", sum/1024; else print "N/A"}')
    # ─── GPU 额定显存规格库 + 检测值交叉验证 ───
    # 检测值（memory.total MiB）永远来自硬件；额定值（厂商规格）来自此规格库。
    # 匹配算法：型号模式 → 候选额定值列表 → 与检测值交叉验证（GB 十进制/GiB 双口径，取近者）：
    #   差值 < 3% → 匹配成功（额定 = 厂商值，如 H200 检测 143771MiB≈141GiB）
    #   全部不匹配 → ⚠️ 疑似魔改/伪装（如 RTX 2080Ti 魔改 22GB、低端卡刷 BIOS 伪装）
    # 多版本型号（A100 40/80GB、V100 16/32GB、RTX 3080 10/12GB）给候选列表，检测值自动选近者
    GPU_MODEL_LINE=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | head -1 | cut -d',' -f2)
    GPU_MEM_DET_MIB=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | head -1 | cut -d',' -f6 | grep -oE "[0-9]+" | head -1)
    GPU_MEM_SPEC=""
    GPU_MEM_SPEC_NOTE=""
    if [ -n "$GPU_MODEL_LINE" ] && [ -n "$GPU_MEM_DET_MIB" ] && command -v verify_gpu_mem >/dev/null 2>&1; then
        # 统一魔改检测（v1.46.2）：verify_gpu_mem 双口径多候选最近匹配（原逻辑泛化，NVIDIA/AMD 共用）
        verify_gpu_mem "$GPU_MODEL_LINE" "$GPU_MEM_DET_MIB"
        if [ -n "$VERIFY_MEM_SPEC" ]; then
            if [ -z "$VERIFY_MEM_NOTE" ]; then
                GPU_MEM_SPEC="${VERIFY_MEM_SPEC}GB/卡"
            else
                GPU_MEM_MISMATCH=$(awk -v d="$GPU_MEM_DET_MIB" 'BEGIN{printf "%.0f", d/1024}' < /dev/null)
                GPU_MEM_SPEC="${VERIFY_MEM_SPEC}GB"
                GPU_MEM_SPEC_NOTE="⚠️ ${VERIFY_MEM_NOTE}（疑似显存魔改或伪装，需核实）"
            fi
        fi
    fi
    # 功耗/温度数值守卫：非数值（[N/A]/空）不参与统计，防全部 N/A 输出 "0 W"/"0°C" 或均值被稀释
    # 注意：CSV 值带前导空格（" 700.00 W"），须先 trim 再校验（v1.33.4 修正）
    GPU_POWER=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -v col="${power_col:-8}" -F',' '{
        v = $col; gsub(/^ +| +$/, "", v); gsub(/ W/, "", v)
        if(v ~ /^[0-9.]+$/) { if(v+0 > max+0) max = v; n++ }
    } END{if(n>0) printf "%.0f W", max; else print "N/A"}')
    GPU_TEMP=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -v col="${temp_col:-9}" -F',' '{
        t = $col; gsub(/^ +| +$/, "", t)
        if(t ~ /^[0-9.]+$/) { sum += t; if(t+0 > tmax+0) tmax = t; n++ }
    } END{if(n>0) printf "%.0f°C (max %.0f)", sum/n, tmax; else print "N/A"}')
    # 额定总量（单卡额定 × 卡数，如 288GB×8=2304GB）；与可用总量(GPU_MEM)并列显示
    GPU_MEM_SPEC_TOTAL=""
    if [ -n "$GPU_MEM_SPEC" ]; then
        GPU_MEM_SPEC_NUM=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+" | head -1)
        [ -n "$GPU_MEM_SPEC_NUM" ] && GPU_MEM_SPEC_TOTAL=$(awk "BEGIN{printf \"%.0fGB\", ${GPU_MEM_SPEC_NUM}*${GPU_COUNT}}" < /dev/null)
    fi
    # 每卡明细行（兼容新旧 CSV：新 18 列含 PCIe/利用率，旧 12 列降级为 N/A）
    while IFS=',' read -r gidx gname gsn gbdf guuid gmem gused glimit gdraw gtemp gutil gclk gcclk gecc ggen gwidth ggenmax gwidthmax; do
        # 注意：此处禁止 echo|sed/tr 管道——循环 stdin 是 here-string，子进程会抢占 fd 导致 read 错位
        shopt -s extglob
        gname=${gname##*( )}; gname=${gname%%*( )}
        gsn=${gsn##*( )}; gsn=${gsn%%*( )}
        gmem_f=${gmem// /}
        # 显存单位统一：MiB → GiB（275040MiB → 268.6 GiB）；纯参数运算无子进程
        if [[ "$gmem_f" == *MiB ]] && [[ "${gmem_f%MiB}" =~ ^[0-9]+$ ]]; then
            gmem_f=$(awk "BEGIN{printf \"%.1f GiB\", ${gmem_f%MiB}/1024}" < /dev/null)
        fi
        gused_f=${gused// /}
        # 已用显存单位统一：MiB → GiB
        if [[ "$gused_f" == *MiB ]] && [[ "${gused_f%MiB}" =~ ^[0-9]+$ ]]; then
            gused_f=$(awk "BEGIN{printf \"%.1f GiB\", ${gused_f%MiB}/1024}" < /dev/null)
        fi
        gdraw_f=${gdraw// /}
        glimit_f=${glimit// /}
        gtemp_f=${gtemp// /}
        gutil_f=${gutil// /}
        gwidth=${gwidth// /}
        gwidthmax=${gwidthmax// /}
        ggen=${ggen// /}
        ggenmax=${ggenmax// /}
        # 旧 12 列 CSV 无 PCIe/利用率字段 → 识别并置 N/A（旧列: $9=temp $10=clk $11=clk $12=ecc）
        if [ -z "$ggen" ] && [ -z "$gwidth" ]; then
            gtemp_f="$gdraw"    # 旧布局 $9 是温度（被 gdraw 变量接住）
            ggen="N/A"; gwidth="N/A"; ggenmax="N/A"; gwidthmax="N/A"
            gutil_f="N/A"; gdraw_f="N/A"
        fi
        # 功耗回退：旧 CSV 无 power.draw 列 → 从每卡 detail 日志补（Instantaneous/Average Power Draw）
        if [ "$gdraw_f" = "N/A" ] || [ -z "$gdraw_f" ]; then
            _gdraw_detail=$(grep -m1 "Instantaneous Power Draw" "${GPU_DIR}/gpu_${gidx}_detail.log" 2>/dev/null | grep -oE "[0-9.]+ W" | head -1)
            [ -z "$_gdraw_detail" ] && _gdraw_detail=$(grep -m1 "Average Power Draw" "${GPU_DIR}/gpu_${gidx}_detail.log" 2>/dev/null | grep -oE "[0-9.]+ W" | head -1)
            [ -n "$_gdraw_detail" ] && gdraw_f="$_gdraw_detail"
        fi
        [ -n "$gtemp_f" ] && [ "$gtemp_f" != "N/A" ] && [ "$gtemp_f" != "[N/A]" ] && gtemp_f="${gtemp_f}°C"
        # PCIe 显示：两侧都 N/A 时合并为单个 N/A（避免 N/A/N/A/N/A/N/A）
        gpcie_cur="N/A"; gpcie_max="N/A"
        [ "$ggen" != "N/A" ] && [ -n "$ggen" ] && gpcie_cur="${ggen}x${gwidth}"
        [ "$ggenmax" != "N/A" ] && [ -n "$ggenmax" ] && gpcie_max="${ggenmax}x${gwidthmax}"
        [ "$gpcie_cur" = "N/A" ] && [ "$gpcie_max" != "N/A" ] && gpcie_cur="?"
        GPU_DETAILS="${GPU_DETAILS}${gidx}|${gname}|${gsn}|${gmem_f}|${gdraw_f}|${gtemp_f}|${gutil_f}|${gpcie_cur}|${gpcie_max}|${gused_f}|${glimit_f}"$'\n'
        # 魔改/伪装逐卡检测（混插识别：每卡用自身型号匹配规格库，检测显存与额定交叉验证 >3% 即标记）
        _gdet=${gmem// /}; _gdet=${_gdet%MiB}
        if [[ "$_gdet" =~ ^[0-9]+$ ]]; then
            _gcands=$(gpu_mem_candidates "$gname")
            if [ -n "$_gcands" ]; then
                _gbc="" _gbd=""
                for _c in ${_gcands//|/ }; do
                    for _mib in $(awk -v c="$_c" 'BEGIN{printf "%.0f %.0f", c*1000000000/1048576, c*1024}' < /dev/null); do
                        _d=$(awk -v d="$_gdet" -v m="$_mib" 'BEGIN{printf "%.4f", (d>m?d-m:m-d)/d}' < /dev/null)
                        if [ -z "$_gbd" ] || awk -v a="$_d" -v b="$_gbd" 'BEGIN{exit !(a<b)}'; then _gbd="$_d"; _gbc="$_c"; fi
                    done
                done
                if ! awk -v d="$_gbd" 'BEGIN{exit !(d<0.03)}'; then
                    GPU_MEM_MISMATCH_CARDS="${GPU_MEM_MISMATCH_CARDS}GPU${gidx}($(awk -v d="$_gdet" 'BEGIN{printf "%.0f", d/1024}' < /dev/null)GB vs 额定${_gbc}GB),"
                fi
            fi
        fi
        # PCIe 宽度降级检测（宽度空闲不变，是最可靠信号；gen 低可能是省电不算）
        if [ -n "$gwidth" ] && [ -n "$gwidthmax" ] && [ "$gwidth" != "[N/A]" ] && [ "$gwidthmax" != "[N/A]" ] && [ "$gwidth" -lt "$gwidthmax" ] 2>/dev/null; then
            GPU_DEGRADED="${GPU_DEGRADED}GPU${gidx}: PCIe ${ggen}x${gwidth} (期望 ${ggenmax}x${gwidthmax}),"
        fi
    done <<< "$(grep -v '^#' "$GPU_CSV" | tail -n +2)"
    # 逐卡魔改检测结果（覆盖仅第一卡的汇总警告：混插/伪装时列出具体卡）
    if [ -n "${GPU_MEM_MISMATCH_CARDS:-}" ]; then
        GPU_MEM_SPEC_NOTE="⚠️ ${GPU_MEM_MISMATCH_CARDS%,} 检测显存与额定不符（疑似显存魔改或伪装，需核实）"
    fi
    GPU_DETAILS=$(printf '%b' "$GPU_DETAILS")
fi
# 每卡 VBIOS 固件版本（gpu_N_detail.log 的 VBIOS Version；交付核对固件用，明细表展示）
declare -A GPU_VBIOS_MAP
if [ -n "$GPU_DETAILS" ]; then
    for gf in "${GPU_DIR}"/gpu_*_detail.log; do
        [ -f "$gf" ] || continue
        gvb_idx=$(basename "$gf" | sed 's/^gpu_//; s/_detail\.log$//')
        gvb_ver=$(grep -m1 -E "VBIOS Version|Firmware Version" "$gf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
        [ -n "$gvb_ver" ] && GPU_VBIOS_MAP["$gvb_idx"]="$gvb_ver"
    done
    # 明细行追加第 11 列 VBIOS（映射不到置 N/A）
    GPU_DETAILS=$(while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gused glimit; do
        [ -z "$gidx" ] && continue
        echo "${gidx}|${gname}|${gsn}|${gmem}|${gdraw}|${gtemp}|${gutil}|${gpcie}|${gmax}|${gused}|${glimit}|${GPU_VBIOS_MAP[$gidx]:-N/A}"
    done <<< "$GPU_DETAILS")
fi
# ECC 模式与累计错误（列: 3=mode, 4-7=错误计数）
if [ -f "$GPU_ECC_CSV" ]; then
    GPU_ECC=$(grep -v "^#" "$GPU_ECC_CSV" | tail -n +2 | awk -F',' '{e+=$4+$5+$6+$7; mode=$3; gsub(/^ /,"",mode)} END{printf "%s, errors: %d", mode, e}')
fi
# GPU 序列号列表（资产追踪；消费卡 serial=0 时忽略）
GPU_SERIALS=$(grep -v "^#" "$GPU_CSV" 2>/dev/null | tail -n +2 | awk -F',' '{gsub(/^ +/,"",$3); gsub(/ +$/,"",$3); if($3!="" && $3!="0" && $3!="[N/A]") print $3}' | tr '\n' ',' | sed 's/,$//')

# ─── AMD GPU 解析（v1.46.1，ROCm）：nvidia GPU_CSV 无数据但 gpu_amd_inventory.json 存在时 ───
load_manifest "${GPU_DIR}" gpu_amd_inventory "gpu_amd_inventory.json"
if [ -z "$GPU_DETAILS" ] && [ -f "${gpu_amd_inventory}" ] 2>/dev/null; then
    AMD_JSON="${gpu_amd_inventory}"
    _amd_cards=$(grep -oE '"card[0-9]+"' "${AMD_JSON}" 2>/dev/null | sort -u)
    if [ -n "$_amd_cards" ]; then
        # v1.46.3+ 修复（v1.48.1 加固）：awk 逐卡提取——缓冲累积法，rocm-smi（每卡单行紧凑）与
        # amd-smi（ROCm 7+，pretty 多行）两种 JSON 格式都兼容：card 行起累积缓冲至下一 card 行
        # （或 EOF）后从缓冲整体提取字段（此前按"cardN 与字段同行"硬编码，amd-smi pretty 时字段全空）
        _amd_rows=$(awk '
            function emit() {
                if (buf == "") return
                cn=buf; sub(/.*"card/,"",cn); sub(/".*/,"",cn)
                an=buf; sub(/.*"Product Name":[[:space:]]*"/,"",an); sub(/".*/,"",an)
                uid=buf; sub(/.*"Unique ID":[[:space:]]*"/,"",uid); sub(/".*/,"",uid)
                mem=buf; sub(/.*"VRAM Total Memory \(B\)":[[:space:]]*"/,"",mem); sub(/".*/,"",mem)
                tmp=buf; sub(/.*"Temperature \(Sensor edge\) \(C\)":[[:space:]]*"/,"",tmp); sub(/".*/,"",tmp)
                pwr=buf; sub(/.*"Average Graphics Package Power Consumption \(W\)":[[:space:]]*"/,"",pwr); sub(/".*/,"",pwr)
                utl=buf; sub(/.*"GPU use \(%\)":[[:space:]]*"/,"",utl); sub(/".*/,"",utl)
                printf "%s|%s|%s|%s|%s|%s|%s\n", cn, an, uid, mem, tmp, pwr, utl
                buf=""
            }
            /"card[0-9]+"/ { emit(); buf=$0; next }
            { if (buf != "") buf = buf " " $0 }
            END { emit() }
        ' "${AMD_JSON}")
        GPU_COUNT=$(printf '%s\n' "$_amd_rows" | grep -c '|')
        GPU_NAMES=$(grep -oE '"Product Name": "[^"]*"' "${AMD_JSON}" | sort -u | head -3 | cut -d'"' -f4 | tr '\n' ',' | sed 's/,$//')
        GPU_MEM=$(grep -oE '"VRAM Total Memory \(B\)": "[0-9]+"' "${AMD_JSON}" | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%.0f GiB", s/1024/1024/1024}')
        GPU_DETAILS=""
        _ai=0
        while IFS='|' read -r _cardn _an _auid _amem _atmp _apwr _autl; do
            [ -z "$_cardn" ] && continue
            [ -z "$_amem" ] && _amem="0"
            # 魔改/伪装检测（v1.46.2）：统一 verify_gpu_mem（B→MiB 后双口径匹配）
            _aspec=""
            if [ -n "$_amem" ] && command -v verify_gpu_mem >/dev/null 2>&1; then
                _amem_mib=$(awk -v b="$_amem" 'BEGIN{printf "%.0f", b/1048576}')
                if verify_gpu_mem "$_an" "$_amem_mib"; then
                    _aspec="$VERIFY_MEM_SPEC"
                else
                    [ -n "$VERIFY_MEM_NOTE" ] && GPU_AMD_SUSPECT="${GPU_AMD_SUSPECT}卡${_cardn}(${_an} ${VERIFY_MEM_NOTE}); "
                fi
            fi
            _amem_gb=$(awk -v b="$_amem" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
            GPU_DETAILS="${GPU_DETAILS}${_ai}|${_an:-N/A}|${_auid:-N/A}|${_amem_gb}GB${_aspec:+/$_aspec}|${_apwr:-N/A} W|${_atmp:-N/A}|${_autl:-N/A}|N/A|N/A|N/A|N/A|N/A"$'\n'
            _ai=$((_ai + 1))
        done <<< "$_amd_rows"
        GPU_DETAILS=$(printf '%s' "$GPU_DETAILS" | sed '/^$/d')
        # 汇总：温度/功耗从明细聚合（字段 5=功耗 6=温度）
        GPU_TEMP=$(printf '%s
' "$GPU_DETAILS" | awk -F'|' '{gsub(/[^0-9.]/,"",$6); if($6+0>mx)mx=$6+0} END{if(mx>0) printf "%d°C", mx; else print "N/A"}')
        GPU_POWER=$(printf '%s
' "$GPU_DETAILS" | awk -F'|' '{gsub(/[^0-9.]/,"",$5); s+=$5} END{if(s>0) printf "%d W", s; else print "N/A"}')
        GPU_PLATFORM="amd"
        GPU_PCI_VENDOR="AMD"
    fi
fi

# ─── 昇腾 Atlas 附注（v1.47.0）：npu-smi 全量日志（info/board/HCCS topo/health）已落盘 ───
# HCCS 互联与健康判定解析【待真机校准】；当前统一 CSV 为 lspci 层（名称/BDF/PCIe 链路可判）
GPU_ASCEND_NOTE=""
if [ -f "${GPU_DIR}/gpu_ascend_hccs_topo.log" ] || [ -f "${GPU_DIR}/gpu_ascend_health.log" ]; then
    GPU_ASCEND_NOTE="昇腾 Atlas 采集（npu-smi info/board/HCCS 拓扑/health 全量日志已落盘；HCCS 互联与健康判定解析待真机校准）"
fi

# ─── AMD xGMI/Infinity Fabric 互联摘要（v1.48.0；adapter_amd 落盘 --showtopo 拓扑日志）───
# xGMI 链路健康判定【待真机校准】；当前做存在性摘要（有拓扑数据即显示，验收互联项据此 N/A 不计入）
GPU_XGMI_SUMMARY=""
if [ -f "${GPU_DIR}/gpu_amd_topo.log" ]; then
    _xlinks=$(grep -oiE "xGMI|XGMI" "${GPU_DIR}/gpu_amd_topo.log" 2>/dev/null | wc -l)
    if [ "${_xlinks:-0}" -gt 0 ] 2>/dev/null; then
        GPU_XGMI_SUMMARY="xGMI/Infinity Fabric 互联拓扑已采集（${_xlinks} 处 xGMI 标记；链路健康判定待真机校准）"
    else
        GPU_XGMI_SUMMARY="xGMI 拓扑日志已采集（未检出 xGMI 标记，解析待真机校准）"
    fi
fi
