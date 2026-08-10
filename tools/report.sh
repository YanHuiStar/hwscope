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
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}[REPORT] 开始生成报告...${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}[REPORT] 解析目录: ${OUT}${NC}"

# ─── 提取辅助：从日志取字段（第一个匹配，去注释，保留冒号后全部） ───
extract() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { echo ""; return; }
    grep -iE "$pattern" "$file" 2>/dev/null | grep -v "^#" | head -1 | cut -d':' -f2- | sed 's/^ *//;s/ *$//' | head -c 200
}

# ─── 清单加载：从 manifest.txt 读取模块输出文件名，回退到默认值 ───
# 用法: load_manifest <目录> <key> [默认文件名]
# 若 <目录>/manifest.txt 存在且含 <key>=<value>，设置 shell 变量 $key 为完整路径；
# 否则使用 <目录>/<默认文件名>（默认文件名 = key 本身）。
load_manifest() {
    local dir="$1" key="$2" default="${3:-$2}"
    local manifest="${dir}/manifest.txt"
    if [ -f "$manifest" ]; then
        local val
        val=$(grep "^${key}=" "$manifest" 2>/dev/null | tail -1 | cut -d'=' -f2-)
        if [ -n "$val" ]; then
            eval "${key}=\"${dir}/${val}\""
            return
        fi
    fi
    eval "${key}=\"${dir}/${default}\""
}

# ─── 收集基础信息 ───
SUMMARY="${OUT}/summary.txt"
HOSTNAME=$(extract "Hostname" "$SUMMARY")
VERSION=$(extract "Version" "$SUMMARY")
[ -z "$VERSION" ] && VERSION="N/A"   # 老版本采集数据无 Version 行
PLATFORM=$(grep -m1 "^Platform" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
TIMESTAMP=$(grep -m1 "^Timestamp" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | sed 's/^ //')

# ─── 采集耗时（summary 耗时统计段） ───
TIMING_TOTAL=$(grep -m1 "^总时长" "$SUMMARY" 2>/dev/null | awk '{print $3}')
TIMING_TOP=$(grep -A6 "^模块耗时 Top5:" "$SUMMARY" 2>/dev/null | grep -E "^[[:space:]]*[0-9]" | sed 's/^ *//;s/ *$//' | tr '\n' '; ' | sed 's/; $//')

# ─── 环境（OS/内核/驱动/CUDA） ───
OS_DIR="${OUT}/os"
load_manifest "${OS_DIR}" os_release "os-release.log"
load_manifest "${OS_DIR}" os_uname "uname.log"
OS_NAME=$(grep -m1 "PRETTY_NAME" "${os_release}" 2>/dev/null | cut -d'"' -f2)
KERNEL=$(grep -m1 -v "^#" "${os_uname}" 2>/dev/null | awk '{print $3}')
GPU_DIR="${OUT}/gpu"
load_manifest "${GPU_DIR}" gpu_full "gpu_full.log"
GPU_DRIVER=$(grep -m1 "Driver Version" "${gpu_full}" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
GPU_CUDA=$(grep -m1 "CUDA Version" "${gpu_full}" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')

# ─── 主板 ───
MB_DIR="${OUT}/motherboard"
load_manifest "${MB_DIR}" dmidecode_system "dmidecode_system.log"
load_manifest "${MB_DIR}" dmidecode_bios "dmidecode_bios.log"
load_manifest "${MB_DIR}" dmidecode_chassis "dmidecode_chassis.log"
MB_MANUFACTURER=$(extract "Manufacturer" "${dmidecode_system}")
MB_PRODUCT=$(extract "Product Name" "${dmidecode_system}")
MB_SN=$(extract "Serial Number" "${dmidecode_system}")
BIOS_VERSION=$(extract "Version" "${dmidecode_bios}" | head -c 80)
CHASSIS_SN=$(extract "Serial Number" "${dmidecode_chassis}")

# ─── CPU ───
CPU_DIR="${OUT}/cpu"
load_manifest "${CPU_DIR}" cpu_summary "cpu_summary.log"
load_manifest "${CPU_DIR}" proc_cpuinfo_full "proc_cpuinfo_full.log"
load_manifest "${CPU_DIR}" cpu_stepping "cpu_stepping.log"
load_manifest "${CPU_DIR}" lscpu "lscpu.log"
load_manifest "${CPU_DIR}" dmidecode_processor "dmidecode_processor.log"
CPU_MODEL=$(grep -m1 -iE "^model name" "${cpu_summary}" 2>/dev/null | cut -d':' -f2- | tr -d '\t' | sed 's/^ *//' | head -c 100)
CPU_CORES=$(grep -m1 -iE "^cpu cores|^Core Count" "${cpu_summary}" 2>/dev/null | cut -d':' -f2- | tr -d ' \t')
CPU_SOCKETS=$(grep "physical id" "${proc_cpuinfo_full}" 2>/dev/null | cut -d':' -f2- | sort -u | wc -l)
CPU_STEPPING=$(grep -m1 "^Stepping" "${cpu_stepping}" 2>/dev/null | awk '{print $2}')
[ -z "$CPU_STEPPING" ] && CPU_STEPPING=$(grep -m1 "Stepping:" "${lscpu}" 2>/dev/null | awk '{print $2}')
CPU_MAX_SPEED=$(grep -m1 "Max Speed" "${dmidecode_processor}" 2>/dev/null | awk '{print $(NF-1)}')
[ -z "$CPU_MAX_SPEED" ] && CPU_MAX_SPEED=$(grep -m1 "CPU max MHz" "${lscpu}" 2>/dev/null | awk '{print $NF}')
CPU_CUR_SPEED=$(grep -m1 "Current Speed" "${dmidecode_processor}" 2>/dev/null | awk '{print $(NF-1)}')
[ -z "$CPU_CUR_SPEED" ] && CPU_CUR_SPEED=$(grep -m1 "CPU MHz" "${lscpu}" 2>/dev/null | awk '{print $NF}')

# CPU 每颗明细（从 dmidecode_processor.log 按 Processor Information 块解析）
CPU_DETAILS=""
if [ -f "${dmidecode_processor}" ]; then
    CPU_DETAILS=$(awk '/^Processor Information/{
        socket=""; model=""; cores=""; threads=""; maxspd=""; curspd=""; step=""
        while((getline line) > 0) {
            if(line ~ /^$/) break
            if(line ~ /Handle 0x/) break
            if(line ~ /Socket Designation:/) {sub(/.*: /,"",line); socket=line}
            if(line ~ /Version:/) {sub(/.*: /,"",line); model=line}
            if(line ~ /Core Count:/) {sub(/.*: /,"",line); cores=line}
            if(line ~ /Thread Count:/) {sub(/.*: /,"",line); threads=line}
            if(line ~ /Max Speed:/) {sub(/.*: /,"",line); maxspd=line}
            if(line ~ /Current Speed:/) {sub(/.*: /,"",line); curspd=line}
            if(line ~ /Stepping:/) {sub(/.*: /,"",line); step=line}
        }
        if(socket!="") print socket"|"model"|"cores"|"threads"|"maxspd"|"curspd"|"step
    }' "${dmidecode_processor}" 2>/dev/null)
fi

# ─── 内存 ───
MEM_DIR="${OUT}/memory"
load_manifest "${MEM_DIR}" proc_meminfo "proc_meminfo.log"
load_manifest "${MEM_DIR}" dmidecode_memory_full "dmidecode_memory_full.log"
MEM_TOTAL=$(grep -m1 "MemTotal" "${proc_meminfo}" 2>/dev/null | awk '{printf "%.1f GB", $2/1024/1024}')
MEM_SPEED=$(extract "Configured Clock Speed|Speed:" "${dmidecode_memory_full}")
MEM_SLOTS=$(grep -c "Memory Device" "${dmidecode_memory_full}" 2>/dev/null)
MEM_POPULATED=$(grep -cE "^[[:space:]]*Size: [0-9]" "${dmidecode_memory_full}" 2>/dev/null)
# 每槽 DIMM 明细（插槽|容量|厂商|SN|部件号|原速率|现速率），空槽跳过
# 行模式状态机：从 "Memory Device" 段头开始，空行结束（Size 行在 Locator 之前）
# 速率语义：Speed=模块标称（原速率），Configured Memory Speed=当前实际运行（现速率）
MEM_DIMMS=""
if [ -f "${dmidecode_memory_full}" ]; then
    MEM_DIMMS=$(awk '
        /^Memory Device/ { in_dimm=1; slot=""; size=""; mfr=""; sn=""; pn=""; nom=""; cur=""; next }
        in_dimm && /^[[:space:]]*Locator:/ && !/Bank Locator/ {slot=$0;  sub(/^[[:space:]]*Locator:[[:space:]]*/,"",slot); next}
        in_dimm && /^[[:space:]]*Size:/              {size=$0; sub(/^[[:space:]]*Size:[[:space:]]*/,"",size); sub(/ No Module.*/,"",size); next}
        in_dimm && /^[[:space:]]*Manufacturer:/      {mfr=$0;  sub(/^[[:space:]]*Manufacturer:[[:space:]]*/,"",mfr); next}
        in_dimm && /^[[:space:]]*Serial Number:/     {sn=$0;   sub(/^[[:space:]]*Serial Number:[[:space:]]*/,"",sn); next}
        in_dimm && /^[[:space:]]*Part Number:/       {pn=$0;   sub(/^[[:space:]]*Part Number:[[:space:]]*/,"",pn); sub(/[[:space:]]+$/,"",pn); next}
        in_dimm && /^[[:space:]]*Speed:/             {nom=$0;  sub(/^[[:space:]]*Speed:[[:space:]]*/,"",nom); next}
        in_dimm && /^[[:space:]]*Configured Memory Speed:/ {cur=$0; sub(/^[[:space:]]*Configured Memory Speed:[[:space:]]*/,"",cur); next}
        in_dimm && /^[[:space:]]*$/ { if(size!="") printf "%s|%s|%s|%s|%s|%s|%s\n", slot, size, mfr, sn, pn, nom, cur; in_dimm=0 }
    ' "${dmidecode_memory_full}" 2>/dev/null)
fi

# ─── GPU（解析 inventory.csv；列: 1=idx 2=name 3=serial 4=bdf 5=uuid 6=mem.total 7=mem.used 8=power.limit 9=power.draw 10=temp 11=util 12-13=clocks 14=ecc.mode 15=gen.cur 16=width.cur 17=gen.max 18=width.max） ───
load_manifest "${GPU_DIR}" gpu_inventory "gpu_inventory.csv"
load_manifest "${GPU_DIR}" gpu_ecc_inventory "gpu_ecc_inventory.csv"
GPU_CSV="${gpu_inventory}"
GPU_ECC_CSV="${gpu_ecc_inventory}"
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
        # PCIe 显示：两侧都 N/A 时合并为单个 N/A（避免 N/A/N/A/N/A/N/A）
        gpcie_cur="N/A"; gpcie_max="N/A"
        [ "$ggen" != "N/A" ] && [ -n "$ggen" ] && gpcie_cur="${ggen}x${gwidth}"
        [ "$ggenmax" != "N/A" ] && [ -n "$ggenmax" ] && gpcie_max="${ggenmax}x${gwidthmax}"
        [ "$gpcie_cur" = "N/A" ] && [ "$gpcie_max" != "N/A" ] && gpcie_cur="?"
        GPU_DETAILS="${GPU_DETAILS}${gidx}|${gname}|${gsn}|${gmem_f}|${gdraw_f}|${gtemp_f}|${gutil_f}|${gpcie_cur}|${gpcie_max}"$'\n'
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
load_manifest "${STO_DIR}" block_devices_all "block_devices_all.log"
load_manifest "${STO_DIR}" disk_inventory "disk_inventory.csv"
STORAGE_COUNT=0; STORAGE_TOTAL="N/A"; STORAGE_MODELS=""
# 系统盘识别：根文件系统 / 挂载所在的物理盘（lsblk 树形回溯父盘）
SYS_DISK=""
if [ -f "${block_devices_all}" ]; then
    SYS_DISK=$(grep -v "^#" "${block_devices_all}" | awk '
        $1 ~ /^[a-zA-Z0-9_]+$/ {cur=$1}
        $0 ~ / \/ / && $0 !~ /\/boot/ {print cur; exit}
    ')
fi
if [ -f "${block_devices_all}" ]; then
    # 物理盘行遍历找 size 字段（model 可能含空格导致列偏移，不能用固定列）；默认排除系统盘
    STORAGE_COUNT=$(grep -v "^#" "${block_devices_all}" | awk -v sys="$SYS_DISK" '$NF=="disk" && $1 != sys {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/ && $i != "0B") c++} END{print c+0}')
    STORAGE_TOTAL=$(grep -v "^#" "${block_devices_all}" | awk -v sys="$SYS_DISK" '$NF=="disk" && $1 != sys {v=""; for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/ && $i != "0B") {v=$i; break}; \
        if(v!=""){n=substr(v,1,length(v)-1); u=substr(v,length(v)); \
        if(u=="T")s+=n*1024; else if(u=="G")s+=n; else if(u=="M")s+=n/1024; else if(u=="K")s+=n/1024/1024}} \
        END{printf "%.0f GB", s}' 2>/dev/null)
    STORAGE_MODELS=$(grep -v "^#" "${block_devices_all}" | awk -v sys="$SYS_DISK" '$NF=="disk" && $1 != sys {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/ && $i != "0B") {for(j=2;j<i;j++) m=m" "$j; break}} END{print m}' | sed 's/^ //' | sort -u | sed 's/\(^.\{40\}\).*/\1…/' | tr '\n' ',' | sed 's/,$//')
fi

# 盘明细（disk_inventory.csv: name|type|size|model|serial|fw|bdf|power_on）
DISK_DETAILS=""
if [ -f "${disk_inventory}" ]; then
    while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare; do
        [ -z "$dname" ] || [ "$dname" = "N/A" ] && continue
        [ "$dname" = "#" ] && continue
        [ "$dname" = "$SYS_DISK" ] && continue   # 默认排除系统盘
        DISK_DETAILS="${DISK_DETAILS}${dname}|${dtype}|${dsize}|${dmodel}|${dsn}|${dfw}|${dbdf}|${dpo}|${dpc}|${dspare}"$'\n'
    done < <(grep -v "^#" "${disk_inventory}" 2>/dev/null)
fi

# GPU 退役行数（gpu_remapped_rows.csv）
GPU_REMAP="N/A"
load_manifest "${GPU_DIR}" gpu_remapped_rows "gpu_remapped_rows.csv"
if [ -f "${gpu_remapped_rows}" ]; then
    GPU_REMAP=$(grep -v "^#" "${gpu_remapped_rows}" | grep -v "^$" | awk -F',' '{gsub(/ /,"",$1); gsub(/ /,"",$2); gsub(/ /,"",$3); gsub(/ /,"",$4); c+=$1; u+=$2; p+=$3; f+=$4} END{if(NR>0) printf "CE:%d UE:%d pending:%d fail:%d", c, u, p, f; else print "N/A"}')
fi

# NVLink 链路（gpu_nvlink_status.log：每 GPU 链路数 + 速率 + 异常链路）
NV_LINK_SUMMARY="N/A"
load_manifest "${GPU_DIR}" gpu_nvlink_status "gpu_nvlink_status.log"
if [ -f "${gpu_nvlink_status}" ]; then
    NV_GPU_LINKS=$(grep -c "Link [0-9]" "${gpu_nvlink_status}" 2>/dev/null)
    NV_GPU_COUNT=$(grep -c "^GPU " "${gpu_nvlink_status}" 2>/dev/null)
    NV_LINK_RATE=$(grep -m1 "Link 0:" "${gpu_nvlink_status}" 2>/dev/null | awk '{print $(NF-1)" "$NF}')
    # 异常链路：速率明确为 0 / N/A / Down / Off（避免匹配 "200.0" 里的 0）
    NV_LINK_DOWN=$(grep -E "Link [0-9]+: *(0|N/A|Down|Off)( |$)" "${gpu_nvlink_status}" 2>/dev/null | wc -l)
    if [ "$NV_GPU_COUNT" -gt 0 ] 2>/dev/null; then
        NV_LINK_SUMMARY="${NV_GPU_COUNT}卡 × ${NV_LINK_RATE}"
        [ "$NV_LINK_DOWN" -gt 0 ] && NV_LINK_SUMMARY="${NV_LINK_SUMMARY} ⚠️${NV_LINK_DOWN}链路异常"
    fi
fi

# NVSwitch（nvswitch_*.log：状态/温度/端口）
NVS_DIR="${OUT}/nvswitch"
NVS_DETAILS=""
if ls ${NVS_DIR}/nvswitch_*.log >/dev/null 2>&1; then
    for nf in ${NVS_DIR}/nvswitch_*.log; do
        nidx=$(basename "$nf" | sed 's/nvswitch_//; s/\.log//')
        nstate=$(grep -m1 "Switch State" "$nf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
        ntemp=$(grep -m1 "Temperature" "$nf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ' | sed 's/C$//')
        nports=$(grep -m1 "Active Nvlink Ports" "$nf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
        ntotal=$(grep -m1 "Total Nvlink Ports" "$nf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
        nstat="${nstate:-N/A}"
        [ "$nstat" != "Active" ] && [ "$nstat" != "N/A" ] && nstat="${nstat} ⚠️"
        NVS_DETAILS="${NVS_DETAILS}${nidx}|${nstat}|${ntemp:-N/A}°C|${nports:-N/A}/${ntotal:-N/A}"$'\n'
    done
fi

# ─── 网络 ───
NET_DIR="${OUT}/network"
load_manifest "${NET_DIR}" ibstat "ibstat.log"
load_manifest "${NET_DIR}" ibdev2netdev "ibdev2netdev.log"
load_manifest "${NET_DIR}" nic_inventory "nic_inventory.csv"
IB_COUNT=$(grep -c "State: Active" "${ibstat}" 2>/dev/null)
IB_SPEED=$(grep -A2 "State: Active" "${ibstat}" 2>/dev/null | grep -iE "Rate:" | awk '{print $2}' | sort -n | tail -1)
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
load_manifest "${BMC_DIR}" ipmi_fru_summary "ipmi_fru_summary.log"
load_manifest "${BMC_DIR}" ipmi_mc "ipmi_mc.log"
load_manifest "${BMC_DIR}" ipmi_lan1 "ipmi_lan1.log"
load_manifest "${BMC_DIR}" ipmi_sel_elist "ipmi_sel_elist.log"
BMC_FRU=$(extract "Product Name|Product Part Number" "${ipmi_fru_summary}" | head -c 80)
BMC_FW=$(extract "Firmware Revision" "${ipmi_mc}")
BMC_IP=$(grep "IP Address" "${ipmi_lan1}" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
BMC_MAC=$(grep -m1 "MAC Address" "${ipmi_lan1}" 2>/dev/null | awk '{print $NF}')
SEL_TOTAL=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | wc -l)
SEL_CRIT=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | grep -ciE "critical|fatal")
SEL_PCIE_ERR=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | grep -icE "pcie|aer|uncorrectable")

# SEL 最近 20 条事件明细
SEL_DETAILS=""
if [ -f "${ipmi_sel_elist}" ]; then
    SEL_DETAILS=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev|^$" | tail -20 | awk -F'|' '{
        gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3)
        gsub(/^ +| +$/,"",$4); gsub(/^ +| +$/,"",$5); gsub(/^ +| +$/,"",$6)
        if($1!="" && $2!="") print $1"|"$2"|"$3"|"$4"|"$5
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

# 网卡明细（nic_inventory.csv: dev|bdf|mac|sn|pn|fw|speed|width|psid）
# IB 控制器型号识别：ibstat CA type + ibdev2netdev 映射（mlx5_N ↔ ibp*），附加到 PN 列
declare -A CA_MODEL NETDEV_CA
if [ -f "${ibstat}" ]; then
    cur_ca=""
    while IFS= read -r il; do
        case "$il" in
            *"CA '"*) cur_ca=$(echo "$il" | sed "s/.*'\(.*\)'.*/\1/") ;;
            *"CA type:"*) [ -n "$cur_ca" ] && CA_MODEL[$cur_ca]=$(echo "$il" | awk '{print $NF}') ;;
        esac
    done < <(grep -v "^#" "${ibstat}")
fi
if [ -f "${ibdev2netdev}" ]; then
    while IFS= read -r nl; do
        ca=$(echo "$nl" | awk '{print $1}'); dev=$(echo "$nl" | awk '{print $5}')
        [ -n "$ca" ] && [ -n "$dev" ] && NETDEV_CA[$dev]=$ca
    done < <(grep -v "^#" "${ibdev2netdev}")
fi
mt_model() {
    case "$1" in
        MT4131|MT4129) echo "ConnectX-8" ;;
        MT4125) echo "ConnectX-7" ;;
        MT4124) echo "ConnectX-6 Lx" ;;
        MT4123) echo "ConnectX-6 Dx" ;;
        MT4121|MT4122) echo "ConnectX-6" ;;
        MT2892|MT2893) echo "ConnectX-5" ;;
        MT2884|MT2883) echo "ConnectX-4" ;;
        *) echo "Mellanox" ;;
    esac
}
NIC_DETAILS=""
if [ -f "${nic_inventory}" ]; then
    while IFS='|' read -r nnic nnbdf nmac nsn npn nfw nspd nwd npsid; do
        [ -z "$nnic" ] || [ "$nnic" = "N/A" ] && continue
        [ "$nnic" = "#" ] && continue
        # IB 设备（ibp*/ibs*）附加控制器型号
        if [[ "$nnic" == ibp* || "$nnic" == ibs* ]]; then
            mt="${CA_MODEL[${NETDEV_CA[$nnic]:-}]:-}"
            [ -n "$mt" ] && npn="${npn} [$(mt_model "$mt")]"
            # SN 为占位值/空时，用 ibstat Node GUID 兜底（每卡唯一，可区分多卡）
            if [ -z "$nsn" ] || [ "$nsn" = "N/A" ] || [ "$nsn" = "1951526575073" ]; then
                ng_ca="${NETDEV_CA[$nnic]:-}"
                ng_guid=""
                [ -n "$ng_ca" ] && ng_guid=$(awk "/CA '$ng_ca'/{found=1; next} found && /Node GUID/{print \$3; exit}" "${ibstat}" 2>/dev/null)
                [ -n "$ng_guid" ] && nsn="GUID:${ng_guid}"
                [ -z "$nsn" ] && nsn="N/A"
            fi
        fi
        NIC_DETAILS="${NIC_DETAILS}${nnic}|${nnbdf}|${nmac}|${nsn}|${npn}|${nfw}|${nspd}|${nwd}|${npsid}"$'\n'
    done < <(grep -v "^#" "${nic_inventory}" 2>/dev/null)
fi

# ─── 风扇（IPMI 传感器，| 分隔格式） ───
FAN_DIR="${OUT}/fan"
load_manifest "${FAN_DIR}" ipmi_fan_sensors "ipmi_fan_sensors.log"
FAN_COUNT=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' '$1 ~ /FAN[0-9]/{c++} END{print c+0}')
FAN_MIN=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' '$1 ~ /FAN[0-9]/{gsub(/ /,"",$2); print $2}' | sort -n | head -1)
FAN_MAX=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' '$1 ~ /FAN[0-9]/{gsub(/ /,"",$2); print $2}' | sort -n | tail -1)
FAN_SPEED=""
[ -n "$FAN_MIN" ] && FAN_SPEED="${FAN_MIN}-${FAN_MAX} RPM"

# 风扇每风扇明细
FAN_DETAILS=""
if [ -f "${ipmi_fan_sensors}" ]; then
    FAN_DETAILS=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' '$1 ~ /FAN[0-9]/{
        name=$1; gsub(/^ +| +$/,"",name)
        val=$2; gsub(/^ +| +$/,"",val)
        status=$4; gsub(/^ +| +$/,"",status)
        print name"|"val"|"status
    }')
fi

# ─── PSU 清单（ipmi_psu_fru.log：FRU 描述/型号/PN/SN） ───
# 状态机：desc 行出现时输出上一个 FRU（PN/SN 在 Name 之后，须延迟一行）；
# 只保留 PSU 行（PSU1_FRU/PSU4_FRU/Power Supply），过滤风扇/背板/PDB 等其他 FRU
PSU_DIR="${OUT}/psu"
load_manifest "${PSU_DIR}" ipmi_psu_fru "ipmi_psu_fru.log"
PSU_DETAILS=""
if [ -f "${ipmi_psu_fru}" ]; then
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
    done < <(grep -v "^#" "${ipmi_psu_fru}" 2>/dev/null)
    [ -n "$pending" ] && PSU_DETAILS="${PSU_DETAILS}${pending}${ppn:-N/A}|${psn:-N/A}"$'\n'
    # 只保留 PSU 行（PSU 描述含 PSU 编号或 Power Supply）
    PSU_DETAILS=$(echo "$PSU_DETAILS" | grep -iE "PSU[0-9]|Power Supply")
fi

# ─── 生成 JSON ───
gen_json() {
    local f="${OUT}/hwscope_report.json"
    # 内存插槽明细 JSON 数组（slot|size|mfr|sn|pn|nom|cur）
    local dimms_json=""
    if [ -n "$MEM_DIMMS" ]; then
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_json="${dimms_json}      {\"index\": \"${dseq}\", \"slot\": \"${dslot}\", \"size\": \"${dsize}\", \"manufacturer\": \"${dmfr}\", \"serial\": \"${dsn}\", \"part_number\": \"${dpn}\", \"nominal_speed\": \"${dnom}\", \"current_speed\": \"${dcur}\"},"$'\n'
        done <<< "$MEM_DIMMS"
        dimms_json=$(printf '%s' "$dimms_json" | sed '$ s/,$//')
    fi
    # GPU 每卡明细 JSON 数组（idx|name|serial|mem|power|temp|util|pcie_cur|pcie_max）
    local gpu_details_json=""
    if [ -n "$GPU_DETAILS" ]; then
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax; do
            [ -z "$gidx" ] && continue
            gpu_details_json="${gpu_details_json}      {\"index\": \"${gidx}\", \"name\": \"${gname}\", \"serial\": \"${gsn}\", \"memory\": \"${gmem}\", \"power\": \"${gdraw}\", \"temp\": \"${gtemp}\", \"util\": \"${gutil}\", \"pcie\": \"${gpcie}\", \"pcie_max\": \"${gmax}\"},"$'\n'
        done <<< "$GPU_DETAILS"
        gpu_details_json=$(printf '%s' "$gpu_details_json" | sed '$ s/,$//')
    fi
    # 盘明细 JSON 数组（name|type|size|model|sn|fw|bdf|power_on）
    local disk_details_json=""
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare; do
            [ -z "$dname" ] && continue
            disk_details_json="${disk_details_json}      {\"name\": \"${dname}\", \"type\": \"${dtype}\", \"size\": \"${dsize}\", \"model\": \"${dmodel}\", \"serial\": \"${dsn}\", \"firmware\": \"${dfw}\", \"bdf\": \"${dbdf}\", \"power_on_h\": \"${dpo}\", \"power_cyc\": \"${dpc}\", \"spare\": \"${dspare}\"},"$'\n'
        done <<< "$DISK_DETAILS"
        disk_details_json=$(printf '%s' "$disk_details_json" | sed '$ s/,$//')
    fi
    # 网卡明细 JSON 数组（dev|bdf|mac|sn|pn|fw|speed|width）
    local nic_details_json=""
    if [ -n "$NIC_DETAILS" ]; then
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw nspd nwd npsid; do
            [ -z "$nnic" ] && continue
            nic_details_json="${nic_details_json}      {\"dev\": \"${nnic}\", \"bdf\": \"${nnbdf}\", \"mac\": \"${nmac}\", \"serial\": \"${nsn}\", \"pn\": \"${npn}\", \"firmware\": \"${nfw}\", \"speed\": \"${nspd}\", \"width\": \"${nwd}\", \"psid\": \"${npsid}\"},"$'\n'
        done <<< "$NIC_DETAILS"
        nic_details_json=$(printf '%s' "$nic_details_json" | sed '$ s/,$//')
    fi
    # NVSwitch JSON 数组
    local nvs_json=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_json="${nvs_json}      {\"id\": \"${nidx}\", \"state\": \"${nstat}\", \"temp\": \"${ntemp}\", \"ports\": \"${nports}\"},"$'\n'
        done <<< "$NVS_DETAILS"
        nvs_json=$(printf '%s' "$nvs_json" | sed '$ s/,$//')
    fi
    # CPU 每 Socket 明细 JSON 数组
    local cpu_details_json=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_json="${cpu_details_json}      {\"socket\": \"${csocket}\", \"model\": \"${cmodel}\", \"cores\": \"${ccores}\", \"threads\": \"${cthreads}\", \"max_speed\": \"${cmaxspd}\", \"cur_speed\": \"${ccurspd}\", \"stepping\": \"${cstep}\"},"$'\n'
        done <<< "$CPU_DETAILS"
        cpu_details_json=$(printf '%s' "$cpu_details_json" | sed '$ s/,$//')
    fi
    # SEL 最近事件 JSON 数组
    local sel_details_json=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_json="${sel_details_json}      {\"id\": \"${sid}\", \"date\": \"${sdate}\", \"time\": \"${stime}\", \"type\": \"${stype}\", \"description\": \"${sdesc}\"},"$'\n'
        done <<< "$SEL_DETAILS"
        sel_details_json=$(printf '%s' "$sel_details_json" | sed '$ s/,$//')
    fi
    # 风扇明细 JSON 数组
    local fan_details_json=""
    if [ -n "$FAN_DETAILS" ]; then
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fan_details_json="${fan_details_json}      {\"name\": \"${fname}\", \"rpm\": \"${frpm}\", \"status\": \"${fstatus}\"},"$'\n'
        done <<< "$FAN_DETAILS"
        fan_details_json=$(printf '%s' "$fan_details_json" | sed '$ s/,$//')
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
  "timing": {
    "total": "${TIMING_TOTAL:-N/A}",
    "top_modules": "${TIMING_TOP:-N/A}"
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
    "stepping": "${CPU_STEPPING:-N/A}",
    "max_speed": "${CPU_MAX_SPEED:-N/A}",
    "current_speed": "${CPU_CUR_SPEED:-N/A}",
    "details": [
$(if [ -n "$CPU_DETAILS" ]; then
    echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep; do
        printf '      {"socket": "%s", "model": "%s", "cores": "%s", "threads": "%s", "max_speed": "%s", "cur_speed": "%s", "stepping": "%s"},\n' "$cs" "$cm" "$cc" "$ct" "$cmx" "$ccur" "$cstep"
    done | sed '$ s/,$//'
fi)
    ]
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
    "remapped_rows": "${GPU_REMAP:-N/A}",
    "nvlink": "${NV_LINK_SUMMARY:-N/A}",
    "serials": "${GPU_SERIALS:-N/A}",
    "details": [
${gpu_details_json}
    ]
  },
  "storage": {
    "disk_count": "${STORAGE_COUNT:-0}",
    "total_capacity": "${STORAGE_TOTAL:-N/A}",
    "disk_models": "${STORAGE_MODELS:-N/A}",
    "system_disk_excluded": "${SYS_DISK:-N/A}",
    "disks": [
${disk_details_json}
    ]
  },
  "network": {
    "ib_devices": "${IB_COUNT:-0}",
    "ib_speed": "${IB_SPEED:-N/A}",
    "eth_link_up": "${ETH_LINK_UP:-0}",
    "cables": "${CABLE_SUMMARY:-N/A}",
    "cable_pairs": "${CABLE_PAIRS:-N/A}",
    "port_modes": "${LINKTYPE_SUMMARY:-N/A}",
    "nics": [
${nic_details_json}
    ]
  },
  "bmc": {
    "fru": "${BMC_FRU:-N/A}",
    "firmware": "${BMC_FW:-N/A}",
    "ip": "${BMC_IP:-N/A}",
    "mac": "${BMC_MAC:-N/A}",
    "sel_total": "${SEL_TOTAL:-0}",
    "sel_critical": "${SEL_CRIT:-0}",
    "sel_details": [
$(if [ -n "$SEL_DETAILS" ]; then
    echo "$SEL_DETAILS" | while IFS='|' read -r sid sdate stime stype sdesc; do
        printf '      {"id": "%s", "date": "%s", "time": "%s", "type": "%s", "description": "%s"},\n' "$sid" "$sdate" "$stime" "$stype" "$sdesc"
    done | sed '$ s/,$//'
fi)
    ]
  },
  "fan": {
    "count": "${FAN_COUNT:-0}",
    "speed": "${FAN_SPEED:-N/A}",
    "details": [
$(if [ -n "$FAN_DETAILS" ]; then
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        printf '      {"name": "%s", "rpm": "%s", "status": "%s"},\n' "$fname" "$fval" "$fstatus"
    done | sed '$ s/,$//'
fi)
    ]
  },
  "psu": {
    "list": "$(printf '%s' "${PSU_DETAILS:-N/A}" | tr '\n' '; ' | sed 's/; $//')",
    "details": [
$(if [ -n "$PSU_DETAILS" ]; then
    local pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '      {"index": "%s", "description": "%s", "model": "%s", "part_number": "%s", "serial": "%s"},' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn"
        printf '\n'
    done <<< "$PSU_DETAILS" | sed '$ s/,$//'
fi)
    ]
  },
  "nvswitch": [
$(printf '%s' "$nvs_json")
  ],
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
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_md="${dimms_md}| ${dseq} | ${dslot} | ${dsize} | ${dmfr} | ${dsn} | ${dpn} | ${dnom} | ${dcur} |"$'\n'
        done <<< "$MEM_DIMMS"
    fi
    # GPU 每卡明细 Markdown 表
    local gpu_details_md=""
    if [ -n "$GPU_DETAILS" ]; then
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax; do
            [ -z "$gidx" ] && continue
            gpu_details_md="${gpu_details_md}| ${gidx} | ${gname} | ${gsn} | ${gmem} | ${gdraw} | ${gtemp} | ${gutil} | ${gpcie} | ${gmax} |"$'\n'
        done <<< "$GPU_DETAILS"
    fi
    # 盘明细 Markdown 表
    local disk_details_md=""
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare; do
            [ -z "$dname" ] && continue
            disk_details_md="${disk_details_md}| ${dname} | ${dtype} | ${dsize} | ${dmodel} | ${dsn} | ${dfw} | ${dbdf} | ${dpo} | ${dpc} | ${dspare} |"$'\n'
        done <<< "$DISK_DETAILS"
    fi
    # 网卡明细 Markdown 表
    local nic_details_md=""
    if [ -n "$NIC_DETAILS" ]; then
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw nspd nwd npsid; do
            [ -z "$nnic" ] && continue
            nic_details_md="${nic_details_md}| ${nnic} | ${nnbdf} | ${nmac} | ${nsn} | ${npn} | ${nfw} | ${nspd} | ${nwd} | ${npsid} |"$'\n'
        done <<< "$NIC_DETAILS"
    fi
    # NVSwitch Markdown 表
    local nvs_md=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_md="${nvs_md}| ${nidx} | ${nstat} | ${ntemp} | ${nports} |"$'\n'
        done <<< "$NVS_DETAILS"
    fi
    # CPU 每 Socket 明细 Markdown 表
    local cpu_details_md=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_md="${cpu_details_md}| ${csocket} | ${cmodel} | ${ccores} | ${cthreads} | ${cmaxspd} | ${ccurspd} | ${cstep} |"$'\n'
        done <<< "$CPU_DETAILS"
    fi
    # SEL 最近事件 Markdown 表
    local sel_details_md=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_md="${sel_details_md}| ${sid} | ${sdate} | ${stime} | ${stype} | ${sdesc} |"$'\n'
        done <<< "$SEL_DETAILS"
    fi
    # 风扇明细 Markdown 表
    local fan_details_md=""
    if [ -n "$FAN_DETAILS" ]; then
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fan_details_md="${fan_details_md}| ${fname} | ${frpm} | ${fstatus} |"$'\n'
        done <<< "$FAN_DETAILS"
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
| 采集耗时 | ${TIMING_TOTAL:-N/A}（最耗时: ${TIMING_TOP:-N/A}） |

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
| Stepping | ${CPU_STEPPING:-N/A} |
| 频率 | ${CPU_MAX_SPEED:-N/A}（当前 ${CPU_CUR_SPEED:-N/A}） |
$(if [ -n "$CPU_DETAILS" ]; then
    echo "### CPU 明细"
    echo "| Socket | 型号 | 核心 | 线程 | 最大频率 | 当前频率 | Stepping |"
    echo "|--------|------|------|------|---------|---------|----------|"
    echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep; do
        echo "| ${cs} | ${cm} | ${cc} | ${ct} | ${cmx} | ${ccur} | ${cstep} |"
    done
fi)

## 内存
| 项 | 值 |
|----|----|
| 总量 | ${MEM_TOTAL:-N/A} |
| 速率 | ${MEM_SPEED:-N/A} |
| 插槽 | ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} |

### 插槽明细
| # | 插槽 | 容量 | 厂商 | SN | 部件号 | 原速率 | 现速率 |
|----|------|------|------|----|--------|--------|--------|
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
| 退役行 | ${GPU_REMAP:-N/A} |
| NVLink | ${NV_LINK_SUMMARY:-N/A} |

### 每卡明细
| 卡 | 型号 | SN | 显存 | 功耗 | 温度 | 利用率 | PCIe 当前 | PCIe 最大 |
|----|------|----|----|------|------|--------|----------|-----------|
$(printf '%s' "$gpu_details_md")

## 存储
| 项 | 值 |
|----|----|
| 盘数 | ${STORAGE_COUNT:-0} |
| 总容量 | ${STORAGE_TOTAL:-N/A} |
| 盘型号 | ${STORAGE_MODELS:-N/A} |
| 系统盘(已排除) | ${SYS_DISK:-N/A} |

### 盘明细
| 设备 | 类型 | 容量 | 型号 | SN | 固件 | BDF | 通电(h) | 通电次数 | 寿命% |
|------|------|------|------|----|------|-----|---------|----------|-------|
$(printf '%s' "$disk_details_md")

## 网络
| 项 | 值 |
|----|----|
| IB 设备数 | ${IB_COUNT:-0} |
| IB 速率 | ${IB_SPEED:-N/A} |
| 线缆类型 | ${CABLE_SUMMARY:-N/A} |
| 线缆配对 | ${CABLE_PAIRS:-N/A} |
| 端口模式 | ${LINKTYPE_SUMMARY:-N/A} |
| 以太网口 up | ${ETH_LINK_UP:-0} |

### 网卡明细
| 接口 | BDF | MAC | SN | 型号 | 固件 | 速率 | 宽度 | PSID |
|------|-----|-----|----|------|------|------|------|------|
$(printf '%s' "$nic_details_md")

## BMC
| 项 | 值 |
|----|----|
| 型号 | ${BMC_FRU:-N/A} |
| 固件 | ${BMC_FW:-N/A} |
| IP | ${BMC_IP:-N/A} |
| MAC | ${BMC_MAC:-N/A} |
| SEL 事件 | ${SEL_TOTAL:-0}（Critical ${SEL_CRIT:-0}） |
$(if [ -n "$SEL_DETAILS" ]; then
    echo "### SEL 事件（最近 20 条）"
    echo "| # | 日期 | 时间 | 类型 | 描述 |"
    echo "|---|------|------|------|------|"
    local sel_seq=0
    echo "$SEL_DETAILS" | while IFS='|' read -r sid sdate stime stype sdesc; do
        sel_seq=$((sel_seq+1))
        echo "| ${sid} | ${sdate} | ${stime} | ${stype} | ${sdesc} |"
    done
fi)

## 风扇
| 项 | 值 |
|----|----|
| 数量 | ${FAN_COUNT:-0} |
| 转速 | ${FAN_SPEED:-N/A} |
$(if [ -n "$FAN_DETAILS" ]; then
    echo "### 风扇明细"
    echo "| 风扇 | 转速(RPM) | 状态 |"
    echo "|------|----------|------|"
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        echo "| ${fname} | ${fval} | ${fstatus} |"
    done
fi)

## 电源 PSU
| # | 描述 | 型号 | 部件号 | 序列号 |
|----|------|------|--------|--------|
$(if [ -n "$PSU_DETAILS" ]; then
    local pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '| %s | %s | %s | %s | %s |\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn"
    done <<< "$PSU_DETAILS"
fi)

## NVSwitch
| 编号 | 状态 | 温度 | 活动/总端口 |
|------|------|------|-------------|
$(printf '%s' "$nvs_md")

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
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_txt="${dimms_txt}    ${dseq}. ${dslot}  ${dsize}  ${dmfr}  SN:${dsn}  P/N:${dpn}  标称${dnom}/现${dcur}"$'\n'
        done <<< "$MEM_DIMMS"
    fi
    # GPU 每卡明细纯文本
    local gpu_details_txt=""
    if [ -n "$GPU_DETAILS" ]; then
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax; do
            [ -z "$gidx" ] && continue
            gpu_details_txt="${gpu_details_txt}    GPU${gidx}  ${gname}  SN:${gsn}  ${gmem}  ${gdraw}  ${gtemp}  util:${gutil}  PCIe:${gpcie}/${gmax}"$'\n'
        done <<< "$GPU_DETAILS"
    fi
    # 盘明细纯文本
    local disk_details_txt=""
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare; do
            [ -z "$dname" ] && continue
            disk_details_txt="${disk_details_txt}    ${dname}  ${dtype}  ${dsize}  ${dmodel}  SN:${dsn}  FW:${dfw}  ${dbdf}  ${dpo}h  cyc:${dpc}  spare:${dspare}"$'\n'
        done <<< "$DISK_DETAILS"
    fi
    # 网卡明细纯文本
    local nic_details_txt=""
    if [ -n "$NIC_DETAILS" ]; then
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw nspd nwd npsid; do
            [ -z "$nnic" ] && continue
            nic_details_txt="${nic_details_txt}    ${nnic}  ${nnbdf}  ${nmac}  SN:${nsn}  ${npn}  FW:${nfw}  ${nspd}/${nwd}  PSID:${npsid}"$'\n'
        done <<< "$NIC_DETAILS"
    fi
    # NVSwitch 纯文本
    local nvs_txt=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_txt="${nvs_txt}    NVSwitch${nidx}  ${nstat}  ${ntemp}  端口:${nports}"$'\n'
        done <<< "$NVS_DETAILS"
    fi
    # CPU 每 Socket 明细纯文本
    local cpu_details_txt=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_txt="${cpu_details_txt}    ${csocket}  ${cmodel}  ${ccores}C/${cthreads}T  ${cmaxspd}/${ccurspd}  ${cstep}"$'\n'
        done <<< "$CPU_DETAILS"
    fi
    # SEL 最近事件纯文本
    local sel_details_txt=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_txt="${sel_details_txt}    ${sid}  ${sdate} ${stime}  ${stype}  ${sdesc}"$'\n'
        done <<< "$SEL_DETAILS"
    fi
    # 风扇明细纯文本
    local fan_details_txt=""
    if [ -n "$FAN_DETAILS" ]; then
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fan_details_txt="${fan_details_txt}    ${fname}  ${frpm} RPM  ${fstatus}"$'\n'
        done <<< "$FAN_DETAILS"
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
  采集耗时 : ${TIMING_TOTAL:-N/A}  (Top: ${TIMING_TOP:-N/A})

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
  Stepping: ${CPU_STEPPING:-N/A}
  频率   : ${CPU_MAX_SPEED:-N/A} (当前 ${CPU_CUR_SPEED:-N/A})
$(if [ -n "$CPU_DETAILS" ]; then
    echo "  CPU明细:"
    echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep; do
        printf "    %-6s %-30s %sC/%sT  %s/%s  %s\n" "$cs" "$cm" "$cc" "$ct" "$cmx" "$ccur" "$cstep"
    done
fi)

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
  退役行 : ${GPU_REMAP:-N/A}
  NVLink : ${NV_LINK_SUMMARY:-N/A}
$(printf '%s' "$gpu_details_txt")

[存储]
  盘数   : ${STORAGE_COUNT:-0}
  总容量 : ${STORAGE_TOTAL:-N/A}
  盘型号 : ${STORAGE_MODELS:-N/A}
  系统盘 : ${SYS_DISK:-N/A} (已从统计排除)
$(printf '%s' "$disk_details_txt")

[网络]
  IB设备 : ${IB_COUNT:-0}
  IB速率 : ${IB_SPEED:-N/A}
  线缆   : ${CABLE_SUMMARY:-N/A}
  配对   : ${CABLE_PAIRS:-N/A}
  端口模式: ${LINKTYPE_SUMMARY:-N/A}
  网口up : ${ETH_LINK_UP:-0}
$(printf '%s' "$nic_details_txt")

[BMC]
  型号   : ${BMC_FRU:-N/A}
  固件   : ${BMC_FW:-N/A}
  IP     : ${BMC_IP:-N/A}
  MAC    : ${BMC_MAC:-N/A}
  SEL    : ${SEL_TOTAL:-0} (Critical ${SEL_CRIT:-0})
$(if [ -n "$SEL_DETAILS" ]; then
    echo "  SEL事件(最近20条):"
    echo "$SEL_DETAILS" | while IFS='|' read -r sid sdate stime stype sdesc; do
        printf "    %-4s %-12s %-10s %-25s %s\n" "$sid" "$sdate" "$stime" "$stype" "$sdesc"
    done
fi)

[风扇]
  数量   : ${FAN_COUNT:-0}
  转速   : ${FAN_SPEED:-N/A}
$(if [ -n "$FAN_DETAILS" ]; then
    echo "  风扇明细:"
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        printf "    %-16s %8s RPM  %s\n" "$fname" "$fval" "$fstatus"
    done
fi)

[电源PSU]
$(if [ -n "$PSU_DETAILS" ]; then
    local pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '  %s. %s  %s  PN:%s  SN:%s\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn"
    done <<< "$PSU_DETAILS"
else echo "  N/A"; fi)

[NVSwitch]
$(printf '%s' "$nvs_txt")

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

echo -e "${GREEN}[REPORT] 生成完成${NC}"
