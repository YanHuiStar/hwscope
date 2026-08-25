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
# IB 设备总数（CA 数量）与活动口数（State: Active）分开统计——"设备数"≠"活动口数"
IB_COUNT=$(grep -c "^CA '" "${ibstat}" 2>/dev/null)
IB_ACTIVE=$(grep -c "State: Active" "${ibstat}" 2>/dev/null)
# Link 状态统计：Down（未连）+ 未插线缆（mlxlink Recommendation，排除 module 文件）
IB_LINK_DOWN=$(grep -c "State: Down" "${ibstat}" 2>/dev/null)
IB_UNPLUGGED=$(for f in "${NET_DIR}"/mlxlink_mlx5_*.log; do [ -f "$f" ] || continue; case "$f" in *_module.log) continue;; esac; grep -c "Cable is unplugged" "$f" 2>/dev/null; done | awk '{s+=$1} END{print s+0}')
# 活动口的速率分布（如 "100 Gb/s ×4"；无活动口显示 Down）
IB_ACTIVE_SPEED=""
if [ "${IB_ACTIVE:-0}" -gt 0 ] 2>/dev/null; then
    IB_ACTIVE_SPEED=$(grep -A2 "State: Active" "${ibstat}" 2>/dev/null | grep -iE "Rate:" | awk '{print $2}' | sort -n | uniq -c | awk '{printf "%s Gb/s ×%d ", $2, $1}' | sed 's/ $//')
fi
IB_SPEED=$(grep -A2 "State: Active" "${ibstat}" 2>/dev/null | grep -iE "Rate:" | awk '{print $2}' | sort -n | tail -1)
[ -n "$IB_SPEED" ] && IB_SPEED="${IB_SPEED} Gb/s"

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

# ─── BMC ───
BMC_DIR="${OUT}/bmc"
load_manifest "${BMC_DIR}" ipmi_fru_summary "ipmi_fru_summary.log"
load_manifest "${BMC_DIR}" ipmi_mc "ipmi_mc.log"
load_manifest "${BMC_DIR}" ipmi_lan1 "ipmi_lan1.log"
load_manifest "${BMC_DIR}" ipmi_sel_elist "ipmi_sel_elist.log"
load_manifest "${BMC_DIR}" redfish_system "redfish_system.log"
BMC_FRU=$(extract "Product Name|Product Part Number" "${ipmi_fru_summary}" | head -c 80)
BMC_FW=$(extract "Firmware Revision" "${ipmi_mc}")
BMC_IP=$(grep "IP Address" "${ipmi_lan1}" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
BMC_MAC=$(grep -m1 "MAC Address" "${ipmi_lan1}" 2>/dev/null | awk '{print $NF}')
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
