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

# ─── 参数解析（兼容: report.sh [dir] [--acceptance|--json|--md|--txt|--both] [--test-dir <path>] [--baseline <dir>]） ───
OUT=""; FORMAT=""; TEST_DIR=""; BASELINE_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --json|--md|--txt|--both|--acceptance) FORMAT="$1"; shift ;;
        --test-dir)
            TEST_DIR="$2"
            if [ -z "$TEST_DIR" ] || [ ! -d "$TEST_DIR" ]; then
                echo -e "${RED}[ERROR] --test-dir 需要有效压测目录路径（如 logs/test/20260818120000）${NC}"; exit 1
            fi
            shift 2 ;;
        --baseline)
            BASELINE_DIR="$2"
            if [ -z "$BASELINE_DIR" ] || [ ! -d "$BASELINE_DIR" ]; then
                echo -e "${RED}[ERROR] --baseline 需要有效历史采集目录路径${NC}"; exit 1
            fi
            shift 2 ;;
        --*) echo -e "${YELLOW}[WARN] 未知参数: $1${NC}"; shift ;;
        *)  [ -z "$OUT" ] && OUT="$1"; shift ;;
    esac
done
if [ -z "$OUT" ]; then
    OUT=$(ls -dt "${SCRIPT_DIR}/output"/*/ 2>/dev/null | head -1 | sed 's|/$||')
fi
[ -z "$OUT" ] || [ ! -d "$OUT" ] && echo -e "${RED}[ERROR] 未找到采集目录: $OUT${NC}" && exit 1
[ -z "$FORMAT" ] && FORMAT="both"
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
# HGX 机头标记（x86_64_head 等：PCIe Fabric 接模组，无本地 GPU；报告与验收清单使用专门文案）
HEAD_NODE=0
PLATFORM_LABEL="$PLATFORM"
case "$PLATFORM" in
    *_head) HEAD_NODE=1; PLATFORM_LABEL="${PLATFORM}（HGX 机头：PCIe Fabric 接模组，模组单独采集）" ;;
esac
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
# PCIe 拓扑（lspci 直读型号用，走 manifest 解耦）
PCIE_DIR="${OUT}/pcie"
load_manifest "${PCIE_DIR}" lspci_all "lspci_all.log"
# PCIe Fabric Switch（PEX89xxx/PEX97xxx/Switchtec）：提取无条件（JSON 字段需要原始检测值）；
# MD/TXT 展示仅在无 GPU 时（有 GPU 的一体化/SXM 主机主板也带 PEX89，单独展示会误导为"机头"）
FABRIC_SW=""
if [ -f "${lspci_all}" ]; then
    FABRIC_SW=$(grep -v "^#" "${lspci_all}" 2>/dev/null | grep -oiE "PEX89[0-9xX]*|PEX97[0-9xX]*|Switchtec [A-Za-z0-9]+" | sort -u | tr '\n' ',' | sed 's/,$//')
fi
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
# 速率：优先取实际运行速率（Configured Memory Speed），fallback 额定 Speed
MEM_SPEED=$(extract "Configured Memory Speed" "${dmidecode_memory_full}")
[ -z "$MEM_SPEED" ] && MEM_SPEED=$(extract "^[[:space:]]*Speed:" "${dmidecode_memory_full}")
MEM_SPEED_NOTE=""
# 降速检测：额定 Speed 与运行速率不一致时提示（如 6400 额定 / 5200 实际）
# 插满降速是 DDR5 物理必然（信号负载/散热），不算故障；未插满仍降速才需关注
# 正文保留提示（信息价值），验收清单判定时再结合插满状态区分
MEM_NOM=$(extract "^[[:space:]]*Speed:" "${dmidecode_memory_full}")
if [ -n "$MEM_SPEED" ] && [ -n "$MEM_NOM" ] && [ "$MEM_SPEED" != "$MEM_NOM" ] 2>/dev/null; then
    MEM_SPEED_NOTE="⚠️ 降速运行（额定 ${MEM_NOM}）"
fi
MEM_SLOTS=$(grep -c "Memory Device" "${dmidecode_memory_full}" 2>/dev/null)
MEM_POPULATED=$(grep -cE "^[[:space:]]*Size: [0-9]" "${dmidecode_memory_full}" 2>/dev/null)
# 插满状态标记（验收清单用：插满降速=正常，不算 WARN）
MEM_FULL=0
[ "${MEM_POPULATED:-0}" -ge "${MEM_SLOTS:-0}" ] 2>/dev/null && [ "${MEM_SLOTS:-0}" -gt 0 ] && MEM_FULL=1
# 每槽 DIMM 明细（插槽|容量|厂商|SN|部件号|原速率|现速率|Rank），空槽跳过
# 行模式状态机：从 "Memory Device" 段头开始，空行结束（Size 行在 Locator 之前）
# 速率语义：Speed=模块额定（原速率），Configured Memory Speed=当前实际运行（现速率）
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
# 物理额定总量（每槽 Size 求和，64GB×32=2048GB）——与系统可见(MEM_TOTAL)区分，需在 MEM_DIMMS 之后计算
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
    # 有效性守卫：nvidia-smi 失败时 csv 只有报错行（如 "NVIDIA-SMI has failed..."），不算 GPU 数据
    if grep -v "^#" "$GPU_CSV" | grep -qiE "NVIDIA-SMI has failed|couldn't communicate|No devices were found"; then
        GPU_CSV=""
    fi
fi
# GPU 硬件存在性（lspci 3D controller NVIDIA 数量）——区分「无 GPU」vs「有 GPU 但驱动异常/采集失败」
GPU_PCI_PRESENT=$(grep -c "3D controller: NVIDIA" "${lspci_all}" 2>/dev/null)
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
        gsub(/ MiB/, "", $col)
        sum += $col
    } END{printf "%.0f GiB", sum/1024}')
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
    # 额定显存候选：型号 → 候选 GB 列表（| 分隔，多版本给列表交叉验证选近者）；空=未知型号
    # 供第一卡（汇总展示）与逐卡魔改检测（混插/伪装识别）复用
    gpu_mem_candidates() {
        case "$1" in
            # ── 精确/长型号优先（防通用模式误配：A2 勿配 A2000、T4 勿配 T400、L4 勿配 L40）──
            *"RTX PRO 6000"*)        echo "96" ;;          # Blackwell 96GB GDDR7
            *"RTX PRO 5000 72GB"*)   echo "72" ;;
            *"RTX PRO 5000"*)        echo "32" ;;
            *"RTX PRO 4500"*)        echo "24" ;;
            *"RTX PRO 4000"*)        echo "20" ;;
            *"RTX PRO 2000"*)        echo "16" ;;
            *"RTX 6000 Ada"*)        echo "48" ;;
            *"RTX 6000D"*)           echo "48" ;;
            *"RTX 8000"*)            echo "48" ;;          # Turing 48GB
            *"RTX 6000"*)            echo "24|48" ;;       # Turing 24GB / Ada 48GB 同名不同容量
            *"RTX 5000 Ada"*)        echo "32" ;;
            *"RTX 4500 Ada"*)        echo "24" ;;
            *"RTX 4000 SFF Ada"*)    echo "20" ;;
            *"RTX 4000 Ada"*)        echo "20" ;;
            *"RTX 2000"*)            echo "16" ;;          # 2000 Ada / 2000E Ada
            *"RTX A2000"*)           echo "6|12" ;;
            *A1000*)                 echo "4|8" ;;          # 桌面8G/移动4G；无 RTX 前缀也匹配（防落到 A100 误配触发魔改误报）
            *"RTX A400"*)            echo "4" ;;
            *"RTX A6000"*)           echo "48" ;;
            *"RTX A5000"*)           echo "24" ;;
            *"RTX A4000"*)           echo "16" ;;
            *T1000*)                 echo "4" ;;
            *T600*)                  echo "4" ;;
            *T400*)                  echo "2" ;;
            *A5000*)                 echo "24" ;;
            *A4000*)                 echo "16" ;;
            # ── 数据中心/加速卡（长型号先匹配：GH200 须在 H200 前、L20 须在 L2 前防子串误配）──
            *B300*|*GB300*)          echo "288" ;;
            *B200*|*GB200*)          echo "192" ;;
            *GH200*)                 echo "96" ;;
            *H200*)                  echo "141" ;;
            *H20*)                   echo "96" ;;
            *H100*|*H800*)           echo "80" ;;
            *AX800*|*A100*|*A800*)   echo "40|80" ;;
            *A30*|*A10*)             echo "24" ;;
            *A16*)                   echo "16" ;;
            *A40*|*L40S*|*L40*|*L20*) echo "48" ;;
            *L2*)                    echo "24" ;;
            *V100*)                  echo "16|32" ;;
            *P100*)                  echo "12|16" ;;
            *P40*)                   echo "24" ;;
            *P4*)                    echo "8" ;;
            *L4*)                    echo "24" ;;
            *T4*)                    echo "16" ;;
            # ── 消费/游戏卡（魔改重灾区）──
            *"RTX 4090"*)            echo "24" ;;
            *"RTX 4080"*)            echo "16" ;;
            *"RTX 4070"*)            echo "12" ;;
            *"RTX 4060"*)            echo "8|16" ;;
            *"RTX 3090"*)            echo "24" ;;
            *"RTX 3080 Ti"*)         echo "12" ;;
            *"RTX 3080"*)            echo "10|12" ;;
            *"RTX 3070"*)            echo "8" ;;
            *"RTX 3060"*)            echo "12" ;;
            *"RTX 2080 Ti"*)         echo "11" ;;
            *"RTX 2080"*)            echo "8" ;;
            *"GTX 1080 Ti"*)         echo "11" ;;
            *"GTX 1080"*)            echo "8" ;;
            *A2*)                    echo "16" ;;          # 放最后防误配 A2000/A1000/A400
            *)                       echo "" ;;
        esac
    }
    if [ -n "$GPU_MODEL_LINE" ] && [ -n "$GPU_MEM_DET_MIB" ]; then
        _cands=$(gpu_mem_candidates "$GPU_MODEL_LINE")
        if [ -n "$_cands" ]; then
            # 交叉验证：找与检测 MiB 最接近的候选口径（GB 十进制≈953.674 MiB/GB；GiB=1024 MiB/GiB）
            _best_c="" _best_diff="" _best_mib=""
            for _c in ${_cands//|/ }; do
                for _mib in $(awk -v c="$_c" 'BEGIN{printf "%.0f %.0f", c*1000000000/1048576, c*1024}' < /dev/null); do
                    _diff=$(awk -v d="$GPU_MEM_DET_MIB" -v m="$_mib" 'BEGIN{printf "%.4f", (d>m?d-m:m-d)/d}' < /dev/null)
                    if [ -z "$_best_diff" ] || awk -v a="$_diff" -v b="$_best_diff" 'BEGIN{exit !(a<b)}'; then
                        _best_diff="$_diff"; _best_c="$_c"; _best_mib="$_mib"
                    fi
                done
            done
            if awk -v d="$_best_diff" 'BEGIN{exit !(d<0.03)}'; then
                GPU_MEM_SPEC="${_best_c}GB/卡"
            else
                GPU_MEM_MISMATCH=$(awk -v d="$GPU_MEM_DET_MIB" 'BEGIN{printf "%.0f", d/1024}' < /dev/null)
                GPU_MEM_SPEC="${_best_c}GB"
                GPU_MEM_SPEC_NOTE="⚠️ 检测 ${GPU_MEM_MISMATCH}GB 与额定 ${_best_c}GB 不符（疑似显存魔改或伪装，需核实）"
            fi
        fi
    fi
    GPU_POWER=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -v col="${power_col:-8}" -F',' '{
        gsub(/ W/, "", $col)
        if($col+0 > max+0) max = $col
    } END{printf "%.0f W", max}')
    GPU_TEMP=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -v col="${temp_col:-9}" -F',' '{
        t = $col
        sum += t
        if(t+0 > tmax+0) tmax = t
    } END{printf "%.0f°C (max %.0f)", sum/NR, tmax}')
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
        gvb_ver=$(grep -m1 "VBIOS Version" "$gf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
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
        STORAGE_MODELS=$(grep -v "^#" "${disk_inventory}" 2>/dev/null | awk -F'|' -v sys="$SYS_DISK" '$1!="" && $1!=sys && $4!="N/A" && $4!="" && $4 !~ /MegaRAID|MR[0-9][0-9][0-9]|PERC|Smart Array|Adaptec/ {print $4}' | sort -u | sed 's/\(^.\{40\}\).*/\1…/' | tr '\n' ',' | sed 's/,$//')
    else
        STORAGE_MODELS=$(grep -v "^#" "${block_devices_all}" | awk -v sys="$SYS_DISK" '$NF=="disk" && $1 != sys {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/ && $i != "0B") {print $(i-1); break}}' | sort -u | sed 's/\(^.\{40\}\).*/\1…/' | tr '\n' ',' | sed 's/,$//')
    fi
fi

# 盘明细（disk_inventory.csv: name|type|size|model|serial|fw|bdf|power_on）
# RAID 虚拟盘（逻辑盘）与物理盘分表：虚拟盘型号是 RAID 卡型号，SN 是 LUN，无 SMART，混在物理盘表会误导
DISK_DETAILS=""
RAID_VD_DETAILS=""
if [ -f "${disk_inventory}" ]; then
    while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare; do
        [ -z "$dname" ] || [ "$dname" = "N/A" ] && continue
        [ "$dname" = "#" ] && continue
        [ "$dname" = "$SYS_DISK" ] && continue   # 默认排除系统盘
        # RAID 虚拟盘判定：型号是 RAID 卡型号（MegaRAID/MRxxxx/PERC/Smart Array/Adaptec）
        is_raid_vd=0
        case "$dmodel" in
            *MegaRAID*|*MR[0-9][0-9][0-9]*|*PERC*|*"Smart Array"*|*Adaptec*|*ServeRAID*) is_raid_vd=1 ;;
        esac
        # 额定容量：优先从型号字符串自动提取（如 "PM1733a RI 3.84TB"、"MTFDKBA480TFR"→480GB），
        # Samsung 硬编码表兜底（型号无容量字样时）
        dspec=""
        case "$dmodel" in
            *MZWL61T9HFLT*|*MZWL61T9HBLN*) dspec="额定1.92TB" ;;
            *MZWL63T8HFLT*|*MZWL63T8HBLN*) dspec="额定3.84TB" ;;
            *MZWL67T6HFLT*) dspec="额定7.68TB" ;;
            *MZ7L31T9*|*MZ7LH1T9*) dspec="额定1.92TB" ;;
            *MZ7L33T8*|*MZ7LH3T8*) dspec="额定3.84TB" ;;
            *MZ7L37T6*) dspec="额定7.68TB" ;;
            *MZQL21T9*) dspec="额定1.92TB" ;;
            *MZQL23T8*) dspec="额定3.84TB" ;;
            *MZQL27T6*) dspec="额定7.68TB" ;;
            *MZIL21T6*) dspec="额定1.6TB" ;;
            *MZIL23T8*) dspec="额定3.2TB" ;;
            *MZIL27T6*) dspec="额定6.4TB" ;;
            *)
                # Micron 型号规则: MTFDKBA480TFR / MTFDHBE960TFR → 数字=容量GB（T 是家族代号非 TB）
                if echo "$dmodel" | grep -qE 'MTFD[KHC][A-Z]{2}[0-9]{3,4}TFR'; then
                    micap=$(echo "$dmodel" | grep -oE '[0-9]{3,4}TFR' | head -1 | grep -oE '[0-9]+')
                    [ -n "$micap" ] && dspec="额定${micap}GB"
                fi
                # 通用提取：型号中显式容量（3.84TB / 1.92T / 480G 等）
                if [ -z "$dspec" ]; then
                    cap=$(echo "$dmodel" | grep -oE '[0-9]+(\.[0-9]+)?[TtGg][Bb]?' | head -1)
                    if [ -n "$cap" ]; then
                        # 统一单位：T→TB，G→GB（保留一位小数）
                        num=$(echo "$cap" | grep -oE '[0-9]+(\.[0-9]+)?')
                        unit=$(echo "$cap" | grep -oE '[TtGg]' | tr '[:lower:]' '[:upper:]')
                        dspec="额定${num}${unit}B"
                    fi
                fi
                ;;
        esac
        # 寿命归一化：N/A%（未采集到 SMART 数据）→ 显示 "—"（避免客户误读为盘异常）
        case "$dspare" in
            ""|N/A|N/A%|na|NA) dspare="—" ;;
        esac
        # SMART 整体健康（overall-health PASSED/FAILED 或 NVMe Critical Warning 0x00）
        dhealth="—"
        _disk_ctl=$(echo "$dname" | sed 's/n[0-9]*$//')   # nvme0n1 → nvme0（控制器），sda → sda
        for _hlog in "smart_${dname}.log" "smart_${_disk_ctl}.log"; do
            [ -f "${STO_DIR}/$_hlog" ] || continue
            _h=$(grep -m1 -iE "SMART overall-health|SMART Health Status" "${STO_DIR}/$_hlog" 2>/dev/null)
            if [ -n "$_h" ]; then
                case "$_h" in
                    *PASSED*|*OK*) dhealth="PASSED" ;;
                    *FAILED*|*FAILING*|*BAD*) dhealth="FAILED" ;;
                esac
                break
            fi
            _cw=$(grep -m1 -i "Critical Warning" "${STO_DIR}/$_hlog" 2>/dev/null | grep -oE "0x[0-9a-fA-F]+" | head -1)
            if [ -n "$_cw" ]; then
                [ "$_cw" = "0x00" ] && dhealth="OK" || dhealth="⚠️${_cw}"
                break
            fi
        done
        # SN/FW 回退：disk_inventory 的 SN/FW 为 N/A 时，从 smartctl 日志回退（RAID 逻辑盘是 SCSI 格式 Serial number:/Revision:）
        if [ "$dsn" = "N/A" ] || [ -z "$dsn" ]; then
            for _slog in "smart_${dname}_scsi.log" "smart_${dname}.log"; do
                [ -f "${STO_DIR}/$_slog" ] || continue
                _s=$(grep -m1 -iE "^Serial number:" "${STO_DIR}/$_slog" 2>/dev/null | cut -d: -f2- | xargs)
                [ -z "$_s" ] && _s=$(grep -m1 -iE "^Serial Number:" "${STO_DIR}/$_slog" 2>/dev/null | cut -d: -f2- | xargs)
                if [ -n "$_s" ] && [ "$_s" != "N/A" ]; then dsn="$_s"; break; fi
            done
        fi
        if [ "$dfw" = "N/A" ] || [ -z "$dfw" ]; then
            for _slog in "smart_${dname}_scsi.log" "smart_${dname}.log"; do
                [ -f "${STO_DIR}/$_slog" ] || continue
                _f=$(grep -m1 -iE "^Revision:" "${STO_DIR}/$_slog" 2>/dev/null | cut -d: -f2- | xargs)
                [ -z "$_f" ] && _f=$(grep -m1 -iE "Firmware Version:" "${STO_DIR}/$_slog" 2>/dev/null | cut -d: -f2- | xargs)
                if [ -n "$_f" ] && [ "$_f" != "N/A" ]; then dfw="$_f"; break; fi
            done
        fi
        if [ "$is_raid_vd" -eq 1 ]; then
            RAID_VD_DETAILS="${RAID_VD_DETAILS}${dname}|${dmodel}|${dsize}|${dsn}"$'\n'
        else
            DISK_DETAILS="${DISK_DETAILS}${dname}|${dtype}|${dsize}|${dmodel}|${dsn}|${dfw}|${dbdf}|${dpo}|${dpc}|${dspare}|${dspec}|${dhealth}"$'\n'
        fi
    done < <(grep -v "^#" "${disk_inventory}" 2>/dev/null)
fi

# GPU 退役行数（gpu_remapped_rows.csv）
GPU_REMAP="N/A"
load_manifest "${GPU_DIR}" gpu_remapped_rows "gpu_remapped_rows.csv"
if [ -f "${gpu_remapped_rows}" ]; then
    GPU_REMAP=$(grep -v "^#" "${gpu_remapped_rows}" | grep -v "^$" | awk -F',' '{gsub(/ /,"",$1); gsub(/ /,"",$2); gsub(/ /,"",$3); gsub(/ /,"",$4); c+=$1; u+=$2; p+=$3; f+=$4} END{if(NR>0) printf "CE:%d UE:%d pending:%d fail:%d", c, u, p, f; else print "N/A"}')
fi

# VBIOS 版本（每卡 detail 聚合去重；混插时标不一致而非只取第一张卡）
GPU_VBIOS="N/A"
if [ "${#GPU_VBIOS_MAP[@]}" -gt 0 ]; then
    _vbios_agg=$(for _k in "${!GPU_VBIOS_MAP[@]}"; do echo "${GPU_VBIOS_MAP[$_k]}"; done | sort | uniq -c | sort -rn)
    _vbios_uniq=$(printf '%s\n' "$_vbios_agg" | wc -l)
    if [ "$_vbios_uniq" -eq 1 ]; then
        GPU_VBIOS=$(printf '%s\n' "$_vbios_agg" | awk '{print $2}')
    else
        GPU_VBIOS="⚠️ 不一致（$(printf '%s\n' "$_vbios_agg" | awk '{printf "%s×%s ", $2, $1}' | sed 's/ $//')）"
    fi
fi
# 回退：无每卡 detail 日志（旧数据）时用 gpu_full 取第一个（gpu_full 已在环境段 load）
if [ "$GPU_VBIOS" = "N/A" ] && [ -f "${gpu_full}" ]; then
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

# NVSwitch（nvswitch_N.log：状态/温度/端口；只匹配数字索引，避免把 nvswitch_smi_status.log 混入）
NVS_DIR="${OUT}/nvswitch"
NVS_DETAILS=""
if ls ${NVS_DIR}/nvswitch_[0-9]*.log >/dev/null 2>&1; then
    for nf in ${NVS_DIR}/nvswitch_[0-9]*.log; do
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
# B300/GB300 fallback：nvidia-smi nvswitch --status 输出（"Switch N:" 段 + NVSwitch State/Temperature/Link 行）
if [ -z "$NVS_DETAILS" ] && [ -f "${NVS_DIR}/nvswitch_smi_status.log" ]; then
    NVS_DETAILS=$(awk '
        /^Switch [0-9]+:/ { if(idx!="") flush(); idx=$2; gsub(/:/,"",idx); state=""; temp=""; pc=0 }
        idx!="" && /NVSwitch State/ { v=$0; sub(/.*:/,"",v); gsub(/ /,"",v); state=v }
        idx!="" && /NVSwitch Temperature/ { v=$0; sub(/.*:/,"",v); gsub(/ /,"",v); sub(/C.*/,"",v); temp=v }
        idx!="" && /Link [0-9]+ State/ { pc++ }
        function flush() {
            nstat=(state==""?"N/A":state)
            if(nstat!="Active" && nstat!="N/A") nstat=nstat" ⚠️"
            printf "%s|%s|%s°C|%s/%s\n", idx, nstat, (temp==""?"N/A":temp), pc+0, pc+0
        }
        END { if(idx!="") flush() }
    ' "${NVS_DIR}/nvswitch_smi_status.log" 2>/dev/null)
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
    if grep -qiE "No available testing entities|Unable to complete diagnostic|Return: \(-30\)|Couldn't find match" "${dcgmi_diag_level1}" 2>/dev/null; then
        if [ "$HEAD_NODE" -eq 1 ]; then
            DCGM_SUMMARY="N/A（HGX 机头无 GPU，模组单独采集）"
        else
            DCGM_SUMMARY="N/A（无 GPU/无测试实体，未运行诊断）"
        fi
    elif [ "$DCGM_SOFT_FAIL" -gt 0 ] || [ "$DCGM_HW_FAIL" -gt 0 ]; then
        DCGM_SUMMARY="Fail (软件:${DCGM_SOFT_FAIL} 硬件:${DCGM_HW_FAIL})"
        # 纯配置类 Fail（仅 Persistence Mode）→ 标注非硬件
        if [ "$DCGM_HW_FAIL" -eq 0 ] && [ "$DCGM_SOFT_FAIL" -gt 0 ] && [ "$DCGM_PERSIST" -ge "$DCGM_SOFT_FAIL" ]; then
            DCGM_SUMMARY="配置项 Fail (Persistence Mode 未开启, 非硬件故障)"
        fi
    else
        DCGM_SUMMARY="通过 (DCGM ${DCGM_DIAG_VER:-?})"
    fi
fi

# 健康检查文本（变量拼接，避免 $( ) 命令替换剥离尾换行导致排版错乱）
HEALTH_TXT=""
if [ "$GPU_COUNT" -eq 0 ]; then
    if [ "$HEAD_NODE" -eq 1 ]; then
        HEALTH_TXT="${HEALTH_TXT}  PCIe链路 : N/A (HGX 机头无本地 GPU，模组单独采集)"$'\n'
    elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
        HEALTH_TXT="${HEALTH_TXT}  PCIe链路 : ⚠️ 检测到 ${GPU_PCI_PRESENT} 个 NVIDIA GPU 但 nvidia-smi 无数据（驱动未安装或异常）"$'\n'
    else
        HEALTH_TXT="${HEALTH_TXT}  PCIe链路 : N/A (无 GPU)"$'\n'
    fi
else
    HEALTH_TXT="${HEALTH_TXT}  PCIe链路 : ${GPU_DEGRADED:-✓ 全部正常}"$'\n'
fi
if [ "${NVLINK_HEALTH:-N/A}" != "N/A" ]; then
    HEALTH_TXT="${HEALTH_TXT}  NVLink   : ${NVLINK_HEALTH}${NVLINK_CRC:+ (存在CRC错误)}"$'\n'
fi
if [ -n "$DCGM_SUMMARY" ] && [ "$DCGM_SUMMARY" != "N/A" ]; then
    HEALTH_TXT="${HEALTH_TXT}  DCGM诊断 : ${DCGM_SUMMARY}"$'\n'
elif [ "$HEAD_NODE" -eq 1 ]; then
    HEALTH_TXT="${HEALTH_TXT}  DCGM诊断 : N/A（HGX 机头无 GPU，模组单独采集）"$'\n'
fi
if [ -n "$DCGM_NOTICE" ]; then
    HEALTH_TXT="${HEALTH_TXT}  ⚠️ ${DCGM_NOTICE}"$'\n'
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
NIC_DPU=0
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
USB_NICS=""
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
        # tab 偏移修正：表头以 tab/空格开头时 $1 为空，列号比数据行小 1（数据行 $1=GPU0 占位）
        # 判定：表头首字符为空白（\t 或空格）→ 所有列号 +1
        _tabfix=0
        case "$_hdr" in
            [[:space:]]*) _tabfix=1 ;;
        esac
        while IFS= read -r _pair; do
            _nic_cols+=("${_pair%%:*}")
            _nic_idx+=("$(( ${_pair##*:} + _tabfix ))")
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
        # 分类：非 PCIe BDF（如 USB 路径 2-9.4:1.0）→ USB 网卡，单独列表显示（不混入 PCIe 主表）
        nusb=0
        if [ -n "$nnbdf" ] && ! echo "$nnbdf" | grep -qE "^[0-9a-fA-F]{2,4}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$"; then
            nusb=1
            USB_NICS="${USB_NICS}${nnic}|${nmac}|${npn}|${nfw}"$'\n'
            continue
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
                dev==bdf && /Base GUID:/ {
                    if (psid != "" && psid != "N/A") { print psid; exit }
                    if (pn != "" && pn != "--") { print "PN:" pn; exit }
                    exit
                }
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
            if [ -f "${lspci_all}" ]; then
                mt=$(grep -E "^${nnbdf%% (USB)*} " "${lspci_all}" 2>/dev/null | grep -oE '\[ConnectX-[0-9]+( Lx| Dx)?\]|\[BlueField[^]]*\]' | head -1 | tr -d '[]')
            fi
            # 兜底：lspci 无型号时用 CA type 映射（MT4129→ConnectX-7 等）
            if [ -z "$mt" ]; then
                mt="${CA_MODEL[${NETDEV_CA[$nnic]:-}]:-}"
                [ -n "$mt" ] && mt=$(mt_model "$mt")
            fi
            [ -n "$mt" ] && npn="${npn} [${mt}]"
            # BlueField 系列 = DPU（Data Processing Unit，内置 Arm 处理器），标注区分普通网卡
            if echo "$mt" | grep -qiE "BlueField"; then
                npn="${npn} [DPU]"
                NIC_DPU=1
            fi
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
        # 固件回退：旧采集 csv 固件被 awk 截断成第一段（如 "0x00012b2c," 带逗号 / "9.00" 丢 NVM 版本）
        # → 从 ethtool_<dev>_driver.log 取完整固件字符串（新采集已修复，此处兼容旧数据）
        if echo "$nfw" | grep -qE ",$|^[0-9]+\.[0-9]+$"; then
            _nfw_full=$(grep -m1 "firmware-version" "${NET_DIR}/ethtool_${nnic}_driver.log" 2>/dev/null | cut -d: -f2- | xargs)
            [ -n "$_nfw_full" ] && nfw="$_nfw_full"
        fi
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
# 网卡明细回退：nic_inventory.csv 空但 ibstat 有 CA（旧采集 v1.x 未生成 csv）→ 从 ibstat 构建简化明细
# 字段：ca|ca_type|node_guid|state（ibstat 只有 CA 级信息，无接口/BDF/固件——标注回退来源）
NIC_FALLBACK_DETAILS=""
if [ -z "$NIC_DETAILS" ] && [ -f "${ibstat}" ]; then
    _ca_count=$(grep -c "^CA '" "${ibstat}" 2>/dev/null)
    if [ "$_ca_count" -gt 0 ]; then
        NIC_FALLBACK_DETAILS=$(awk '
            /^CA /{ca=$2; gsub(/'"'"'/,"",ca)}
            /CA type/{type=$NF}
            /Node GUID/{guid=$NF}
            /State: /{state=$NF; printf "%s|%s|%s|%s\n", ca, type, guid, state}
        ' "${ibstat}" 2>/dev/null)
    fi
fi

# ─── PSID 缺失提示：有 Mellanox 卡但 PSID 全空时说明（采集时 MST 未启动/旧数据） ───
PSID_NOTICE=""
if [ "$NIC_MLX" -eq 1 ]; then
    _mlx_no_psid=0
    _mlx_total=0
    while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip; do
        [ -z "$nnic" ] && continue
        # 只统计 Mellanox 卡（型号含 ConnectX/BlueField/MLX，或芯片列 MT 编号 MT3xxx/MT4xxx）
        if ! echo "$npn" | grep -qiE "ConnectX|BlueField|MLX" && ! echo "$nchip" | grep -qE "^MT[0-9]{4}"; then
            continue
        fi
        _mlx_total=$((_mlx_total + 1))
        case "$npsid" in ""|N/A|—) _mlx_no_psid=$((_mlx_no_psid + 1)) ;; esac
    done <<< "$NIC_DETAILS"
    if [ "$_mlx_total" -gt 0 ] && [ "$_mlx_no_psid" -eq "$_mlx_total" ]; then
        PSID_NOTICE="⚠️ 有 ${_mlx_total} 张 Mellanox 卡未读到 PSID（采集时 MST 未启动或旧数据）；重新采集可获取"
    fi
fi

# ─── 风扇（IPMI 传感器，| 分隔格式） ───
FAN_DIR="${OUT}/fan"
load_manifest "${FAN_DIR}" ipmi_fan_sensors "ipmi_fan_sensors.log"
# 风扇匹配：兼容 Fan10_Speed_F / FAN1_Speed / Fan2 等大小写变体；只统计转速传感器（$3=RPM），
# 跳过 Present/discrete 等离散值（如 PSU1 Slow FAN1 是 discrete 状态位 0x1，非真实转速）
FAN_COUNT=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{c++} END{print c+0}')
FAN_MIN=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{gsub(/ /,"",$2); if($2 ~ /^[0-9]+\.[0-9]+$/) sub(/\.?0+$/,"",$2); print $2}' | sort -n | head -1)
FAN_MAX=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{gsub(/ /,"",$2); if($2 ~ /^[0-9]+\.[0-9]+$/) sub(/\.?0+$/,"",$2); print $2}' | sort -n | tail -1)
FAN_SPEED=""
[ -n "$FAN_MIN" ] && FAN_SPEED="${FAN_MIN}-${FAN_MAX} RPM"

# 风扇每风扇明细
FAN_DETAILS=""
if [ -f "${ipmi_fan_sensors}" ]; then
    FAN_DETAILS=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{
        name=$1; gsub(/^ +| +$/,"",name)
        val=$2; gsub(/^ +| +$/,"",val)
        # 转速去尾零（9300.000 → 9300）
        if(val ~ /^[0-9]+\.[0-9]+$/) {sub(/\.?0+$/,"",val)}
        status=$4; gsub(/^ +| +$/,"",status)
        print name"|"val"|"status
    }')
fi

# 温度概况（ipmi_sensors_temp.log：进风/出风/CPU/内存/电源 关键温度聚合 min-max）
TEMP_SUMMARY=""
load_manifest "${BMC_DIR}" ipmi_sensors_temp "ipmi_sensors_temp.log"
if [ -f "${ipmi_sensors_temp}" ]; then
    _temp_agg() {   # $1=匹配模式, $2=标签
        grep -v "^#" "${ipmi_sensors_temp}" 2>/dev/null | awk -F'|' -v pat="$1" 'tolower($1) ~ pat {
            v=$2; gsub(/ /,"",v); if(v ~ /^[0-9]+(\.[0-9]+)?$/) { if(v+0>0) print v }
        }' | sort -n | awk -v lbl="$2" 'NR==1{mn=$1} {mx=$1} END{if(mn!=""){sub(/\.0+$/,"",mn); sub(/\.0+$/,"",mx); printf "%s %s-%s°C  ", lbl, mn, mx}}'
    }
    TEMP_SUMMARY="$( _temp_agg 'inlet.*temp|tr[0-9]+.*temp' '进风'; _temp_agg 'outlet.*temp' '出风'; _temp_agg '^cpu[0-9]+[ _]temp' 'CPU'; _temp_agg 'dimm.*temp' '内存'; _temp_agg 'psu[0-9]+[ _]temp' '电源'; _temp_agg 'pch.*temp' 'PCH' )"
    TEMP_SUMMARY=$(echo "$TEMP_SUMMARY" | sed 's/  *$//')
fi

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
    psu_power_csv="${PSU_DIR}/ipmi_psu_sensors.log"
    psu_power_csv2="${BMC_DIR}/ipmi_sensors_power.log"   # 含 PS*_Pin（Inventec 等平台，psu 日志可能只有 Temp）
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
        if [ -n "$PSU_DETAILS" ] && [ -f "${PSU_DIR}/dmidecode_psu.log" ]; then
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
            done < <(grep -v "^#" "${PSU_DIR}/dmidecode_psu.log" 2>/dev/null)
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
                    # 额定容量：从型号解析（DLG3200=3200W, DLG2600=2600W, DLG2000=2000W, DLG1600=1600W...）
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
BMC_PRESENT=0
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
redfish_val() {   # Redfish JSON 字符串字段
    grep -m1 -oE "\"${1}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "${redfish_system}" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}
redfish_num() {   # Redfish JSON 数值字段
    grep -m1 -oE "\"${1}\"[[:space:]]*:[[:space:]]*[0-9.]+" "${redfish_system}" 2>/dev/null | head -1 | grep -oE "[0-9.]+" | head -1
}
BMC_CONSISTENCY=""
if [ "$BMC_PRESENT" -eq 1 ]; then
    local _os_v _bmc_v _res
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

# ─── 压测归档（--test-dir；test/test_common.sh 写 manifest.txt 解耦） ───
TEST_DETAILS=""; TEST_DIR_LABEL=""
if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
    TEST_DIR_LABEL="$TEST_DIR"
    _tsum=""
    [ -f "${TEST_DIR}/manifest.txt" ] && _tsum=$(grep '^summary=' "${TEST_DIR}/manifest.txt" | tail -1 | cut -d= -f2-)
    [ -z "$_tsum" ] && _tsum=$(basename "$(ls "${TEST_DIR}"/*.log 2>/dev/null | head -1)")
    _tsum="${TEST_DIR}/${_tsum}"
    if [ -f "$_tsum" ]; then
        # test_record 行格式: [HH:MM:SS] <name>: <状态> (<Ns>) — 详情: <file>
        TEST_DETAILS=$(grep -E "^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]" "$_tsum" 2>/dev/null \
            | grep -vE "测试开始|测试结束" \
            | sed -E 's/^\[[0-9:]+\] //; s/ \(([0-9]+)s\) — 详情: (.*)$/|\1|\2/; s/: /|/')
    fi
fi

# ─── 报告基线对比（--baseline <历史采集目录>；读两侧数据，输出时序差异） ───
BASELINE_COMPARE=""; BASELINE_DIR_LABEL=""; BASELINE_COMPARE_NOTE=""
if [ -n "$BASELINE_DIR" ]; then
    BL_JSON="${BASELINE_DIR}/hwscope_report.json"
    if [ ! -f "$BL_JSON" ]; then
        echo -e "${YELLOW}[WARN] 基线目录缺少 hwscope_report.json: ${BASELINE_DIR}，跳过基线对比${NC}"
    else
        BASELINE_DIR_LABEL="$BASELINE_DIR"
        # JSON 块内字段提取（依赖 report.sh 固定缩进格式；零新依赖）
        # 注意：单行 JSON 对象含多个键值对（如 details 数组行），必须用 index() 定位
        # 目标键后取其后值；贪心 sub(/.*: *"/) 会误取行内最后一个键的值（v1.30.0 踩坑）
        bl_get() {   # $1=块 $2=键 → 标量值
            awk -v blk="$1" -v key="$2" '
                $0 ~ "^  \"" blk "\": \\{" { inblk=1; next }
                inblk && /^  \},?$/ { exit }
                inblk && (idx = index($0, "\"" key "\":")) {
                    rest = substr($0, idx + length(key) + 3)
                    if (rest ~ /^[[:space:]]*"/) { sub(/^[[:space:]]*"/, "", rest); sub(/".*/, "", rest) }
                    else { sub(/^[[:space:]]*/, "", rest); sub(/,.*/, "", rest) }
                    gsub(/^ +| +$/, "", rest)
                    if (rest != "") { print rest; exit }
                }
            ' "$BL_JSON" 2>/dev/null
        }
        bl_list() {  # $1=块 $2=键 → 块内数组对象中该键的全部取值（逐行）
            awk -v blk="$1" -v key="$2" '
                $0 ~ "^  \"" blk "\": \\{" { inblk=1; next }
                inblk && /^  \},?$/ { exit }
                inblk && (idx = index($0, "\"" key "\":")) {
                    rest = substr($0, idx + length(key) + 3)
                    sub(/^[[:space:]]*"/, "", rest); sub(/".*/, "", rest)
                    gsub(/^ +| +$/, "", rest)
                    if (rest != "" && rest != "N/A") print rest
                }
            ' "$BL_JSON" 2>/dev/null
        }
        # 集合差异行：$1=项名 $2=当前列表 $3=基线列表 → 输出 新增/移除/一致 行
        set_diff_rows() {
            local item="$1" cur="$2" base="$3" c b added removed
            c=$(printf '%s\n' $cur | grep -v "^$" | sort -u)
            b=$(printf '%s\n' $base | grep -v "^$" | sort -u)
            [ -z "$c" ] && [ -z "$b" ] && return
            if [ -z "$c" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}${item}|移除|—|$(echo "$b" | tr '\n' ',' | sed 's/,$//')"$'\n'; return; fi
            if [ -z "$b" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}${item}|新增|$(echo "$c" | tr '\n' ',' | sed 's/,$//')|—"$'\n'; return; fi
            added=$(comm -23 <(echo "$c") <(echo "$b") | tr '\n' ',' | sed 's/,$//')
            removed=$(comm -13 <(echo "$c") <(echo "$b") | tr '\n' ',' | sed 's/,$//')
            [ -n "$added" ] && BASELINE_COMPARE="${BASELINE_COMPARE}${item}|新增|${added}|—"$'\n'
            [ -n "$removed" ] && BASELINE_COMPARE="${BASELINE_COMPARE}${item}|移除|—|${removed}"$'\n'
            [ -z "$added" ] && [ -z "$removed" ] && BASELINE_COMPARE="${BASELINE_COMPARE}${item}|一致|—|—"$'\n'
        }
        # 标量对比行：$1=项名 $2=当前值 $3=基线值（数值口径先归一：取 "/" 前部分）
        bl_cmp() {
            local item="$1" cur_v="${2:-—}" base_v="${3:-—}"
            [ -z "$cur_v" ] && cur_v="—"; [ -z "$base_v" ] && base_v="—"
            cur_v="${cur_v%%/*}"; base_v="${base_v%%/*}"
            [ "$cur_v" = "—" ] && [ "$base_v" = "—" ] && return
            local st="一致"; [ "$cur_v" != "$base_v" ] && st="变化"
            BASELINE_COMPARE="${BASELINE_COMPARE}${item}|${st}|${cur_v}|${base_v}"$'\n'
        }
        # ── 标量对比 ──
        bl_cmp "BIOS" "${BIOS_VERSION:-}" "$(bl_get motherboard bios)"
        bl_cmp "CPU 型号" "${CPU_MODEL:-}" "$(bl_get cpu model)"
        bl_cmp "内存总量" "${MEM_TOTAL_PHYS:-${MEM_TOTAL:-}}" "$(bl_get memory total)"
        bl_cmp "内存插槽(已插)" "${MEM_POPULATED:-}" "$(bl_get memory populated)"
        bl_cmp "GPU 数量" "${GPU_COUNT:-}" "$(bl_get gpu count)"
        bl_cmp "GPU VBIOS" "${GPU_VBIOS:-}" "$(bl_get gpu vbios)"
        bl_cmp "BMC 固件" "${BMC_FW:-}" "$(bl_get bmc firmware)"
        # ── 集合对比（SN 级：新增/移除即部件变更） ──
        _cur_gpu_sn=$(echo "${GPU_SERIALS:-}" | tr ',' '\n')
        set_diff_rows "GPU 序列号" "$_cur_gpu_sn" "$(bl_list gpu serial)"
        _cur_disk_sn=$(echo "$DISK_DETAILS" | awk -F'|' '$1!=""{print $5}')
        set_diff_rows "磁盘序列号" "$_cur_disk_sn" "$(bl_list storage serial)"
        _cur_nic_sn=$(echo "$NIC_DETAILS" | awk -F'|' '$1!=""{print $4}')
        set_diff_rows "网卡序列号" "$_cur_nic_sn" "$(bl_list network serial)"
        # ── 固件版本逐项对比（component|device → version） ──
        declare -A _fw_cur _fw_base
        if [ -n "$FW_COMPLIANCE_DETAILS" ]; then
            while IFS='|' read -r _fc _fd _fcur _fbase _fst _fnote; do
                [ -z "$_fc" ] && continue
                _fw_cur["${_fc}|${_fd}"]="$_fcur"
            done < <(printf '%s\n' "$FW_COMPLIANCE_DETAILS")
        fi
        while IFS= read -r _fl; do
            _fc=$(echo "$_fl" | sed -n 's/.*"component": "\([^"]*\)".*/\1/p')
            _fd=$(echo "$_fl" | sed -n 's/.*"device": "\([^"]*\)".*/\1/p')
            _fv=$(echo "$_fl" | sed -n 's/.*"current": "\([^"]*\)".*/\1/p')
            [ -n "$_fc" ] && [ -n "$_fd" ] && [ -n "$_fv" ] && _fw_base["${_fc}|${_fd}"]="$_fv"
        done < <(grep -E '^\s*\{\s*"component"' "$BL_JSON")
        # 合并 key 列表（注意：key 含空格，必须逐行 read，禁止 for 循环单词拆分）
        while IFS= read -r _k; do
            [ -z "$_k" ] && continue
            _cv="${_fw_cur[$_k]:-}"; _bv="${_fw_base[$_k]:-}"
            # 显示名去除 key 内分隔符（组件|设备 → "组件 设备"），避免破坏 | 分隔行
            _kdisp="${_k//|/ }"
            if [ -z "$_cv" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}固件 ${_kdisp}|移除|—|${_bv}"$'\n'
            elif [ -z "$_bv" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}固件 ${_kdisp}|新增|${_cv}|—"$'\n'
            elif [ "$_cv" != "$_bv" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}固件 ${_kdisp}|变化|${_cv}|${_bv}"$'\n'
            fi
        done < <(printf '%s\n' "${!_fw_cur[@]}" "${!_fw_base[@]}" | sort -u)
        BASELINE_COMPARE=$(printf '%b' "$BASELINE_COMPARE")
        if [ -n "$BASELINE_COMPARE" ]; then
            _bl_chg=$(printf '%s\n' "$BASELINE_COMPARE" | grep -vc "|一致|")
            BASELINE_COMPARE_NOTE="与 ${BASELINE_DIR_LABEL} 对比：共 $(printf '%s\n' "$BASELINE_COMPARE" | grep -c .) 项，${_bl_chg} 项有变化（新增/移除/版本变化）"
        fi
    fi
fi

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
        done < <(printf '%s\n' "$MEM_DIMMS")
        dimms_json=$(printf '%s' "$dimms_json" | sed '$ s/,$//')
    fi
    # GPU 每卡明细 JSON 数组（idx|name|serial|mem|power|temp|util|pcie_cur|pcie_max）
    local gpu_details_json=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存标注额定（如 B300: 268.6 GiB (额定288GB)）
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gused glimit gvb; do
            [ -z "$gidx" ] && continue
            gpu_details_json="${gpu_details_json}      {\"index\": \"${gidx}\", \"name\": \"${gname}\", \"serial\": \"${gsn}\", \"memory\": \"${gmem}\", \"memory_used\": \"${gused:-N/A}\", \"memory_spec\": \"${gmem_spec}\", \"power\": \"${gdraw}\", \"power_limit\": \"${glimit:-N/A}\", \"temp\": \"${gtemp}\", \"pcie\": \"${gpcie}\", \"pcie_max\": \"${gmax}\", \"vbios\": \"${gvb:-N/A}\"},"$'\n'
        done < <(printf '%s\n' "$GPU_DETAILS")
        gpu_details_json=$(printf '%s' "$gpu_details_json" | sed '$ s/,$//')
    fi
    # 盘明细 JSON 数组（name|type|size|model|sn|fw|bdf|power_on）
    local disk_details_json=""
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            disk_details_json="${disk_details_json}      {\"name\": \"${dname}\", \"type\": \"${dtype}\", \"size\": \"${dsize}\", \"model\": \"${dmodel}\", \"serial\": \"${dsn}\", \"firmware\": \"${dfw}\", \"bdf\": \"${dbdf}\", \"power_on_h\": \"${dpo}\", \"power_cyc\": \"${dpc}\", \"spare\": \"${dspare}\", \"size_spec\": \"${dspec}\", \"health\": \"${dhealth}\"},"$'\n'
        done < <(printf '%s\n' "$DISK_DETAILS")
        disk_details_json=$(printf '%s' "$disk_details_json" | sed '$ s/,$//')
    fi
    # RAID 虚拟盘 JSON 数组（dev|raid_card|size|sn）
    local raid_vd_json=""
    if [ -n "$RAID_VD_DETAILS" ]; then
        while IFS='|' read -r rvdname rvdmodel rvdsize rvdsn; do
            [ -z "$rvdname" ] && continue
            raid_vd_json="${raid_vd_json}      {\"dev\": \"${rvdname}\", \"raid_card\": \"${rvdmodel}\", \"size\": \"${rvdsize}\", \"sn\": \"${rvdsn:-N/A}\"},"$'\n'
        done < <(printf '%s\n' "$RAID_VD_DETAILS")
        raid_vd_json=$(printf '%s' "$raid_vd_json" | sed '$ s/,$//')
    fi
    # 网卡明细 JSON 数组（dev|bdf|mac|sn|pn|fw|speed|width）
    local nic_details_json=""
    if [ -n "$NIC_DETAILS" ]; then
        # awk 一次生成（避免 while read 在本函数上下文的空读异常；与其他管道生成模式一致）
        nic_details_json=$(printf '%s' "$NIC_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"dev\": \"%s\", \"bdf\": \"%s\", \"mac\": \"%s\", \"serial\": \"%s\", \"pn\": \"%s\", \"chip\": \"%s\", \"firmware\": \"%s\", \"pcie\": \"%s\", \"psid\": \"%s\", \"gpu_direct\": \"%s\"},\n", $1, $2, $3, $4, $5, $10, $6, $7, $8, $9
            }' | sed '$ s/,$//')
    elif [ -n "$NIC_FALLBACK_DETAILS" ]; then
        # 回退（旧采集无 nic_inventory）：ca|type|guid|state
        nic_details_json=$(printf '%s' "$NIC_FALLBACK_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"dev\": \"%s\", \"ca_type\": \"%s\", \"guid\": \"%s\", \"state\": \"%s\", \"fallback\": \"ibstat\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
    fi
    # NVSwitch JSON 数组
    local nvs_json=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_json="${nvs_json}      {\"id\": \"${nidx}\", \"state\": \"${nstat}\", \"temp\": \"${ntemp}\", \"ports\": \"${nports}\"},"$'\n'
        done < <(printf '%s\n' "$NVS_DETAILS")
        nvs_json=$(printf '%s' "$nvs_json" | sed '$ s/,$//')
    fi
    # CPU 每 Socket 明细 JSON 数组
    local cpu_details_json=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_json="${cpu_details_json}      {\"socket\": \"${csocket}\", \"model\": \"${cmodel}\", \"cores\": \"${ccores}\", \"threads\": \"${cthreads}\", \"max_speed\": \"${cmaxspd}\", \"cur_speed\": \"${ccurspd}\", \"stepping\": \"${cstep}\"},"$'\n'
        done < <(printf '%s\n' "$CPU_DETAILS")
        cpu_details_json=$(printf '%s' "$cpu_details_json" | sed '$ s/,$//')
    fi
    # SEL 最近事件 JSON 数组
    local sel_details_json=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_json="${sel_details_json}      {\"id\": \"${sid}\", \"date\": \"${sdate}\", \"time\": \"${stime}\", \"type\": \"${stype}\", \"description\": \"${sdesc}\"},"$'\n'
        done < <(printf '%s\n' "$SEL_DETAILS")
        sel_details_json=$(printf '%s' "$sel_details_json" | sed '$ s/,$//')
    fi
    # 风扇明细 JSON 数组
    local fan_details_json=""
    if [ -n "$FAN_DETAILS" ]; then
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fan_details_json="${fan_details_json}      {\"name\": \"${fname}\", \"rpm\": \"${frpm}\", \"status\": \"${fstatus}\"},"$'\n'
        done < <(printf '%s\n' "$FAN_DETAILS")
        fan_details_json=$(printf '%s' "$fan_details_json" | sed '$ s/,$//')
    fi
    # 固件合规 JSON 数组（component|device|current|baseline|status|note）
    local fw_details_json=""
    if [ -n "$FW_COMPLIANCE_DETAILS" ]; then
        fw_details_json=$(printf '%s' "$FW_COMPLIANCE_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"component\": \"%s\", \"device\": \"%s\", \"current\": \"%s\", \"baseline\": \"%s\", \"status\": \"%s\", \"note\": \"%s\"},\n", $1, $2, $3, $4, $5, $6
            }' | sed '$ s/,$//')
    fi
    # BMC 一致性 JSON 数组（item|os_side|bmc_side|result）
    local bmc_consistency_json=""
    if [ -n "$BMC_CONSISTENCY" ]; then
        bmc_consistency_json=$(printf '%s' "$BMC_CONSISTENCY" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"item\": \"%s\", \"os_side\": \"%s\", \"bmc_side\": \"%s\", \"result\": \"%s\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
    fi
    # 压测归档 JSON 数组（name|status|elapsed_s|detail_file）
    local test_details_json=""
    if [ -n "$TEST_DETAILS" ]; then
        test_details_json=$(printf '%s' "$TEST_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"name\": \"%s\", \"status\": \"%s\", \"elapsed_s\": \"%s\", \"detail_file\": \"%s\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
    fi
    # 基线对比 JSON 数组（item|status|current|baseline）
    local baseline_compare_json=""
    if [ -n "$BASELINE_COMPARE" ]; then
        baseline_compare_json=$(printf '%s' "$BASELINE_COMPARE" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"item\": \"%s\", \"status\": \"%s\", \"current\": \"%s\", \"baseline\": \"%s\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
    fi
    cat > "$f" << EOF
{
  "hwscope": {
    "version": "${VERSION:-unknown}",
    "report_generator": "${REPORT_VERSION:-unknown}",
    "hostname": "${HOSTNAME:-unknown}",
    "platform": "${PLATFORM:-unknown}",
    "platform_label": "${PLATFORM_LABEL:-unknown}",
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
    "chassis_sn": "${CHASSIS_SN:-N/A}",
    "fabric_switch": "${FABRIC_SW:-}"
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
    echo "$CPU_DETAILS" | awk -F'|' '{for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) } printf "      {\"index\": \"%d\", \"socket\": \"%s\", \"model\": \"%s\", \"cores\": \"%s\", \"threads\": \"%s\", \"max_speed\": \"%s\", \"cur_speed\": \"%s\", \"stepping\": \"%s\", \"serial\": \"%s\"},\n", NR, $1, $2, $3, $4, $5, $6, $7, $8}' | sed '$ s/,$//'
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
    "memory_spec_note": "${GPU_MEM_SPEC_NOTE:-}",
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
    ],
    "raid_vds": [
${raid_vd_json}
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
    ],
    "usb_nics": [
$(if [ -n "$USB_NICS" ]; then
    local ujson=""
    while IFS='|' read -r unnic unmac unpn unfw; do
        [ -z "$unnic" ] && continue
        ujson="${ujson}      {\"dev\": \"${unnic}\", \"mac\": \"${unmac}\", \"pn\": \"${unpn:-}\", \"firmware\": \"${unfw:-}\"},"$'\n'
    done < <(printf '%s\n' "$USB_NICS")
    printf '%s' "$ujson" | sed '$ s/,$//'
fi)
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
    done < <(printf '%s\n' "$PSU_DETAILS") | sed '$ s/,$//'
fi)
    ]
  },
  "psu_system": {
    "total_power": "${PSU_EXTRA:-}",
    "dcmi": "${PSU_DCMI:-}"
  },
  "raid": [
$(if [ -n "$RAID_DETAILS" ]; then
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd rvd_list; do
        [ -z "$ridx" ] && continue
        printf '    {"controller": "%s", "model": "%s", "serial": "%s", "firmware": "%s", "virtual_disks": "%s", "vd_list": "%s"},\n' "$ridx" "$rmodel" "$rsn" "$rfw" "$rvd" "$rvd_list"
    done | sed '$ s/,$//'
fi)
  ],
  "hba": [
$(if [ -n "$HBA_DETAILS" ]; then
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat hsas hports; do
        [ -z "$hname" ] && continue
        printf '    {"controller": "%s", "model": "%s", "firmware": "%s", "serial": "%s", "status": "%s", "sas_address": "%s", "ports": "%s"},\n' "$hname" "$htype" "$hfw" "$hsn" "$hstat" "$hsas" "$hports"
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
  },
  "firmware": {
    "summary": "${FW_SUMMARY:-N/A}",
    "items": [
${fw_details_json}
    ]
  },
  "power_ledger": {
    "current_power": "${PWR_CUR:-N/A}",
    "power_min": "${PWR_MIN:-N/A}",
    "power_max": "${PWR_MAX:-N/A}",
    "power_avg": "${PWR_AVG:-N/A}",
    "cumulative_energy": "${PWR_ENERGY:-N/A}",
    "energy_source": "${PWR_ENERGY_SRC:-N/A}",
    "note": "${PWR_NOTE:-}"
  },
  "bmc_consistency": {
    "items": [
${bmc_consistency_json}
    ]
  },
  "test_archive": {
    "dir": "${TEST_DIR_LABEL:-}",
    "items": [
${test_details_json}
    ]
  },
  "baseline_compare": {
    "baseline_dir": "${BASELINE_DIR_LABEL:-}",
    "note": "${BASELINE_COMPARE_NOTE:-}",
    "items": [
${baseline_compare_json}
    ]
  }
}
EOF
    echo -e "${GREEN}[REPORT] JSON: ${f}${NC}"
}

# ─── 术语说明（交付报告末尾，解释报告内出现的专业词） ───
GLOSSARY_ENTRIES=(
    "IB|InfiniBand，高速互联网络（GPU/存储集群专用），速率代际 SDR→DDR→QDR→FDR→EDR→HDR→NDR→XDR 每代翻倍（10G→800G/单口）"
    "额定/实际速率|额定=网卡硬件支持的最大速率（固件声明，无需接线）；实际=当前链路协商速率（取决于对端交换机/线缆，未接为 Down）"
    "GPU直连|网卡与 GPU 处于同一 PCIe Switch（PIX），可做 GPU Direct RDMA 高速通信"
    "NVLink|NVIDIA GPU 间高速互联总线（B300 每卡 18 条，53.125 GB/s/条）"
    "NVSwitch|NVLink 交换芯片，连接多卡实现全互联（B300 集成于 GPU 模块内）"
    "DCGM|NVIDIA Data Center GPU Manager，GPU 诊断工具（dcgmi diag）"
    "SEL|System Event Log，BMC 记录的系统事件日志（含硬件告警）"
    "SXM|NVIDIA 数据中心 GPU 模块化形态（非 PCIe 插卡），如 B300 SXM6"
    "PSID|网卡产品 ID（Mellanox 卡标识，用于固件匹配）"
    "退役行(Remapped Rows)|GPU 显存中检测到故障后自动重映射隐藏的行，计数>0 提示显存健康问题"
    "2DPC|DIMM Per Channel=每内存通道插 2 条；满插时信号负载大，内存降速运行属平台规范正常现象"
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

# 网络段附加行（线缆/配对/端口模式；PSID/MST 提示已并入 nic_details_txt 开头）
net_extra_txt() {
    local out=""
    [ -n "$CABLE_SUMMARY" ]   && [ "$CABLE_SUMMARY" != "N/A" ]   && out="${out}  线缆   : ${CABLE_SUMMARY}"$'\n'
    [ -n "$CABLE_PAIRS" ]     && [ "$CABLE_PAIRS" != "N/A" ]     && out="${out}  配对   : ${CABLE_PAIRS}"$'\n'
    [ -n "$LINKTYPE_SUMMARY" ] && [ "$LINKTYPE_SUMMARY" != "N/A" ] && out="${out}  端口模式: ${LINKTYPE_SUMMARY}"$'\n'
    [ -n "$out" ] && printf '\n%s' "$out"
}

# 网络段附加行（Markdown 表格版；空值不产生空行）
net_extra_md() {
    local out=""
    [ -n "$CABLE_SUMMARY" ]   && [ "$CABLE_SUMMARY" != "N/A" ]   && out="${out}| 线缆类型 | ${CABLE_SUMMARY} |"$'\n'
    [ -n "$CABLE_PAIRS" ]     && [ "$CABLE_PAIRS" != "N/A" ]     && out="${out}| 线缆配对 | ${CABLE_PAIRS} |"$'\n'
    [ -n "$LINKTYPE_SUMMARY" ] && [ "$LINKTYPE_SUMMARY" != "N/A" ] && out="${out}| 端口模式 | ${LINKTYPE_SUMMARY} |"$'\n'
    [ -n "$MST_NOTICE" ]      && out="${out}| ⚠️ 提示 | ${MST_NOTICE} |"$'\n'
    [ -n "$PSID_NOTICE" ]     && out="${out}| ⚠️ PSID | ${PSID_NOTICE} |"$'\n'
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
        done < <(printf '%s\n' "$MEM_DIMMS")
    fi
    # GPU 每卡明细 Markdown 表
    local gpu_details_md=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存显示 默认(额定)/可用（如 288GB/268.6 GiB 可用），防止客户误读检测值为卡容量
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gused glimit gvb; do
            [ -z "$gidx" ] && continue
            # PCIe 合并：满速只显当前值，降速才标注能力（如 "5x8 (能力 5x16)"）
            gpcie_disp="$gpcie"
            if [ "$gpcie" != "N/A" ] && [ "$gmax" != "N/A" ] && [ -n "$gmax" ] && [ "$gpcie" != "$gmax" ]; then
                gpcie_disp="${gpcie} (能力 ${gmax})"
            fi
            # 显存 检测/额定（检测=采集可见值 GiB，额定=规格 GB，差异为 ECC/显存预留）
            gmem_disp="${gmem:-N/A}"
            if [ -n "$gmem_spec" ] && [ "$gmem" != "N/A" ] && [ -n "$gmem" ]; then
                gmem_disp="${gmem}/${gmem_spec}"
            fi
            # 功耗 检测/额定（检测=当前功耗，额定=规格最大功耗）
            gdraw_disp="${gdraw:-N/A}"
            if [ -n "$gdraw" ] && [ -n "$glimit" ] && [ "$gdraw" != "N/A" ] && [ "$glimit" != "N/A" ]; then
                _gl=$(echo "$glimit" | grep -oE "[0-9.]+" | head -1 | awk '{printf "%g", $1}')
                gdraw_disp="${gdraw}/${_gl}W"
            fi
            gpu_details_md="${gpu_details_md}| ${gidx} | ${gname} | ${gsn} | ${gmem_disp} | ${gdraw_disp} | ${gtemp} | ${gpcie_disp} | ${gvb:-N/A} |"$'\n'
        done < <(printf '%s\n' "$GPU_DETAILS")
    fi
    # 盘明细 Markdown 表
    local disk_details_md=""
    # 整列隐藏判定：寿命%/额定/健康 整列全为占位符（旧采集无 SMART 数据）时隐藏该列（有任一值即显示）
    local disk_has_spare=0 disk_has_spec=0 disk_has_health=0
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            [ -n "$dspare" ] && [ "$dspare" != "—" ] && [ "$dspare" != "N/A" ] && disk_has_spare=1
            [ -n "$dspec" ] && [ "$dspec" != "—" ] && [ "$dspec" != "N/A" ] && disk_has_spec=1
            [ -n "$dhealth" ] && [ "$dhealth" != "—" ] && [ "$dhealth" != "N/A" ] && disk_has_health=1
        done < <(printf '%s\n' "$DISK_DETAILS")
        local dn=0
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            dn=$((dn + 1))
            # 动态列拼接（整列无值列省略，保持表头/数据行列一致；额定列紧跟容量便于检测/规格对比）
            _spare_col=""; [ "$disk_has_spare" -eq 1 ] && _spare_col=" | ${dspare}"
            _spec_col="";  [ "$disk_has_spec" -eq 1 ] && _spec_col=" | ${dspec#额定}"   # MD 有列头"额定"，值去前缀防重复
            _health_col=""; [ "$disk_has_health" -eq 1 ] && _health_col=" | ${dhealth}"
            disk_details_md="${disk_details_md}| ${dn} | ${dname} | ${dtype} | ${dsize}${_spec_col} | ${dmodel} | ${dsn} | ${dfw} | ${dbdf} | ${dpo} | ${dpc}${_spare_col}${_health_col} |"$'\n'
        done < <(printf '%s\n' "$DISK_DETAILS")
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
        done < <(printf '%s\n' "$NIC_DETAILS")
    fi
    # NVSwitch Markdown 表
    local nvs_md=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_md="${nvs_md}| ${nidx} | ${nstat} | ${ntemp} | ${nports} |"$'\n'
        done < <(printf '%s\n' "$NVS_DETAILS")
    fi
    # CPU 每 Socket 明细 Markdown 表
    local cpu_details_md=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_md="${cpu_details_md}| ${csocket} | ${cmodel} | ${ccores} | ${cthreads} | ${cmaxspd} | ${ccurspd} | ${cstep} |"$'\n'
        done < <(printf '%s\n' "$CPU_DETAILS")
    fi
    # SEL 最近事件 Markdown 表
    local sel_details_md=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_md="${sel_details_md}| ${sid} | ${sdate} | ${stime} | ${stype} | ${sdesc} |"$'\n'
        done < <(printf '%s\n' "$SEL_DETAILS")
    fi
    # 风扇明细 Markdown 表
    local fan_details_md=""
    if [ -n "$FAN_DETAILS" ]; then
        local fn=0
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fn=$((fn + 1))
            fan_details_md="${fan_details_md}| ${fn} | ${fname} | ${frpm} | ${fstatus} |"$'\n'
        done < <(printf '%s\n' "$FAN_DETAILS")
    fi
    cat > "$f" << EOF
# HwScope 硬件巡检报告

**采集版本:** ${VERSION:-unknown} · **报告生成器:** ${REPORT_VERSION:-unknown} · **主机:** ${HOSTNAME:-unknown} · **平台:** ${PLATFORM_LABEL:-unknown} · **时间:** ${TIMESTAMP:-unknown}

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
$(if [ -n "$FABRIC_SW" ] && [ "$GPU_COUNT" -eq 0 ]; then echo "| PCIe Fabric Switch | ${FABRIC_SW}（HGX 模组互联通道） |"; fi)
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
    done < <(printf '%s\n' "$CPU_DETAILS")
    echo "### 处理器明细（CPU）"
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

### 内存模块明细（DIMM）
| # | 插槽 | 容量 | 厂商 | SN | 部件号 | 额定速率 | 当前速率 | Rank |
|----|------|------|------|----|--------|--------|--------|------|
$(printf '%s' "$dimms_md")

## GPU
$(if [ "$GPU_COUNT" -eq 0 ]; then
    echo "| 项 | 值 |"
    echo "|----|----|"
    if [ "$HEAD_NODE" -eq 1 ]; then
        echo "| 状态 | HGX 机头（无本地 GPU，HGX 模组经 PCIe Fabric 单独接入，需单独采集） |"
    elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
        echo "| 状态 | ⚠️ 检测到 ${GPU_PCI_PRESENT} 个 NVIDIA GPU（PCI 3D controller），但 nvidia-smi 无数据（驱动未安装或异常） |"
    else
        echo "| 状态 | N/A（无 GPU） |"
    fi
else
    echo "| 项 | 值 |"
    echo "|----|----|"
    echo "| 数量 | ${GPU_COUNT:-0} |"
    echo "| 型号 | ${GPU_NAMES:-N/A} |"
    echo "| 显存总量 | ${GPU_MEM:-N/A}/${GPU_MEM_SPEC_TOTAL:-${GPU_MEM:-N/A}}（检测/额定${GPU_MEM_SPEC:+，${GPU_MEM_SPEC}}）${GPU_MEM_SPEC_NOTE:+ ${GPU_MEM_SPEC_NOTE}} |"
    echo "| 额定功耗 | ${GPU_POWER:-N/A} |"
    echo "| 温度 | ${GPU_TEMP:-N/A} |"
    echo "| ECC | ${GPU_ECC:-N/A} |"
    echo "| 退役行 | ${GPU_REMAP:-N/A} |"
    echo "| VBIOS | ${GPU_VBIOS:-N/A} |"
    if [ -n "$NV_LINK_SUMMARY" ] && [ "$NV_LINK_SUMMARY" != "N/A" ]; then
        echo "| NVLink | ${NV_LINK_SUMMARY} |"
    fi
fi)
$(if [ -n "$gpu_details_md" ]; then
    echo ""
    echo "### 图形处理器明细（GPU）"
    echo "| 卡 | 型号 | SN | 显存(检测/额定) | 功耗(检测/额定) | 温度 | PCIe(协商) | VBIOS |"
    echo "|----|------|----|----|------|------|----------|-------|"
    printf '%s' "$gpu_details_md"
fi)

$(if [ -n "$nvs_md" ]; then
    echo ""
    echo "## NVSwitch"
    echo "| 编号 | 状态 | 温度 | 活动/总端口 |"
    echo "|------|------|------|-------------|"
    printf '%s' "$nvs_md"
fi)

$(if [ -n "$FW_COMPLIANCE_DETAILS" ]; then
    echo ""
    echo "## 固件合规"
    echo "> 对照 conf/fw_required.txt（厂商推荐版本基线）逐项判定；无基线条目判未知（仅记录）"
    echo ""
    echo "| 组件 | 设备 | 当前版本 | 推荐版本 | 状态 | 说明 |"
    echo "|------|------|---------|---------|------|------|"
    echo "$FW_COMPLIANCE_DETAILS" | while IFS='|' read -r fc fd fcur fbase fst fnote; do
        [ -z "$fc" ] && continue
        case "$fst" in
            合规) fst_disp="✅ 合规" ;;
            落后) fst_disp="⚠️ 落后" ;;
            *)    fst_disp="$fst" ;;
        esac
        echo "| ${fc} | ${fd} | ${fcur} | ${fbase} | ${fst_disp} | ${fnote:-} |"
    done
    [ -n "$FW_SUMMARY" ] && echo ""
    [ -n "$FW_SUMMARY" ] && echo "> ${FW_SUMMARY}"
fi)

## 存储
| 项 | 值 |
|----|----|
| 盘数 | ${STORAGE_COUNT:-0} |
| 总容量 | ${STORAGE_TOTAL:-N/A} |
| 盘型号 | ${STORAGE_MODELS:-N/A} |
| 系统盘(已排除) | ${SYS_DISK:-N/A} |

### 存储盘明细
| # | 设备 | 类型 | 容量$(if [ "$disk_has_spec" -eq 1 ]; then echo " | 额定"; fi) | 型号 | SN | 固件 | BDF | 通电(h) | 通电次数$(if [ "$disk_has_spare" -eq 1 ]; then echo " | 寿命%"; fi)$(if [ "$disk_has_health" -eq 1 ]; then echo " | 健康"; fi) |
|---|------|------|------$(if [ "$disk_has_spec" -eq 1 ]; then echo "|------"; fi)|------|----|------|-----|---------|----------$(if [ "$disk_has_spare" -eq 1 ]; then echo "|-------"; fi)$(if [ "$disk_has_health" -eq 1 ]; then echo "|------"; fi)|
$(printf '%s' "$disk_details_md")
$(if [ -n "$DISK_DETAILS" ] && { [ "$disk_has_spare" -eq 0 ] || [ "$disk_has_health" -eq 0 ]; }; then
    echo "> 注：$(if [ "$disk_has_spare" -eq 0 ]; then echo "寿命%"; fi)$(if [ "$disk_has_spare" -eq 0 ] && [ "$disk_has_health" -eq 0 ]; then echo "、"; fi)$(if [ "$disk_has_health" -eq 0 ]; then echo "健康"; fi) 列因旧采集无 SMART 数据而隐藏"
fi)

$(if [ -n "$RAID_VD_DETAILS" ]; then
    echo "### RAID 虚拟盘明细（VD）"
    echo "| # | 设备 | RAID 卡 | 容量 | SN(LUN) |"
    echo "|---|------|---------|------|---------|"
    local rvd_seq=0
    echo "$RAID_VD_DETAILS" | while IFS='|' read -r rvdname rvdmodel rvdsize rvdsn; do
        [ -z "$rvdname" ] && continue
        rvd_seq=$((rvd_seq+1))
        echo "| ${rvd_seq} | ${rvdname} | ${rvdmodel} | ${rvdsize} | ${rvdsn:-N/A} |"
    done
fi)

$(if [ -n "$RAID_DETAILS" ]; then
    echo "## RAID 控制器"
    echo "| # | 控制器 | 型号 | SN | 固件 | 虚拟盘 |"
    echo "|---|--------|------|----|------|--------|"
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd rvd_list; do
        [ -z "$ridx" ] && continue
        rseq=$((rseq + 1))
        echo "| ${rseq} | ${ridx} | ${rmodel} | ${rsn} | ${rfw} | ${rvd} |"
        # 虚拟盘明细行（VD0:RAID1/1.817 TB/Optimal; 分隔）
        if [ -n "$rvd_list" ]; then
            echo "$rvd_list" | tr ';' '\n' | while IFS= read -r vdline; do
                [ -z "$vdline" ] && continue
                vdname="${vdline%%:*}"
                vdrest="${vdline#*:}"
                echo "|   | ${vdname} | ${vdrest} | | | |"
            done
        fi
    done
else
    if [ -n "$RAID_PCI_PRESENT" ]; then
        echo "## RAID 控制器"
        echo "> ⚠️ 检测到 RAID 控制器（$(echo "$RAID_PCI_PRESENT" | sed 's/.*: //' | xargs)），但 storcli64 未安装或采集失败——RAID 配置/虚拟盘/底层盘信息不可用，需现场安装 storcli64 后重采"
    elif [ -n "$MD_RAID_LIST" ]; then
        echo "## RAID 控制器"
        echo "> ℹ️ Linux 软件 RAID（mdadm）: ${MD_RAID_LIST}（系统级软 RAID，非硬件 RAID 卡）"
    elif [ "${RAID_VMD_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
        echo "## RAID 控制器"
        echo "> ℹ️ 检测到 Intel VMD NVMe RAID（虚拟 RAID，非独立卡，由系统管理）"
    fi
fi)

$(if [ -n "$HBA_DETAILS" ]; then
    echo "## 主机总线适配器明细（HBA）"
    echo "| # | 控制器 | 型号 | 固件 | SN | 状态 | SAS地址 | 端口 |"
    echo "|---|--------|------|------|----|------|---------|------|"
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat hsas hports; do
        [ -z "$hname" ] && continue
        hseq=$((hseq + 1))
        echo "| ${hseq} | ${hname} | ${htype} | ${hfw} | ${hsn} | ${hstat} | ${hsas} | ${hports} |"
    done
else
    if [ -n "$HBA_PCI_PRESENT" ]; then
        echo "## 主机总线适配器明细（HBA）"
        echo "> ⚠️ 检测到 SAS HBA（$(echo "$HBA_PCI_PRESENT" | sed 's/.*: //' | xargs)），但 sas3ircu/sas2ircu 未安装或采集失败——HBA 型号/固件/端口信息不可用"
    fi
fi)

## 网络
| 项 | 值 |
|----|----|
| IB 设备数 | ${IB_COUNT:-0} |
| IB 活动口 | ${IB_ACTIVE:-0}${IB_ACTIVE_SPEED:+ (${IB_ACTIVE_SPEED})} |
| IB Link 状态 | Active ${IB_ACTIVE:-0} / Down ${IB_LINK_DOWN:-0}${IB_UNPLUGGED:+（未插线缆 ${IB_UNPLUGGED}）} |
| IB 额定速率 | ${IB_NOMINAL:-N/A} |
| 以太网口 up | ${ETH_LINK_UP:-0} |
$(net_extra_md)

### 网络适配器明细（NIC）
$(if [ "$GPU_TOPO_AVAIL" -eq 1 ]; then
    echo "| # | 接口 | BDF | MAC | SN | 型号 | 芯片 | 固件 | PCIe(协商) | PSID | GPU直连 |"
    echo "|---|------|-----|-----|----|------|------|------|------|------|------|"
else
    echo "| # | 接口 | BDF | MAC | SN | 型号 | 芯片 | 固件 | PCIe(协商) | PSID |"
    echo "|---|------|-----|-----|----|------|------|------|------|------|"
fi)
$(printf '%s' "$nic_details_md")
$(if [ -z "$nic_details_md" ] && [ -n "$NIC_FALLBACK_DETAILS" ]; then
    echo "### 网络适配器明细（NIC，ibstat 回退，旧采集无 nic_inventory）"
    echo "| # | CA | 型号 | Node GUID | Link 状态 |"
    echo "|---|----|------|-----------|-----------|"
    local nfb=0
    echo "$NIC_FALLBACK_DETAILS" | while IFS='|' read -r fca ftype fguid fstate; do
        [ -z "$fca" ] && continue
        nfb=$((nfb+1))
        echo "| ${nfb} | ${fca} | ${ftype} | ${fguid} | ${fstate} |"
    done
fi)

$(if [ -n "$USB_NICS" ]; then
    echo "另发现 USB 外接网卡（非 PCIe，不参与网卡统计）:"
    echo ""
    echo "| 接口 | MAC | 型号 | 固件 |"
    echo "|------|-----|------|------|"
    while IFS='|' read -r unnic unmac unpn unfw; do
        [ -z "$unnic" ] && continue
        echo "| ${unnic} | ${unmac} | ${unpn:-—} | ${unfw:-—} |"
    done < <(printf '%s\n' "$USB_NICS")
fi)

## BMC
| 项 | 值 |
|----|----|
| 型号 | ${BMC_FRU:-N/A} |
| 固件 | ${BMC_FW:-N/A} |
| IP | ${BMC_IP:-N/A} |
| MAC | ${BMC_MAC:-N/A} |
| SEL 事件 | $(if [ "${SEL_DATA_VALID:-0}" -eq 1 ] 2>/dev/null; then echo "${SEL_TOTAL:-0}（Critical ${SEL_CRIT:-0}）"; else echo "⚠️ 数据不可用"; fi) |
$(if [ "${SEL_DATA_VALID:-0}" -eq 0 ] 2>/dev/null; then
    echo "> ⚠️ SEL 数据不可用（ipmitool 采集失败或无权限），事件列表不完整"
elif [ -n "$SEL_DETAILS" ]; then
    echo "### SEL 告警事件"
    echo "| # | 日期 | 时间 | 类型 | 描述 |"
    echo "|---|------|------|------|------|"
    local sel_seq=0
    echo "$SEL_DETAILS" | while IFS='|' read -r sid sdate stime stype sdesc; do
        sel_seq=$((sel_seq+1))
        echo "| ${sid} | ${sdate} | ${stime} | ${stype} | ${sdesc} |"
    done
else
    echo "> 告警事件: 无"
fi)

$(if [ -n "$BMC_CONSISTENCY" ]; then
    echo ""
    echo "### BMC 数据一致性校验（OS vs BMC）"
    echo "> OS 层采集 vs BMC 层交叉校验（只读既有日志，零新采集）；不一致 = 潜在刷 SN/换件/固件不匹配风险"
    echo ""
    echo "| 对比项 | OS 侧 | BMC 侧 | 结果 |"
    echo "|--------|-------|--------|------|"
    echo "$BMC_CONSISTENCY" | while IFS='|' read -r bitem bos bbmc bres; do
        [ -z "$bitem" ] && continue
        echo "| ${bitem} | ${bos} | ${bbmc} | ${bres} |"
    done
fi)

## 风扇
| 项 | 值 |
|----|----|
| 数量 | ${FAN_COUNT:-0} |
| 转速 | ${FAN_SPEED:-N/A} |
| 温度 | ${TEMP_SUMMARY:-N/A} |
$(if [ -n "$FAN_DETAILS" ]; then
    echo "### 散热风扇明细"
    echo "| # | 风扇 | 转速(RPM) | 状态 |"
    echo "|---|------|----------|------|"
    local fan_seq=0
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        fan_seq=$((fan_seq+1))
        echo "| ${fan_seq} | ${fname} | ${fval} | ${fstatus} |"
    done
elif [ "${FAN_COUNT:-0}" -eq 0 ] 2>/dev/null; then
    echo "> ⚠️ 未采集到风扇数据（ipmitool 风扇传感器不可读或平台无风扇传感器）"
fi)

## 电源 PSU
### 电源模块明细（PSU）
| # | 描述 | 型号 | 部件号 | 序列号 | 额定容量 | 当前功耗 |
|----|------|------|--------|--------|---------|---------|
$(if [ -n "$PSU_DETAILS" ]; then
    local pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "${pcap:-N/A}" "${ppower:-N/A}"
    done < <(printf '%s\n' "$PSU_DETAILS")
else
    echo "| — | N/A（无 PSU 数据：无电源 FRU 且电源传感器为空，可能采集时 BMC 传感器不可读） | — | — | — | — | — |"
fi)
$(
    # PSU 尾注（冗余/整机功耗/DCMI/平台说明），合并块避免空输出堆积空行
    if [ "$PSU_REDUNDANT" != "N/A" ] || [ -n "$PSU_EXTRA" ] || [ -n "$PSU_DCMI" ]; then
        echo ""
    fi
    [ "$PSU_REDUNDANT" != "N/A" ] && echo "**电源冗余: ${PSU_REDUNDANT}**"
    [ -n "$PSU_EXTRA" ] && echo "**${PSU_EXTRA}**"
    [ -n "$PSU_DCMI" ] && echo "**${PSU_DCMI}**"
    [ -n "$PSU_PLATFORM_NOTE" ] && echo "> ⚠️ ${PSU_PLATFORM_NOTE}"
)

$(if [ -n "$PWR_CUR" ] || [ -n "$PWR_ENERGY" ]; then
    echo ""
    echo "## 能耗台账"
    echo "| 项 | 值 |"
    echo "|----|----|"
    [ -n "$PWR_CUR" ] && echo "| 当前功耗 | ${PWR_CUR} |"
    [ -n "$PWR_MIN" ] && echo "| 采样最小 | ${PWR_MIN} |"
    [ -n "$PWR_MAX" ] && echo "| 采样最大 | ${PWR_MAX} |"
    [ -n "$PWR_AVG" ] && echo "| 采样平均 | ${PWR_AVG} |"
    [ -n "$PWR_ENERGY" ] && echo "| 累计能耗 | ${PWR_ENERGY}${PWR_ENERGY_SRC:+（${PWR_ENERGY_SRC}）} |"
    [ -n "$PWR_NOTE" ] && echo ""
    [ -n "$PWR_NOTE" ] && echo "> ${PWR_NOTE}"
fi)

## 健康检查
| 项 | 状态 |
|----|------|
$(
    if [ "$GPU_COUNT" -eq 0 ]; then
        if [ "$HEAD_NODE" -eq 1 ]; then
            echo "| GPU PCIe 链路 | N/A（HGX 机头无本地 GPU，模组单独采集） |"
        else
            echo "| GPU PCIe 链路 | N/A（无 GPU） |"
        fi
    else
        echo "| GPU PCIe 链路 | ${GPU_DEGRADED:-✓ 全部正常} |"
    fi
    if [ "${NVLINK_HEALTH:-N/A}" != "N/A" ]; then
        echo "| NVLink | ${NVLINK_HEALTH}${NVLINK_CRC:+ (存在CRC错误)} |"
    fi
    if [ -n "$DCGM_SUMMARY" ] && [ "$DCGM_SUMMARY" != "N/A" ]; then
        echo "| DCGM 诊断 | ${DCGM_SUMMARY} |"
    elif [ "$HEAD_NODE" -eq 1 ]; then
        echo "| DCGM 诊断 | N/A（HGX 机头无 GPU，模组单独采集） |"
    fi
    if [ -n "$DCGM_NOTICE" ]; then
        echo "| ⚠️ DCGM | ${DCGM_NOTICE} |"
    fi
)
| SEL PCIe 错误 | ${SEL_PCIE_ERR:-0} 条 |
| 线缆配对 | ${CABLE_PAIRS:-N/A} |

$(if [ -n "$TEST_DETAILS" ]; then
    echo ""
    echo "## 压测归档"
    echo "> 压测目录: ${TEST_DIR_LABEL}（test/ 压测脚本落盘，report 只读解析，不重跑）"
    echo ""
    echo "| 测试项 | 结果 | 耗时 | 详情文件 |"
    echo "|--------|------|------|---------|"
    echo "$TEST_DETAILS" | while IFS='|' read -r tname tstatus telapsed tfile; do
        [ -z "$tname" ] && continue
        case "$tstatus" in
            通过) tst_disp="✅ 通过" ;;
            异常*) tst_disp="❌ ${tstatus}" ;;
            工具缺失) tst_disp="— 工具缺失" ;;
            *) tst_disp="$tstatus" ;;
        esac
        echo "| ${tname} | ${tst_disp} | ${telapsed}s | ${tfile} |"
    done
fi)

$(if [ -n "$BASELINE_COMPARE" ]; then
    echo ""
    echo "## 基线对比"
    echo "> ${BASELINE_COMPARE_NOTE}"
    echo ""
    echo "| 项 | 状态 | 当前 | 基线 |"
    echo "|----|------|------|------|"
    echo "$BASELINE_COMPARE" | while IFS='|' read -r bitem bst bcur bbase; do
        [ -z "$bitem" ] && continue
        case "$bst" in
            变化|新增) bst_disp="⚠️ ${bst}" ;;
            移除) bst_disp="❌ ${bst}" ;;
            *) bst_disp="$bst" ;;
        esac
        echo "| ${bitem} | ${bst_disp} | ${bcur} | ${bbase} |"
    done
fi)

---
## 术语说明

| 术语 | 说明 |
|------|------|
$(glossary_md)
$(if [ -n "$NIC_MLX" ]; then
    echo ""
    echo "### 网卡型号对照表"
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

> 数据来源：只读解析采集日志（不重新采集）；"额定"为硬件规格，检测值为采集时刻实际状态；明细见 output/&lt;SN&gt;/&lt;模块&gt;/。
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
            dimms_txt="${dimms_txt}    ${dseq}. ${dslot}  ${dsize}  ${dmfr}  SN:${dsn}  P/N:${dpn}  额定${dnom}/现${dcur}  Rank:${drank:-N/A}"$'\n'
        done < <(printf '%s\n' "$MEM_DIMMS")
    fi
    # GPU 每卡明细纯文本
    local gpu_details_txt=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存 可用/总 + 功耗 当前/上限（双值让客户看到余量）
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gused glimit gvb; do
            [ -z "$gidx" ] && continue
            # PCIe 合并：满速只显当前值，降速才标注能力（如 "5x8 (能力 5x16)"）
            gpcie_disp="$gpcie"
            if [ "$gpcie" != "N/A" ] && [ "$gmax" != "N/A" ] && [ -n "$gmax" ] && [ "$gpcie" != "$gmax" ]; then
                gpcie_disp="${gpcie} (能力 ${gmax})"
            fi
            # 显存 检测/额定（检测=采集可见值 GiB，额定=规格 GB）
            gmem_disp="${gmem:-N/A}"
            if [ -n "$gmem_spec" ] && [ "$gmem" != "N/A" ] && [ -n "$gmem" ]; then
                gmem_disp="${gmem}/${gmem_spec}"
            fi
            # 功耗 检测/额定（检测=当前功耗，额定=规格最大功耗）
            gdraw_disp="${gdraw:-N/A}"
            if [ -n "$gdraw" ] && [ -n "$glimit" ] && [ "$gdraw" != "N/A" ] && [ "$glimit" != "N/A" ]; then
                _gl=$(echo "$glimit" | grep -oE "[0-9.]+" | head -1 | awk '{printf "%g", $1}')
                gdraw_disp="${gdraw}/${_gl}W"
            fi
            gpu_details_txt="${gpu_details_txt}    GPU${gidx}  ${gname}  SN:${gsn}  显存:${gmem_disp}  功耗:${gdraw_disp}  ${gtemp}  PCIe(协商):${gpcie_disp}  VBIOS:${gvb:-N/A}"$'\n'
        done < <(printf '%s\n' "$GPU_DETAILS")
    fi
    # 盘明细纯文本
    local disk_details_txt=""
    # 整列隐藏判定（同 MD）：寿命%/额定/健康 整列无值省略字段（旧采集无 SMART）
    local disk_has_spare=0 disk_has_spec=0 disk_has_health=0
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            [ -n "$dspare" ] && [ "$dspare" != "—" ] && [ "$dspare" != "N/A" ] && disk_has_spare=1
            [ -n "$dspec" ] && [ "$dspec" != "—" ] && [ "$dspec" != "N/A" ] && disk_has_spec=1
            [ -n "$dhealth" ] && [ "$dhealth" != "—" ] && [ "$dhealth" != "N/A" ] && disk_has_health=1
        done < <(printf '%s\n' "$DISK_DETAILS")
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            _spare_txt=""; [ "$disk_has_spare" -eq 1 ] && _spare_txt="  spare:${dspare}"
            _spec_txt="";  [ "$disk_has_spec" -eq 1 ] && _spec_txt="  ${dspec:-}"
            _health_txt=""; [ "$disk_has_health" -eq 1 ] && _health_txt="  健康:${dhealth}"
            disk_details_txt="${disk_details_txt}    ${dname}  ${dtype}  ${dsize}${_spec_txt}  ${dmodel}  SN:${dsn}  FW:${dfw}  ${dbdf}  ${dpo}h  cyc:${dpc}${_spare_txt}${_health_txt}"$'\n'
        done < <(printf '%s\n' "$DISK_DETAILS")
    fi
    # 网卡明细纯文本（TXT 专用；PSID/MST 提示并入开头，避免命令替换剥尾换行粘连）
    local nic_details_txt=""
    [ -n "$PSID_NOTICE" ] && nic_details_txt="  ${PSID_NOTICE}"$'\n'
    [ -n "$MST_NOTICE" ] && nic_details_txt="${nic_details_txt}  ⚠️ ${MST_NOTICE}"$'\n'
    if [ -n "$NIC_DETAILS" ]; then
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip; do
            [ -z "$nnic" ] && continue
            if [ "$GPU_TOPO_AVAIL" -eq 1 ]; then
                nic_details_txt="${nic_details_txt}    ${nnic}  ${nnbdf}  ${nmac}  SN:${nsn}  ${npn}  FW:${nfw}  PCIe(协商):${npcie}  PSID:${npsid}  ${ngd:-}${nchip:+ 芯片:${nchip}}"$'\n'
            else
                nic_details_txt="${nic_details_txt}    ${nnic}  ${nnbdf}  ${nmac}  SN:${nsn}  ${npn}  FW:${nfw}  PCIe(协商):${npcie}  PSID:${npsid}${nchip:+ 芯片:${nchip}}"$'\n'
            fi
        done < <(printf '%s\n' "$NIC_DETAILS")
    fi
    # USB 外接网卡（非 PCIe）追加到明细末尾，独立成段
    if [ -n "$USB_NICS" ]; then
        nic_details_txt="${nic_details_txt}  -- USB 外接网卡（非 PCIe，不参与统计） --"$'\n'
        while IFS='|' read -r unnic unmac unpn unfw; do
            [ -z "$unnic" ] && continue
            nic_details_txt="${nic_details_txt}    ${unnic}  ${unmac}  ${unpn:-—}  FW:${unfw:-—}"$'\n'
        done < <(printf '%s\n' "$USB_NICS")
    fi
    # NVSwitch 纯文本
    local nvs_txt=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_txt="${nvs_txt}    NVSwitch${nidx}  ${nstat}  ${ntemp}  端口:${nports}"$'\n'
        done < <(printf '%s\n' "$NVS_DETAILS")
    fi
    # CPU 每 Socket 明细纯文本
    local cpu_details_txt=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_txt="${cpu_details_txt}    ${csocket}  ${cmodel}  ${ccores}C/${cthreads}T  ${cmaxspd}/${ccurspd}  ${cstep}"$'\n'
        done < <(printf '%s\n' "$CPU_DETAILS")
    fi
    # SEL 最近事件纯文本
    local sel_details_txt=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_txt="${sel_details_txt}    ${sid}  ${sdate} ${stime}  ${stype}  ${sdesc}"$'\n'
        done < <(printf '%s\n' "$SEL_DETAILS")
    fi
    # 风扇明细纯文本
    local fan_details_txt=""
    if [ -n "$FAN_DETAILS" ]; then
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fan_details_txt="${fan_details_txt}    ${fname}  ${frpm} RPM  ${fstatus}"$'\n'
        done < <(printf '%s\n' "$FAN_DETAILS")
    fi
    cat > "$f" << EOF
============================================
HwScope 硬件巡检报告
============================================
采集版本: ${VERSION:-unknown}    报告生成器: ${REPORT_VERSION:-unknown}    主机: ${HOSTNAME:-unknown}
平台: ${PLATFORM_LABEL:-unknown}   时间: ${TIMESTAMP:-unknown}

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
  机箱SN : ${CHASSIS_SN:-N/A}$(if [ -n "$FABRIC_SW" ] && [ "$GPU_COUNT" -eq 0 ]; then printf '\n  PCIe Fabric Switch: %s（HGX 模组互联通道）' "$FABRIC_SW"; fi)

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
$(if [ "$GPU_COUNT" -eq 0 ]; then
    if [ "$HEAD_NODE" -eq 1 ]; then
        echo "  HGX 机头（无本地 GPU，HGX 模组经 PCIe Fabric 单独接入，需单独采集）"
    elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
        echo "  ⚠️ 检测到 ${GPU_PCI_PRESENT} 个 NVIDIA GPU（PCI 3D controller），但 nvidia-smi 无数据（驱动未安装或异常）"
    else
        echo "  N/A (无 GPU)"
    fi
else
    echo "  数量   : ${GPU_COUNT:-0}"
    echo "  型号   : ${GPU_NAMES:-N/A}"
    echo "  显存   : ${GPU_MEM:-N/A}/${GPU_MEM_SPEC_TOTAL:-${GPU_MEM:-N/A}}（检测/额定${GPU_MEM_SPEC:+，${GPU_MEM_SPEC}}）${GPU_MEM_SPEC_NOTE:+ ${GPU_MEM_SPEC_NOTE}}"
    echo "  功耗   : ${GPU_POWER:-N/A}（额定）"
    echo "  温度   : ${GPU_TEMP:-N/A}"
    echo "  ECC    : ${GPU_ECC:-N/A}"
    echo "  退役行 : ${GPU_REMAP:-N/A}"
    echo "  VBIOS  : ${GPU_VBIOS:-N/A}"
fi)$(if [ -n "$NV_LINK_SUMMARY" ] && [ "$NV_LINK_SUMMARY" != "N/A" ]; then echo "  NVLink   : ${NV_LINK_SUMMARY}"; fi)$(if [ "$GPU_COUNT" -gt 0 ]; then printf '%s' "$gpu_details_txt"; fi)$(if [ -n "$nvs_txt" ]; then printf '\n[NVSwitch]\n'; printf '%s' "$nvs_txt"; fi)$(if [ -n "$FW_COMPLIANCE_DETAILS" ]; then
    printf '\n[固件合规]\n'
    echo "$FW_COMPLIANCE_DETAILS" | while IFS='|' read -r fc fd fcur fbase fst fnote; do
        [ -z "$fc" ] && continue
        case "$fst" in
            落后) fst="⚠️ $fst" ;;
            合规) fst="✅ $fst" ;;
        esac
        printf '  %-10s %-26s 当前:%s  推荐:%s  %s  %s\n' "$fc" "$fd" "$fcur" "$fbase" "$fst" "$fnote"
    done
    [ -n "$FW_SUMMARY" ] && printf '  %s\n' "$FW_SUMMARY"
fi)

[存储]
  盘数   : ${STORAGE_COUNT:-0}
  总容量 : ${STORAGE_TOTAL:-N/A}
  盘型号 : ${STORAGE_MODELS:-N/A}
  系统盘 : ${SYS_DISK:-N/A} (已从统计排除)$(if [ -n "$disk_details_txt" ]; then printf '\n%s' "$disk_details_txt"; fi)$(if [ -n "$RAID_VD_DETAILS" ]; then
    printf '\n  RAID虚拟盘（逻辑盘）:\n'
    echo "$RAID_VD_DETAILS" | while IFS='|' read -r rvdname rvdmodel rvdsize rvdsn; do
        [ -z "$rvdname" ] && continue
        printf '    %s  %s  %s  SN(LUN):%s\n' "$rvdname" "$rvdmodel" "$rvdsize" "${rvdsn:-N/A}"
    done
fi)$(if [ -n "$RAID_DETAILS" ]; then
    printf '\n[RAID控制器]\n'
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd rvd_list; do
        [ -z "$ridx" ] && continue
        printf '  %s  %s  SN:%s  固件:%s  虚拟盘:%s\n' "$ridx" "$rmodel" "$rsn" "$rfw" "$rvd"
        if [ -n "$rvd_list" ]; then
            echo "$rvd_list" | tr ';' '\n' | while IFS= read -r vdline; do
                [ -z "$vdline" ] && continue
                vdname="${vdline%%:*}"
                vdrest="${vdline#*:}"
                printf '    %s  %s\n' "$vdname" "$vdrest"
            done
        fi
    done
fi)$(if [ -z "$RAID_DETAILS" ] && [ -n "$RAID_PCI_PRESENT" ]; then
    printf '\n[RAID控制器]\n'
    printf '  ⚠️ 检测到 RAID 控制器（%s），但 storcli64 未安装或采集失败——RAID 配置/虚拟盘/底层盘信息不可用，需现场安装 storcli64 后重采\n' "$(echo "$RAID_PCI_PRESENT" | sed 's/.*: //' | xargs)"
elif [ -z "$RAID_DETAILS" ] && [ -n "$MD_RAID_LIST" ]; then
    printf '\n[RAID控制器]\n'
    printf '  ℹ️ Linux 软件 RAID（mdadm）: %s（系统级软 RAID，非硬件 RAID 卡）\n' "$MD_RAID_LIST"
elif [ -z "$RAID_DETAILS" ] && [ "${RAID_VMD_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
    printf '\n[RAID控制器]\n'
    printf '  ℹ️ 检测到 Intel VMD NVMe RAID（虚拟 RAID，非独立卡，由系统管理）\n'
fi)$(if [ -n "$HBA_DETAILS" ]; then
    printf '\n[HBA直通卡]\n'
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat hsas hports; do
        [ -z "$hname" ] && continue
        printf '  %s  %s  固件:%s  SN:%s  状态:%s  SAS:%s  端口:%s\n' "$hname" "$htype" "$hfw" "$hsn" "$hstat" "$hsas" "$hports"
    done
fi)$(if [ -z "$HBA_DETAILS" ] && [ -n "$HBA_PCI_PRESENT" ]; then
    printf '\n[HBA直通卡]\n'
    printf '  ⚠️ 检测到 SAS HBA（%s），但 sas3ircu/sas2ircu 未安装或采集失败——HBA 型号/固件/端口信息不可用\n' "$(echo "$HBA_PCI_PRESENT" | sed 's/.*: //' | xargs)"
fi)

[网络]
  IB设备 : ${IB_COUNT:-0}
  活动口 : ${IB_ACTIVE:-0}${IB_ACTIVE_SPEED:+ (${IB_ACTIVE_SPEED})}
  Link状态: Active ${IB_ACTIVE:-0} / Down ${IB_LINK_DOWN:-0}${IB_UNPLUGGED:+（未插线缆 ${IB_UNPLUGGED}）}
  额定速率: ${IB_NOMINAL:-N/A}
  网口up : ${ETH_LINK_UP:-0}$(net_extra_txt)$(if [ -n "$nic_details_txt" ]; then printf '\n%s' "$nic_details_txt"; fi)$(if [ -z "$nic_details_txt" ] && [ -n "$NIC_FALLBACK_DETAILS" ]; then
    printf '\n  网卡明细（ibstat 回退，旧采集无 nic_inventory）:\n'
    echo "$NIC_FALLBACK_DETAILS" | while IFS='|' read -r fca ftype fguid fstate; do
        [ -z "$fca" ] && continue
        printf '    %s  %s  GUID:%s  %s\n' "$fca" "$ftype" "$fguid" "$fstate"
    done
fi)

[BMC]
  型号   : ${BMC_FRU:-N/A}
  固件   : ${BMC_FW:-N/A}
  IP     : ${BMC_IP:-N/A}
  MAC    : ${BMC_MAC:-N/A}
  SEL    : $(if [ "${SEL_DATA_VALID:-0}" -eq 1 ] 2>/dev/null; then echo "${SEL_TOTAL:-0} (Critical ${SEL_CRIT:-0})"; else echo "⚠️ 数据不可用"; fi)
$(if [ "${SEL_DATA_VALID:-0}" -eq 0 ] 2>/dev/null; then
    echo "  ⚠️ SEL 数据不可用（ipmitool 采集失败或无权限），事件列表不完整"
elif [ -n "$SEL_DETAILS" ]; then
    echo "  SEL告警事件:"
    echo "$SEL_DETAILS" | while IFS='|' read -r sid sdate stime stype sdesc; do
        printf "    %-4s %-12s %-10s %-25s %s\n" "$sid" "$sdate" "$stime" "$stype" "$sdesc"
    done
else
    echo "  告警事件: 无"
fi)$(if [ -n "$BMC_CONSISTENCY" ]; then
    printf '\n  BMC 一致性校验（OS vs BMC，零新采集）:\n'
    echo "$BMC_CONSISTENCY" | while IFS='|' read -r bitem bos bbmc bres; do
        [ -z "$bitem" ] && continue
        printf '    %-8s OS:%s  BMC:%s  %s\n' "$bitem" "$bos" "$bbmc" "$bres"
    done
    printf '    （不一致 = 潜在刷 SN/换件/固件不匹配风险）\n'
fi)

[风扇]
  数量   : ${FAN_COUNT:-0}
  转速   : ${FAN_SPEED:-N/A}
  温度   : ${TEMP_SUMMARY:-N/A}
$(if [ -n "$FAN_DETAILS" ]; then
    echo "  风扇明细:"
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        printf "    %-16s %8s RPM  %s\n" "$fname" "$fval" "$fstatus"
    done
elif [ "${FAN_COUNT:-0}" -eq 0 ] 2>/dev/null; then
    echo "  ⚠️ 未采集到风扇数据（ipmitool 风扇传感器不可读或平台无风扇传感器）"
fi)

[电源PSU]
$(if [ -n "$PSU_DETAILS" ]; then
    local pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '  %s. %s  %s  PN:%s  SN:%s  容量:%s  当前功耗:%s\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "${pcap:-N/A}" "${ppower:-N/A}"
    done < <(printf '%s\n' "$PSU_DETAILS")
else echo "  N/A（无 PSU 数据：无电源 FRU 且电源传感器为空，可能采集时 BMC 传感器不可读）"; fi)$(if [ -n "$PSU_NOTE_TXT" ]; then printf '\n%s' "$PSU_NOTE_TXT"; fi)$(if [ -n "$PWR_CUR" ] || [ -n "$PWR_ENERGY" ]; then
    printf '\n[能耗台账]\n'
    [ -n "$PWR_CUR" ] && printf '  当前功耗 : %s\n' "$PWR_CUR"
    [ -n "$PWR_MIN" ] && printf '  采样最小 : %s\n' "$PWR_MIN"
    [ -n "$PWR_MAX" ] && printf '  采样最大 : %s\n' "$PWR_MAX"
    [ -n "$PWR_AVG" ] && printf '  采样平均 : %s\n' "$PWR_AVG"
    [ -n "$PWR_ENERGY" ] && printf '  累计能耗 : %s%s\n' "$PWR_ENERGY" "${PWR_ENERGY_SRC:+（${PWR_ENERGY_SRC}）}"
    [ -n "$PWR_NOTE" ] && printf '  %s\n' "$PWR_NOTE"
fi)

[健康检查]
$(printf '%s' "$HEALTH_TXT")
  SEL PCIe : ${SEL_PCIE_ERR:-0} 条错误
  线缆配对 : ${CABLE_PAIRS:-N/A}$(if [ -n "$TEST_DETAILS" ]; then
    printf '\n\n[压测归档]  目录: %s\n' "$TEST_DIR_LABEL"
    echo "$TEST_DETAILS" | while IFS='|' read -r tname tstatus telapsed tfile; do
        [ -z "$tname" ] && continue
        case "$tstatus" in
            通过) tst="✅ 通过" ;;
            异常*) tst="❌ $tstatus" ;;
            工具缺失) tst="— 工具缺失" ;;
            *) tst="$tstatus" ;;
        esac
        printf '  %-24s %-16s %5ss  %s\n' "$tname" "$tst" "$telapsed" "$tfile"
    done
fi)$(if [ -n "$BASELINE_COMPARE" ]; then
    printf '\n[基线对比]  %s\n' "$BASELINE_COMPARE_NOTE"
    echo "$BASELINE_COMPARE" | while IFS='|' read -r bitem bst bcur bbase; do
        [ -z "$bitem" ] && continue
        printf '  %-26s %-6s 当前:%s  基线:%s\n' "$bitem" "$bst" "$bcur" "$bbase"
    done
fi)

[术语说明]
$(glossary_txt)
$(if [ -n "$NIC_MLX" ]; then
    echo ""
    echo "网卡型号对照 (MT 编号 → 型号, lspci 直读优先):"
    echo "  MT4131=ConnectX-8  MT4129/MT2910/MT4125=ConnectX-7  MT4124=ConnectX-6 Lx"
    echo "  MT4123=ConnectX-6 Dx  MT4121/MT4122=ConnectX-6  MT2892/MT2893=ConnectX-5  MT2884/MT2883=ConnectX-4"
fi)
--------------------------------------------
数据来源: 只读解析采集日志（不重新采集）；"额定"为硬件规格，检测值为采集时刻实际状态；明细见 output/<SN>/<模块>/。
--------------------------------------------
由 HwScope ${REPORT_VERSION:-unknown} 报告生成器生成（数据采集版本: ${VERSION:-unknown}）
EOF
    echo -e "${GREEN}[REPORT] TXT: ${f}${NC}"
}

# ─── HTML 报告（MD → HTML，md2html.awk 内嵌专业样式；交付/展示用）───
gen_html() {
    local f="${OUT}/hwscope_report.md"
    [ -f "$f" ] || return 0
    awk -f "${SCRIPT_DIR}/tools/md2html.awk" "$f" > "${OUT}/hwscope_report.html" 2>/dev/null || return 0
    echo -e "${GREEN}[REPORT] HTML: ${OUT}/hwscope_report.html${NC}"
}

# ─── 验收清单生成（--acceptance）───
# 逐项评估硬件状态，输出 hwscope_acceptance.md（交付交接单）
# 项状态: PASS=通过 / FAIL=不通过 / WARN=有条件通过 / N/A=无数据
gen_acceptance() {
    local f="${OUT}/hwscope_acceptance.md"
    local n=0 pass=0 fail=0 warn=0 na=0
    local rows="" st=""
    local verdict="合格"

    # 逐项评估函数：add_item "名称" "状态" "说明" [不计入N/A=1]
    # 第4参数=1 时 N/A 不计数（机头 GPU 项：无 GPU 是平台固有形态，非数据缺失，不计入"数据不足"判定）
    add_item() {
        n=$((n + 1))
        case "$2" in
            PASS) pass=$((pass + 1)); st="✅ PASS" ;;
            FAIL) fail=$((fail + 1)); st="❌ FAIL" ;;
            WARN) warn=$((warn + 1)); st="⚠️ WARN" ;;
            *)    [ "${4:-0}" != "1" ] && na=$((na + 1)); st="— N/A" ;;
        esac
        rows="${rows}| ${n} | $1 | ${st} | $3 |"$'\n'
    }

    # 1. GPU PCIe 链路完整（无 GPU 机器判 N/A 且不计入"数据不足"——无 GPU 是平台形态非数据缺失；
    #    有 GPU 但驱动异常（lspci 3D controller 存在但 nvidia-smi 无数据）→ WARN，无法验收即问题）
    if [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
        if [ "$HEAD_NODE" -eq 1 ]; then
            add_item "GPU PCIe 链路完整" "N/A" "HGX 机头（无本地 GPU，模组单独采集验收）" 1
        elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
            add_item "GPU PCIe 链路完整" "WARN" "检测到 ${GPU_PCI_PRESENT} 个 NVIDIA GPU（PCI 3D controller）但 nvidia-smi 无数据（驱动未安装或异常）"
        else
            add_item "GPU PCIe 链路完整" "N/A" "无 GPU" 1
        fi
    elif [ -n "$GPU_DEGRADED" ]; then
        add_item "GPU PCIe 链路完整" "FAIL" "${GPU_DEGRADED%%,}（期望最高速率）"
    else
        add_item "GPU PCIe 链路完整" "PASS" "全部 GPU 处于最高 PCIe 速率"
    fi

    # 2. NVLink 互联
    case "${NVLINK_HEALTH:-N/A}" in
        OK)   add_item "NVLink 互联" "PASS" "全互联无降级链路" ;;
        异常) add_item "NVLink 互联" "FAIL" "存在降级链路${NVLINK_CRC:+，且有非零 CRC 错误}" ;;
        *)    if [ "$HEAD_NODE" -eq 1 ]; then
                  add_item "NVLink 互联" "N/A" "机头无 NVLink（模组另采）" 1
              elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
                  add_item "NVLink 互联" "WARN" "检测到 NVIDIA GPU 但驱动异常，NVLink 状态不可用"
              elif [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
                  add_item "NVLink 互联" "N/A" "无 GPU" 1
              else
                  add_item "NVLink 互联" "N/A" "无 topo 数据（旧采集）"
              fi ;;
    esac

    # 3. DCGM 诊断
    case "${DCGM_SUMMARY:-N/A}" in
        通过*) add_item "DCGM 诊断" "PASS" "${DCGM_SUMMARY}" ;;
        Fail*硬件:[1-9]*) add_item "DCGM 诊断" "FAIL" "${DCGM_SUMMARY}" ;;
        配置项*Fail*|Fail*) add_item "DCGM 诊断" "WARN" "${DCGM_SUMMARY}（软件/配置类，非硬件故障）" ;;
        *)    if [ "$HEAD_NODE" -eq 1 ]; then
                  add_item "DCGM 诊断" "N/A" "机头无 GPU（模组另采）" 1
              elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
                  add_item "DCGM 诊断" "WARN" "检测到 NVIDIA GPU 但驱动异常，DCGM 无法运行"
              elif [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
                  add_item "DCGM 诊断" "N/A" "无 GPU" 1
              else
                  add_item "DCGM 诊断" "N/A" "未运行（DCGM 未安装或已禁用）"
              fi ;;
    esac

    # 4. GPU VBIOS 版本一致（混插固件是交付要记录的固件一致性问题）
    if [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
        if [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
            add_item "GPU VBIOS 版本一致" "WARN" "检测到 NVIDIA GPU 但驱动异常，VBIOS 不可读"
        else
            add_item "GPU VBIOS 版本一致" "N/A" "无 GPU" 1
        fi
    elif [ "$GPU_VBIOS" = "N/A" ]; then
        add_item "GPU VBIOS 版本一致" "N/A" "无 VBIOS 数据（旧采集或驱动不可用）"
    elif echo "$GPU_VBIOS" | grep -q "不一致"; then
        add_item "GPU VBIOS 版本一致" "WARN" "${GPU_VBIOS#⚠️ }"
    else
        add_item "GPU VBIOS 版本一致" "PASS" "${GPU_VBIOS}"
    fi

    # 内存运行速率（2DPC 满插降速是平台规范/DDR5 物理必然，不算故障；未插满降速才提示；无数据 → N/A）
    if [ -z "$MEM_SPEED" ] || [ "$MEM_SPEED" = "N/A" ]; then
        add_item "内存运行速率" "N/A" "内存速率数据不可用"
    elif [ -n "$MEM_SPEED_NOTE" ]; then
        if [ "$MEM_FULL" -eq 1 ]; then
            add_item "内存运行速率" "PASS" "${MEM_SPEED_NOTE}（插满 ${MEM_POPULATED}/${MEM_SLOTS} 槽 2DPC，降速属平台规范正常现象）"
        else
            add_item "内存运行速率" "WARN" "${MEM_SPEED_NOTE}（仅插 ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} 槽仍降速，建议核查）"
        fi
    else
        add_item "内存运行速率" "PASS" "额定速率运行（${MEM_SPEED:-N/A}）"
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
        done < <(printf '%s\n' "$DISK_DETAILS")
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

    # SMART 整体健康（overall-health PASSED/FAILED，比寿命%更直接的盘可用判定）
    local dhealth_fail="" dhealth_warn="" dhealth_known=0
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            case "$dhealth" in
                FAILED) dhealth_known=$((dhealth_known+1)); dhealth_fail="${dhealth_fail}${dname}," ;;
                ⚠️*)   dhealth_known=$((dhealth_known+1)); dhealth_warn="${dhealth_warn}${dname}(${dhealth#⚠️})," ;;
                PASSED|OK) dhealth_known=$((dhealth_known+1)) ;;
            esac
        done < <(printf '%s\n' "$DISK_DETAILS")
    fi
    if [ "$dhealth_known" -eq 0 ]; then
        add_item "SMART 健康状态" "N/A" "无 SMART 健康数据（旧采集或盘不支持）"
    elif [ -n "$dhealth_fail" ]; then
        add_item "SMART 健康状态" "FAIL" "${dhealth_fail%,}（SMART 健康评估 FAILED）"
    elif [ -n "$dhealth_warn" ]; then
        add_item "SMART 健康状态" "WARN" "${dhealth_warn%,}（SMART 有警告）"
    else
        add_item "SMART 健康状态" "PASS" "全部盘 SMART 健康评估通过"
    fi

    # 电源冗余（N+N 冗余是供电可靠性核心；失效=单点故障风险）
    case "$PSU_REDUNDANT" in
        N/A) add_item "电源冗余（N+N）" "N/A" "无冗余传感器数据" ;;
        *失效*) add_item "电源冗余（N+N）" "FAIL" "电源冗余失效（单点故障风险）" ;;
        *) add_item "电源冗余（N+N）" "PASS" "${PSU_REDUNDANT}" ;;
    esac

    # 12. 整机温度正常范围（进风/出风/CPU/内存/电源/PCH 传感器均 ok）
    if [ -z "$TEMP_SUMMARY" ]; then
        add_item "整机温度正常" "N/A" "无温度传感器数据"
    else
        add_item "整机温度正常" "PASS" "${TEMP_SUMMARY}"
    fi

    # 13. SEL 事件（合并 Critical + PCIe 错误；采集失败/无数据 → N/A，禁止假阳性 PASS）
    if [ "${SEL_DATA_VALID:-0}" -ne 1 ] 2>/dev/null; then
        add_item "SEL 事件" "N/A" "SEL 数据不可用（ipmitool 采集失败或无权限）"
    elif [ "${SEL_CRIT:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "FAIL" "共 ${SEL_TOTAL:-0} 条 SEL，其中 ${SEL_CRIT} 条 Critical"
    elif [ "${SEL_PCIE_ERR:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "FAIL" "${SEL_PCIE_ERR} 条 PCIe/AER/uncorrectable 记录"
    elif [ "${SEL_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "PASS" "${SEL_TOTAL} 条 SEL，无 Critical/PCIe 错误（有历史事件）"
    else
        add_item "SEL 事件" "PASS" "无 SEL 事件"
    fi

    # 14. 固件版本合规（15_firmware 输出；落后=FAIL，无基线判未知=N/A 不误报——未配置基线是
    #     验收配置缺口而非硬件问题；全部未知即整体 N/A 提示补录基线）
    if [ -z "$FW_COMPLIANCE_DETAILS" ]; then
        add_item "固件版本合规" "N/A" "无固件数据（15_firmware 未采集或旧数据）"
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|落后|"; then
        _fw_behind=$(printf '%s\n' "$FW_COMPLIANCE_DETAILS" | awk -F'|' '$5=="落后"{printf "%s(%s→%s), ", $2, $4, $3}')
        add_item "固件版本合规" "FAIL" "固件落后于推荐版本: ${_fw_behind%,}"
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|无法比较|"; then
        add_item "固件版本合规" "WARN" "部分固件版本格式非标准，需人工核对"
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|未知|"; then
        add_item "固件版本合规" "N/A" "无基线配置（conf/fw_required.txt 未录入推荐版本），仅记录当前版本"
    else
        add_item "固件版本合规" "PASS" "全部固件版本满足推荐基线（较新不判落后）"
    fi

    # 15. OS vs BMC 口径一致（零新采集交叉校验；不一致=FAIL，仅单侧数据=WARN，无数据=N/A）
    # 无 BMC 机器（IPMI 日志全错误/无有效 FRU）→ N/A 且不计入"数据不足"——无 BMC 是平台固有形态
    if [ "${BMC_PRESENT:-0}" -eq 0 ] 2>/dev/null; then
        if ls "${BMC_DIR}"/ipmi_*.log >/dev/null 2>&1; then
            add_item "OS-BMC 口径一致" "N/A" "机器无 BMC（IPMI 日志为错误输出，平台固有形态，交叉校验不适用）" 1
        else
            add_item "OS-BMC 口径一致" "N/A" "无 IPMI/Redfish 数据（ipmitool 未安装或模块关闭），无法交叉校验"
        fi
    elif [ -z "$BMC_CONSISTENCY" ]; then
        add_item "OS-BMC 口径一致" "N/A" "无 BMC 对比数据（旧采集或采集失败）"
    elif printf '%s\n' "$BMC_CONSISTENCY" | grep -q "⚠️ 不一致"; then
        _bc_bad=$(printf '%s\n' "$BMC_CONSISTENCY" | awk -F'|' '$4 ~ /不一致/{printf "%s, ", $1}')
        add_item "OS-BMC 口径一致" "FAIL" "${_bc_bad%,} 不一致（潜在刷 SN/换件/固件不匹配风险）"
    elif printf '%s\n' "$BMC_CONSISTENCY" | grep -qE "仅(OS|BMC)侧数据"; then
        add_item "OS-BMC 口径一致" "WARN" "部分对比项仅单侧数据（建议补采 Redfish 完整核验）"
    else
        add_item "OS-BMC 口径一致" "PASS" "OS 与 BMC 口径完全一致"
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

    # ── 配置单派生（硬件概览表格数据：内存每槽/网卡归类/PSU 汇总/盘型号） ──
    ACC_MEM_DIMM="N/A"
    if [ "${MEM_POPULATED:-0}" -gt 0 ] 2>/dev/null && [ -n "${MEM_TOTAL_PHYS:-}" ]; then
        _mtp=$(echo "$MEM_TOTAL_PHYS" | grep -oE "[0-9.]+" | head -1)
        [ -n "$_mtp" ] && ACC_MEM_DIMM=$(awk -v t="$_mtp" -v p="$MEM_POPULATED" 'BEGIN{printf "%.0fGB", t/p}' < /dev/null)
    fi
    ACC_NIC_IB="N/A"; ACC_NIC_IB_COUNT=0; ACC_NIC_ETH="N/A"; ACC_NIC_ETH_COUNT=0
    if [ -n "$NIC_DETAILS" ]; then
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip; do
            [ -z "$nnic" ] && continue
            if echo "${npn}${nchip}" | grep -qiE "ConnectX|MCX[0-9]|MT[0-9]{4}"; then
                ACC_NIC_IB_COUNT=$((ACC_NIC_IB_COUNT+1))
                [ "$ACC_NIC_IB" = "N/A" ] && ACC_NIC_IB="${npn:-N/A}"
            else
                ACC_NIC_ETH_COUNT=$((ACC_NIC_ETH_COUNT+1))
                [ "$ACC_NIC_ETH" = "N/A" ] && ACC_NIC_ETH="$(echo "${npn:-N/A}" | sed 's/Intel Corporation Ethernet Controller //; s/ for 10GBASE-T.*//; s/ (rev [0-9]*)//')"
            fi
        done < <(printf '%s\n' "$NIC_DETAILS")
    fi
    ACC_PSU_MODEL="N/A"; ACC_PSU_CAP="N/A"; ACC_PSU_COUNT=0
    if [ -n "$PSU_DETAILS" ]; then
        while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
            [ -z "$pdesc" ] && continue
            ACC_PSU_COUNT=$((ACC_PSU_COUNT+1))
            [ "$ACC_PSU_MODEL" = "N/A" ] && [ "$pmodel" != "N/A" ] && [ -n "$pmodel" ] && ACC_PSU_MODEL="$pmodel"
            [ "$ACC_PSU_CAP" = "N/A" ] && [ "$pcap" != "N/A" ] && [ -n "$pcap" ] && ACC_PSU_CAP="$pcap"
        done < <(printf '%s\n' "$PSU_DETAILS")
    fi
    ACC_DISK_MODEL="N/A"
    if [ -n "${STORAGE_MODELS:-}" ]; then
        ACC_DISK_MODEL=$(echo "$STORAGE_MODELS" | tr ',' '\n' | head -1)
    fi

    {
        echo "# HwScope 验收清单（Acceptance Checklist）"
        echo ""
        echo "## 硬件概览（配置单，自动生成自检测数据）"
        echo ""
        echo "| 项目 | 规格型号描述（含配置） | 单位 | 数量 |"
        echo "|------|------------------------|------|------|"
        echo "| 准系统 | ${MB_MANUFACTURER:-N/A} ${MB_PRODUCT:-N/A}（机箱 SN: ${CHASSIS_SN:-N/A}，BIOS: ${BIOS_VERSION:-N/A}） | 台 | 1 |"
        echo "| CPU | ${CPU_MODEL:-N/A}（${CPU_CORES:-0} 核/颗，${CPU_MAX_SPEED:-N/A}MHz） | 颗 | ${CPU_SOCKETS:-0} |"
        echo "| 内存 | ${MEM_TYPE:-DDR} ${ACC_MEM_DIMM:-N/A} ECC RDIMM（额定 ${MEM_NOM:-N/A}，实际 ${MEM_SPEED:-N/A}） | 条 | ${MEM_POPULATED:-0} |"
        # GPU 显存类型（数据中心 HBM / 消费与专业 GDDR；未识别型号不标注，避免误导）
        ACC_GPU_MEMTYPE=""
        if [ "${GPU_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            if echo "$GPU_NAMES" | grep -qiE "B200|B300|H100|H200|H800|A100|A800|A30|A16|V100|P100|GH200|MI[0-9]"; then
                ACC_GPU_MEMTYPE="HBM"
            elif echo "$GPU_NAMES" | grep -qiE "GeForce|GTX|RTX|Quadro"; then
                ACC_GPU_MEMTYPE="GDDR"
            fi
        fi
        if [ "${GPU_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            echo "| GPU模组 | ${GPU_NAMES:-N/A}（${GPU_MEM_SPEC:-N/A}${ACC_GPU_MEMTYPE:+ ${ACC_GPU_MEMTYPE}}） | 张 | ${GPU_COUNT} |"
        else
            echo "| GPU模组 | 无（${PLATFORM_LABEL:-N/A} 平台） | — | — |"
        fi
        if [ "${ACC_NIC_IB_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            echo "| 计算网卡 | ${ACC_NIC_IB:-N/A}（IB ${IB_NOMINAL:-N/A}） | 张 | ${ACC_NIC_IB_COUNT} |"
        fi
        if [ "${ACC_NIC_ETH_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            echo "| 网卡&端口 | ${ACC_NIC_ETH:-N/A} | 张 | ${ACC_NIC_ETH_COUNT} |"
        fi
        echo "| 存储 | ${ACC_DISK_MODEL:-N/A}（${STORAGE_TOTAL:-0}） | 块 | ${STORAGE_COUNT:-0} |"
        echo "| 电源模块 | ${ACC_PSU_MODEL:-N/A}（${ACC_PSU_CAP:-N/A}） | 个 | ${ACC_PSU_COUNT:-0} |"
        echo "| 系统管理 | BMC（固件 ${BMC_FW:-N/A}） | 套 | 1 |"
        echo ""
        echo "## 验收信息"
        echo ""
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
    # 验收清单 HTML（同 md2html.awk 转换，交付交接单展示用）
    awk -f "${SCRIPT_DIR}/tools/md2html.awk" "$f" > "${OUT}/hwscope_acceptance.html" 2>/dev/null && \
        echo -e "${GREEN}[REPORT] 验收清单 HTML: ${OUT}/hwscope_acceptance.html${NC}"
}

case "$FORMAT" in
    --json) gen_json ;;
    --md)   gen_md; gen_html ;;
    --txt)  gen_txt ;;
    --acceptance) gen_acceptance ;;
    *)      gen_json; gen_md; gen_txt; gen_html ;;
esac

echo -e "${GREEN}[REPORT] 生成完成${NC}"
