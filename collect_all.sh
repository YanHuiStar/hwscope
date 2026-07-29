#!/bin/bash
# =============================================================================
# HwScope — Hardware Scope: Server Hardware Inspection & Data Collection System
#
# Author  : YanHui / Hermes Agent
# Version : 1.0.0 (2026-07)
# License : Apache 2.0
#
# 要求：LANG=en_US.UTF-8 或 C.UTF-8（避免中文乱码）
# 用法：
#   sudo bash collect_all.sh                          # 完整采集
#   sudo bash collect_all.sh --modules gpu,system      # 只采部分模块
#   sudo bash collect_all.sh --skip bmc,nvsm           # 跳过某些模块
#   sudo bash collect_all.sh --output /data/collect    # 指定输出目录
#   sudo bash collect_all.sh --force                   # 覆盖已有目录
#   sudo bash collect_all.sh --help                    # 帮助
#
# 每个模块输出到独立子目录：output/<timestamp>/<module>/
# 每个查询命令保存到独立日志文件，文件开头包含执行的命令原文
# =============================================================================

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
# 格式: "编号:标识符:函数名:描述"
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

# ─── 模块开关映射（从配置文件读取） ───
declare -A MODULE_SWITCH
MODULE_SWITCH[motherboard]="${MODULE_MB:-1}"
MODULE_SWITCH[cpu]="${MODULE_CPU:-1}"
MODULE_SWITCH[memory]="${MODULE_MEMORY:-1}"
MODULE_SWITCH[gpu]="${MODULE_GPU:-1}"
MODULE_SWITCH[nvswitch]="${MODULE_NVSWITCH:-1}"
MODULE_SWITCH[pcie]="${MODULE_PCIE:-1}"
MODULE_SWITCH[network]="${MODULE_NETWORK:-1}"
MODULE_SWITCH[storage]="${MODULE_STORAGE:-1}"
MODULE_SWITCH[raid]="${MODULE_RAID:-1}"
MODULE_SWITCH[psu]="${MODULE_PSU:-1}"
MODULE_SWITCH[fan]="${MODULE_FAN:-1}"
MODULE_SWITCH[bmc]="${MODULE_BMC:-1}"
MODULE_SWITCH[nvsm]="${MODULE_NVSM:-1}"
MODULE_SWITCH[dcgm]="${MODULE_DCGM:-1}"
MODULE_SWITCH[os]="${MODULE_OS:-1}"

# ─── 解析命令行参数 ───
SELECTED_MODULES=""      # 空 = 全部
SKIP_MODULES=""          # 空 = 不跳过
OUTPUT_BASE="${OUTPUT_BASE_DIR:-}"
FORCE_MODE="${FORCE:-0}"

usage() {
    echo "用法: $0 [OPTIONS]"
    echo ""
    echo "选项:"
    echo "  --modules gpu,system,memory   只采指定模块（逗号分隔）"
    echo "  --skip bmc,nvsm               跳过指定模块"
    echo "  --output /path/to/dir         指定输出目录"
    echo "  --force                       覆盖已有输出目录"
    echo "  -h, --help                    显示此帮助"
    echo ""
    echo "可用模块:"
    for mod_info in "${MODULES[@]}"; do
        IFS=':' read -r num id fn desc <<< "$mod_info"
        echo "  ${num}. ${id} - ${desc}"
    done
    echo ""
    echo "示例:"
    echo "  sudo bash $0                              # 全部采集"
    echo "  sudo bash $0 --modules gpu,bmc,system     # 只采 GPU/BMC/主板"
    echo "  sudo bash $0 --skip dcgm,nvsm             # 跳过诊断模块"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --modules)
            SELECTED_MODULES="$2"
            shift 2
            ;;
        --skip)
            SKIP_MODULES="$2"
            shift 2
            ;;
        --output)
            OUTPUT_BASE="$2"
            shift 2
            ;;
        --force)
            FORCE_MODE=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}错误: 未知参数 $1${NC}"
            usage
            ;;
    esac
done

# ─── 机器标识（用于输出目录命名，按优先级降级） ───
# ① 服务器SN → ② 主板SN → ③ 机器UUID → ⑥ 时间戳保底
MACHINE_ID=""
if check_cmd dmidecode; then
    MACHINE_ID=$(dmidecode -t system 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
    [ -z "$MACHINE_ID" ] && MACHINE_ID=$(dmidecode -t baseboard 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
    [ -z "$MACHINE_ID" ] && MACHINE_ID=$(dmidecode -t system 2>/dev/null | grep -i 'UUID' | head -1 | awk -F': ' '{print $2}' | tr -d ' -')
fi
# 兜底：时间戳（保证一定不冲突）
[ -z "$MACHINE_ID" ] && MACHINE_ID=$(date '+%Y%m%d_%H%M%S')

# ─── 输出目录初始化 ───
local_timestamp=$(date '+%Y%m%d_%H%M%S')
if [ -z "$OUTPUT_BASE" ]; then
    OUTPUT_BASE="${SCRIPT_DIR}/output/${MACHINE_ID}/${local_timestamp}"
else
    # --output 用户指定了完整路径，直接使用
    :
fi

if [ -d "$OUTPUT_BASE" ]; then
    if [ "$FORCE_MODE" -eq 1 ]; then
        rm -rf "$OUTPUT_BASE"
        echo -e "${YELLOW}[WARN] 覆盖已有输出目录: ${OUTPUT_BASE}${NC}"
    else
        echo -e "${RED}[ERROR] 输出目录已存在: ${OUTPUT_BASE}${NC}"
        echo "使用 --force 覆盖或指定其他目录"
        exit 1
    fi
fi

mkdir -p "$OUTPUT_BASE"

# ─── 开启执行日志（同时输出到终端和文件） ───
LOG_FILE="${OUTPUT_BASE}/collect_all.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date '+%H:%M:%S')] 日志输出到: ${LOG_FILE}"

# ─── 平台检测 ───
HW_ARCH=$(uname -m 2>/dev/null || echo "unknown")
PLATFORM="${HW_ARCH}"
# GPU 拓扑判断
if check_cmd nvidia-smi; then
    GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l || echo 0)
    if check_cmd nvswitch && nvswitch -q 2>/dev/null | grep -qi "Switch Name"; then
        PLATFORM="${HW_ARCH}_SXM"
    elif [ "$GPU_COUNT" -gt 0 ]; then
        PLATFORM="${HW_ARCH}_PCIe"
    else
        PLATFORM="${HW_ARCH}_none"
    fi
else
    PLATFORM="${HW_ARCH}_none"
fi
echo -e "${CYAN}[INFO]${NC} Platform: ${PLATFORM} (GPU: ${GPU_COUNT:-0})"

# ─── 解析选中/跳过的模块列表 ───
declare -A MODULE_MAP
for mod_info in "${MODULES[@]}"; do
    IFS=':' read -r num id fn desc <<< "$mod_info"
    MODULE_MAP["$id"]="$fn|$desc|$num"
done

# ─── 汇总文件 ───
SUMMARY_FILE="${OUTPUT_BASE}/summary.txt"
{
    echo "============================================================"
    echo "HwScope - Hardware Scope Collection"
    echo "Hostname : $(hostname)"
    echo "Platform : ${PLATFORM} (GPU: ${GPU_COUNT:-0})"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Output   : ${OUTPUT_BASE}"
    echo "============================================================"
    echo ""
} > "$SUMMARY_FILE"

# ─── 保存执行时的配置快照 ───
cp "$CONF_FILE" "${OUTPUT_BASE}/config_backup.conf" 2>/dev/null || true

# ─── 主循环：执行选定模块 ───
echo ""
echo "========================================"
echo -e "${BLUE}HwScope - 服务器硬件巡检采集${NC}"
echo "平台: ${PLATFORM}  输出: ${OUTPUT_BASE}"
echo "========================================"
echo ""

TOTAL_COUNT=0
FILE_COUNT=0

for mod_info in "${MODULES[@]}"; do
    IFS=':' read -r num id fn desc <<< "$mod_info"

    # 检查是否有 --modules 过滤
    if [ -n "$SELECTED_MODULES" ]; then
        if ! echo ",${SELECTED_MODULES}," | grep -qi ",${id},"; then
            echo -e "${YELLOW}[SKIP] ${id} - 未在 --modules 列表中${NC}"
            continue
        fi
    fi

    # 检查是否在 --skip 列表中
    if [ -n "$SKIP_MODULES" ]; then
        if echo ",${SKIP_MODULES}," | grep -qi ",${id},"; then
            echo -e "${YELLOW}[SKIP] ${id} - 在 --skip 列表中${NC}"
            continue
        fi
    fi

    # 检查配置开关
    if [ "${MODULE_SWITCH[$id]:-1}" -ne 1 ]; then
        echo -e "${YELLOW}[SKIP] ${id} - 配置已禁用${NC}"
        continue
    fi

    # 加载模块脚本
    MODULE_SCRIPT="${SCRIPT_DIR}/modules/${num}_${id}.sh"
    if [ ! -f "$MODULE_SCRIPT" ]; then
        echo -e "${RED}[ERROR] 模块脚本不存在: ${MODULE_SCRIPT}${NC}"
        continue
    fi

    source "$MODULE_SCRIPT"

    # 执行模块的 run_ 函数
    if declare -F "$fn" >/dev/null 2>&1; then
        # 记录开始时间（主循环内不能用 local）
        start_ts=$(date +%s)

        # 创建模块子目录
        mkdir -p "${OUTPUT_BASE}/${id}"

        # 执行模块（捕获文件数）
        "$fn" "$OUTPUT_BASE"

        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))

        # 统计该模块生成了多少个日志文件
        mod_file_count=$(find "${OUTPUT_BASE}/${id}" -type f 2>/dev/null | wc -l)
        FILE_COUNT=$((FILE_COUNT + mod_file_count))

        summary_append "$SUMMARY_FILE" "${num}.${id} (${desc})" "${mod_file_count} files, ${elapsed}s"
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
    else
        echo -e "${RED}[ERROR] 函数 ${fn} 未在 ${MODULE_SCRIPT} 中定义${NC}"
    fi
done

# ─── 生成最终汇总报告 ───
{
    echo ""
    echo "============================================================"
    echo "采集完成汇总"
    echo "============================================================"
    echo "执行模块数 : ${TOTAL_COUNT}"
    echo "总日志文件 : ${FILE_COUNT}"
    echo "输出目录   : ${OUTPUT_BASE}"
    echo "完成时间   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo ""
    echo "输出目录结构:"
    echo "  ${OUTPUT_BASE}/"
    for mod_info in "${MODULES[@]}"; do
        IFS=':' read -r num id fn desc <<< "$mod_info"
        subdir="${OUTPUT_BASE}/${id}"
        if [ -d "$subdir" ]; then
            fcount=$(find "$subdir" -type f 2>/dev/null | wc -l)
            echo "  ├── ${id}/    (${fcount} files)"
        fi
    done
    echo "  └── summary.txt"
    echo ""
} >> "$SUMMARY_FILE"

# ─── 目录结构预览 ───
echo ""
echo "========================================"
echo -e "${GREEN}采集完成！${NC}"
echo "输出目录: ${OUTPUT_BASE}"
echo "总日志数: ${FILE_COUNT}"
echo "========================================"
echo ""
echo "目录结构:"
find "${OUTPUT_BASE}" -type d | sort | while read d; do
    indent=$(echo "$d" | sed "s|${OUTPUT_BASE}||" | tr '/' ' ')
    level=$(echo "$d" | tr -cd '/' | wc -c)
    prefix=""
    for ((i=0; i<level-1; i++)); do
        prefix="${prefix}  "
    done
    [ "$level" -gt 0 ] && echo "${prefix}├── $(basename "$d")/"
done

echo ""
echo -e "${CYAN}汇总文件: ${SUMMARY_FILE}${NC}"
echo ""
echo "提示: 单独跑某个模块: bash modules/04_gpu.sh <output_dir>"
