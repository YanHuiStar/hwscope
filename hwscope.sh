#!/bin/bash
# =============================================================================
# HwScope — Hardware Scope: Server Hardware Inspection & Data Collection System
#
# Author  : YanHui / Hermes Agent
# Version : 1.26.43 (2026-08)
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
    for _try in LC_ALL=C.UTF-8 LC_ALL=C.utf8 LC_ALL=en_US.UTF-8 LANG=C.UTF-8 LANG=C.utf8 LANG=en_US.UTF-8; do
        if export "$_try" 2>/dev/null && [ "$(locale charmap 2>/dev/null)" = "UTF-8" ]; then
            break
        fi
    done
    # 最终兜底：仍非 UTF-8 则强制 LC_ALL=C.UTF-8（即使 locale -a 没列出，部分系统仍可用）
    if [ "$(locale charmap 2>/dev/null)" != "UTF-8" ]; then
        export LC_ALL=C.UTF-8 2>/dev/null
        if [ "$(locale charmap 2>/dev/null)" != "UTF-8" ]; then
            echo "[WARN] 无可用 UTF-8 locale，中文日志可能乱码。安装: sudo locale-gen C.UTF-8" >&2
        fi
    fi
    unset _try
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── 加载公共库 ───
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/platform.sh"

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
HWSCOPE_VERSION="v1.26.43"

# ─── 命令行参数 ───
SELECTED_MODULES=""; SKIP_MODULES=""; OUTPUT_BASE="${OUTPUT_BASE_DIR:-}"
FORCE_MODE="${FORCE:-0}"; QUIET=0; PARALLEL=1; NO_MODULE=0; MODULE_PARALLEL=1

usage() {
    echo "用法: $0 [OPTIONS]"
    echo "版本: ${HWSCOPE_VERSION} (2026-08)"
    echo ""
    echo "选项:"
    echo "  --modules gpu,storage           只采指定模块（逗号分隔）"
    echo "  --skip dcgm,nvsm                跳过指定模块"
    echo "  --parallel                      并行执行所有模块（默认开启）"
    echo "  --serial                        串行执行（实时输出每模块结果）"
    echo "  --no-parallel                   禁用模块内命令并行（降级为逐条执行）"
    echo "  --sim [N]                       模拟模式：每模块等待 N 秒（默认 5）"
    echo "  --no-module                     跳过光模块查询（缩短采集时长约 48s）"
    echo "  --output /path/to/dir           指定输出目录"
    echo "  --force                         覆盖已有输出目录"
    echo "  -q, --quiet                     静默模式（仅输出异常）"
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
    echo "  sudo bash $0                              # 全部采集（默认并行）"
    echo "  sudo bash $0 --serial                     # 串行采集（实时输出）"
    echo "  sudo bash $0 --quiet                      # 并行静默采集"
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
        --serial)   PARALLEL=0; shift ;;
        --no-parallel) MODULE_PARALLEL=0; shift ;;
        --sim)
            # 模拟模式：每模块等待 N 秒（--sim 或 --sim N，N 默认 5）
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then SIM_DELAY="$2"; shift 2; else SIM_DELAY=5; shift; fi ;;
        --no-module) NO_MODULE=1; shift ;;
        -q|--quiet) QUIET=1; shift ;;
        -h|--help)  usage ;;
        -v|--version) echo "HwScope ${HWSCOPE_VERSION} (2026-08) — Hardware Scope"
                      echo "Author: YanHui / Hermes Agent · License: Apache 2.0"
                      echo "https://github.com/YanHuiStar/hwscope"
                      exit 0 ;;
        *) echo -e "${RED}错误: 未知参数 $1${NC}"; usage ;;
    esac
done

# ─── 校验 --modules/--skip 模块名是否有效 ───
validate_module_names() {
    local list="$1" flag="$2"
    local -a valid_ids
    for mod_info in "${MODULES[@]}"; do
        IFS=':' read -r _n _id _f _d <<< "$mod_info"
        valid_ids+=("$_id")
    done
    local unknown=""
    IFS=',' read -ra names <<< "$list"
    for n in "${names[@]}"; do
        n=$(echo "$n" | tr -d ' ')
        [ -z "$n" ] && continue
        local found=0
        for vid in "${valid_ids[@]}"; do
            [ "$n" = "$vid" ] && found=1 && break
        done
        [ "$found" -eq 0 ] && unknown="${unknown} ${n}"
    done
    if [ -n "$unknown" ]; then
        echo -e "${RED}[ERROR] ${flag} 存在未知模块:${unknown}${NC}"
        echo "  可用: ${valid_ids[*]}"
        exit 1
    fi
}
[ -n "$SELECTED_MODULES" ] && validate_module_names "$SELECTED_MODULES" "--modules"
[ -n "$SKIP_MODULES" ] && validate_module_names "$SKIP_MODULES" "--skip"

# ─── 机器标识 ───
MACHINE_ID=$(detect_machine_id)

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

# ─── 平台检测 ───
detect_platform

# ─── IPMI 预热 ───
ipmi_preheat

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
echo -e "${BLUE}HwScope - 服务器硬件巡检采集${NC}  ${HWSCOPE_VERSION}"
echo "平台: ${PLATFORM} (GPU: ${GPU_COUNT:-0})"
echo "输出: ${OUTPUT_BASE}"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

TOTAL_COUNT=0; FILE_COUNT=0
START_TS=$(date +%s); MOD_TIMES=""
export SIM_DELAY   # 模拟模式秒数（conf 读取，--sim 覆盖），子 shell 继承

if [ "$PARALLEL" -eq 1 ]; then
    # ═══════════════ 并行模式 ═══════════════
    echo -e "${CYAN}[QUEUE]${NC} 并行启动所有模块..."

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
            # 导出 OUTPUT_DIR 供 module_end 落盘 WARN 计数（跨进程读取）
            export OUTPUT_DIR="${OUTPUT_BASE}/${id}"
            (
                start_ts=$(date +%s)
                reset_warn_count
                # 模块级超时保护：默认 300s/模块，防止命令卡死导致主脚本永久等待。
                # 原实现同进程调用（WARN 计数正确）；此处模块脚本独立执行（自 source common.sh），
                # 计数经 module_end 写入 ${id}/.warn_count 文件，主脚本读文件。
                timeout "${MODULE_TIMEOUT:-300}" bash "${MODULE_SCRIPT}" "$OUTPUT_BASE" 2>&1
                mod_rc=$?
                echo "$(( $(date +%s) - start_ts ))" > "${OUTPUT_BASE}/.${id}_time"
                warn=$(cat "${OUTPUT_BASE}/${id}/.warn_count" 2>/dev/null || echo 0)
                # 超时(124)/信号中断(128+)时 module_end 不执行、WARN 不落盘 → 补记，避免超时模块误显示 0 WARN/OK
                if [ "$mod_rc" -eq 124 ] 2>/dev/null || [ "$mod_rc" -gt 128 ] 2>/dev/null; then
                    warn=$((warn + 1))
                    echo "[WARN] 模块超时/中断（exit=${mod_rc}，时限 ${MODULE_TIMEOUT:-300}s）——采集可能不完整，请检查对应模块日志" >> "${OUTPUT_BASE}/.${id}_log" 2>/dev/null
                fi
                echo "$warn" > "${OUTPUT_BASE}/.${id}_warn"
                rm -f "${OUTPUT_BASE}/${id}/.warn_count"   # 不计入模块文件数
                find "${OUTPUT_BASE}/${id}" -type f 2>/dev/null | wc -l > "${OUTPUT_BASE}/.${id}_files"
                touch "${OUTPUT_BASE}/.${id}_done"
            ) > "${OUTPUT_BASE}/.${id}_log" 2>&1 &
            PIDS+=($!); MODULE_INFO+=("${num}|${id}|${desc}")
        fi
    done

    # ─── 等待循环：动画 + 模块完成即输出该模块完整日志 ───
    total=${#MODULE_INFO[@]}
    declared=0; chars='/-\|'; i=0
    while [ "$declared" -lt "$total" ]; do
        # 动画行（仅 TTY）
        [ -t 1 ] && printf "\r\033[36m%c\033[0m 正在并行采集... %s/%s 模块完成" "${chars:$((i%4)):1}" "$declared" "$total"
        # 新完成模块 → 立即输出该模块日志
        for info in "${MODULE_INFO[@]}"; do
            IFS='|' read -r num id desc <<< "$info"
            [ -f "${OUTPUT_BASE}/.${id}_done" ] || continue
            [ -f "${OUTPUT_BASE}/.${id}_printed" ] && continue
            [ -t 1 ] && printf "\r\033[K"
            if [ "$QUIET" -eq 1 ]; then
                # 静默：模块完成输出摘要行（耗时 + 状态）+ 异常细节
                mtime=$(cat "${OUTPUT_BASE}/.${id}_time" 2>/dev/null || echo 0)
                warn=$(cat "${OUTPUT_BASE}/.${id}_warn" 2>/dev/null || echo 0)
                fmt=$(printf "%d:%02ds" $((mtime/60)) $((mtime%60)))
                st="OK"; [ "$warn" -gt 0 ] && st="WARN"
                echo -e "${CYAN}[${id}]${NC} ${st} [ ${fmt} ]"
                grep -E "\[WARN\]|SKIP" "${OUTPUT_BASE}/.${id}_log" 2>/dev/null
            else
                cat "${OUTPUT_BASE}/.${id}_log" 2>/dev/null
            fi
            touch "${OUTPUT_BASE}/.${id}_printed"
            declared=$((declared+1))
        done
        [ "$declared" -ge "$total" ] && break
        i=$((i+1)); sleep 0.2
    done
    [ -t 1 ] && printf "\r\033[K"

    # 汇总（summary.txt 按注册表顺序）
    for info in "${MODULE_INFO[@]}"; do
        IFS='|' read -r num id desc <<< "$info"
        warn=$(cat "${OUTPUT_BASE}/.${id}_warn" 2>/dev/null || echo 0)
        files=$(cat "${OUTPUT_BASE}/.${id}_files" 2>/dev/null || echo 0)
        mtime=$(cat "${OUTPUT_BASE}/.${id}_time" 2>/dev/null || echo 0)
        FILE_COUNT=$((FILE_COUNT + files))
        summary_append "$SUMMARY_FILE" "${num}.${id} (${desc})" "${files} files, ${mtime}s, ${warn} WARN"
        MOD_TIMES="${MOD_TIMES}${num}.${id}|${mtime}"$'\n'
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        rm -f "${OUTPUT_BASE}/.${id}_log" "${OUTPUT_BASE}/.${id}_warn" "${OUTPUT_BASE}/.${id}_files" "${OUTPUT_BASE}/.${id}_time" "${OUTPUT_BASE}/.${id}_done" "${OUTPUT_BASE}/.${id}_printed"
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
            export OUTPUT_DIR="${OUTPUT_BASE}/${id}"
            timeout "${MODULE_TIMEOUT:-300}" bash "${MODULE_SCRIPT}" "$OUTPUT_BASE" 2>&1
            mod_rc=$?
            warn_count=$(cat "${OUTPUT_BASE}/${id}/.warn_count" 2>/dev/null || echo 0)
            # 超时/信号中断补记（并行分支同逻辑）
            if [ "$mod_rc" -eq 124 ] 2>/dev/null || [ "$mod_rc" -gt 128 ] 2>/dev/null; then
                warn_count=$((warn_count + 1))
                echo -e "${YELLOW}[WARN] 模块超时/中断（exit=${mod_rc}，时限 ${MODULE_TIMEOUT:-300}s）——采集可能不完整${NC}"
            fi
            rm -f "${OUTPUT_BASE}/${id}/.warn_count"
            end_ts=$(date +%s); elapsed=$((end_ts - start_ts))
            mod_file_count=$(find "${OUTPUT_BASE}/${id}" -type f 2>/dev/null | wc -l)
            FILE_COUNT=$((FILE_COUNT + mod_file_count))
            summary_append "$SUMMARY_FILE" "${num}.${id} (${desc})" "${mod_file_count} files, ${elapsed}s, ${warn_count} WARN"
            MOD_TIMES="${MOD_TIMES}${num}.${id}|${elapsed}"$'\n'
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

# ─── 耗时统计（总时长 + 模块 Top5，写入 summary.txt） ───
TOTAL_ELAPSED=$(( $(date +%s) - START_TS ))
{
    echo ""
    echo "============================================================"
    echo "耗时统计"
    echo "============================================================"
    echo "总时长      : ${TOTAL_ELAPSED}s"
    echo "模块耗时 Top5:"
    echo "$MOD_TIMES" | grep -v "^$" | sort -t'|' -k2 -rn | head -5 | while IFS='|' read -r mt_name mt_sec; do
        pct="0%"
        [ "$TOTAL_ELAPSED" -gt 0 ] && pct=$(awk "BEGIN{printf \"%d%%\", $mt_sec*100/$TOTAL_ELAPSED}")
        printf "  %-16s %4ss  (%s)\n" "$mt_name" "$mt_sec" "$pct"
    done
    echo "============================================================"
} >> "$SUMMARY_FILE"

echo ""
echo "========================================"
echo -e "${GREEN}采集完成！${NC}"; echo "输出目录: ${OUTPUT_BASE}"; echo "总日志数: ${FILE_COUNT}"; echo -e "${CYAN}总耗时: ${TOTAL_ELAPSED}s${NC}"
echo "========================================"
echo ""
find "${OUTPUT_BASE}" -type d | sort | while read d; do
    indent=$(echo "$d" | sed "s|${OUTPUT_BASE}||" | tr '/' ' ')
    level=$(echo "$d" | tr -cd '/' | wc -c); prefix=""
    for ((i=0; i<level-1; i++)); do prefix="${prefix}  "; done
    [ "$level" -gt 0 ] && echo "${prefix}├── $(basename "$d")/"
done
echo ""
echo -e "${CYAN}日志文件: ${LOG_FILE}${NC}"
echo -e "${CYAN}汇总文件: ${SUMMARY_FILE}${NC}"

# ─── 生成汇总报告（json + md + txt） ───
if [ -f "${SCRIPT_DIR}/tools/report.sh" ]; then
    echo ""
    bash "${SCRIPT_DIR}/tools/report.sh" "$OUTPUT_BASE"
    # 验收清单默认一并生成（交付交接单；仅 --modules 部分采集时仍生成，缺数据项显示 N/A）
    bash "${SCRIPT_DIR}/tools/report.sh" "$OUTPUT_BASE" --acceptance
fi

# ─── 打包归档（与 REPORT 阶段分隔，独立排版） ───
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}[ARCHIVE] 开始打包归档...${NC}"
echo -e "${CYAN}========================================${NC}"
LOGS_DIR="${SCRIPT_DIR}/logs"
ARCHIVE_TS=$(date '+%Y%m%d_%H%M%S')
ARCHIVE_NAME="${MACHINE_ID}-${ARCHIVE_TS}.tar.gz"
mkdir -p "$LOGS_DIR"
if check_cmd tar; then
    tar czf "${LOGS_DIR}/${ARCHIVE_NAME}" -C "$(dirname "$OUTPUT_BASE")" "$(basename "$OUTPUT_BASE")" 2>/dev/null
    echo -e "${GREEN}[ARCHIVE]${NC} 日志包: ${LOGS_DIR}/${ARCHIVE_NAME}"
fi

# 报告单独打包到 logs/report/（与详细日志包对应）
if check_cmd tar; then
    REPORT_DIR="${LOGS_DIR}/report"
    mkdir -p "$REPORT_DIR"
    if ls "${OUTPUT_BASE}"/hwscope_report.* >/dev/null 2>&1; then
        REPORT_ARCHIVE="${REPORT_DIR}/${MACHINE_ID}-${ARCHIVE_TS}-report.tar.gz"
        tar czf "$REPORT_ARCHIVE" -C "$OUTPUT_BASE" \
            hwscope_report.json hwscope_report.md hwscope_report.txt \
            hwscope_acceptance.md 2>/dev/null || \
        tar czf "$REPORT_ARCHIVE" -C "$OUTPUT_BASE" \
            hwscope_report.json hwscope_report.md hwscope_report.txt
        echo -e "${GREEN}[ARCHIVE]${NC} 报告包: ${REPORT_ARCHIVE}"
    fi
fi
echo -e "${GREEN}[ARCHIVE] 归档完成${NC}"
echo ""

# ─── 清理 ANSI（放最后：sed -i 替换 inode 会令 tee 后续写入丢失，故须在所有输出之后） ───
if [ -f "$LOG_FILE" ] && check_cmd sed; then
    sed -i 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" 2>/dev/null || true
fi
exit 0
