#!/bin/bash
# =============================================================================
# HwScope — 报告生成器
# tools/report.sh
# 用法: bash tools/report.sh [output_dir] [--md|--json|--both]
# 功能: 从采集日志提取关键信息，生成 .md + .json 汇总报告
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

# ─── 定位输出目录 ───
if [ -n "$1" ] && [ -d "$1" ]; then
    OUT="$1"
else
    OUT=$(ls -dt "${SCRIPT_DIR}/output"/*/ 2>/dev/null | head -1 | sed 's|/$||')
fi
[ -z "$OUT" ] || [ ! -d "$OUT" ] && echo -e "${RED}[ERROR] 未找到采集目录: $OUT${NC}" && exit 1

FORMAT="${2:-both}"
echo -e "${CYAN}[REPORT] 解析目录: ${OUT}${NC}"

# ─── 提取辅助：从日志取字段（第一个匹配，去注释，保留冒号后全部） ───
extract() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { echo ""; return; }
    grep -iE "$pattern" "$file" 2>/dev/null | grep -v "^#" | head -1 | cut -d':' -f2- | tr -d ' \t' | head -c 200
}

# ─── 收集基础信息 ───
SUMMARY="${OUT}/summary.txt"
HOSTNAME=$(extract "Hostname" "$SUMMARY")
VERSION=$(extract "Version" "$SUMMARY")
[ -z "$VERSION" ] && VERSION="N/A"   # 老版本采集数据无 Version 行
PLATFORM=$(grep -m1 "^Platform" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
TIMESTAMP=$(grep -m1 "^Timestamp" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | sed 's/^ //')

# ─── 环境（OS/内核/驱动/CUDA） ───
OS_DIR="${OUT}/os"
OS_NAME=$(grep -m1 "PRETTY_NAME" "${OS_DIR}/os-release.log" 2>/dev/null | cut -d'"' -f2)
KERNEL=$(grep -m1 -v "^#" "${OS_DIR}/uname.log" 2>/dev/null | awk '{print $3}')
GPU_DRIVER=$(grep -m1 "Driver Version" "${OUT}/gpu/gpu_full.log" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
GPU_CUDA=$(grep -m1 "CUDA Version" "${OUT}/gpu/gpu_full.log" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')

# ─── 主板 ───
MB_DIR="${OUT}/motherboard"
MB_MANUFACTURER=$(extract "Manufacturer" "${MB_DIR}/dmidecode_system.log")
MB_PRODUCT=$(extract "Product Name" "${MB_DIR}/dmidecode_system.log")
MB_SN=$(extract "Serial Number" "${MB_DIR}/dmidecode_system.log")
BIOS_VERSION=$(extract "Version" "${MB_DIR}/dmidecode_bios.log" | head -c 80)
CHASSIS_SN=$(extract "Serial Number" "${MB_DIR}/dmidecode_chassis.log")

# ─── CPU ───
CPU_DIR="${OUT}/cpu"
CPU_MODEL=$(grep -m1 -iE "^model name" "${CPU_DIR}/cpu_summary.log" 2>/dev/null | cut -d':' -f2- | tr -d '\t' | sed 's/^ *//' | head -c 100)
CPU_CORES=$(grep -m1 -iE "^cpu cores|^Core Count" "${CPU_DIR}/cpu_summary.log" 2>/dev/null | cut -d':' -f2- | tr -d ' \t')
CPU_SOCKETS=$(grep "physical id" "${CPU_DIR}/proc_cpuinfo_full.log" 2>/dev/null | cut -d':' -f2- | sort -u | wc -l)
CPU_MAX_SPEED=$(grep -m1 "Max Speed" "${CPU_DIR}/dmidecode_processor.log" 2>/dev/null | awk '{print $(NF-1)}')
[ -z "$CPU_MAX_SPEED" ] && CPU_MAX_SPEED=$(grep -m1 "CPU max MHz" "${CPU_DIR}/lscpu.log" 2>/dev/null | awk '{print $NF}')
CPU_CUR_SPEED=$(grep -m1 "Current Speed" "${CPU_DIR}/dmidecode_processor.log" 2>/dev/null | awk '{print $(NF-1)}')
[ -z "$CPU_CUR_SPEED" ] && CPU_CUR_SPEED=$(grep -m1 "CPU MHz" "${CPU_DIR}/lscpu.log" 2>/dev/null | awk '{print $NF}')

# ─── 内存 ───
MEM_DIR="${OUT}/memory"
MEM_TOTAL=$(grep -m1 "MemTotal" "${MEM_DIR}/proc_meminfo.log" 2>/dev/null | awk '{printf "%.1f GB", $2/1024/1024}')
MEM_SPEED=$(extract "Configured Clock Speed|Speed:" "${MEM_DIR}/dmidecode_memory_full.log")
MEM_SLOTS=$(grep -c "Memory Device" "${MEM_DIR}/dmidecode_memory_full.log" 2>/dev/null)
MEM_POPULATED=$(grep -cE "^[[:space:]]*Size: [0-9]" "${MEM_DIR}/dmidecode_memory_full.log" 2>/dev/null)
# 每槽 DIMM 明细（插槽|容量|厂商|SN|部件号|原速率|现速率），空槽跳过
# 行模式状态机：从 "Memory Device" 段头开始，空行结束（Size 行在 Locator 之前）
MEM_DIMMS=""
if [ -f "${MEM_DIR}/dmidecode_memory_full.log" ]; then
    MEM_DIMMS=$(awk '
        /^Memory Device/ { in_dimm=1; slot=""; size=""; mfr=""; sn=""; pn=""; cspd=""; spd=""; next }
        in_dimm && /^[[:space:]]*Locator:/ && !/Bank Locator/ {slot=$0;  sub(/^[[:space:]]*Locator:[[:space:]]*/,"",slot); next}
        in_dimm && /^[[:space:]]*Size:/              {size=$0; sub(/^[[:space:]]*Size:[[:space:]]*/,"",size); sub(/ No Module.*/,"",size); next}
        in_dimm && /^[[:space:]]*Manufacturer:/      {mfr=$0;  sub(/^[[:space:]]*Manufacturer:[[:space:]]*/,"",mfr); next}
        in_dimm && /^[[:space:]]*Serial Number:/     {sn=$0;   sub(/^[[:space:]]*Serial Number:[[:space:]]*/,"",sn); next}
        in_dimm && /^[[:space:]]*Part Number:/       {pn=$0;   sub(/^[[:space:]]*Part Number:[[:space:]]*/,"",pn); sub(/[[:space:]]+$/,"",pn); next}
        in_dimm && /^[[:space:]]*Speed:/             {spd=$0;  sub(/^[[:space:]]*Speed:[[:space:]]*/,"",spd); next}
        in_dimm && /^[[:space:]]*Configured Memory Speed:/ {cspd=$0; sub(/^[[:space:]]*Configured Memory Speed:[[:space:]]*/,"",cspd); next}
        in_dimm && /^[[:space:]]*$/ { if(size!="") printf "%s|%s|%s|%s|%s|%s|%s\n", slot, size, mfr, sn, pn, cspd, spd; in_dimm=0 }
    ' "${MEM_DIR}/dmidecode_memory_full.log" 2>/dev/null)
fi

# ─── GPU（解析 inventory.csv；列: 1=idx 2=name 3=serial 4=bdf 5=uuid 6=mem.total 7=mem.used 8=power.limit 9=power.draw 10=temp 11=util 12-13=clocks 14=ecc.mode 15=gen.cur 16=width.cur 17=gen.max 18=width.max） ───
GPU_CSV="${OUT}/gpu/gpu_inventory.csv"
GPU_ECC_CSV="${OUT}/gpu/gpu_ecc_inventory.csv"
GPU_COUNT=0; GPU_NAMES=""; GPU_MEM=""; GPU_POWER=""; GPU_TEMP=""; GPU_ECC=""; GPU_DETAILS=""; GPU_DEGRADED=""
if [ -f "$GPU_CSV" ]; then
    GPU_COUNT=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | wc -l)
    GPU_NAMES=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -F',' '{print $2}' | sed 's/^ *//;s/ *$//' | sort -u | tr '\n' ',' | sed 's/,$//')
    # 显存总量 / 功耗上限 / 温度
    GPU_MEM=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -F',' '{gsub(/ MiB/,"",$6); sum+=$6} END{printf "%.0f GB", sum/1024}')
    GPU_POWER=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -F',' '{gsub(/ W/,"",$8); if($8+0>max+0) max=$8} END{printf "%.0f W", max}')
    GPU_TEMP=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -F',' '{t=(NF>=17)?$10:$9; sum+=t; if(t+0>tmax+0) tmax=t} END{printf "%.0f°C (max %.0f)", sum/NR, tmax}')
    # 每卡明细行（兼容新旧 CSV：新 18 列含 PCIe/利用率，旧 12 列降级为 N/A）
    while IFS=',' read -r gidx gname gsn gbdf guuid gmem gused glimit gdraw gtemp gutil gclk gcclk gecc ggen gwidth ggenmax gwidthmax; do
        gname=$(echo "$gname" | sed 's/^ *//;s/ *$//')
        gsn=$(echo "$gsn" | sed 's/^ *//;s/ *$//')
        gmem_f=$(echo "$gmem" | tr -d ' ')
        gdraw_f=$(echo "$gdraw" | tr -d ' ')
        gtemp_f=$(echo "$gtemp" | tr -d ' ')
        gutil_f=$(echo "$gutil" | tr -d ' ')
        gwidth=$(echo "$gwidth" | tr -d ' ')
        gwidthmax=$(echo "$gwidthmax" | tr -d ' ')
        ggen=$(echo "$ggen" | tr -d ' ')
        ggenmax=$(echo "$ggenmax" | tr -d ' ')
        # 旧 12 列 CSV 无 PCIe/利用率字段 → 识别并置 N/A（旧列: $9=temp $10=clk $11=clk $12=ecc）
        if [ -z "$ggen" ] && [ -z "$gwidth" ]; then
            gtemp_f="$gdraw"    # 旧布局 $9 是温度（被 gdraw 变量接住）
            ggen="N/A"; gwidth="N/A"; ggenmax="N/A"; gwidthmax="N/A"
            gutil_f="N/A"; gdraw_f="N/A"
        fi
        [ -n "$gtemp_f" ] && [ "$gtemp_f" != "N/A" ] && [ "$gtemp_f" != "[N/A]" ] && gtemp_f="${gtemp_f}°C"
        # GPU 卡板号（从每卡 detail.log 提取 Board Part Number）
        gbpn="N/A"
        [ -f "${OUT}/gpu/gpu_${gidx}_detail.log" ] && gbpn=$(grep -m1 "Board Part Number" "${OUT}/gpu/gpu_${gidx}_detail.log" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
        # PCIe 显示：两侧都 N/A 时合并为单个 N/A（避免 N/A/N/A/N/A/N/A）
        gpcie_cur="N/A"; gpcie_max="N/A"
        [ "$ggen" != "N/A" ] && [ -n "$ggen" ] && gpcie_cur="${ggen}x${gwidth}"
        [ "$ggenmax" != "N/A" ] && [ -n "$ggenmax" ] && gpcie_max="${ggenmax}x${gwidthmax}"
        [ "$gpcie_cur" = "N/A" ] && [ "$gpcie_max" != "N/A" ] && gpcie_cur="?"
        GPU_DETAILS="${GPU_DETAILS}${gidx}|${gname}|${gsn}|${gmem_f}|${gdraw_f}|${gtemp_f}|${gutil_f}|${gpcie_cur}|${gpcie_max}|${gbpn}"$'\n'
        # PCIe 宽度降级检测（宽度空闲不变，是最可靠信号；gen 低可能是省电不算）
        if [ -n "$gwidth" ] && [ -n "$gwidthmax" ] && [ "$gwidth" != "[N/A]" ] && [ "$gwidthmax" != "[N/A]" ] && [ "$gwidth" -lt "$gwidthmax" ] 2>/dev/null; then
            GPU_DEGRADED="${GPU_DEGRADED}GPU${gidx}: PCIe ${ggen}x${gwidth} (期望 ${ggenmax}x${gwidthmax}),"
        fi
    done <<< "$(grep -v '^#' "$GPU_CSV" | tail -n +2)"
    GPU_DETAILS=$(printf '%b' "$GPU_DETAILS")
fi
# ECC 模式与累计错误（列: 3=mode, 4-7=错误计数）
if [ -f "$GPU_ECC_CSV" ]; then
    GPU_ECC=$(grep -v "^#" "$GPU_ECC_CSV" | tail -n +2 | awk -F',' '{e+=$4+$5+$6+$7; mode=$3; gsub(/^ /,"",mode)} END{printf "%s, errors: %d", mode, e}')
fi
# GPU 序列号列表（资产追踪；消费卡 serial=0 时忽略）
GPU_SERIALS=$(grep -v "^#" "$GPU_CSV" 2>/dev/null | tail -n +2 | awk -F',' '{gsub(/^ +/,"",$3); gsub(/ +$/,"",$3); if($3!="" && $3!="0" && $3!="[N/A]") print $3}' | tr '\n' ',' | sed 's/,$//')
# 汇总表 SN 截断（完整列表在每卡明细），避免表格超宽换行
GPU_SERIALS_SHORT="N/A"
if [ -n "$GPU_SERIALS" ] && [ "$GPU_SERIALS" != "N/A" ]; then
    GPU_SERIALS_SHORT=$(echo "$GPU_SERIALS" | cut -d',' -f1-2)" … 共 ${GPU_COUNT} 个"
fi

# ─── 存储（只统计物理盘 TYPE=disk，避免把分区/LVM 计入容量） ───
STO_DIR="${OUT}/storage"
STORAGE_COUNT=0; STORAGE_TOTAL="N/A"; STORAGE_MODELS=""
if [ -f "${STO_DIR}/block_devices_all.log" ]; then
    STORAGE_COUNT=$(grep -v "^#" "${STO_DIR}/block_devices_all.log" | awk '$NF=="disk"' | wc -l)
    STORAGE_TOTAL=$(grep -v "^#" "${STO_DIR}/block_devices_all.log" | awk '$NF=="disk" {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/) {v=$i; break}; \
        n=substr(v,1,length(v)-1); u=substr(v,length(v)); \
        if(u=="T")s+=n*1024; else if(u=="G")s+=n; else if(u=="M")s+=n/1024; else if(u=="K")s+=n/1024/1024} \
        END{printf "%.0f GB", s}' 2>/dev/null)
    STORAGE_MODELS=$(grep -v "^#" "${STO_DIR}/block_devices_all.log" | awk '$NF=="disk" {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/) {for(j=2;j<i;j++) m=m" "$j; break}} END{print m}' | sed 's/^ //' | sort -u | sed 's/\(^.\{40\}\).*/\1…/' | tr '\n' ',' | sed 's/,$//')
fi

# ─── 网络 ───
NET_DIR="${OUT}/network"
IB_COUNT=$(grep -c "State: Active" "${NET_DIR}/ibstat.log" 2>/dev/null)
IB_SPEED=$(grep -A2 "State: Active" "${NET_DIR}/ibstat.log" 2>/dev/null | grep -iE "Rate:" | awk '{print $2}' | sort -n | tail -1)
[ -n "$IB_SPEED" ] && IB_SPEED="${IB_SPEED} Gb/s"
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
BMC_FRU=$(extract "Product Name|Product Part Number" "${BMC_DIR}/ipmi_fru_summary.log" | head -c 80)
BMC_FW=$(extract "Firmware Revision" "${BMC_DIR}/ipmi_mc.log")
BMC_IP=$(grep "IP Address" "${BMC_DIR}/ipmi_lan1.log" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
BMC_MAC=$(grep -m1 "MAC Address" "${BMC_DIR}/ipmi_lan1.log" 2>/dev/null | awk '{print $NF}')
SEL_TOTAL=$(grep -v "^#" "${BMC_DIR}/ipmi_sel_elist.log" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | wc -l)
SEL_CRIT=$(grep -v "^#" "${BMC_DIR}/ipmi_sel_elist.log" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | grep -ciE "critical|fatal")
SEL_PCIE_ERR=$(grep -v "^#" "${BMC_DIR}/ipmi_sel_elist.log" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | grep -icE "pcie|aer|uncorrectable")

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

# 端口模式汇总（mlxconfig_*_linktype.log：每口 IB/ETH 模式）
LINKTYPE_SUMMARY=""
for f in "${NET_DIR}"/mlxconfig_*_linktype.log; do
    [ -f "$f" ] || continue
    cfg_dev=$(basename "$f" | sed 's/mlxconfig_\(.*\)_linktype.log/\1/')
    [ -z "$cfg_dev" ] && continue
    p1=$(grep "LINK_TYPE_P1" "$f" | awk '{print $2}' | head -1)
    p2=$(grep "LINK_TYPE_P2" "$f" | awk '{print $2}' | head -1)
    [ -z "$p1" ] && [ -z "$p2" ] && continue
    LINKTYPE_SUMMARY="${LINKTYPE_SUMMARY}${cfg_dev}:P1=${p1:-N/A} P2=${p2:-N/A},"
done
LINKTYPE_SUMMARY=$(echo "$LINKTYPE_SUMMARY" | sed 's/,$//')

# ─── 风扇（IPMI 传感器，| 分隔格式） ───
FAN_DIR="${OUT}/fan"
FAN_COUNT=$(grep -v "^#" "${FAN_DIR}/ipmi_fan_sensors.log" 2>/dev/null | awk -F'|' '$1 ~ /FAN[0-9]/{c++} END{print c+0}')
FAN_MIN=$(grep -v "^#" "${FAN_DIR}/ipmi_fan_sensors.log" 2>/dev/null | awk -F'|' '$1 ~ /FAN[0-9]/{gsub(/ /,"",$2); print $2}' | sort -n | head -1)
FAN_MAX=$(grep -v "^#" "${FAN_DIR}/ipmi_fan_sensors.log" 2>/dev/null | awk -F'|' '$1 ~ /FAN[0-9]/{gsub(/ /,"",$2); print $2}' | sort -n | tail -1)
FAN_SPEED=""
[ -n "$FAN_MIN" ] && FAN_SPEED="${FAN_MIN}-${FAN_MAX} RPM"

# ─── 生成 JSON ───
gen_json() {
    local f="${OUT}/hwscope_report.json"
    # 内存插槽明细 JSON 数组（slot|size|mfr|sn|pn|cspd|spd）
    local dimms_json=""
    if [ -n "$MEM_DIMMS" ]; then
        while IFS='|' read -r dslot dsize dmfr dsn dpn dcspd dspd; do
            [ -z "$dslot" ] && continue
            dimms_json="${dimms_json}      {\"slot\": \"${dslot}\", \"size\": \"${dsize}\", \"manufacturer\": \"${dmfr}\", \"serial\": \"${dsn}\", \"part_number\": \"${dpn}\", \"configured_speed\": \"${dcspd}\", \"speed\": \"${dspd}\"},"$'\n'
        done <<< "$MEM_DIMMS"
        dimms_json=$(printf '%s' "$dimms_json" | sed '$ s/,$//')
    fi
    # GPU 每卡明细 JSON 数组（idx|name|serial|mem|power|temp|util|pcie_cur|pcie_max）
    local gpu_details_json=""
    if [ -n "$GPU_DETAILS" ]; then
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gbpn; do
            [ -z "$gidx" ] && continue
            gpu_details_json="${gpu_details_json}      {\"index\": \"${gidx}\", \"name\": \"${gname}\", \"serial\": \"${gsn}\", \"memory\": \"${gmem}\", \"power\": \"${gdraw}\", \"temp\": \"${gtemp}\", \"util\": \"${gutil}\", \"pcie\": \"${gpcie}\", \"pcie_max\": \"${gmax}\", \"board_pn\": \"${gbpn}\"},"$'\n'
        done <<< "$GPU_DETAILS"
        gpu_details_json=$(printf '%s' "$gpu_details_json" | sed '$ s/,$//')
    fi
    cat > "$f" << EOF
{
  "hwscope": {
    "version": "${VERSION:-unknown}",
    "hostname": "${HOSTNAME:-unknown}",
    "platform": "${PLATFORM:-unknown}",
    "timestamp": "${TIMESTAMP:-unknown}"
  },
  "environment": {
    "os": "${OS_NAME:-N/A}",
    "kernel": "${KERNEL:-N/A}",
    "driver": "${GPU_DRIVER:-N/A}",
    "cuda": "${GPU_CUDA:-N/A}"
  },
  "motherboard": {
    "manufacturer": "${MB_MANUFACTURER:-N/A}",
    "product": "${MB_PRODUCT:-N/A}",
    "serial": "${MB_SN:-N/A}",
    "bios": "${BIOS_VERSION:-N/A}",
    "chassis_sn": "${CHASSIS_SN:-N/A}"
  },
  "cpu": {
    "model": "${CPU_MODEL:-N/A}",
    "cores": "${CPU_CORES:-N/A}",
    "sockets": "${CPU_SOCKETS:-N/A}",
    "max_speed": "${CPU_MAX_SPEED:-N/A}",
    "current_speed": "${CPU_CUR_SPEED:-N/A}"
  },
  "memory": {
    "total": "${MEM_TOTAL:-N/A}",
    "speed": "${MEM_SPEED:-N/A}",
    "slots": "${MEM_SLOTS:-N/A}",
    "populated": "${MEM_POPULATED:-0}",
    "dimms": [
${dimms_json}
    ]
  },
  "gpu": {
    "count": "${GPU_COUNT:-0}",
    "models": "${GPU_NAMES:-N/A}",
    "memory_total": "${GPU_MEM:-N/A}",
    "power_limit": "${GPU_POWER:-N/A}",
    "temp": "${GPU_TEMP:-N/A}",
    "ecc": "${GPU_ECC:-N/A}",
    "serials": "${GPU_SERIALS:-N/A}",
    "details": [
${gpu_details_json}
    ]
  },
  "storage": {
    "disk_count": "${STORAGE_COUNT:-0}",
    "total_capacity": "${STORAGE_TOTAL:-N/A}",
    "disk_models": "${STORAGE_MODELS:-N/A}"
  },
  "network": {
    "ib_devices": "${IB_COUNT:-0}",
    "ib_speed": "${IB_SPEED:-N/A}",
    "eth_link_up": "${ETH_LINK_UP:-0}",
    "cables": "${CABLE_SUMMARY:-N/A}",
    "cable_pairs": "${CABLE_PAIRS:-N/A}",
    "port_modes": "${LINKTYPE_SUMMARY:-N/A}"
  },
  "bmc": {
    "fru": "${BMC_FRU:-N/A}",
    "firmware": "${BMC_FW:-N/A}",
    "ip": "${BMC_IP:-N/A}",
    "mac": "${BMC_MAC:-N/A}",
    "sel_total": "${SEL_TOTAL:-0}",
    "sel_critical": "${SEL_CRIT:-0}"
  },
  "fan": {
    "count": "${FAN_COUNT:-0}",
    "speed": "${FAN_SPEED:-N/A}"
  },
  "health": {
    "gpu_pcie_degraded": "${GPU_DEGRADED:-OK}",
    "sel_pcie_errors": "${SEL_PCIE_ERR:-0}",
    "cable_pairs": "${CABLE_PAIRS:-N/A}"
  }
}
EOF
    echo -e "${GREEN}[REPORT] JSON: ${f}${NC}"
}

# ─── 生成 Markdown ───
gen_md() {
    local f="${OUT}/hwscope_report.md"
    # 内存插槽明细 Markdown 表
    local dimms_md=""
    if [ -n "$MEM_DIMMS" ]; then
        while IFS='|' read -r dslot dsize dmfr dsn dpn dcspd dspd; do
            [ -z "$dslot" ] && continue
            dimms_md="${dimms_md}| ${dslot} | ${dsize} | ${dmfr} | ${dsn} | ${dpn} | ${dcspd} | ${dspd} |"$'\n'
        done <<< "$MEM_DIMMS"
    fi
    # GPU 每卡明细 Markdown 表
    local gpu_details_md=""
    if [ -n "$GPU_DETAILS" ]; then
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gbpn; do
            [ -z "$gidx" ] && continue
            gpu_details_md="${gpu_details_md}| ${gidx} | ${gname} | ${gsn} | ${gmem} | ${gdraw} | ${gtemp} | ${gutil} | ${gpcie} | ${gmax} | ${gbpn} |"$'\n'
        done <<< "$GPU_DETAILS"
    fi
    cat > "$f" << EOF
# HwScope 硬件巡检报告

**版本:** ${VERSION:-unknown} · **主机:** ${HOSTNAME:-unknown} · **平台:** ${PLATFORM:-unknown} · **时间:** ${TIMESTAMP:-unknown}

## 环境
| 项 | 值 |
|----|----|
| OS | ${OS_NAME:-N/A} |
| 内核 | ${KERNEL:-N/A} |
| 驱动 | ${GPU_DRIVER:-N/A} |
| CUDA | ${GPU_CUDA:-N/A} |

## 主板
| 项 | 值 |
|----|----|
| 制造商 | ${MB_MANUFACTURER:-N/A} |
| 型号 | ${MB_PRODUCT:-N/A} |
| SN | ${MB_SN:-N/A} |
| BIOS | ${BIOS_VERSION:-N/A} |
| 机箱 SN | ${CHASSIS_SN:-N/A} |

## CPU
| 项 | 值 |
|----|----|
| 型号 | ${CPU_MODEL:-N/A} |
| 核心数 | ${CPU_CORES:-N/A} |
| 插槽数 | ${CPU_SOCKETS:-N/A} |
| 频率 | ${CPU_MAX_SPEED:-N/A}（当前 ${CPU_CUR_SPEED:-N/A}） |

## 内存
| 项 | 值 |
|----|----|
| 总量 | ${MEM_TOTAL:-N/A} |
| 速率 | ${MEM_SPEED:-N/A} |
| 插槽 | ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} |

### 插槽明细
| 插槽 | 容量 | 厂商 | SN | 部件号 | 原速率 | 现速率 |
|------|------|------|----|--------|--------|--------|
$(printf '%s' "$dimms_md")

## GPU
| 项 | 值 |
|----|----|
| 数量 | ${GPU_COUNT:-0} |
| 型号 | ${GPU_NAMES:-N/A} |
| 显存总量 | ${GPU_MEM:-N/A} |
| 功耗上限 | ${GPU_POWER:-N/A} |
| 温度 | ${GPU_TEMP:-N/A} |
| ECC | ${GPU_ECC:-N/A} |

### 每卡明细
| 卡 | 型号 | SN | 显存 | 功耗 | 温度 | 利用率 | PCIe 当前 | PCIe 最大 | 板号 |
|----|------|----|----|------|------|--------|----------|-----------|------|
$(printf '%s' "$gpu_details_md")

## 存储
| 项 | 值 |
|----|----|
| 盘数 | ${STORAGE_COUNT:-0} |
| 总容量 | ${STORAGE_TOTAL:-N/A} |
| 盘型号 | ${STORAGE_MODELS:-N/A} |

## 网络
| 项 | 值 |
|----|----|
| IB 设备数 | ${IB_COUNT:-0} |
| IB 速率 | ${IB_SPEED:-N/A} |
| 线缆类型 | ${CABLE_SUMMARY:-N/A} |
| 线缆配对 | ${CABLE_PAIRS:-N/A} |
| 端口模式 | ${LINKTYPE_SUMMARY:-N/A} |
| 以太网口 up | ${ETH_LINK_UP:-0} |

## BMC
| 项 | 值 |
|----|----|
| 型号 | ${BMC_FRU:-N/A} |
| 固件 | ${BMC_FW:-N/A} |
| IP | ${BMC_IP:-N/A} |
| MAC | ${BMC_MAC:-N/A} |
| SEL 事件 | ${SEL_TOTAL:-0}（Critical ${SEL_CRIT:-0}） |

## 风扇
| 项 | 值 |
|----|----|
| 数量 | ${FAN_COUNT:-0} |
| 转速 | ${FAN_SPEED:-N/A} |

## 健康检查
| 项 | 状态 |
|----|------|
| GPU PCIe 链路 | ${GPU_DEGRADED:-✓ 全部正常} |
| SEL PCIe 错误 | ${SEL_PCIE_ERR:-0} 条 |
| 线缆配对 | ${CABLE_PAIRS:-N/A} |

---
*由 HwScope ${VERSION:-unknown} 自动生成*
EOF
    echo -e "${GREEN}[REPORT] MD: ${f}${NC}"
}

# ─── 生成 TXT（纯文本，cat/less 直接看） ───
gen_txt() {
    local f="${OUT}/hwscope_report.txt"
    # 内存插槽明细纯文本（紧凑单行）
    local dimms_txt=""
    if [ -n "$MEM_DIMMS" ]; then
        while IFS='|' read -r dslot dsize dmfr dsn dpn dcspd dspd; do
            [ -z "$dslot" ] && continue
            dimms_txt="${dimms_txt}    ${dslot}  ${dsize}  ${dmfr}  SN:${dsn}  P/N:${dpn}  ${dcspd}/${dspd}"$'\n'
        done <<< "$MEM_DIMMS"
    fi
    # GPU 每卡明细纯文本
    local gpu_details_txt=""
    if [ -n "$GPU_DETAILS" ]; then
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gbpn; do
            [ -z "$gidx" ] && continue
            gpu_details_txt="${gpu_details_txt}    GPU${gidx}  ${gname}  SN:${gsn}  ${gmem}  ${gdraw}  ${gtemp}  util:${gutil}  PCIe:${gpcie}/${gmax}  板号:${gbpn}"$'\n'
        done <<< "$GPU_DETAILS"
    fi
    cat > "$f" << EOF
============================================
HwScope 硬件巡检报告
============================================
版本: ${VERSION:-unknown}    主机: ${HOSTNAME:-unknown}
平台: ${PLATFORM:-unknown}   时间: ${TIMESTAMP:-unknown}

[环境]
  OS     : ${OS_NAME:-N/A}
  内核   : ${KERNEL:-N/A}
  驱动   : ${GPU_DRIVER:-N/A}
  CUDA   : ${GPU_CUDA:-N/A}

[主板]
  制造商 : ${MB_MANUFACTURER:-N/A}
  型号   : ${MB_PRODUCT:-N/A}
  SN     : ${MB_SN:-N/A}
  BIOS   : ${BIOS_VERSION:-N/A}
  机箱SN : ${CHASSIS_SN:-N/A}

[CPU]
  型号   : ${CPU_MODEL:-N/A}
  核心数 : ${CPU_CORES:-N/A}
  插槽数 : ${CPU_SOCKETS:-N/A}
  频率   : ${CPU_MAX_SPEED:-N/A} (当前 ${CPU_CUR_SPEED:-N/A})

[内存]
  总量   : ${MEM_TOTAL:-N/A}
  速率   : ${MEM_SPEED:-N/A}
  插槽   : ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A}
$(printf '%s' "$dimms_txt")

[GPU]
  数量   : ${GPU_COUNT:-0}
  型号   : ${GPU_NAMES:-N/A}
  显存   : ${GPU_MEM:-N/A}
  功耗   : ${GPU_POWER:-N/A}
  温度   : ${GPU_TEMP:-N/A}
  ECC    : ${GPU_ECC:-N/A}
$(printf '%s' "$gpu_details_txt")

[存储]
  盘数   : ${STORAGE_COUNT:-0}
  总容量 : ${STORAGE_TOTAL:-N/A}
  盘型号 : ${STORAGE_MODELS:-N/A}

[网络]
  IB设备 : ${IB_COUNT:-0}
  IB速率 : ${IB_SPEED:-N/A}
  线缆   : ${CABLE_SUMMARY:-N/A}
  配对   : ${CABLE_PAIRS:-N/A}
  端口模式: ${LINKTYPE_SUMMARY:-N/A}
  网口up : ${ETH_LINK_UP:-0}

[BMC]
  型号   : ${BMC_FRU:-N/A}
  固件   : ${BMC_FW:-N/A}
  IP     : ${BMC_IP:-N/A}
  MAC    : ${BMC_MAC:-N/A}
  SEL    : ${SEL_TOTAL:-0} (Critical ${SEL_CRIT:-0})

[风扇]
  数量   : ${FAN_COUNT:-0}
  转速   : ${FAN_SPEED:-N/A}

[健康检查]
  PCIe链路 : ${GPU_DEGRADED:-✓ 全部正常}
  SEL PCIe : ${SEL_PCIE_ERR:-0} 条错误
  线缆配对 : ${CABLE_PAIRS:-N/A}

--------------------------------------------
由 HwScope ${VERSION:-unknown} 自动生成
EOF
    echo -e "${GREEN}[REPORT] TXT: ${f}${NC}"
}

case "$FORMAT" in
    --json) gen_json ;;
    --md)   gen_md ;;
    --txt)  gen_txt ;;
    *)      gen_json; gen_md; gen_txt ;;
esac
