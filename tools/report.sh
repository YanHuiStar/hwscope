#!/bin/bash
# =============================================================================
# HwScope — 报告生成器
# tools/report.sh
# 用法: bash tools/report.sh [output_dir] [--md|--json|--both]
# 功能: 从采集日志提取关键信息，生成 .md + .json 汇总报告
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/nvlink.sh" 2>/dev/null || true

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

# ─── 过滤日志：去除注释行（行首 #）和空行 ───
filter_log() {
    grep -v "^#" "$1" 2>/dev/null | grep -v "^$"
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
            declare -g "${key}=${dir}/${val}"
            return
        fi
    fi
    declare -g "${key}=${dir}/${default}"
}

# ─── CSV 列名动态匹配 ───
# 用法: get_csv_col_index <csv_file> <column_name>
# 返回: 列索引（从 1 开始），未找到返回 0
get_csv_col_index() {
    local csv_file="$1" col_name="$2"
    [ ! -f "$csv_file" ] && echo 0 && return
    local header=$(filter_log "$csv_file" | head -1)
    [ -z "$header" ] && echo 0 && return
    echo "$header" | awk -F',' -v target="$col_name" '{
        for(i=1; i<=NF; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            if($i == target) {
                print i
                exit
            }
        }
        print 0
    }'
}

# ─── JSON 明细数组生成辅助 ───
# 用法: gen_details_json <分隔的数据> <字段映射>
# 输入: 管道分隔的多行数据（如 CPU_DETAILS）
# 字段映射格式: "字段名:字段索引" （索引从 1 开始）
# 示例: gen_details_json "$CPU_DETAILS" "socket:1 model:2 cores:3 threads:4"
gen_details_json() {
    local data="$1" fields="$2"
    [ -z "$data" ] && return

    local output=""
    while IFS='|' read -r line; do
        [ -z "$line" ] && continue
        local json_line="{"
        local first=1
        while IFS=':' read -r name idx; do
            [ -z "$name" ] && continue
            local value=$(echo "$line" | cut -d'|' -f"$idx" 2>/dev/null)
            [ -z "$first" ] && json_line="${json_line}, "
            json_line="${json_line}\"${name}\": \"${value}\""
            first=0
        done <<< "$fields"
        json_line="${json_line}},"
        output="${output}      ${json_line}"$'\n'
    done <<< "$data"

    # 移除最后一个逗号
    printf '%s' "$output" | sed '$ s/,$//'
}

# ─── 收集基础信息 ───
SUMMARY="${OUT}/summary.txt"
HOSTNAME=$(extract "Hostname" "$SUMMARY")
VERSION=$(extract "Version" "$SUMMARY")
[ -z "$VERSION" ] && VERSION="N/A"   # 老版本采集数据无 Version 行
# 报告生成器版本（读 hwscope.sh 权威源；与采集版本 VERSION 区分：
# 采集版本=数据何时采集，生成器版本=报告用哪个工具版本生成）
REPORT_VERSION=$(grep '^HWSCOPE_VERSION=' "${SCRIPT_DIR}/hwscope.sh" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -z "$REPORT_VERSION" ] && REPORT_VERSION="unknown"
PLATFORM=$(grep -m1 "^Platform" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
TIMESTAMP=$(grep -m1 "^Timestamp" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | sed 's/^ //')

# ─── 采集耗时（summary 耗时统计段） ───
TIMING_TOTAL=$(grep -m1 "^总时长" "$SUMMARY" 2>/dev/null | awk '{print $3}')
TIMING_TOP=$(grep -A6 "^模块耗时 Top5:" "$SUMMARY" 2>/dev/null | grep -E "^[[:space:]]*[0-9]" | sed 's/^ *//;s/ *$//' | sed 's/  */ /g' | awk '{printf "%s<br>", $0}' | sed 's/<br>$//')

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
load_manifest "${MB_DIR}" baseboard_summary "baseboard_summary.log"
MB_MANUFACTURER=$(extract "Manufacturer" "${dmidecode_system}")
MB_PRODUCT=$(extract "Product Name" "${dmidecode_system}")
MB_SN=$(extract "Serial Number" "${dmidecode_system}")
# 主板独立 SN（Base Board 与整机 System SN 是不同物理组件序列号，华硕 B300 实测三者各异）
MB_BOARD_SN=$(extract "Serial Number" "${baseboard_summary}")
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
# 总核心数 = 每颗核心数 × 路数（如 48×2=96），与"每颗核心数"区分展示
CPU_TOTAL_CORES=""
if [ -n "$CPU_CORES" ] && [ "${CPU_SOCKETS:-0}" -gt 0 ] 2>/dev/null; then
    CPU_TOTAL_CORES=$((CPU_CORES * CPU_SOCKETS))
fi
CPU_STEPPING=$(grep -m1 "^Stepping" "${cpu_stepping}" 2>/dev/null | awk '{print $2}')
[ -z "$CPU_STEPPING" ] && CPU_STEPPING=$(grep -m1 "Stepping:" "${lscpu}" 2>/dev/null | awk '{print $2}')
CPU_MAX_SPEED=$(grep -m1 "Max Speed" "${dmidecode_processor}" 2>/dev/null | awk '{print $(NF-1)}')
[ -z "$CPU_MAX_SPEED" ] && CPU_MAX_SPEED=$(grep -m1 "CPU max MHz" "${lscpu}" 2>/dev/null | awk '{print $NF}')
CPU_CUR_SPEED=$(grep -m1 "Current Speed" "${dmidecode_processor}" 2>/dev/null | awk '{print $(NF-1)}')
[ -z "$CPU_CUR_SPEED" ] && CPU_CUR_SPEED=$(grep -m1 "CPU MHz" "${lscpu}" 2>/dev/null | awk '{print $NF}')

# CPU 每颗明细（从 dmidecode_processor.log 按 Processor Information 块解析）
# SN 列：有真实 SN 才显示（Not Specified/空 → 空标记，报告端不展示该列）
CPU_DETAILS=""
if [ -f "${dmidecode_processor}" ]; then
    CPU_DETAILS=$(awk '/^Processor Information/{
        socket=""; model=""; cores=""; threads=""; maxspd=""; curspd=""; step=""; sn=""
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
            if(line ~ /Serial Number:/) {sub(/.*: /,"",line); sn=line}
            # 有的平台 Stepping 在 Signature 行内（如 "Signature: Type 0, Family 6, Model 173, Stepping 1"）
            if(line ~ /Signature:.*Stepping/) {match(line, /Stepping [0-9]+/); step=substr(line, RSTART+9, RLENGTH-9)}
        }
        # SN 为 Not Specified/UNKNOWN/空 → 置空（报告端不显示）；仅保留真实 SN
        if(sn ~ /Not Specified|UNKNOWN|Unknown/) sn=""
        if(socket!="") print socket"|"model"|"cores"|"threads"|"maxspd"|"curspd"|"step"|"sn
    }' "${dmidecode_processor}" 2>/dev/null)
fi

# ─── 内存 ───
MEM_DIR="${OUT}/memory"
load_manifest "${MEM_DIR}" proc_meminfo "proc_meminfo.log"
load_manifest "${MEM_DIR}" dmidecode_memory_full "dmidecode_memory_full.log"
MEM_TOTAL=$(grep -m1 "MemTotal" "${proc_meminfo}" 2>/dev/null | awk '{printf "%.1f GiB", $2/1024/1024}')
# 速率：优先取实际运行速率（Configured Memory Speed），fallback 标称 Speed
MEM_SPEED=$(extract "Configured Memory Speed" "${dmidecode_memory_full}")
[ -z "$MEM_SPEED" ] && MEM_SPEED=$(extract "^[[:space:]]*Speed:" "${dmidecode_memory_full}")
MEM_SPEED_NOTE=""
# 降速检测：标称 Speed 与运行速率不一致时提示（如 6400 标称 / 5200 实际）
# 插满降速是 DDR5 物理必然（信号负载/散热），不算故障；未插满仍降速才需关注
# 正文保留提示（信息价值），验收清单判定时再结合插满状态区分
MEM_NOM=$(extract "^[[:space:]]*Speed:" "${dmidecode_memory_full}")
if [ -n "$MEM_SPEED" ] && [ -n "$MEM_NOM" ] && [ "$MEM_SPEED" != "$MEM_NOM" ] 2>/dev/null; then
    MEM_SPEED_NOTE="⚠️ 降速运行（标称 ${MEM_NOM}）"
fi
MEM_SLOTS=$(grep -c "Memory Device" "${dmidecode_memory_full}" 2>/dev/null)
MEM_POPULATED=$(grep -cE "^[[:space:]]*Size: [0-9]" "${dmidecode_memory_full}" 2>/dev/null)
# 插满状态标记（验收清单用：插满降速=正常，不算 WARN）
MEM_FULL=0
[ "${MEM_POPULATED:-0}" -ge "${MEM_SLOTS:-0}" ] 2>/dev/null && [ "${MEM_SLOTS:-0}" -gt 0 ] && MEM_FULL=1
# 每槽 DIMM 明细（插槽|容量|厂商|SN|部件号|原速率|现速率|Rank），空槽跳过
# 行模式状态机：从 "Memory Device" 段头开始，空行结束（Size 行在 Locator 之前）
# 速率语义：Speed=模块标称（原速率），Configured Memory Speed=当前实际运行（现速率）
MEM_DIMMS=""
if [ -f "${dmidecode_memory_full}" ]; then
    MEM_DIMMS=$(awk '
        /^Memory Device/ { in_dimm=1; slot=""; size=""; mfr=""; sn=""; pn=""; nom=""; cur=""; rank=""; next }
        in_dimm && /^[[:space:]]*Locator:/ && !/Bank Locator/ {slot=$0;  sub(/^[[:space:]]*Locator:[[:space:]]*/,"",slot); next}
        in_dimm && /^[[:space:]]*Size:/              {size=$0; sub(/^[[:space:]]*Size:[[:space:]]*/,"",size); sub(/ No Module.*/,"",size); next}
        in_dimm && /^[[:space:]]*Manufacturer:/      {mfr=$0;  sub(/^[[:space:]]*Manufacturer:[[:space:]]*/,"",mfr); next}
        in_dimm && /^[[:space:]]*Serial Number:/     {sn=$0;   sub(/^[[:space:]]*Serial Number:[[:space:]]*/,"",sn); next}
        in_dimm && /^[[:space:]]*Part Number:/       {pn=$0;   sub(/^[[:space:]]*Part Number:[[:space:]]*/,"",pn); sub(/[[:space:]]+$/,"",pn); next}
        in_dimm && /^[[:space:]]*Speed:/             {nom=$0;  sub(/^[[:space:]]*Speed:[[:space:]]*/,"",nom); next}
        in_dimm && /^[[:space:]]*Configured Memory Speed:/ {cur=$0; sub(/^[[:space:]]*Configured Memory Speed:[[:space:]]*/,"",cur); next}
        in_dimm && /^[[:space:]]*Rank:/              {rank=$0; sub(/^[[:space:]]*Rank:[[:space:]]*/,"",rank); next}
        in_dimm && /^[[:space:]]*$/ { if(size!="") printf "%s|%s|%s|%s|%s|%s|%s|%s\n", slot, size, mfr, sn, pn, nom, cur, rank; in_dimm=0 }
    ' "${dmidecode_memory_full}" 2>/dev/null)
fi
# 物理标称总量（每槽 Size 求和，64GB×32=2048GB）——与系统可见(MEM_TOTAL)区分，需在 MEM_DIMMS 之后计算
MEM_TOTAL_PHYS=""
if [ -n "$MEM_DIMMS" ]; then
    MEM_TOTAL_PHYS=$(echo "$MEM_DIMMS" | awk -F'|' '{gsub(/[^0-9.]/,"",$2); if($2+0>0) sum+=$2} END{if(sum>0) printf "%.0fGB", sum; else print ""}')
fi
# 内存类型（DDR4/DDR5）与 ECC 类型（Single-bit ECC 等；供日志展示，报告不输出 ECC）
MEM_TYPE=$(grep -m1 "^[[:space:]]*Type: DDR" "${dmidecode_memory_full}" 2>/dev/null | awk '{print $2}')
MEM_ECC_TYPE=$(grep -m1 "Error Correction Type" "${dmidecode_memory_full}" 2>/dev/null | cut -d: -f2- | xargs)
# EDAC 错误计数（日志展示用；报告不输出）
MEM_EDAC="N/A"
load_manifest "${MEM_DIR}" edac_errors "edac_errors.log"
if [ -f "${edac_errors}" ]; then
    MEM_EDAC=$(grep -E "CE_count|UE_count" "${edac_errors}" 2>/dev/null | grep -vE "N/A|^#" | awk -F': ' '{sum[$1]+=$2} END{if(NR>0) printf "CE:%d UE:%d", sum["CE_count"], sum["UE_count"]; else print "0/0"}')
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
    # 显存总量（nvidia-smi memory.total，MiB→GiB 二进制换算，为可见值含 ECC 预留）
    # 动态匹配列名，避免硬编码位置
    mem_col=$(get_csv_col_index "$GPU_CSV" "memory.total [MiB]")
    power_col=$(get_csv_col_index "$GPU_CSV" "power.limit [W]")
    temp_col=$(get_csv_col_index "$GPU_CSV" "temperature.gpu")

    GPU_MEM=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -v col="${mem_col:-6}" -F',' '{
        gsub(/ MiB/, "", $col)
        sum += $col
    } END{printf "%.0f GiB", sum/1024}')
    # 每卡标称规格（型号→标称映射，标注检测值 vs 规格的差异；未知型号显示检测值）
    GPU_MODEL_LINE=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | head -1 | cut -d',' -f2)
    GPU_MEM_SPEC=""
    case "$GPU_MODEL_LINE" in
        *B300*)   GPU_MEM_SPEC="标称 288GB/卡" ;;
        *B200*)   GPU_MEM_SPEC="标称 192GB/卡" ;;
        *H200*)   GPU_MEM_SPEC="标称 141GB/卡" ;;
        *H100*)   GPU_MEM_SPEC="标称 80GB/卡" ;;
        *)        GPU_MEM_SPEC="" ;;
    esac
    GPU_POWER=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -v col="${power_col:-8}" -F',' '{
        gsub(/ W/, "", $col)
        if($col+0 > max+0) max = $col
    } END{printf "%.0f W", max}')
    GPU_TEMP=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -v col="${temp_col:-9}" -F',' '{
        t = $col
        sum += t
        if(t+0 > tmax+0) tmax = t
    } END{printf "%.0f°C (max %.0f)", sum/NR, tmax}')
    # 标称总量（单卡标称 × 卡数，如 288GB×8=2304GB）；与可用总量(GPU_MEM)并列显示
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
        END{printf "%.0f GiB", s}' 2>/dev/null)
    # 盘型号：从 disk_inventory.csv 取（MODEL/SERIAL 已分离）；排除系统盘（与盘数/容量口径一致）；回退 block_devices 提取
    if [ -f "${disk_inventory}" ]; then
        STORAGE_MODELS=$(grep -v "^#" "${disk_inventory}" 2>/dev/null | awk -F'|' -v sys="$SYS_DISK" '$1!="" && $1!=sys && $4!="N/A" && $4!="" {print $4}' | sort -u | sed 's/\(^.\{40\}\).*/\1…/' | tr '\n' ',' | sed 's/,$//')
    else
        STORAGE_MODELS=$(grep -v "^#" "${block_devices_all}" | awk -v sys="$SYS_DISK" '$NF=="disk" && $1 != sys {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/ && $i != "0B") {print $(i-1); break}}' | sort -u | sed 's/\(^.\{40\}\).*/\1…/' | tr '\n' ',' | sed 's/,$//')
    fi
fi

# 盘明细（disk_inventory.csv: name|type|size|model|serial|fw|bdf|power_on）
DISK_DETAILS=""
if [ -f "${disk_inventory}" ]; then
    while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare; do
        [ -z "$dname" ] || [ "$dname" = "N/A" ] && continue
        [ "$dname" = "#" ] && continue
        [ "$dname" = "$SYS_DISK" ] && continue   # 默认排除系统盘
        # 标称容量：优先从型号字符串自动提取（如 "PM1733a RI 3.84TB"、"MTFDKBA480TFR"→480GB），
        # Samsung 硬编码表兜底（型号无容量字样时）
        dspec=""
        case "$dmodel" in
            *MZWL61T9HFLT*|*MZWL61T9HBLN*) dspec="标称1.92TB" ;;
            *MZWL63T8HFLT*|*MZWL63T8HBLN*) dspec="标称3.84TB" ;;
            *MZWL67T6HFLT*) dspec="标称7.68TB" ;;
            *MZ7L31T9*|*MZ7LH1T9*) dspec="标称1.92TB" ;;
            *MZ7L33T8*|*MZ7LH3T8*) dspec="标称3.84TB" ;;
            *MZ7L37T6*) dspec="标称7.68TB" ;;
            *MZQL21T9*) dspec="标称1.92TB" ;;
            *MZQL23T8*) dspec="标称3.84TB" ;;
            *MZQL27T6*) dspec="标称7.68TB" ;;
            *MZIL21T6*) dspec="标称1.6TB" ;;
            *MZIL23T8*) dspec="标称3.2TB" ;;
            *MZIL27T6*) dspec="标称6.4TB" ;;
            *)
                # Micron 型号规则: MTFDKBA480TFR / MTFDHBE960TFR → 数字=容量GB（T 是家族代号非 TB）
                if echo "$dmodel" | grep -qE 'MTFD[KHC][A-Z]{2}[0-9]{3,4}TFR'; then
                    micap=$(echo "$dmodel" | grep -oE '[0-9]{3,4}TFR' | head -1 | grep -oE '[0-9]+')
                    [ -n "$micap" ] && dspec="标称${micap}GB"
                fi
                # 通用提取：型号中显式容量（3.84TB / 1.92T / 480G 等）
                if [ -z "$dspec" ]; then
                    cap=$(echo "$dmodel" | grep -oE '[0-9]+(\.[0-9]+)?[TtGg][Bb]?' | head -1)
                    if [ -n "$cap" ]; then
                        # 统一单位：T→TB，G→GB（保留一位小数）
                        num=$(echo "$cap" | grep -oE '[0-9]+(\.[0-9]+)?')
                        unit=$(echo "$cap" | grep -oE '[TtGg]' | tr '[:lower:]' '[:upper:]')
                        dspec="标称${num}${unit}B"
                    fi
                fi
                ;;
        esac
        # 寿命归一化：N/A%（未采集到 SMART 数据）→ 显示 "—"（避免客户误读为盘异常）
        case "$dspare" in
            ""|N/A|N/A%|na|NA) dspare="—" ;;
        esac
        DISK_DETAILS="${DISK_DETAILS}${dname}|${dtype}|${dsize}|${dmodel}|${dsn}|${dfw}|${dbdf}|${dpo}|${dpc}|${dspare}|${dspec}"$'\n'
    done < <(grep -v "^#" "${disk_inventory}" 2>/dev/null)
fi

# GPU 退役行数（gpu_remapped_rows.csv）
GPU_REMAP="N/A"
load_manifest "${GPU_DIR}" gpu_remapped_rows "gpu_remapped_rows.csv"
if [ -f "${gpu_remapped_rows}" ]; then
    GPU_REMAP=$(grep -v "^#" "${gpu_remapped_rows}" | grep -v "^$" | awk -F',' '{gsub(/ /,"",$1); gsub(/ /,"",$2); gsub(/ /,"",$3); gsub(/ /,"",$4); c+=$1; u+=$2; p+=$3; f+=$4} END{if(NR>0) printf "CE:%d UE:%d pending:%d fail:%d", c, u, p, f; else print "N/A"}')
fi

# VBIOS 版本（gpu_full.log 全量输出；交付验收核对固件用）
GPU_VBIOS="N/A"
load_manifest "${GPU_DIR}" gpu_full "gpu_full.log"
if [ -f "${gpu_full}" ]; then
    GPU_VBIOS=$(grep -m1 "VBIOS Version" "${gpu_full}" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
    [ -z "$GPU_VBIOS" ] && GPU_VBIOS="N/A"
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
        # 每卡链路数 = 总链路/卡数（B300 每卡 18 条）；显示"卡数 × 每卡链路数 × 单链路速率"避免误读为整卡带宽
        NV_LINKS_PER_GPU=0
        if [ "$NV_GPU_COUNT" -gt 0 ] && [ "$NV_GPU_LINKS" -gt 0 ] 2>/dev/null; then
            NV_LINKS_PER_GPU=$((NV_GPU_LINKS / NV_GPU_COUNT))
        fi
        if [ "$NV_LINKS_PER_GPU" -gt 0 ]; then
            NV_LINK_SUMMARY="${NV_GPU_COUNT}卡 全互联 (${NV_LINKS_PER_GPU}条/卡 × ${NV_LINK_RATE})"
        else
            NV_LINK_SUMMARY="${NV_GPU_COUNT}卡 × ${NV_LINK_RATE}"
        fi
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
load_manifest "${NET_DIR}" mst_notice "mst_notice.log"
# MST 未启动提示（Mellanox SN 兜底说明）
MST_NOTICE=""
[ -f "${mst_notice}" ] && MST_NOTICE=$(grep -v "^#" "${mst_notice}" | head -1)
# IB 设备总数（CA 数量）与活动口数（State: Active）分开统计——"设备数"≠"活动口数"
IB_COUNT=$(grep -c "^CA '" "${ibstat}" 2>/dev/null)
IB_ACTIVE=$(grep -c "State: Active" "${ibstat}" 2>/dev/null)
# 活动口的速率分布（如 "100 Gb/s ×4"；无活动口显示 Down）
IB_ACTIVE_SPEED=""
if [ "${IB_ACTIVE:-0}" -gt 0 ] 2>/dev/null; then
    IB_ACTIVE_SPEED=$(grep -A2 "State: Active" "${ibstat}" 2>/dev/null | grep -iE "Rate:" | awk '{print $2}' | sort -n | uniq -c | awk '{printf "%s Gb/s ×%d ", $2, $1}' | sed 's/ $//')
fi
IB_SPEED=$(grep -A2 "State: Active" "${ibstat}" 2>/dev/null | grep -iE "Rate:" | awk '{print $2}' | sort -n | tail -1)
[ -n "$IB_SPEED" ] && IB_SPEED="${IB_SPEED} Gb/s"

# 标称速率（卡能力，无需接线）：解析 mlxlink Enabled Link Speed 位图，取最大速率族
# Mellanox 位图: bit0=SDR(10G) bit1=DDR(20G) bit2=QDR(40G) bit3=FDR10(40G) bit4=FDR(56G)
#                bit5=EDR(100G) bit6=HDR(200G) bit7=NDR(400G) bit8=XDR(800G) bit9=GDR(1600G)
IB_NOMINAL="N/A"
_NOMINAL_SPEEDS=()
for f in "${NET_DIR}"/mlxlink_mlx5_*.log; do
    [ -f "$f" ] || continue
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
    elif [ $((_v & 0x04)) -ne 0 ]; then _nom="40G (QDR)"
    elif [ $((_v & 0x02)) -ne 0 ]; then _nom="20G (DDR)"
    elif [ $((_v & 0x01)) -ne 0 ]; then _nom="10G (SDR)"
    fi
    _NOMINAL_SPEEDS+=("$_nom")
done
# 取所有口中最大标称速率
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
SEL_CRIT=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | grep -ciE "critical|fatal")
SEL_PCIE_ERR=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" | grep -icE "pcie|aer|uncorrectable")

# SEL 最近 20 条事件明细
SEL_DETAILS=""
if [ -f "${ipmi_sel_elist}" ]; then
    SEL_DETAILS=$(grep -v "^#" "${ipmi_sel_elist}" 2>/dev/null | grep -vE "Could not open|Unable|No such file|command failed|device at /dev|^$" | tail -20 | awk -F'|' '{
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

# ─── NVLink 状态（读采集日志，lib/nvlink.sh） ───
nvlink_load_from_logs "$GPU_DIR"
NVLINK_HEALTH="OK"
if [ "${NVLINK_DATA:-0}" -eq 0 ]; then
    NVLINK_HEALTH="N/A"   # 无 NVLink 采集数据（无 GPU/旧采集），判定用 N/A 而非 OK
else
    nvlink_is_healthy || NVLINK_HEALTH="异常"
fi

# ─── DCGM 诊断结果（dcgmi_diag_level1.log：区分硬件 Fail 与配置类 Fail） ───
# Persistence Mode 未开启是环境配置问题（8 卡全 Fail 时常见），不属硬件故障，单独标注
DCGM_SUMMARY="N/A"
DCGM_DIR="${OUT}/dcgm"
load_manifest "${DCGM_DIR}" dcgmi_diag_level1 "dcgmi_diag_level1.log"
load_manifest "${DCGM_DIR}" dcgm_notice "dcgm_notice.log"
DCGM_NOTICE=""
[ -f "${dcgm_notice}" ] && DCGM_NOTICE=$(grep -v "^#" "${dcgm_notice}" | head -1)
if [ -f "${dcgmi_diag_level1}" ]; then
    DCGM_SOFT_FAIL=$(grep -A1 "^| software" "${dcgmi_diag_level1}" 2>/dev/null | grep -c "Fail")
    DCGM_HW_FAIL=$(grep -E "^\| (memory|pcie|nvlink|diagnostic|compute|graphics|nvswitch)" "${dcgmi_diag_level1}" 2>/dev/null | grep -c "Fail")
    DCGM_PERSIST=$(grep -c "Persistence Mode" "${dcgmi_diag_level1}" 2>/dev/null)
    DCGM_DIAG_VER=$(grep -m1 "DCGM Version" "${dcgmi_diag_level1}" 2>/dev/null | grep -oP 'DCGM Version\s+\|\s*\K[0-9.]+' | head -1)
    if [ "$DCGM_SOFT_FAIL" -gt 0 ] || [ "$DCGM_HW_FAIL" -gt 0 ]; then
        DCGM_SUMMARY="Fail (软件:${DCGM_SOFT_FAIL} 硬件:${DCGM_HW_FAIL})"
        # 纯配置类 Fail（仅 Persistence Mode）→ 标注非硬件
        if [ "$DCGM_HW_FAIL" -eq 0 ] && [ "$DCGM_SOFT_FAIL" -gt 0 ] && [ "$DCGM_PERSIST" -ge "$DCGM_SOFT_FAIL" ]; then
            DCGM_SUMMARY="配置项 Fail (Persistence Mode 未开启, 非硬件故障)"
        fi
    else
        DCGM_SUMMARY="通过 (DCGM ${DCGM_DIAG_VER:-?})"
    fi
fi

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
NIC_MLX=0
GPU_TOPO_AVAIL=0
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
        MT4131) echo "ConnectX-8" ;;
        # MT4129=ConnectX-7 (MCX75xxx, NDR 400G)；MT2910/MT4125 同代不同封装
        MT4129|MT2910|MT4125) echo "ConnectX-7" ;;
        MT4124) echo "ConnectX-6 Lx" ;;
        MT4123) echo "ConnectX-6 Dx" ;;
        MT4121|MT4122) echo "ConnectX-6" ;;
        MT2892|MT2893) echo "ConnectX-5" ;;
        MT2884|MT2883) echo "ConnectX-4" ;;
        *) echo "Mellanox" ;;
    esac
}
NIC_DETAILS=""
# GPU 直连标注：解析 topo 矩阵（gpu_topo_nic.log 优先；旧版 -n 语法错误时回退 gpu_topo.log，
# v1.26.27+ 的 topo -m 已自带 NIC 列）
# PIX = 同一 PCIe switch（GPU 直连），NODE = 同 NUMA，SYS = 跨节点
# NIC0..NICn 按 BDF 升序对应 nic_inventory 中的 PCIe 网卡
declare -A GPU_DIRECT_NIC
GPU_TOPO_FILE=""
for _tf in "${GPU_DIR}/gpu_topo_nic.log" "${GPU_DIR}/gpu_topo.log"; do
    [ -f "$_tf" ] || continue
    # 内容有效性：含 NIC 列且无 "-n" 语法报错
    if grep -v "^#" "$_tf" 2>/dev/null | grep -qE "NIC[0-9]+" && ! grep -q "Option \"-n\"" "$_tf" 2>/dev/null; then
        GPU_TOPO_FILE="$_tf"
        break
    fi
done
if [ -n "$GPU_TOPO_FILE" ]; then
    _nic_cols=()
    _nic_idx=()
    _hdr=$(grep -v "^#" "$GPU_TOPO_FILE" | grep -E "NIC[0-9]" | head -1)
    # 同时记录列名与列号（动态计算，兼容 4/8 GPU 等不同卡数导致的列偏移）
    if [ -n "$_hdr" ]; then
        while IFS= read -r _pair; do
            _nic_cols+=("${_pair%%:*}")
            _nic_idx+=("${_pair##*:}")
        done < <(echo "$_hdr" | awk '{for(i=1;i<=NF;i++) if($i~/^NIC[0-9]+$/) printf "%s:%d\n", $i, i}')
    fi
    if [ "${#_nic_cols[@]}" -gt 0 ]; then
        # 每列 NIC：统计 GPU 行中 PIX 出现次数（任一 GPU 直连即标记）
        declare -A _nic_pix
        while IFS= read -r _row; do
            [ -z "$_row" ] && continue
            echo "$_row" | grep -qE "^GPU[0-9]+" || continue
            _idx=0
            for _col in "${_nic_cols[@]}"; do
                _val=$(echo "$_row" | awk -v c="${_nic_idx[$_idx]}" '{print $c}')
                [ "$_val" = "PIX" ] && _nic_pix[$_col]=1
                _idx=$((_idx+1))
            done
        done < <(grep -v "^#" "$GPU_TOPO_FILE")
        # 映射：topo NIC 列按 BDF 升序 = nic_inventory 中 PCIe 网卡按 BDF 升序
        _pci_nics=()
        while IFS='|' read -r _d _bdf _rest; do
            [ -z "$_d" ] || [ "$_d" = "#" ] && continue
            echo "$_bdf" | grep -qE "^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$" && _pci_nics+=("$_d|$_bdf")
        done < <(grep -v "^#" "${nic_inventory}" 2>/dev/null)
        # 按 BDF 排序（topo NIC 列序 = BDF 升序）
        _pci_nics=($(printf '%s\n' "${_pci_nics[@]}" | sort -t'|' -k2))
        _nn=0
        for _col in "${_nic_cols[@]}"; do
            _entry="${_pci_nics[$_nn]:-}"
            [ -n "$_entry" ] && [ "${_nic_pix[$_col]:-0}" -eq 1 ] && GPU_DIRECT_NIC[${_entry%%|*}]="1"
            _nn=$((_nn+1))
        done
    fi
fi
if [ -f "${nic_inventory}" ]; then
    while IFS='|' read -r nnic nnbdf nmac nsn npn nfw nspd nwd npsid ncapspd ncapwd; do
        [ -z "$nnic" ] || [ "$nnic" = "N/A" ] && continue
        [ "$nnic" = "#" ] && continue
        # 非 PCIe BDF（如 USB 路径 3-1.5:2.0）标记为 USB，避免误当 PCIe 槽位
        if [ -n "$nnbdf" ] && ! echo "$nnbdf" | grep -qE "^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\\.[0-9a-fA-F]$"; then
            nnbdf="${nnbdf} (USB)"
        fi
        # PSID 回查：nic_inventory 中 PSID=N/A 时，从 mlxfwmanager.log 按 BDF 补 PSID/Part Number
        # （采集端 mstflint 失败或 mlxfwmanager 无 PSID 字段时；报告端日志已就绪，无竞态）
        # 顺序: Device # → Device Type → Part Number → Description → PSID → PCI Device Name → ...
        # 字段散落在 Device Name 前后——遇下一设备头结算上一设备
        if [ "$npsid" = "N/A" ] && [ -f "${NET_DIR}/mlxfwmanager.log" ]; then
            # PSID 回查：按行扫描，PSID/PN 归属到其后的 PCI Device Name 匹配设备
            # 顺序: Device # → Device Type → Part Number → Description → PSID → PCI Device Name → Base GUID
            rpsid=$(awk -v bdf="${nnbdf%% (USB)*}" '
                /Part Number:/ { pn=$0; sub(/.*Part Number:[[:space:]]*/, "", pn) }
                /PSID:/        { psid=$0; sub(/.*PSID:[[:space:]]*/, "", psid) }
                /PCI Device Name:/ { dev=$NF; sub(/^0000:/, "", dev) }
                dev==bdf && /Base GUID:/ { if (psid != "" && psid != "N/A") print psid; else if (pn != "") print "PN:" pn; exit }
            ' "${NET_DIR}/mlxfwmanager.log" 2>/dev/null | head -1)
            # 取第一行匹配，防多行污染
            rpsid=$(echo "$rpsid" | tr -d '\n\r')
            [ -n "$rpsid" ] && npsid="$rpsid"
        fi
        # IB 设备（ibp*/ibs*）附加控制器型号
        if [[ "$nnic" == ibp* || "$nnic" == ibs* ]]; then
            NIC_MLX=1
            # 型号附加：优先 lspci 直读（PCI ID 权威，认识所有 Mellanox 卡，无需维护映射表）
            mt=""
            if [ -f "${OUT}/pcie/lspci_all.log" ]; then
                mt=$(grep -E "^${nnbdf%% (USB)*} " "${OUT}/pcie/lspci_all.log" 2>/dev/null | grep -oE '\[ConnectX-[0-9]+( Lx| Dx)?\]|\[BlueField[^]]*\]' | head -1 | tr -d '[]')
            fi
            # 兜底：lspci 无型号时用 CA type 映射（MT4129→ConnectX-7 等）
            if [ -z "$mt" ]; then
                mt="${CA_MODEL[${NETDEV_CA[$nnic]:-}]:-}"
                [ -n "$mt" ] && mt=$(mt_model "$mt")
            fi
            [ -n "$mt" ] && npn="${npn} [${mt}]"
            # 芯片编号（MT 编号：MT4129 等，工程/固件视角核对用）
            nchip=""
            if [[ "$nnic" == ibp* || "$nnic" == ibs* ]]; then
                nchip="${CA_MODEL[${NETDEV_CA[$nnic]:-}]:-}"
            fi
            # SN 为占位值/空时，用 ibstat Node GUID 兜底（每卡唯一，可区分多卡）
            if [ -z "$nsn" ] || [ "$nsn" = "N/A" ] || [ "$nsn" = "1951526575073" ]; then
                ng_ca="${NETDEV_CA[$nnic]:-}"
                ng_guid=""
                [ -n "$ng_ca" ] && ng_guid=$(awk "/CA '$ng_ca'/{found=1; next} found && /Node GUID/{print \$3; exit}" "${ibstat}" 2>/dev/null)
                [ -n "$ng_guid" ] && nsn="GUID:${ng_guid}"
                [ -z "$nsn" ] && nsn="N/A"
            fi
        else
            # 非 IB 卡（Intel/Broadcom 等）：sysfs serial 常是 MAC 变形（如 f5-96-29-ff-ff-9f-ad-a0）
            # 特征：含 ff-ff 或与 MAC 高度相似（- 分隔 16 进制），识别后标记为 MAC 派生
            if [ -n "$nsn" ] && echo "$nsn" | grep -qE "^([0-9a-f]{2}-){5,}[0-9a-f]{2}$"; then
                nsn="${nsn} (MAC)"
            fi
        fi
        # GPU 直连标记（topo PIX 判定）——无有效 topo 数据（旧采集/采集失败）时整列隐藏，避免误会：
        #   "GPU直连" = PIX 直连；"—" = 有 topo 数据但非直连
        gd_mark=""
        if [ -n "$GPU_TOPO_FILE" ]; then
            GPU_TOPO_AVAIL=1
            if [ "${GPU_DIRECT_NIC[$nnic]:-0}" = "1" ]; then
                gd_mark="GPU直连"
            else
                gd_mark="—"
            fi
        fi
        # PCIe 能力（LnkCap）与当前（LnkSta）合并显示：当前一致时只显当前，不一致标注能力
        npcie_cap=""
        if [ -n "$ncapspd" ] && [ "$ncapspd" != "N/A" ]; then
            if [ "$nspd" = "$ncapspd" ] && [ "$nwd" = "$ncapwd" ]; then
                npcie_cap="${nspd}/${nwd}"
            else
                npcie_cap="${nspd}/${nwd} (能力 ${ncapspd}/${ncapwd})"
            fi
        else
            npcie_cap="${nspd}/${nwd}"
        fi
        # PCIe 无数据（N/A/N/A）→ 统一 "—"
        case "${npcie_cap:-}" in ""|N/A|N/A/N/A|/|na|NA) npcie_cap="—" ;; esac
        # 无数据统一占位 "—"（N/A/空 → —；仅 GPU直连 保留三态语义）
        case "${nsn:-}" in ""|N/A|na|NA) nsn="—" ;; esac
        case "${npn:-}" in ""|N/A|na|NA) npn="—" ;; esac
        case "${nfw:-}" in ""|N/A|na|NA) nfw="—" ;; esac
        case "${npsid:-}" in ""|N/A|na|NA) npsid="—" ;; esac
        case "${nchip:-}" in ""|N/A|na|NA) nchip="—" ;; esac
        [ -z "$nmac" ] && nmac="—"
        [ -z "$npcie_cap" ] && npcie_cap="—"
        NIC_DETAILS="${NIC_DETAILS}${nnic}|${nnbdf}|${nmac}|${nsn}|${npn}|${nfw}|${npcie_cap}|${npsid}|${gd_mark}|${nchip}"$'\n'
    done < <(grep -v "^#" "${nic_inventory}" 2>/dev/null)
fi

# ─── 风扇（IPMI 传感器，| 分隔格式） ───
FAN_DIR="${OUT}/fan"
load_manifest "${FAN_DIR}" ipmi_fan_sensors "ipmi_fan_sensors.log"
# 风扇匹配：兼容 Fan10_Speed_F / FAN1_Speed / Fan2 等大小写变体；只统计转速传感器（_Speed/_RPM），跳过 Present 等离散值
FAN_COUNT=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{c++} END{print c+0}')
FAN_MIN=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{gsub(/ /,"",$2); if($2 ~ /^[0-9]+\.[0-9]+$/) sub(/\.?0+$/,"",$2); print $2}' | sort -n | head -1)
FAN_MAX=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{gsub(/ /,"",$2); if($2 ~ /^[0-9]+\.[0-9]+$/) sub(/\.?0+$/,"",$2); print $2}' | sort -n | tail -1)
FAN_SPEED=""
[ -n "$FAN_MIN" ] && FAN_SPEED="${FAN_MIN}-${FAN_MAX} RPM"

# 风扇每风扇明细
FAN_DETAILS=""
if [ -f "${ipmi_fan_sensors}" ]; then
    FAN_DETAILS=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{
        name=$1; gsub(/^ +| +$/,"",name)
        val=$2; gsub(/^ +| +$/,"",val)
        # 转速去尾零（9300.000 → 9300）
        if(val ~ /^[0-9]+\.[0-9]+$/) {sub(/\.?0+$/,"",val)}
        status=$4; gsub(/^ +| +$/,"",status)
        print name"|"val"|"status
    }')
fi

# ─── PSU 清单（ipmi_psu_fru.log：FRU 描述/型号/PN/SN） ───
# 状态机：desc 行出现时输出上一个 FRU（PN/SN 在 Name 之后，须延迟一行）；
# 只保留 PSU 行（PSU1_FRU/PSU4_FRU/Power Supply），过滤风扇/背板/PDB 等其他 FRU
PSU_DIR="${OUT}/psu"
load_manifest "${PSU_DIR}" ipmi_psu_fru "ipmi_psu_fru.log"
# 采集端 head -80 可能截断 FRU 列表（B300 23+ FRU，PSU9 排末尾被切）：
# psu 目录日志 PSU 数 < BMC 完整日志时，fallback 用 bmc/ipmi_fru_all.log（无截断）
_fru_src="${ipmi_psu_fru}"
if [ -f "$_fru_src" ] && [ -f "${OUT}/bmc/ipmi_fru_all.log" ]; then
    _n_psu=$(grep -c "FRU Device Description : PSU" "$_fru_src" 2>/dev/null)
    _n_full=$(grep -c "FRU Device Description : PSU" "${OUT}/bmc/ipmi_fru_all.log" 2>/dev/null)
    [ "${_n_full:-0}" -gt "${_n_psu:-0}" ] && _fru_src="${OUT}/bmc/ipmi_fru_all.log"
fi
PSU_DETAILS=""
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
    psu_power_csv="${PSU_DIR}/ipmi_psu_sensors.log"
    # 回退：部分平台（如 Inventec）FRU 不暴露 PSU 条目，但传感器有 PSU*_Temp —— 用传感器生成占位行
    if [ -z "$PSU_DETAILS" ] && [ -f "$psu_power_csv" ]; then
        PSU_DETAILS=$(grep -v "^#" "$psu_power_csv" 2>/dev/null | awk -F'|' '
            tolower($1) ~ /psu[0-9]+_temp/ {
                num=$1; gsub(/[^0-9]/, "", num)
                if(num!="" && !seen[num]++) printf "PSU%s|N/A|N/A|N/A|N/A|N/A\n", num
            }')
    fi
    # 整机功耗（Total_Power 行首精确匹配，避免误取 CPU_Total_Power/MEM_Total_Power 等分段功耗）
    total_pwr=$(grep -v "^#" "${PSU_DIR}/ipmi_psu_power.log" 2>/dev/null | awk -F'|' 'tolower($1) ~ /^total_power/{gsub(/ /,"",$2); print $2"W"; exit}')
    [ -n "$total_pwr" ] && PSU_DETAILS="${PSU_DETAILS}"$'\n'"整机功耗|N/A|N/A|N/A|N/A|${total_pwr}"$'\n'
    # 每只 PSU 当前输入功率（ipmi_psu_sensors.log: Pwr_PSU<N>_In | W |），按编号匹配追加
    psu_power_csv="${PSU_DIR}/ipmi_psu_sensors.log"
    if [ -f "$psu_power_csv" ] && [ -n "$PSU_DETAILS" ] && grep -q "Pwr_PSU[0-9]" "$psu_power_csv" 2>/dev/null; then
        # 一次性构建 编号→功率 映射，再一次性追加（避免逐行 echo|awk 嵌套性能灾难）
        PSU_DETAILS=$(awk -v psu_detail="$PSU_DETAILS" '
            BEGIN { FS="|"; OFS="|" }
            /Pwr_PSU[0-9]+_In/ {
                num=$1; sub(/.*Pwr_PSU/, "", num); sub(/_In.*/, "", num)
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
                    # 标称容量：从型号解析（DLG3200=3200W, DLG2600=2600W, DLG2000=2000W, DLG1600=1600W...）
                    model=f[2]
                    cap=""
                    if(model ~ /3200/) cap="3200W"
                    else if(model ~ /2600/) cap="2600W"
                    else if(model ~ /2200/) cap="2200W"
                    else if(model ~ /2000/) cap="2000W"
                    else if(model ~ /1600/) cap="1600W"
                    else if(model ~ /1400/) cap="1400W"
                    else if(model ~ /1300/) cap="1300W"
                    else if(model ~ /1200/) cap="1200W"
                    else if(model ~ /1000/) cap="1000W"
                    else if(model ~ /800/) cap="800W"
                    else if(model ~ /550/) cap="550W"
                    else if(model ~ /500/) cap="500W"
                    else cap="N/A"
                    cur_power="N/A"
                    if(pnum!="" && (pnum in power)) cur_power=power[pnum]
                    if(cap!="N/A") print line "|" cap "|" cur_power
                    else print line "|N/A|" cur_power
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
        rvd=$(grep -cE "VD [0-9]+|/v[0-9]+" "${RAID_DIR}/ctrl${raidx}_vd_all.log" 2>/dev/null)
        [ -z "$rvd" ] && rvd=0
        RAID_DETAILS="${RAID_DETAILS}c${raidx}|${rmodel:-N/A}|${rsn:-N/A}|${rfw:-N/A}|${rvd}"$'\n'
        raidx=$((raidx + 1))
    done
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
    HBA_DETAILS="${HBA_DETAILS}${hname}|${htype:-N/A}|${hfw:-N/A}|${hsn:-N/A}|${hstat:-N/A}"$'\n'
done

# ─── 生成 JSON ───
gen_json() {
    local f="${OUT}/hwscope_report.json"
    # 内存插槽明细 JSON 数组（slot|size|mfr|sn|pn|nom|cur|rank）
    local dimms_json=""
    if [ -n "$MEM_DIMMS" ]; then
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur drank; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_json="${dimms_json}      {\"index\": \"${dseq}\", \"slot\": \"${dslot}\", \"size\": \"${dsize}\", \"manufacturer\": \"${dmfr}\", \"serial\": \"${dsn}\", \"part_number\": \"${dpn}\", \"nominal_speed\": \"${dnom}\", \"current_speed\": \"${dcur}\", \"rank\": \"${drank:-N/A}\"},"$'\n'
        done <<< "$MEM_DIMMS"
        dimms_json=$(printf '%s' "$dimms_json" | sed '$ s/,$//')
    fi
    # GPU 每卡明细 JSON 数组（idx|name|serial|mem|power|temp|util|pcie_cur|pcie_max）
    local gpu_details_json=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存标注标称（如 B300: 268.6 GiB (标称288GB)）
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax; do
            [ -z "$gidx" ] && continue
            gpu_details_json="${gpu_details_json}      {\"index\": \"${gidx}\", \"name\": \"${gname}\", \"serial\": \"${gsn}\", \"memory\": \"${gmem}\", \"memory_spec\": \"${gmem_spec}\", \"memory_used\": \"${gused_f:-N/A}\", \"power\": \"${gdraw}\", \"temp\": \"${gtemp}\", \"util\": \"${gutil}\", \"pcie\": \"${gpcie}\", \"pcie_max\": \"${gmax}\"},"$'\n'
        done <<< "$GPU_DETAILS"
        gpu_details_json=$(printf '%s' "$gpu_details_json" | sed '$ s/,$//')
    fi
    # 盘明细 JSON 数组（name|type|size|model|sn|fw|bdf|power_on）
    local disk_details_json=""
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec; do
            [ -z "$dname" ] && continue
            disk_details_json="${disk_details_json}      {\"name\": \"${dname}\", \"type\": \"${dtype}\", \"size\": \"${dsize}\", \"model\": \"${dmodel}\", \"serial\": \"${dsn}\", \"firmware\": \"${dfw}\", \"bdf\": \"${dbdf}\", \"power_on_h\": \"${dpo}\", \"power_cyc\": \"${dpc}\", \"spare\": \"${dspare}\", \"size_spec\": \"${dspec}\"},"$'\n'
        done <<< "$DISK_DETAILS"
        disk_details_json=$(printf '%s' "$disk_details_json" | sed '$ s/,$//')
    fi
    # 网卡明细 JSON 数组（dev|bdf|mac|sn|pn|fw|speed|width）
    local nic_details_json=""
    if [ -n "$NIC_DETAILS" ]; then
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip; do
            [ -z "$nnic" ] && continue
            nic_details_json="${nic_details_json}      {\"dev\": \"${nnic}\", \"bdf\": \"${nnbdf}\", \"mac\": \"${nmac}\", \"serial\": \"${nsn}\", \"pn\": \"${npn}\", \"chip\": \"${nchip}\", \"firmware\": \"${nfw}\", \"pcie\": \"${npcie}\", \"psid\": \"${npsid}\", \"gpu_direct\": \"${ngd}\"},"$'\n'
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
    "report_generator": "${REPORT_VERSION:-unknown}",
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
    "board_serial": "${MB_BOARD_SN:-N/A}",
    "bios": "${BIOS_VERSION:-N/A}",
    "chassis_sn": "${CHASSIS_SN:-N/A}"
  },
  "cpu": {
    "model": "${CPU_MODEL:-N/A}",
    "cores": "${CPU_CORES:-N/A}",
    "cores_total": "${CPU_TOTAL_CORES:-N/A}",
    "sockets": "${CPU_SOCKETS:-N/A}",
    "stepping": "${CPU_STEPPING:-N/A}",
    "max_speed": "${CPU_MAX_SPEED:-N/A}",
    "current_speed": "${CPU_CUR_SPEED:-N/A}",
    "details": [
$(if [ -n "$CPU_DETAILS" ]; then
    echo "$CPU_DETAILS" | awk -F'|' '{printf "      {\"index\": \"%d\", \"socket\": \"%s\", \"model\": \"%s\", \"cores\": \"%s\", \"threads\": \"%s\", \"max_speed\": \"%s\", \"cur_speed\": \"%s\", \"stepping\": \"%s\", \"serial\": \"%s\"},\n", NR, $1, $2, $3, $4, $5, $6, $7, $8}' | sed '$ s/,$//'
fi)
    ]
  },
  "memory": {
    "total": "${MEM_TOTAL_PHYS:-${MEM_TOTAL:-N/A}}/${MEM_TOTAL:-N/A} 可见",
    "type": "${MEM_TYPE:-N/A}",
    "speed": "${MEM_SPEED:-N/A}",
    "speed_note": "${MEM_SPEED_NOTE:-}",
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
    "memory_spec": "${GPU_MEM_SPEC:-N/A}",
    "memory_spec_total": "${GPU_MEM_SPEC_TOTAL:-N/A}",
    "power_limit": "${GPU_POWER:-N/A}",
    "temp": "${GPU_TEMP:-N/A}",
    "ecc": "${GPU_ECC:-N/A}",
    "remapped_rows": "${GPU_REMAP:-N/A}",
    "vbios": "${GPU_VBIOS:-N/A}",
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
    "ib_active": "${IB_ACTIVE:-0}",
    "ib_active_speed": "${IB_ACTIVE_SPEED:-N/A}",
    "ib_nominal_speed": "${IB_NOMINAL:-N/A}",
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
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '      {"index": "%s", "description": "%s", "model": "%s", "part_number": "%s", "serial": "%s", "capacity": "%s", "power_in": "%s"},' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "${pcap:-N/A}" "${ppower:-N/A}"
        echo ""
    done <<< "$PSU_DETAILS" | sed '$ s/,$//'
fi)
    ]
  },
  "raid": [
$(if [ -n "$RAID_DETAILS" ]; then
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd; do
        [ -z "$ridx" ] && continue
        printf '    {"controller": "%s", "model": "%s", "serial": "%s", "firmware": "%s", "virtual_disks": "%s"},\n' "$ridx" "$rmodel" "$rsn" "$rfw" "$rvd"
    done | sed '$ s/,$//'
fi)
  ],
  "hba": [
$(if [ -n "$HBA_DETAILS" ]; then
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat; do
        [ -z "$hname" ] && continue
        printf '    {"controller": "%s", "model": "%s", "firmware": "%s", "serial": "%s", "status": "%s"},\n' "$hname" "$htype" "$hfw" "$hsn" "$hstat"
    done | sed '$ s/,$//'
fi)
  ],
  "nvswitch": [
$(printf '%s' "$nvs_json")
  ],
  "health": {
    "gpu_pcie_degraded": "${GPU_DEGRADED:-OK}",
    "nvlink_status": "${NVLINK_HEALTH:-N/A}",
    "nvlink_crc_errors": "${NVLINK_CRC:+存在非零CRC错误}",
    "dcgm_diag": "${DCGM_SUMMARY:-N/A}",
    "sel_pcie_errors": "${SEL_PCIE_ERR:-0}",
    "cable_pairs": "${CABLE_PAIRS:-N/A}"
  }
}
EOF
    echo -e "${GREEN}[REPORT] JSON: ${f}${NC}"
}

# ─── 术语说明（交付报告末尾，解释报告内出现的专业词） ───
GLOSSARY_ENTRIES=(
    "IB|InfiniBand，高速互联网络（GPU/存储集群专用），速率代际 SDR→DDR→QDR→FDR→EDR→HDR→NDR→XDR 每代翻倍"
    "SDR/DDR/QDR/FDR/EDR/HDR/NDR/XDR|IB 速率代际：分别对应 10G/20G/40G/56G/100G/200G/400G/800G（单口 4X 计）"
    "标称速率|网卡硬件支持的最大速率（固件声明，无需接线即可读取）"
    "实际速率|当前链路协商速率（取决于对端交换机/线缆，未接为 Down）"
    "GPU直连|网卡与 GPU 处于同一 PCIe Switch（PIX），可做 GPU Direct RDMA 高速通信"
    "PIX/NODE/SYS|PCIe 拓扑连接类型：PIX=同一 Switch 直连，NODE=同 CPU/NUMA 节点，SYS=跨节点（延迟递增）"
    "NVLink|NVIDIA GPU 间高速互联总线（B300 每卡 18 条，53.125 GB/s/条）"
    "NVSwitch|NVLink 交换芯片，连接多卡实现全互联（B300 集成于 GPU 模块内）"
    "DCGM|NVIDIA Data Center GPU Manager，GPU 诊断工具（dcgmi diag）"
    "Persistence Mode|GPU 常驻模式；未开启时 DCGM 报配置类 Fail（非硬件故障）"
    "SEL|System Event Log，BMC 记录的系统事件日志（含硬件告警）"
    "BMC|基板管理控制器，服务器带外管理（IPMI/Redfish 远程管理接口）"
    "SXM|NVIDIA 数据中心 GPU 模块化形态（非 PCIe 插卡），如 B300 SXM6"
    "PSID|网卡产品 ID（Mellanox 卡标识，用于固件匹配）"
    "Rank|内存 Bank 分组，Rank 2 = 双列（每 DIMM 2 组存储阵列）"
    "DAC|Direct Attach Cable，铜缆直连线（短距高速连接）"
    "MT/s|Mega Transfers per second，内存每通道每秒传输次数（DDR5 常见 6400 MT/s）"
    "2DPC|DIMM Per Channel=每内存通道插 2 条；2DPC 满插时信号负载大，内存降速运行属平台规范正常现象（如 6400→5200 MT/s）"
    "退役行(Remapped Rows)|GPU 显存中检测到故障后自动重映射隐藏的行，计数>0 提示显存健康问题"
)

glossary_md() {
    local out=""
    local i=0
    for entry in "${GLOSSARY_ENTRIES[@]}"; do
        IFS='|' read -r term def <<< "$entry"
        out="${out}| **${term}** | ${def} |"$'\n'
        ((i++))
    done
    printf '%s' "$out"
}

glossary_txt() {
    local out=""
    for entry in "${GLOSSARY_ENTRIES[@]}"; do
        IFS='|' read -r term def <<< "$entry"
        out="${out}  ${term}: ${def}"$'\n'
    done
    printf '%s' "$out"
}

# 网络段附加行（线缆/配对/端口模式/MST 提示；空值不产生空行）
net_extra_txt() {
    local out=""
    [ -n "$CABLE_SUMMARY" ]   && [ "$CABLE_SUMMARY" != "N/A" ]   && out="${out}  线缆   : ${CABLE_SUMMARY}"$'\n'
    [ -n "$CABLE_PAIRS" ]     && [ "$CABLE_PAIRS" != "N/A" ]     && out="${out}  配对   : ${CABLE_PAIRS}"$'\n'
    [ -n "$LINKTYPE_SUMMARY" ] && [ "$LINKTYPE_SUMMARY" != "N/A" ] && out="${out}  端口模式: ${LINKTYPE_SUMMARY}"$'\n'
    [ -n "$MST_NOTICE" ]      && out="${out}  ⚠️ ${MST_NOTICE}"$'\n'
    printf '%s' "$out"
}

# 网络段附加行（Markdown 表格版；空值不产生空行）
net_extra_md() {
    local out=""
    [ -n "$CABLE_SUMMARY" ]   && [ "$CABLE_SUMMARY" != "N/A" ]   && out="${out}| 线缆类型 | ${CABLE_SUMMARY} |"$'\n'
    [ -n "$CABLE_PAIRS" ]     && [ "$CABLE_PAIRS" != "N/A" ]     && out="${out}| 线缆配对 | ${CABLE_PAIRS} |"$'\n'
    [ -n "$LINKTYPE_SUMMARY" ] && [ "$LINKTYPE_SUMMARY" != "N/A" ] && out="${out}| 端口模式 | ${LINKTYPE_SUMMARY} |"$'\n'
    [ -n "$MST_NOTICE" ]      && out="${out}| ⚠️ 提示 | ${MST_NOTICE} |"$'\n'
    printf '%s' "$out"
}

# ─── 生成 Markdown ───
gen_md() {
    local f="${OUT}/hwscope_report.md"
    # 内存插槽明细 Markdown 表
    local dimms_md=""
    if [ -n "$MEM_DIMMS" ]; then
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur drank; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_md="${dimms_md}| ${dseq} | ${dslot} | ${dsize} | ${dmfr} | ${dsn} | ${dpn} | ${dnom} | ${dcur} | ${drank:-N/A} |"$'\n'
        done <<< "$MEM_DIMMS"
    fi
    # GPU 每卡明细 Markdown 表
    local gpu_details_md=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存显示 默认(标称)/可用（如 288GB/268.6 GiB 可用），防止客户误读检测值为卡容量
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax; do
            [ -z "$gidx" ] && continue
            if [ -n "$gmem_spec" ]; then
                gpu_details_md="${gpu_details_md}| ${gidx} | ${gname} | ${gsn} | ${gmem_spec}/${gmem} 可用 | ${gdraw} | ${gtemp} | ${gutil} | ${gpcie} | ${gmax} |"$'\n'
            else
                gpu_details_md="${gpu_details_md}| ${gidx} | ${gname} | ${gsn} | ${gmem} | ${gdraw} | ${gtemp} | ${gutil} | ${gpcie} | ${gmax} |"$'\n'
            fi
        done <<< "$GPU_DETAILS"
    fi
    # 盘明细 Markdown 表
    local disk_details_md=""
    if [ -n "$DISK_DETAILS" ]; then
        local dn=0
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec; do
            [ -z "$dname" ] && continue
            dn=$((dn + 1))
            disk_details_md="${disk_details_md}| ${dn} | ${dname} | ${dtype} | ${dsize} | ${dmodel} | ${dsn} | ${dfw} | ${dbdf} | ${dpo} | ${dpc} | ${dspare} | ${dspec:-} |"$'\n'
        done <<< "$DISK_DETAILS"
    fi
    # 网卡明细 Markdown 表
    local nic_details_md=""
    if [ -n "$NIC_DETAILS" ]; then
        local nn=0
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip; do
            [ -z "$nnic" ] && continue
            nn=$((nn + 1))
            if [ "$GPU_TOPO_AVAIL" -eq 1 ]; then
                nic_details_md="${nic_details_md}| ${nn} | ${nnic} | ${nnbdf} | ${nmac} | ${nsn} | ${npn} | ${nchip:-} | ${nfw} | ${npcie} | ${npsid} | ${ngd:-} |"$'\n'
            else
                nic_details_md="${nic_details_md}| ${nn} | ${nnic} | ${nnbdf} | ${nmac} | ${nsn} | ${npn} | ${nchip:-} | ${nfw} | ${npcie} | ${npsid} |"$'\n'
            fi
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
        local fn=0
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fn=$((fn + 1))
            fan_details_md="${fan_details_md}| ${fn} | ${fname} | ${frpm} | ${fstatus} |"$'\n'
        done <<< "$FAN_DETAILS"
    fi
    cat > "$f" << EOF
# HwScope 硬件巡检报告

**采集版本:** ${VERSION:-unknown} · **报告生成器:** ${REPORT_VERSION:-unknown} · **主机:** ${HOSTNAME:-unknown} · **平台:** ${PLATFORM:-unknown} · **时间:** ${TIMESTAMP:-unknown}

## 环境
| 项 | 值 |
|----|----|
| OS | ${OS_NAME:-N/A} |
| 内核 | ${KERNEL:-N/A} |
| 驱动 | ${GPU_DRIVER:-N/A} |
| CUDA | ${GPU_CUDA:-N/A} |
| 采集耗时 | ${TIMING_TOTAL:-N/A} |

## 主板
| 项 | 值 |
|----|----|
| 制造商 | ${MB_MANUFACTURER:-N/A} |
| 型号 | ${MB_PRODUCT:-N/A} |
| SN | ${MB_SN:-N/A} |
| 主板 SN | ${MB_BOARD_SN:-N/A} |
| BIOS | ${BIOS_VERSION:-N/A} |
| 机箱 SN | ${CHASSIS_SN:-N/A} |

## CPU
| 项 | 值 |
|----|----|
| 型号 | ${CPU_MODEL:-N/A} |
| 核心数 | ${CPU_CORES:-N/A}/颗 × ${CPU_SOCKETS:-N/A} 路 = ${CPU_TOTAL_CORES:-N/A} 总核 |
| 插槽数 | ${CPU_SOCKETS:-N/A} |
| Stepping | ${CPU_STEPPING:-N/A} |
| 频率 | ${CPU_MAX_SPEED:-N/A} MHz（当前 ${CPU_CUR_SPEED:-N/A} MHz） |
$(if [ -n "$CPU_DETAILS" ]; then
    local cseq=0
    local c_has_sn=0
    # 检测是否有任何 CPU 有真实 SN（Not Specified 已置空）
    while IFS='|' read -r cs cm cc ct cmx ccur cstep csn; do
        [ -z "$cs" ] && continue
        [ -n "$csn" ] && c_has_sn=1
    done <<< "$CPU_DETAILS"
    echo "### CPU 明细"
    if [ "$c_has_sn" -eq 1 ]; then
        echo "| # | Socket | 型号 | 核心 | 线程 | 最大频率 | 当前频率 | Stepping | SN |"
        echo "|---|--------|------|------|------|---------|---------|----------|----|"
        echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep csn; do
            cseq=$((cseq + 1))
            echo "| ${cseq} | ${cs} | ${cm} | ${cc} | ${ct} | ${cmx} | ${ccur} | ${cstep} | ${csn:-} |"
        done
    else
        echo "| # | Socket | 型号 | 核心 | 线程 | 最大频率 | 当前频率 | Stepping |"
        echo "|---|--------|------|------|------|---------|---------|----------|"
        echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep csn; do
            cseq=$((cseq + 1))
            echo "| ${cseq} | ${cs} | ${cm} | ${cc} | ${ct} | ${cmx} | ${ccur} | ${cstep} |"
        done
    fi
fi)

## 内存
| 项 | 值 |
|----|----|
| 总量 | ${MEM_TOTAL_PHYS:-${MEM_TOTAL:-N/A}}/${MEM_TOTAL:-N/A} 可见 |
| 类型 | ${MEM_TYPE:-N/A} |
| 速率 | ${MEM_SPEED:-N/A} ${MEM_SPEED_NOTE:-} |
| 插槽 | ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} |

### 插槽明细
| # | 插槽 | 容量 | 厂商 | SN | 部件号 | 原速率 | 现速率 | Rank |
|----|------|------|------|----|--------|--------|--------|------|
$(printf '%s' "$dimms_md")

## GPU
| 项 | 值 |
|----|----|
| 数量 | ${GPU_COUNT:-0} |
| 型号 | ${GPU_NAMES:-N/A} |
| 显存总量 | ${GPU_MEM_SPEC_TOTAL:-${GPU_MEM:-N/A}}/${GPU_MEM:-N/A} 可用${GPU_MEM_SPEC:+ (${GPU_MEM_SPEC})} |
| 功耗上限 | ${GPU_POWER:-N/A} |
| 温度 | ${GPU_TEMP:-N/A} |
| ECC | ${GPU_ECC:-N/A} |
| 退役行 | ${GPU_REMAP:-N/A} |
| VBIOS | ${GPU_VBIOS:-N/A} |
$(if [ -n "$NV_LINK_SUMMARY" ] && [ "$NV_LINK_SUMMARY" != "N/A" ]; then echo "| NVLink | ${NV_LINK_SUMMARY} |"; fi)

### 每卡明细
| 卡 | 型号 | SN | 显存(默认/可用) | 功耗 | 温度 | 利用率 | PCIe 当前 | PCIe 最大 |
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
| # | 设备 | 类型 | 容量 | 型号 | SN | 固件 | BDF | 通电(h) | 通电次数 | 寿命% | 标称 |
|---|------|------|------|------|----|------|-----|---------|----------|-------|------|
$(printf '%s' "$disk_details_md")

## 网络
| 项 | 值 |
|----|----|
| IB 设备数 | ${IB_COUNT:-0} |
| IB 活动口 | ${IB_ACTIVE:-0}${IB_ACTIVE_SPEED:+ (${IB_ACTIVE_SPEED})} |
| IB 标称速率 | ${IB_NOMINAL:-N/A} |
| 以太网口 up | ${ETH_LINK_UP:-0} |
$(net_extra_md)

### 网卡明细
$(if [ "$GPU_TOPO_AVAIL" -eq 1 ]; then
    echo "| # | 接口 | BDF | MAC | SN | 型号 | 芯片 | 固件 | PCIe | PSID | GPU直连 |"
    echo "|---|------|-----|-----|----|------|------|------|------|------|------|"
else
    echo "| # | 接口 | BDF | MAC | SN | 型号 | 芯片 | 固件 | PCIe | PSID |"
    echo "|---|------|-----|-----|----|------|------|------|------|------|"
fi)
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
    echo "| # | 风扇 | 转速(RPM) | 状态 |"
    echo "|---|------|----------|------|"
    local fan_seq=0
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        fan_seq=$((fan_seq+1))
        echo "| ${fan_seq} | ${fname} | ${fval} | ${fstatus} |"
    done
fi)

## 电源 PSU
| # | 描述 | 型号 | 部件号 | 序列号 | 标称容量 | 当前功耗 |
|----|------|------|--------|--------|---------|---------|
$(if [ -n "$PSU_DETAILS" ]; then
    local pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "${pcap:-N/A}" "${ppower:-N/A}"
    done <<< "$PSU_DETAILS"
fi)

$(if [ -n "$RAID_DETAILS" ]; then
    local rseq=0
    echo "## RAID 控制器"
    echo "| # | 控制器 | 型号 | SN | 固件 | 虚拟盘数 |"
    echo "|---|--------|------|----|------|---------|"
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd; do
        [ -z "$ridx" ] && continue
        rseq=$((rseq + 1))
        echo "| ${rseq} | ${ridx} | ${rmodel} | ${rsn} | ${rfw} | ${rvd} |"
    done
fi)

$(if [ -n "$HBA_DETAILS" ]; then
    local hseq=0
    echo "## HBA 直通卡"
    echo "| # | 控制器 | 型号 | 固件 | SN | 状态 |"
    echo "|---|--------|------|------|----|------|"
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat; do
        [ -z "$hname" ] && continue
        hseq=$((hseq + 1))
        echo "| ${hseq} | ${hname} | ${htype} | ${hfw} | ${hsn} | ${hstat} |"
    done
fi)

$(if [ -n "$nvs_md" ]; then
    echo "## NVSwitch"
    echo "| 编号 | 状态 | 温度 | 活动/总端口 |"
    echo "|------|------|------|-------------|"
    printf '%s' "$nvs_md"
fi)

## 健康检查
| 项 | 状态 |
|----|------|
| GPU PCIe 链路 | ${GPU_DEGRADED:-✓ 全部正常} |
$(if [ "${NVLINK_HEALTH:-N/A}" != "N/A" ]; then echo "| NVLink | ${NVLINK_HEALTH}${NVLINK_CRC:+ (存在CRC错误)} |"; fi)
$(if [ -n "$DCGM_SUMMARY" ] && [ "$DCGM_SUMMARY" != "N/A" ]; then echo "| DCGM 诊断 | ${DCGM_SUMMARY} |"; fi)$(if [ -n "$DCGM_NOTICE" ]; then echo "| ⚠️ DCGM | ${DCGM_NOTICE} |"; fi)
| SEL PCIe 错误 | ${SEL_PCIE_ERR:-0} 条 |
| 线缆配对 | ${CABLE_PAIRS:-N/A} |

---
## 术语说明

| 术语 | 说明 |
|------|------|
$(glossary_md)
$(if [ -n "$NIC_MLX" ]; then
    echo ""
    echo "### 网卡型号对照（MT 编号 → 型号，lspci 直读优先）"
    echo ""
    echo "| MT 编号 | 型号 |"
    echo "|---------|------|"
    echo "| MT4131 | ConnectX-8 |"
    echo "| MT4129 / MT2910 / MT4125 | ConnectX-7 |"
    echo "| MT4124 | ConnectX-6 Lx |"
    echo "| MT4123 | ConnectX-6 Dx |"
    echo "| MT4121 / MT4122 | ConnectX-6 |"
    echo "| MT2892 / MT2893 | ConnectX-5 |"
    echo "| MT2884 / MT2883 | ConnectX-4 |"
fi)
---
*由 HwScope ${REPORT_VERSION:-unknown} 报告生成器生成（数据采集版本: ${VERSION:-unknown}）*

> 数据来源说明：本报告所有数值均从采集日志提取（只读解析，不重新采集）。检测值为采集时刻的实际状态；
> 标注"标称"的为硬件规格（如 GPU 显存 288GB 标称 vs 268.6 GiB 检测可见值，差异为 ECC/显存预留）。
> 各段明细见 output/&lt;SN&gt;/&lt;模块&gt;/ 下的原始日志。
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
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur drank; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_txt="${dimms_txt}    ${dseq}. ${dslot}  ${dsize}  ${dmfr}  SN:${dsn}  P/N:${dpn}  标称${dnom}/现${dcur}  Rank:${drank:-N/A}"$'\n'
        done <<< "$MEM_DIMMS"
    fi
    # GPU 每卡明细纯文本
    local gpu_details_txt=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存显示 默认(标称)/可用（如 288GB/268.6 GiB 可用）
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax; do
            [ -z "$gidx" ] && continue
            if [ -n "$gmem_spec" ]; then
                gpu_details_txt="${gpu_details_txt}    GPU${gidx}  ${gname}  SN:${gsn}  ${gmem_spec}/${gmem} 可用  ${gdraw}  ${gtemp}  util:${gutil}  PCIe:${gpcie}/${gmax}"$'\n'
            else
                gpu_details_txt="${gpu_details_txt}    GPU${gidx}  ${gname}  SN:${gsn}  ${gmem}  ${gdraw}  ${gtemp}  util:${gutil}  PCIe:${gpcie}/${gmax}"$'\n'
            fi
        done <<< "$GPU_DETAILS"
    fi
    # 盘明细纯文本
    local disk_details_txt=""
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec; do
            [ -z "$dname" ] && continue
            disk_details_txt="${disk_details_txt}    ${dname}  ${dtype}  ${dsize}  ${dmodel}  SN:${dsn}  FW:${dfw}  ${dbdf}  ${dpo}h  cyc:${dpc}  spare:${dspare}  ${dspec:-}"$'\n'
        done <<< "$DISK_DETAILS"
    fi
    # 网卡明细纯文本
    local nic_details_txt=""
    if [ -n "$NIC_DETAILS" ]; then
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip; do
            [ -z "$nnic" ] && continue
            if [ "$GPU_TOPO_AVAIL" -eq 1 ]; then
                nic_details_txt="${nic_details_txt}    ${nnic}  ${nnbdf}  ${nmac}  SN:${nsn}  ${npn}  FW:${nfw}  PCIe:${npcie}  PSID:${npsid}  ${ngd:-}${nchip:+ 芯片:${nchip}}"$'\n'
            else
                nic_details_txt="${nic_details_txt}    ${nnic}  ${nnbdf}  ${nmac}  SN:${nsn}  ${npn}  FW:${nfw}  PCIe:${npcie}  PSID:${npsid}${nchip:+ 芯片:${nchip}}"$'\n'
            fi
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
采集版本: ${VERSION:-unknown}    报告生成器: ${REPORT_VERSION:-unknown}    主机: ${HOSTNAME:-unknown}
平台: ${PLATFORM:-unknown}   时间: ${TIMESTAMP:-unknown}

[环境]
  OS     : ${OS_NAME:-N/A}
  内核   : ${KERNEL:-N/A}
  驱动   : ${GPU_DRIVER:-N/A}
  CUDA   : ${GPU_CUDA:-N/A}
  采集耗时 : ${TIMING_TOTAL:-N/A}

[主板]
  制造商 : ${MB_MANUFACTURER:-N/A}
  型号   : ${MB_PRODUCT:-N/A}
  SN     : ${MB_SN:-N/A}
  主板SN : ${MB_BOARD_SN:-N/A}
  BIOS   : ${BIOS_VERSION:-N/A}
  机箱SN : ${CHASSIS_SN:-N/A}

[CPU]
  型号   : ${CPU_MODEL:-N/A}
  核心数 : ${CPU_CORES:-N/A}/颗 × ${CPU_SOCKETS:-N/A} 路 = ${CPU_TOTAL_CORES:-N/A} 总核
  插槽数 : ${CPU_SOCKETS:-N/A}
  Stepping: ${CPU_STEPPING:-N/A}
  频率   : ${CPU_MAX_SPEED:-N/A} MHz (当前 ${CPU_CUR_SPEED:-N/A} MHz)
$(if [ -n "$CPU_DETAILS" ]; then
    echo "  CPU明细:"
    echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep csn; do
        if [ -n "$csn" ]; then
            printf "    %-6s %-30s %sC/%sT  %s/%s  %s  SN:%s\n" "$cs" "$cm" "$cc" "$ct" "$cmx" "$ccur" "$cstep" "$csn"
        else
            printf "    %-6s %-30s %sC/%sT  %s/%s  %s\n" "$cs" "$cm" "$cc" "$ct" "$cmx" "$ccur" "$cstep"
        fi
    done
fi)

[内存]
  总量   : ${MEM_TOTAL_PHYS:-${MEM_TOTAL:-N/A}}/${MEM_TOTAL:-N/A} 可见
  类型   : ${MEM_TYPE:-N/A}
  速率   : ${MEM_SPEED:-N/A} ${MEM_SPEED_NOTE:-}
  插槽   : ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A}
$(printf '%s' "$dimms_txt")

[GPU]
  数量   : ${GPU_COUNT:-0}
  型号   : ${GPU_NAMES:-N/A}
  显存   : ${GPU_MEM_SPEC_TOTAL:-${GPU_MEM:-N/A}}/${GPU_MEM:-N/A} 可用${GPU_MEM_SPEC:+ (${GPU_MEM_SPEC})}
  功耗   : ${GPU_POWER:-N/A}
  温度   : ${GPU_TEMP:-N/A}
  ECC    : ${GPU_ECC:-N/A}
  退役行 : ${GPU_REMAP:-N/A}
  VBIOS  : ${GPU_VBIOS:-N/A}
$(if [ -n "$NV_LINK_SUMMARY" ] && [ "$NV_LINK_SUMMARY" != "N/A" ]; then echo "  NVLink   : ${NV_LINK_SUMMARY}"; fi)
$(printf '%s' "$gpu_details_txt")

[存储]
  盘数   : ${STORAGE_COUNT:-0}
  总容量 : ${STORAGE_TOTAL:-N/A}
  盘型号 : ${STORAGE_MODELS:-N/A}
  系统盘 : ${SYS_DISK:-N/A} (已从统计排除)
$(printf '%s' "$disk_details_txt")

[网络]
  IB设备 : ${IB_COUNT:-0}
  活动口 : ${IB_ACTIVE:-0}${IB_ACTIVE_SPEED:+ (${IB_ACTIVE_SPEED})}
  标称速率: ${IB_NOMINAL:-N/A}
  网口up : ${ETH_LINK_UP:-0}
$(net_extra_txt)$(printf '%s' "$nic_details_txt")

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
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '  %s. %s  %s  PN:%s  SN:%s  容量:%s  当前功耗:%s\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "${pcap:-N/A}" "${ppower:-N/A}"
    done <<< "$PSU_DETAILS"
else echo "  N/A"; fi)

$(if [ -n "$RAID_DETAILS" ]; then
    echo "[RAID控制器]"
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd; do
        [ -z "$ridx" ] && continue
        printf '  %s  %s  SN:%s  固件:%s  虚拟盘:%s\n' "$ridx" "$rmodel" "$rsn" "$rfw" "$rvd"
    done
fi)

$(if [ -n "$HBA_DETAILS" ]; then
    echo "[HBA直通卡]"
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat; do
        [ -z "$hname" ] && continue
        printf '  %s  %s  固件:%s  SN:%s  状态:%s\n' "$hname" "$htype" "$hfw" "$hsn" "$hstat"
    done
fi)

$(if [ -n "$nvs_txt" ]; then
    echo "[NVSwitch]"
    printf '%s' "$nvs_txt"
fi)

[健康检查]
  PCIe链路 : ${GPU_DEGRADED:-✓ 全部正常}
$(if [ "${NVLINK_HEALTH:-N/A}" != "N/A" ]; then echo "  NVLink   : ${NVLINK_HEALTH}${NVLINK_CRC:+ (存在CRC错误)}"; fi)
$(if [ -n "$DCGM_SUMMARY" ] && [ "$DCGM_SUMMARY" != "N/A" ]; then echo "  DCGM诊断 : ${DCGM_SUMMARY}"; fi)$(if [ -n "$DCGM_NOTICE" ]; then echo "  ⚠️ ${DCGM_NOTICE}"; fi)
  SEL PCIe : ${SEL_PCIE_ERR:-0} 条错误
  线缆配对 : ${CABLE_PAIRS:-N/A}

[术语说明]
$(glossary_txt)
$(if [ -n "$NIC_MLX" ]; then
    echo ""
    echo "网卡型号对照 (MT 编号 → 型号, lspci 直读优先):"
    echo "  MT4131=ConnectX-8  MT4129/MT2910/MT4125=ConnectX-7  MT4124=ConnectX-6 Lx"
    echo "  MT4123=ConnectX-6 Dx  MT4121/MT4122=ConnectX-6  MT2892/MT2893=ConnectX-5  MT2884/MT2883=ConnectX-4"
fi)
--------------------------------------------
数据来源说明: 本报告数值均从采集日志提取（只读解析，不重新采集）。
检测值为采集时刻实际状态；标注"标称"的为硬件规格（如 GPU 显存 288GB 标称 vs 268.6 GiB 检测可见值，差异为 ECC/显存预留）。
各段明细见 output/<SN>/<模块>/ 下原始日志。
--------------------------------------------
由 HwScope ${REPORT_VERSION:-unknown} 报告生成器生成（数据采集版本: ${VERSION:-unknown}）
EOF
    echo -e "${GREEN}[REPORT] TXT: ${f}${NC}"
}

# ─── 验收清单生成（--acceptance）───
# 逐项评估硬件状态，输出 hwscope_acceptance.md（交付交接单）
# 项状态: PASS=通过 / FAIL=不通过 / WARN=有条件通过 / N/A=无数据
gen_acceptance() {
    local f="${OUT}/hwscope_acceptance.md"
    local n=0 pass=0 fail=0 warn=0 na=0
    local rows="" st=""
    local verdict="合格"

    # 逐项评估函数：add_item "名称" "状态" "说明"
    add_item() {
        n=$((n + 1))
        case "$2" in
            PASS) pass=$((pass + 1)); st="✅ PASS" ;;
            FAIL) fail=$((fail + 1)); st="❌ FAIL" ;;
            WARN) warn=$((warn + 1)); st="⚠️ WARN" ;;
            *)    na=$((na + 1));     st="— N/A" ;;
        esac
        rows="${rows}| ${n} | $1 | ${st} | $3 |"$'\n'
    }

    # 1. GPU PCIe 链路完整（无 GPU 机器判 N/A，避免假阳性 PASS）
    if [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
        add_item "GPU PCIe 链路完整" "N/A" "无 GPU"
    elif [ -n "$GPU_DEGRADED" ]; then
        add_item "GPU PCIe 链路完整" "FAIL" "${GPU_DEGRADED%%,}（期望最高速率）"
    else
        add_item "GPU PCIe 链路完整" "PASS" "全部 GPU 处于最高 PCIe 速率"
    fi

    # 2. NVLink 互联
    case "${NVLINK_HEALTH:-N/A}" in
        OK)   add_item "NVLink 互联" "PASS" "全互联无降级链路" ;;
        异常) add_item "NVLink 互联" "FAIL" "存在降级链路${NVLINK_CRC:+，且有非零 CRC 错误}" ;;
        *)    add_item "NVLink 互联" "N/A" "无 topo 数据（旧采集或无 GPU）" ;;
    esac

    # 3. DCGM 诊断
    case "${DCGM_SUMMARY:-N/A}" in
        通过*) add_item "DCGM 诊断" "PASS" "${DCGM_SUMMARY}" ;;
        Fail*硬件*) add_item "DCGM 诊断" "FAIL" "${DCGM_SUMMARY}" ;;
        配置项*Fail*|Fail*) add_item "DCGM 诊断" "WARN" "${DCGM_SUMMARY}（软件/配置类，非硬件故障）" ;;
        *)     add_item "DCGM 诊断" "N/A" "未运行（DCGM 未安装或已禁用）" ;;
    esac

    # 4. SEL 无 Critical 事件（SEL 采集失败/无数据 → N/A，禁止假阳性 PASS）
    if [ "${SEL_DATA_VALID:-0}" -ne 1 ] 2>/dev/null; then
        add_item "SEL 无 Critical 事件" "N/A" "SEL 数据不可用（ipmitool 采集失败或无权限）"
    elif [ "${SEL_CRIT:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 无 Critical 事件" "FAIL" "共 ${SEL_TOTAL:-0} 条 SEL，其中 ${SEL_CRIT} 条 Critical"
    elif [ "${SEL_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 无 Critical 事件" "PASS" "${SEL_TOTAL} 条 SEL，无 Critical（有历史事件）"
    else
        add_item "SEL 无 Critical 事件" "PASS" "无 SEL 事件"
    fi

    # 5. SEL 无 PCIe 错误
    if [ "${SEL_DATA_VALID:-0}" -ne 1 ] 2>/dev/null; then
        add_item "SEL 无 PCIe 错误" "N/A" "SEL 数据不可用"
    elif [ "${SEL_PCIE_ERR:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 无 PCIe 错误" "FAIL" "${SEL_PCIE_ERR} 条 PCIe/AER/uncorrectable 记录"
    else
        add_item "SEL 无 PCIe 错误" "PASS" "无 PCIe 相关 SEL"
    fi

    # 6. 内存运行速率（2DPC 满插降速是平台规范/DDR5 物理必然，不算故障；未插满降速才提示；无数据 → N/A）
    if [ -z "$MEM_SPEED" ] || [ "$MEM_SPEED" = "N/A" ]; then
        add_item "内存运行速率" "N/A" "内存速率数据不可用"
    elif [ -n "$MEM_SPEED_NOTE" ]; then
        if [ "$MEM_FULL" -eq 1 ]; then
            add_item "内存运行速率" "PASS" "${MEM_SPEED_NOTE}（插满 ${MEM_POPULATED}/${MEM_SLOTS} 槽 2DPC，降速属平台规范正常现象）"
        else
            add_item "内存运行速率" "WARN" "${MEM_SPEED_NOTE}（仅插 ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} 槽仍降速，建议核查）"
        fi
    else
        add_item "内存运行速率" "PASS" "标称速率运行（${MEM_SPEED:-N/A}）"
    fi

    # 7. 线缆配对完整
    if [ -n "$CABLE_PAIRS" ]; then
        add_item "IB 线缆配对" "PASS" "${CABLE_PAIRS}"
    else
        add_item "IB 线缆配对" "N/A" "无线缆数据（非 IB 平台或旧采集）"
    fi

    # 8. 磁盘寿命充足（spare 第10列；<90% 提示，<50% FAIL；无盘数据 → N/A 禁止假阳性 PASS）
    local disk_warn="" disk_fail=""
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec; do
            [ -z "$dname" ] && continue
            local spare_num=$(echo "$dspare" | tr -dc '0-9')
            if [ -n "$spare_num" ]; then
                if [ "$spare_num" -lt 50 ] 2>/dev/null; then
                    disk_fail="${disk_fail}${dname}(${dspare}),"
                elif [ "$spare_num" -lt 90 ] 2>/dev/null; then
                    disk_warn="${disk_warn}${dname}(${dspare}),"
                fi
            fi
        done <<< "$DISK_DETAILS"
    fi
    if [ -z "$DISK_DETAILS" ]; then
        add_item "磁盘寿命" "N/A" "无数据盘或盘数据不可用"
    elif [ -n "$disk_fail" ]; then
        add_item "磁盘寿命" "FAIL" "${disk_fail%,}（寿命不足 50%）"
    elif [ -n "$disk_warn" ]; then
        add_item "磁盘寿命" "WARN" "${disk_warn%,}（寿命 <90%，建议关注）"
    else
        add_item "磁盘寿命" "PASS" "全部磁盘寿命充足"
    fi

    # 汇总判定（N/A 过多时不得判合格——数据不足无法验收）
    if [ "$fail" -gt 0 ]; then
        verdict="不合格（${fail} 项 FAIL，需处理后再交付）"
    elif [ "$warn" -gt 0 ]; then
        verdict="有条件通过（${warn} 项 WARN，建议记录后交付）"
    elif [ "$na" -ge 4 ]; then
        verdict="数据不足（${na} 项无数据，关键项缺失，无法完成验收判定）"
    elif [ "$na" -gt 0 ]; then
        verdict="基本通过（${na} 项无数据，其余项正常）"
    else
        verdict="合格（全部通过）"
    fi

    {
        echo "# HwScope 验收清单（Acceptance Checklist）"
        echo ""
        echo "- 机器: ${OUT##*/}"
        echo "- 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- 采集版本: ${VERSION:-unknown} / 报告版本: ${REPORT_VERSION:-unknown}"
        echo ""
        echo "## 验收项"
        echo ""
        echo "| # | 检查项 | 结果 | 说明 |"
        echo "|---|--------|------|------|"
        printf '%s' "$rows"
        echo ""
        echo "## 结论"
        echo ""
        echo "| 项 | 数值 |"
        echo "|----|------|"
        echo "| 通过 | ${pass} |"
        echo "| 警告 | ${warn} |"
        echo "| 失败 | ${fail} |"
        echo "| 无数据 | ${na} |"
        echo "| **判定** | **${verdict}** |"
        echo ""
        echo "---"
        echo "*由 HwScope ${REPORT_VERSION:-unknown} 生成（--acceptance 模式）*"
    } > "$f"
    echo -e "${GREEN}[REPORT] 验收清单: ${f}${NC}"
    echo -e "${GREEN}[REPORT] 判定: ${verdict}${NC}"
}

case "$FORMAT" in
    --json) gen_json ;;
    --md)   gen_md ;;
    --txt)  gen_txt ;;
    --acceptance) gen_acceptance ;;
    *)      gen_json; gen_md; gen_txt ;;
esac

echo -e "${GREEN}[REPORT] 生成完成${NC}"
