#!/bin/bash
# =============================================================================
# HwScope - 变量解析：网络 IB/线缆 + BMC + SEL + 线缆配对
# report/sections/40_network_bmc.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# ─── 网络 ───
NET_DIR="${OUT}/network"
load_manifest "${NET_DIR}" ibstat "ibstat.log"
load_manifest "${NET_DIR}" ibdev2netdev "ibdev2netdev.log"
load_manifest "${NET_DIR}" nic_inventory "nic_inventory.csv"
load_manifest "${NET_DIR}" mst_notice "mst_notice.log"
# MST 未启动提示（Mellanox SN 兜底说明）
MST_NOTICE=""
[ -f "${mst_notice}" ] && MST_NOTICE=$(grep -v "^#" "${mst_notice}" | head -1)
# IB 设备口径（v1.44.0）：ibstat CA 含以太模式 CA（如 CX5 双口以太也被枚举为 CA，State: Down 属正常）
# ——真 IB 设备按 ibdev2netdev 映射到 ibp*/ibs* 接口的 CA 计数；无映射数据回退 ibstat CA 总数（旧口径）
IB_CA_LIST=""
if [ -f "${ibdev2netdev}" ]; then
    IB_CA_LIST=$(grep -v "^#" "${ibdev2netdev}" 2>/dev/null | awk '$5 ~ /^ibp[0-9]|^ibs/ {print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')
fi
if [ -n "$IB_CA_LIST" ]; then
    _ib_stats=$(awk -v cas="${IB_CA_LIST}" '
        BEGIN { n=split(cas, arr, ","); for (i=1; i<=n; i++) want[arr[i]]=1 }
        /^CA / { ca=substr($2, 2, length($2)-2); inib=(ca in want); if (inib) total++; next }
        inib && /State: Active/{active++}
        # v1.48.58：补 Initializing（IB 链路协商中，既非 Active 也非 Down）——此前漏计导致
        # "Active N / Down 0" 摘要与实际不符（其余口状态消失，易误读为仅 N 口有问题）
        inib && /State: Initializing/{init++}
        inib && /State: Down/{down++}
        END { printf "%d %d %d %d", total+0, active+0, init+0, down+0 }
    ' "${ibstat}" 2>/dev/null)
    read -r IB_COUNT IB_ACTIVE IB_INITIALIZING IB_LINK_DOWN <<< "${_ib_stats:-0 0 0 0}"
    # 未插线缆统计同样限定 IB CA（CX5 以太口 mlxlink "unplugged" 不算 IB 线缆缺失）
    # 排除 *_module.log / *_counters.log（同前缀的伴随文件，非链路主输出）
    IB_UNPLUGGED=$(for f in "${NET_DIR}"/mlxlink_mlx5_*.log; do
        [ -f "$f" ] || continue
        case "$f" in *_module.log|*_counters.log) continue;; esac
        _ca=$(basename "$f" .log | sed 's/^mlxlink_//')
        echo ",${IB_CA_LIST}," | grep -q ",${_ca}," || continue
        grep -c "Cable is unplugged" "$f" 2>/dev/null
    done | awk '{s+=$1} END{print s+0}')
else
    IB_COUNT=$(grep -c "^CA '" "${ibstat}" 2>/dev/null)
    IB_ACTIVE=$(grep -c "State: Active" "${ibstat}" 2>/dev/null)
    # v1.48.58：Initializing 单独计数（见上）
    IB_INITIALIZING=$(grep -c "State: Initializing" "${ibstat}" 2>/dev/null)
    # Link 状态统计：Down（未连）+ 未插线缆（mlxlink Recommendation，排除 module/counters 文件）
    IB_LINK_DOWN=$(grep -c "State: Down" "${ibstat}" 2>/dev/null)
    IB_UNPLUGGED=$(for f in "${NET_DIR}"/mlxlink_mlx5_*.log; do [ -f "$f" ] || continue; case "$f" in *_module.log|*_counters.log) continue;; esac; grep -c "Cable is unplugged" "$f" 2>/dev/null; done | awk '{s+=$1} END{print s+0}')
fi
# v1.48.58：Initializing=0 时留空——报告行按需显示（避免 "Initializing 0" 占位）
[ "${IB_INITIALIZING:-0}" -eq 0 ] 2>/dev/null && IB_INITIALIZING=""
# 活动口的速率分布（如 "100 Gb/s ×4"；无活动口显示 Down）
IB_ACTIVE_SPEED=""
if [ "${IB_ACTIVE:-0}" -gt 0 ] 2>/dev/null; then
    IB_ACTIVE_SPEED=$(grep -A2 "State: Active" "${ibstat}" 2>/dev/null | grep -iE "Rate:" | awk '{print $2}' | sort -n | uniq -c | awk '{printf "%s Gb/s ×%d ", $2, $1}' | sed 's/ $//')
fi
IB_SPEED=$(grep -A2 "State: Active" "${ibstat}" 2>/dev/null | grep -iE "Rate:" | awk '{print $2}' | sort -n | tail -1)
[ -n "$IB_SPEED" ] && IB_SPEED="${IB_SPEED} Gb/s"

# ─── IB 链路性能计数器（perfquery，v1.48.90）───
# 为什么必需：ibstat/ibstatus 只给链路状态与速率，**看不见误码**——「ACTIVE 400Gb」也可能是
#   在坏线缆/脏光模块上反复纠错才达成的。只有性能计数器能反映真实链路质量。
# 关注计数（非零即需留意，持续增长 = 线缆/光模块/交换机端口问题）：
#   SymbolErrorCounter 符号错误 / LinkDownedCounter 链路掉线次数 /
#   PortRcvErrors 接收错误 / PortXmitDiscards 发送丢弃 /
#   LocalLinkIntegrityErrors 本地链路完整性 / PortRcvRemotePhysicalErrors 对端物理错误。
# perfquery -x 每项形如 "SymbolErrorCounter:................0"，按冒号与点切分取末段数值。
IB_PERF_NONZERO=""; IB_PERF_COUNT=0
if [ -f "${NET_DIR}/perfquery.log" ]; then
    IB_PERF_NONZERO=$(grep -vE "^#|^$" "${NET_DIR}/perfquery.log" 2>/dev/null \
        | awk -F'[:.]+' '
            { k=$1; gsub(/[^A-Za-z]/,"",k)
              v=$NF; gsub(/[^0-9]/,"",v)
              if (k == "SymbolErrorCounter" || k == "LinkDownedCounter" || k == "PortRcvErrors" \
                  || k == "PortXmitDiscards" || k == "LocalLinkIntegrityErrors" \
                  || k == "PortRcvRemotePhysicalErrors" || k == "PortRcvSwitchRelayErrors") {
                  seen[k] += v
              } }
            END { for (x in seen) if (seen[x] + 0 > 0) printf "%s=%d ", x, seen[x] }
        ')
    IB_PERF_COUNT=$(printf '%s' "$IB_PERF_NONZERO" | grep -o '=' | wc -l)
fi

# 额定速率（卡能力，无需接线）：解析 mlxlink Enabled Link Speed 位图，取最大速率族
# Mellanox 位图: bit0=SDR(10G) bit1=DDR(20G) bit2=QDR(40G) bit3=FDR10(40G) bit4=FDR(56G)
#                bit5=EDR(100G) bit6=HDR(200G) bit7=NDR(400G) bit8=XDR(800G) bit9=GDR(1600G)
IB_NOMINAL="N/A"
_NOMINAL_SPEEDS=()
# 只统计 IB HCA 口（ibdev2netdev 映射 hca → ibp* 接口；CX5 以太的 mlxlink Enabled Link Speed 宣传 NDR 位，
# 混入会误判 400G NDR——v1.43.10 实测：mlx5_2/3=CX5 以太 0xf8f1f0d3 vs IB CX6 0x75）
_IB_HCAS=""
if [ -f "${NET_DIR}/ibdev2netdev.log" ]; then
    _IB_HCAS=$(grep -E "port 1.*==> ib" "${NET_DIR}/ibdev2netdev.log" 2>/dev/null | awk '{print $1}')
fi
for f in "${NET_DIR}"/mlxlink_mlx5_*.log; do
    [ -f "$f" ] || continue
    case "$f" in *_module.log|*_counters.log) continue;; esac
    _dev=$(basename "$f" | sed 's/mlxlink_//; s/\.log//')
    if [ -n "$_IB_HCAS" ] && ! echo "$_IB_HCAS" | grep -qw "$_dev"; then continue; fi
    _hex=$(grep -m1 "Enabled Link Speed" "$f" 2>/dev/null | grep -oE "0x[0-9a-fA-F]+" | head -1)
    [ -z "$_hex" ] && continue
    # 纯 bash 十六进制解码（兼容 mawk/gawk）
    _v=$((_hex & 0x3ff)) 2>/dev/null || continue
    # 解码最大速率族（从高位往下找第一个置位 bit）
    _nom="N/A"
    if [ $((_v & 0x200)) -ne 0 ]; then _nom="1600G (GDR)"
    elif [ $((_v & 0x100)) -ne 0 ]; then _nom="800G (XDR)"
    elif [ $((_v & 0x80)) -ne 0 ]; then _nom="400G (NDR)"
    elif [ $((_v & 0x40)) -ne 0 ]; then _nom="200G (HDR)"
    elif [ $((_v & 0x20)) -ne 0 ]; then _nom="100G (EDR)"
    elif [ $((_v & 0x10)) -ne 0 ]; then _nom="56G (FDR)"
    elif [ $((_v & 0x08)) -ne 0 ]; then _nom="40G (FDR10)"
    elif [ $((_v & 0x04)) -ne 0 ]; then _nom="40G (QDR)"
    elif [ $((_v & 0x02)) -ne 0 ]; then _nom="20G (DDR)"
    elif [ $((_v & 0x01)) -ne 0 ]; then _nom="10G (SDR)"
    fi
    _NOMINAL_SPEEDS+=("$_nom")
done
# 取所有口中最大额定速率
if [ "${#_NOMINAL_SPEEDS[@]}" -gt 0 ]; then
    for _s in "${_NOMINAL_SPEEDS[@]}"; do
        _g=$(echo "$_s" | grep -oE "^[0-9]+" || echo 0)
        _cur=$(echo "$IB_NOMINAL" | grep -oE "^[0-9]+" || echo 0)
        [ "${_g:-0}" -gt "${_cur:-0}" ] 2>/dev/null && IB_NOMINAL="$_s"
    done
fi
ETH_LINK_UP=$(grep -h "Link detected: yes" "${NET_DIR}"/ethtool_*.log 2>/dev/null | wc -l)

# 线缆类型检测（DAC 铜缆 / 光模块 / 空口）
CABLE_SUMMARY=""
for f in "${NET_DIR}"/mlxlink_mlx5_*_module.log; do
    [ -f "$f" ] || continue
    dev=$(basename "$f" | sed 's/mlxlink_\(.*\)_module.log/\1/')
    [ -z "$dev" ] && continue
    cable=$(grep -iE "Cable Type|cable type" "$f" | head -1 | cut -d':' -f2- | tr -d ' \t')
    if [ -n "$cable" ] && [ "$cable" != "N/A" ]; then
        case "$cable" in
            *Copper*) CABLE_SUMMARY="${CABLE_SUMMARY}${dev}:DAC," ;;
            *Optical*|*Fiber*) CABLE_SUMMARY="${CABLE_SUMMARY}${dev}:Optical," ;;
            *) CABLE_SUMMARY="${CABLE_SUMMARY}${dev}:${cable}," ;;
        esac
    fi
done
CABLE_SUMMARY=$(echo "$CABLE_SUMMARY" | sed 's/,$//')

# ─── v1.48.58：IB 固件一致性检查（只提示、不判定） ───
# 动机：同 part_number + 同 PSID 的卡本应固件统一。实测 B300 机器 8 张 MCX75310AAS-NEAT
# (PSID MT_0000000838) 出现 3 种固件（28.39.4082×5 / 28.41.1000×1 / 28.43.3608×2），
# 报告中毫无提示。口径刻意保守：仅"同型号+同 PSID"分组内出现多于 1 个固件版本时提示，
# 措辞为"建议核对"——批次混装/分批升级属正常可能，因此不进验收红绿灯、不作故障判定。
IB_FW_INCONSISTENT=""
if [ -f "${NET_DIR}/nic_inventory.csv" ]; then
    IB_FW_INCONSISTENT=$(grep -v "^#" "${NET_DIR}/nic_inventory.csv" 2>/dev/null | \
        awk -F'|' '$9 ~ /^MT_/ && $5 != "" && $6 != "" { v=$6; sub(/ \(.*/, "", v); print $5 "|" $9 "|" v }' | \
        sort -u | \
        awk -F'|' '{ k=$1 "|" $2; c[k]++; v[k]=v[k] (c[k]>1 ? "、" : "") $3 }
                   END { for (k in c) if (c[k] > 1) { split(k, p, "|"); printf "%s (%s) %d 种: %s; ", p[1], p[2], c[k], v[k] } }' \
        2>/dev/null | sed 's/; $//')
fi

# ─── v1.48.58：IB 链路质量（物理计数器与 BER；仅展示原始数值，不作 pass/fail 判定） ───
# 数据源：mlxlink -c 的 "Physical Counters and BER Info"（Symbol/Raw Physical BER、Link Down Counter）
# 说明：Raw Physical BER 含未纠错前的原始误码，NDR 下受 FEC 保护，正常机器也可能非零——
#       故只呈现数值供对比，不设阈值、不进验收项，避免误判。
IB_BER_SUMMARY=""
IB_LINK_DOWN_EVENTS=0
for f in "${NET_DIR}"/mlxlink_mlx5_*_counters.log; do
    [ -f "$f" ] || continue
    _bd=$(basename "$f" | sed 's/^mlxlink_//; s/_counters\.log$//')
    _ber=$(grep -m1 "Raw Physical BER" "$f" 2>/dev/null | awk -F':' '{print $NF}' | tr -d ' \t')
    _ldc=$(grep -m1 "Link Down Counter" "$f" 2>/dev/null | awk -F':' '{print $NF}' | tr -d ' \t')
    # 过滤 mlxlink 无效哨兵：15E-255 为下溢/未初始化占位（非真实误码，避免误读为"极低误码"）；
    # 通用判据 = 指数 > 40 视为无效
    _exp=$(printf '%s' "$_ber" | sed -n 's/.*[Ee]-\([0-9]*\)$/\1/p')
    if [ -n "$_exp" ] && [ "$_exp" -gt 40 ] 2>/dev/null; then _ber=""; fi
    [ -n "$_ldc" ] && [ "$_ldc" -eq "$_ldc" ] 2>/dev/null && IB_LINK_DOWN_EVENTS=$((IB_LINK_DOWN_EVENTS + _ldc))
    [ -n "$_ber" ] && [ "$_ber" != "0" ] && IB_BER_SUMMARY="${IB_BER_SUMMARY}${_bd}:${_ber} "
done
IB_BER_SUMMARY=$(echo "$IB_BER_SUMMARY" | sed 's/ $//')

# ─── BMC ───
BMC_DIR="${OUT}/bmc"
load_manifest "${BMC_DIR}" ipmi_fru_summary "ipmi_fru_summary.log"
load_manifest "${BMC_DIR}" ipmi_mc "ipmi_mc.log"
load_manifest "${BMC_DIR}" ipmi_lan1 "ipmi_lan1.log"
load_manifest "${BMC_DIR}" ipmi_lan_all "ipmi_lan_all.log"
load_manifest "${BMC_DIR}" ipmi_sel_elist "ipmi_sel_elist.log"
load_manifest "${BMC_DIR}" redfish_system "redfish_system.log"
BMC_FRU=$(extract "Product Name|Product Part Number" "${ipmi_fru_summary}" | head -c 80)
BMC_FW=$(extract "Firmware Revision" "${ipmi_mc}")
# v1.48.46：Redfish FirmwareInventory——AMI BMC 固件完整版（ipmitool mc info 只给主次 1.01，
# FirmwareInventory 给完整号如 1.01.00）；BIOS/CPLD/PSU 成员 Version 空 = AMI 实现不填——如实标注不伪造
load_manifest "${BMC_DIR}" redfish_fw_versions "redfish_fw_versions.log"
RF_FW_BMC=""; RF_FW_BIOS=""; RF_FW_CPLD=""; RF_FW_PSU=""; RF_FW_OTHER=""
if [ -f "${redfish_fw_versions}" ]; then
    while IFS='|' read -r _rfname _rfver; do
        [ -z "$_rfname" ] && continue
        _rfver=$(echo "$_rfver" | tr -d ' \r')
        case "$_rfname" in
            BMCImage*) [ -n "$_rfver" ] && RF_FW_BMC="$_rfver" ;;
            BIOS)      [ -n "$_rfver" ] && RF_FW_BIOS="$_rfver" ;;
            CPLD)      [ -n "$_rfver" ] && RF_FW_CPLD="$_rfver" ;;
            PSU)       [ -n "$_rfver" ] && RF_FW_PSU="$_rfver" ;;
            *)         [ -n "$_rfver" ] && RF_FW_OTHER="${RF_FW_OTHER}${_rfname}=${_rfver}, " ;;
        esac
    done < "${redfish_fw_versions}"
fi
# Redfish 完整版优先（比 ipmitool 主次号信息量大）；空则回退 ipmitool
[ -n "$RF_FW_BMC" ] && BMC_FW="$RF_FW_BMC"
# v1.48.31：BMC 管理 IP 多通道——lan print 1 可能是 Shared 口（DHCP 未接=0.0.0.0），Dedicated 管理口
# 通道不定（Compal/AMI 常见通道 8；lan_all 遍历 1-14）——取首个有效地址（非 0.0.0.0/非 169.254 APIPA）
BMC_IP="0.0.0.0"; BMC_MAC=""
for _lf in "${ipmi_lan1}" "${ipmi_lan2}" "${ipmi_lan_all}"; do
    [ -f "$_lf" ] || continue
    # 有效管理地址（非 0.0.0.0/非 169.254 APIPA）→ 采用并结束；仅 0.0.0.0/APIPA → 记录但不结束（继续找 Dedicated 通道）
    _lip=$(grep "IP Address " "$_lf" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | grep -vE "^(0\.0\.0\.0|169\.254\.)" | head -1)
    if [ -n "$_lip" ]; then
        BMC_IP="$_lip"
        # MAC 取 _lip 所在通道段（lan_all 多通道：=== Channel 8 === 段内 MAC；单通道文件直接取首个）
        _lm=$(awk -v ip="$_lip" '/=== Channel/{inseg=0} $0 ~ ip {inseg=1} inseg && /MAC Address/{print $NF; exit}' "$_lf" 2>/dev/null)
        [ -z "$_lm" ] && _lm=$(grep -m1 "MAC Address" "$_lf" 2>/dev/null | awk '{print $NF}')
        [ -n "$_lm" ] && BMC_MAC="$_lm"
        break
    elif [ "$BMC_IP" = "0.0.0.0" ]; then
        _lip0=$(grep "IP Address " "$_lf" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        if [ -n "$_lip0" ]; then
            BMC_IP="$_lip0"
            _lm=$(awk -v ip="$_lip0" '/=== Channel/{inseg=0} $0 ~ ip {inseg=1} inseg && /MAC Address/{print $NF; exit}' "$_lf" 2>/dev/null)
            [ -z "$_lm" ] && _lm=$(grep -m1 "MAC Address" "$_lf" 2>/dev/null | awk '{print $NF}')
            [ -n "$_lm" ] && BMC_MAC="$_lm"
        fi
    fi
done
# SEL 数据有效性（采集失败时统计全为 0，验收不能判 PASS，须区分"无数据"）
SEL_DATA_VALID=0
if [ -f "${ipmi_sel_elist}" ]; then
    _sel_err=$(grep -iE "Could not open|Unable|No such file|command failed|device at /dev" "${ipmi_sel_elist}" 2>/dev/null | head -1)
    [ -z "$_sel_err" ] && SEL_DATA_VALID=1
fi
SEL_TOTAL=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | wc -l)

# ─── BMC 平台可用性（v1.40.7）───
# 非所有机器都有 BMC（传统服务器/虚拟机/部分平台）。依赖 IPMI 传感器的验收项
# （电源冗余/整机温度/风扇冗余）在"平台无 BMC"时应判 N/A 且不计入数据不足，
# 与 GPU 项对无 GPU 机头同语义。判定（对齐 OS-BMC 项）：
#   有 ipmi_*.log 且非全错误 → BMC 存在（BMC_PRESENT=1）
#   有 ipmi_*.log 但全错误   → 平台无 BMC（固有形态，不计数）
#   无任何 ipmi_*.log        → ipmitool 未装/模块关（如实计数）
BMC_LOG_EXISTS=0; BMC_PRESENT=0
if ls "${BMC_DIR}"/ipmi_*.log >/dev/null 2>&1; then
    BMC_LOG_EXISTS=1
    if ! grep -qiE "Could not open|Unable|No such file|command failed|device at /dev" "${BMC_DIR}"/ipmi_*.log 2>/dev/null; then
        BMC_PRESENT=1
    fi
fi
SEL_CRIT=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | grep -ciE "critical|fatal")
SEL_PCIE_ERR=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | grep -icE "pcie|aer|uncorrectable")

# ─── v1.48.86：SEL 告警终态（未解除 / 已自愈）───
# SEL 的 Asserted/Deasserted 是**同一事件的进入/解除两态**：同「传感器 + 事件类型」出现
# Deasserted 即表示该项已恢复正常。旧实现只用 `grep -ciE "critical|fatal"` 数行，
# 会把 Deasserted 行（其事件描述里同样含 "Critical" 字样）也算作告警 ——
# 实测 A100 机 2022 年风扇瞬停事件 4 条（2 Asserted + 2 Deasserted，19 秒后自愈）
# 被报成"2 条 Critical"→ FAIL，判定与事实相反。
# 规则：Critical 级 Asserted 事件，若存在同键 Deasserted → 已自愈（SEL_CRIT_RECOVERED），
#       否则视为当前仍未解除（SEL_CRIT_UNRESOLVED，才是真故障）。
# 累积型事件（Uncorrectable ECC 等）天然没有 Deassert 配对，会自动落到 UNRESOLVED，规则自洽。
SEL_CRIT_UNRESOLVED=0
SEL_CRIT_RECOVERED=0
if [ -f "${ipmi_sel_elist}" ]; then
    _sel_stat=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null \
        | grep -vE "Could not open|Unable|No such file|command failed|device at /dev|^$" \
        | awk -F'|' '
            NF>=6 {
                s=$4; e=$5; st=$6
                gsub(/^ +| +$/,"",s); gsub(/^ +| +$/,"",e); gsub(/^ +| +$/,"",st)
                k=s"|"e
                if (st=="Deasserted") { rel[k]=1; store[++m]=k; next }
                if (st=="Asserted" && tolower(e) ~ /critical|fatal|non-recoverable|nonrecoverable/) {
                    crit[k]=1; order[++n]=k
                }
            }
            END {
                u=0; r=0
                for (i=1;i<=n;i++) { if (order[i] in rel) r++; else u++ }
                printf "%d %d", u, r
            }')
    SEL_CRIT_UNRESOLVED="${_sel_stat%% *}"
    SEL_CRIT_RECOVERED="${_sel_stat##* }"
    : "${SEL_CRIT_UNRESOLVED:=0}"; : "${SEL_CRIT_RECOVERED:=0}"
fi
# 已解除事件的日期（供报告文案标注"何时自愈"）
SEL_RECOVERED_WHEN=""
if [ "${SEL_CRIT_RECOVERED:-0}" -gt 0 ] 2>/dev/null; then
    SEL_RECOVERED_WHEN=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null \
        | grep -vE "Could not open|Unable|No such file|command failed|device at /dev|^$" \
        | awk -F'|' '{st=$6; gsub(/^ +| +$/,"",st); if(st=="Deasserted"){d=$2; gsub(/^ +| +$/,"",d); print d}}' \
        | sort -u | head -1)
fi

# SEL 告警级事件明细（只列 Critical/Error/PCIe/告警类，过滤 Boot/Timestamp 等常规噪声事件）
SEL_DETAILS=""
if [ -f "${ipmi_sel_elist}" ]; then
    SEL_DETAILS=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev|^$" | grep -iE "critical|fatal|warning|error|fail|pcie|aer|uncorrectable|uncorrected|thermal|voltage|power fault" | tail -20 | awk -F'|' '{
        gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3)
        gsub(/^ +| +$/,"",$4); gsub(/^ +| +$/,"",$5); gsub(/^ +| +$/,"",$6)
        if($2!="") printf "%d|%s|%s|%s|%s\n", NR, $2, $3, $4, $5
    }')
fi

# ─── 线缆配对检测（同一根线两端 EEPROM serial 相同） ───
CABLE_PAIRS=""
declare -A CABLE_SERIALS
for f in "${NET_DIR}"/mlxlink_mlx5_*_module.log; do
    [ -f "$f" ] || continue
    dev=$(basename "$f" | sed 's/mlxlink_\(.*\)_module.log/\1/')
    [ -z "$dev" ] && continue
    serial=$(grep -iE "Serial Number|serial number" "$f" | head -1 | cut -d':' -f2- | tr -d ' \t')
    [ -z "$serial" ] || [ "$serial" = "N/A" ] && continue
    if [ -n "${CABLE_SERIALS[$serial]}" ]; then
        CABLE_PAIRS="${CABLE_PAIRS}${CABLE_SERIALS[$serial]}↔${dev},"
    else
        CABLE_SERIALS[$serial]="$dev"
    fi
done
CABLE_PAIRS=$(echo "$CABLE_PAIRS" | sed 's/,$//')
