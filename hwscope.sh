#!/bin/bash
# =============================================================================
# HwScope — Hardware Scope: Server Hardware Inspection & Data Collection System
#
# Author  : YanHui / Hermes Agent
# Version : 1.2.0 (2026-07)
# License : Apache 2.0
#
# 要求：LANG=en_US.UTF-8 或 C.UTF-8（避免中文乱码）
# 用法：
#   sudo bash hwscope.sh                              # 全部采集
#   sudo bash hwscope.sh --modules gpu,storage         # 只采部分模块
#   sudo bash hwscope.sh --skip bmc,nvsm               # 跳过某些模块
#   sudo bash hwscope.sh --parallel                    # 并行采集
#   sudo bash hwscope.sh --quiet                       # 静默模式
#   sudo bash hwscope.sh --output /data/collect        # 指定输出目录
#   sudo bash hwscope.sh --force                       # 覆盖已有目录
#   sudo bash hwscope.sh --help                        # 帮助
#   sudo bash hwscope.sh --version                     # 版本
#
# =============================================================================
#
# ⚠️  CRLF error?  Run:  bash fixcrlf.sh && sudo bash hwscope.sh

set -uo pipefail

# ─── 检查 locale（非 UTF-8 时尝试切换，不影响系统环境） ───
if [ "$(locale charmap 2>/dev/null)" != "UTF-8" ]; then
    for _try in LC_ALL=C.UTF-8 LC_ALL=en_US.UTF-8 LANG=C.UTF-8 LANG=en_US.UTF-8; do
        if export "$_try" 2>/dev/null && [ "$(locale charmap 2>/dev/null)" = "UTF-8" ]; then
            echo "[INFO] 临时切换 locale -> $(locale charmap)（仅本进程有效）"
            break
        fi
    done
    unset _try
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── 加载公共库 ───
source "${SCRIPT_DIR}/lib/common.sh"

# ─── 加载配置 ───
CONF_FILE="${SCRIPT_DIR}/conf/hwscope.conf"
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# ─── 模块注册表 ───
MODULES=(
    "01:motherboard:run_motherboard:主板/BIOS/机箱"
    "02:cpu:run_cpu:CPU 信息"
    "03:memory:run_memory:内存插槽/容量/速率"
    "04:gpu:run_gpu:GPU 信息"
    "05:nvswitch:run_nvswitch:NVSwitch 信息"
    "06:pcie:run_pcie:PCIe 拓扑/速率"
    "07:network:run_network:网络/IB/光模块"
    "08:storage:run_storage:存储设备(SATA/SAS/NVMe/SMART)"
    "09:raid:run_raid:RAID/HBA 卡信息"
    "10:psu:run_psu:电源 (PSU) 信息"
    "11:fan:run_fan:风扇 (FAN) 信息"
    "12:bmc:run_bmc:BMC/IPMI 带外信息"
    "13:nvsm:run_nvsm:NVSM 综合(条件)"
    "14:dcgm:run_dcgm:DCGM 诊断(条件)"
    "99:os:run_os:OS 基础信息"
)

# ─── 模块开关映射 ───
declare -A MODULE_SWITCH
MODULE_SWITCH[motherboard]="${MODULE_MB:-1}"; MODULE_SWITCH[cpu]="${MODULE_CPU:-1}"
MODULE_SWITCH[memory]="${MODULE_MEMORY:-1}"; MODULE_SWITCH[gpu]="${MODULE_GPU:-1}"
MODULE_SWITCH[nvswitch]="${MODULE_NVSWITCH:-1}"; MODULE_SWITCH[pcie]="${MODULE_PCIE:-1}"
MODULE_SWITCH[network]="${MODULE_NETWORK:-1}"; MODULE_SWITCH[storage]="${MODULE_STORAGE:-1}"
MODULE_SWITCH[raid]="${MODULE_RAID:-1}"; MODULE_SWITCH[psu]="${MODULE_PSU:-1}"
MODULE_SWITCH[fan]="${MODULE_FAN:-1}"; MODULE_SWITCH[bmc]="${MODULE_BMC:-1}"
MODULE_SWITCH[nvsm]="${MODULE_NVSM:-1}"; MODULE_SWITCH[dcgm]="${MODULE_DCGM:-1}"
MODULE_SWITCH[os]="${MODULE_OS:-1}"
# ─── 版本声明 ───
HWSCOPE_VERSION="v1.2.0"

# ─── 命令行参数 ───
SELECTED_MODULES=""; SKIP_MODULES=""; OUTPUT_BASE="${OUTPUT_BASE_DIR:-}"
FORCE_MODE="${FORCE:-0}"; QUIET=0; PARALLEL=0; NO_MODULE=0

usage() {
    echo "用法: $0 [OPTIONS]"
    echo ""
    echo "选项:"
    echo "  --modules gpu,storage           只采指定模块（逗号分隔）"
    echo "  --skip dcgm,nvsm                跳过指定模块"
    echo "  --parallel                      并行执行所有模块"
    echo "  --no-module                     跳过光模块查询（省 40s+）"
    echo "  --output /path/to/dir           指定输出目录"
    echo "  --force                         覆盖已有输出目录"
    echo "  -q, --quiet                     静默模式（只看 WARN）"
    echo "  -h, --help                      显示此帮助"
    echo "  -v, --version                   显示版本"
    echo ""
    echo "可用模块:"
    for mod_info in "${MODULES[@]}"; do
        IFS=':' read -r num id fn desc <<< "$mod_info"
        echo "  ${num}. ${id} - ${desc}"
    done
    echo ""
    echo "示例:"
    echo "  sudo bash $0                              # 全部采集（串行）"
    echo "  sudo bash $0 --parallel --quiet           # 并行静默采集"
    echo "  sudo bash $0 --modules gpu,storage        # 只采 GPU+存储"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --modules)  SELECTED_MODULES="$2"; shift 2 ;;
        --skip)     SKIP_MODULES="$2"; shift 2 ;;
        --output)   OUTPUT_BASE="$2"; shift 2 ;;
        --force)    FORCE_MODE=1; shift ;;
        --parallel) PARALLEL=1; shift ;;
        --no-module) NO_MODULE=1; shift ;;
        -q|--quiet) QUIET=1; shift ;;
        -h|--help)  usage ;;
        -v|--version) echo "HwScope v1.2.0 (2026-07) — Hardware Scope"
                      echo "Author: YanHui / Hermes Agent · License: Apache 2.0"
                      echo "https://github.com/YanHuiStar/hwscope"
                      exit 0 ;;
        *) echo -e "${RED}错误: 未知参数 $1${NC}"; usage ;;
    esac
done

# ─── 机器标识 ───
MACHINE_ID=""
if check_cmd dmidecode; then
    MACHINE_ID=$(dmidecode -t system 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
    [ -z "$MACHINE_ID" ] && MACHINE_ID=$(dmidecode -t baseboard 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
    [ -z "$MACHINE_ID" ] && MACHINE_ID=$(dmidecode -t system 2>/dev/null | grep -i 'UUID' | head -1 | awk -F': ' '{print $2}' | tr -d ' -')
fi
[ -z "$MACHINE_ID" ] && MACHINE_ID=$(date '+%Y%m%d_%H%M%S')

# ─── 输出目录 ───
local_timestamp=$(date '+%Y%m%d_%H%M%S')
if [ -z "$OUTPUT_BASE" ]; then
    OUTPUT_BASE="${SCRIPT_DIR}/output/${MACHINE_ID}"
    [ -d "$OUTPUT_BASE" ] && [ "$FORCE_MODE" -ne 1 ] && OUTPUT_BASE="${SCRIPT_DIR}/output/${MACHINE_ID}-${local_timestamp}"
fi

if [ -d "$OUTPUT_BASE" ]; then
    if [ "$FORCE_MODE" -eq 1 ]; then
        rm -rf "$OUTPUT_BASE"
        echo -e "${YELLOW}[WARN] 覆盖已有输出目录: ${OUTPUT_BASE}${NC}"
    else
        echo -e "${RED}[ERROR] 输出目录已存在: ${OUTPUT_BASE}${NC}"; echo "使用 --force 覆盖或指定其他目录"; exit 1
    fi
fi
mkdir -p "$OUTPUT_BASE"

# ─── 执行日志 ───
LOG_FILE="${OUTPUT_BASE}/hwscope.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date '+%H:%M:%S')] 日志输出到: ${LOG_FILE}"

# ─── 平台检测 ───
HW_ARCH=$(uname -m 2>/dev/null || echo "unknown"); PLATFORM="${HW_ARCH}"
if check_cmd nvidia-smi; then
    GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l || echo 0)
    # SXM 检测：nvswitch CLI 优先，无 CLI 则用 lspci 查 NVSwitch 硬件
    _sxm=0
    if check_cmd nvswitch && nvswitch -q 2>/dev/null | grep -qi "Switch Name"; then
        _sxm=1
    elif check_cmd lspci && lspci 2>/dev/null | grep -qi "NVSwitch\|SXM.*Bridge"; then
        _sxm=1
    fi
    if [ "$_sxm" -eq 1 ]; then
        PLATFORM="${HW_ARCH}_SXM"
    elif [ "$GPU_COUNT" -gt 0 ]; then
        PLATFORM="${HW_ARCH}_PCIe"
    else PLATFORM="${HW_ARCH}_none"; fi
else PLATFORM="${HW_ARCH}_none"; fi
echo -e "${CYAN}[INFO]${NC} Platform: ${PLATFORM} (GPU: ${GPU_COUNT:-0})"

# ─── 汇总文件 ───
SUMMARY_FILE="${OUTPUT_BASE}/summary.txt"
{
    echo "============================================================"
    echo "HwScope - Hardware Scope Collection"
    echo "Version  : ${HWSCOPE_VERSION}"
    echo "Hostname : $(hostname)"; echo "Platform : ${PLATFORM} (GPU: ${GPU_COUNT:-0})"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"; echo "Output   : ${OUTPUT_BASE}"
    echo "============================================================"; echo ""
} > "$SUMMARY_FILE"

cp "$CONF_FILE" "${OUTPUT_BASE}/config_backup.conf" 2>/dev/null || true

# ─── 模块执行 ───
echo ""
echo "========================================"
echo -e "${BLUE}HwScope - 服务器硬件巡检采集${NC}"
echo "平台: ${PLATFORM}  输出: ${OUTPUT_BASE}"
echo "========================================"
echo ""

TOTAL_COUNT=0; FILE_COUNT=0

if [ "$PARALLEL" -eq 1 ]; then
    # ═══════════════ 并行模式 ═══════════════
    echo -e "${CYAN}[QUEUE]${NC} 并行启动所有模块..."
    echo ""

    PIDS=(); MODULE_INFO=()
    for mod_info in "${MODULES[@]}"; do
        IFS=':' read -r num id fn desc <<< "$mod_info"
        [ -n "$SELECTED_MODULES" ] && ! echo ",${SELECTED_MODULES}," | grep -qi ",${id}," && continue
        [ -n "$SKIP_MODULES" ]     && echo ",${SKIP_MODULES}," | grep -qi ",${id}," && continue
        [ "${MODULE_SWITCH[$id]:-1}" -ne 1 ] && continue

        MODULE_SCRIPT="${SCRIPT_DIR}/modules/${num}_${id}.sh"
        [ ! -f "$MODULE_SCRIPT" ] && continue
        source "$MODULE_SCRIPT"

        if declare -F "$fn" >/dev/null 2>&1; then
            mkdir -p "${OUTPUT_BASE}/${id}"
            (
                reset_warn_count
                "$fn" "$OUTPUT_BASE" 2>&1
                echo "$(get_warn_count)" > "${OUTPUT_BASE}/.${id}_warn"
                find "${OUTPUT_BASE}/${id}" -type f 2>/dev/null | wc -l > "${OUTPUT_BASE}/.${id}_files"
            ) > "${OUTPUT_BASE}/.${id}_log" 2>&1 &
            PIDS+=($!); MODULE_INFO+=("${num}|${id}|${desc}")
        fi
    done

    # 等待全部完成
    for pid in "${PIDS[@]}"; do wait $pid 2>/dev/null; done

    # 按注册表顺序输出 + 汇总
    for info in "${MODULE_INFO[@]}"; do
        IFS='|' read -r num id desc <<< "$info"
        cat "${OUTPUT_BASE}/.${id}_log" 2>/dev/null
        warn=$(cat "${OUTPUT_BASE}/.${id}_warn" 2>/dev/null || echo 0)
        files=$(cat "${OUTPUT_BASE}/.${id}_files" 2>/dev/null || echo 0)
        FILE_COUNT=$((FILE_COUNT + files))
        summary_append "$SUMMARY_FILE" "${num}.${id} (${desc})" "${files} files, -, ${warn} WARN"
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        rm -f "${OUTPUT_BASE}/.${id}_log" "${OUTPUT_BASE}/.${id}_warn" "${OUTPUT_BASE}/.${id}_files"
    done
else
    # ═══════════════ 串行模式 ═══════════════
    for mod_info in "${MODULES[@]}"; do
        IFS=':' read -r num id fn desc <<< "$mod_info"
        [ -n "$SELECTED_MODULES" ] && ! echo ",${SELECTED_MODULES}," | grep -qi ",${id}," && { [ "$QUIET" -eq 1 ] || echo -e "${YELLOW}[SKIP] ${id} - 未在 --modules 列表中${NC}"; continue; }
        [ -n "$SKIP_MODULES" ] && echo ",${SKIP_MODULES}," | grep -qi ",${id}," && { [ "$QUIET" -eq 1 ] || echo -e "${YELLOW}[SKIP] ${id} - 在 --skip 列表中${NC}"; continue; }
        [ "${MODULE_SWITCH[$id]:-1}" -ne 1 ] && { [ "$QUIET" -eq 1 ] || echo -e "${YELLOW}[SKIP] ${id} - 配置已禁用${NC}"; continue; }

        MODULE_SCRIPT="${SCRIPT_DIR}/modules/${num}_${id}.sh"
        [ ! -f "$MODULE_SCRIPT" ] && { echo -e "${RED}[ERROR] 模块脚本不存在: ${MODULE_SCRIPT}${NC}"; continue; }
        source "$MODULE_SCRIPT"

        if declare -F "$fn" >/dev/null 2>&1; then
            start_ts=$(date +%s); mkdir -p "${OUTPUT_BASE}/${id}"
            reset_warn_count
            "$fn" "$OUTPUT_BASE"
            warn_count=$(get_warn_count)
            end_ts=$(date +%s); elapsed=$((end_ts - start_ts))
            mod_file_count=$(find "${OUTPUT_BASE}/${id}" -type f 2>/dev/null | wc -l)
            FILE_COUNT=$((FILE_COUNT + mod_file_count))
            summary_append "$SUMMARY_FILE" "${num}.${id} (${desc})" "${mod_file_count} files, ${elapsed}s, ${warn_count} WARN"
            TOTAL_COUNT=$((TOTAL_COUNT + 1))
        else
            echo -e "${RED}[ERROR] 函数 ${fn} 未在 ${MODULE_SCRIPT} 中定义${NC}"
        fi
    done
fi

# ─── 最终汇总 ───
{
    echo ""; echo "============================================================"
    echo "采集完成汇总"; echo "============================================================"
    echo "执行模块数 : ${TOTAL_COUNT}"; echo "总日志文件 : ${FILE_COUNT}"
    echo "输出目录   : ${OUTPUT_BASE}"; echo "完成时间   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"; echo ""
    echo "输出目录结构:"; echo "  ${OUTPUT_BASE}/"
    for mod_info in "${MODULES[@]}"; do
        IFS=':' read -r num id fn desc <<< "$mod_info"
        subdir="${OUTPUT_BASE}/${id}"
        [ -d "$subdir" ] && echo "  ├── ${id}/    ($(find "$subdir" -type f 2>/dev/null | wc -l) files)"
    done
    echo "  └── summary.txt"; echo ""
} >> "$SUMMARY_FILE"

echo ""
echo "========================================"
echo -e "${GREEN}采集完成！${NC}"; echo "输出目录: ${OUTPUT_BASE}"; echo "总日志数: ${FILE_COUNT}"
echo "========================================"
echo ""
find "${OUTPUT_BASE}" -type d | sort | while read d; do
    indent=$(echo "$d" | sed "s|${OUTPUT_BASE}||" | tr '/' ' ')
    level=$(echo "$d" | tr -cd '/' | wc -c); prefix=""
    for ((i=0; i<level-1; i++)); do prefix="${prefix}  "; done
    [ "$level" -gt 0 ] && echo "${prefix}├── $(basename "$d")/"
done
echo ""; echo -e "${CYAN}汇总文件: ${SUMMARY_FILE}${NC}"; echo ""

# ─── 清理 ANSI ───
if [ -f "$LOG_FILE" ] && check_cmd sed; then
    sed -i 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" 2>/dev/null || true
fi

# ─── 压缩归档 ───
LOGS_DIR="${SCRIPT_DIR}/logs"
ARCHIVE_NAME="${MACHINE_ID}-$(date '+%Y%m%d_%H%M%S').tar.gz"
mkdir -p "$LOGS_DIR"
if check_cmd tar; then
    tar czf "${LOGS_DIR}/${ARCHIVE_NAME}" -C "$(dirname "$OUTPUT_BASE")" "$(basename "$OUTPUT_BASE")" 2>/dev/null
    echo -e "${GREEN}[ARCHIVE]${NC} ${LOGS_DIR}/${ARCHIVE_NAME}"
fi
