#!/bin/bash
# =============================================================================
# HwScope 采集工具 - 公共函数库
# lib/common.sh
# 功能：日志Header生成、命令执行并记录、目录创建、WARN计数、静默模式
# =============================================================================

# ─── 颜色输出 ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")

# ─── 版本号（hwscope.sh 会覆盖此值） ───
HWSCOPE_VERSION="${HWSCOPE_VERSION:-unknown}"

# ─── 全局状态 ───
_MODULE_WARN_COUNT=0
QUIET="${QUIET:-0}"

# ─── 日志 Header 写入 ───
write_header() {
    local logfile="$1"
    local cmd="$2"
    {
        echo "# ============================================================"
        echo "# Command  : $cmd"
        echo "# Hostname : $HOSTNAME"
        echo "# Version  : HwScope ${HWSCOPE_VERSION}"
        echo "# Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Encoding : $(locale charmap 2>/dev/null || echo 'UTF-8')"
        echo "# ============================================================"
    } > "$logfile"
}

# ─── 执行命令并写入日志 ───
run_and_log() {
    local cmd="$1"
    local logfile="$2"

    mkdir -p "$(dirname "$logfile")"
    write_header "$logfile" "$cmd"
    echo "# --- output start ---" >> "$logfile"

    local start_ns=$(date +%s%N 2>/dev/null || date +%s)

    # 模拟模式：每条命令随机延迟 0.2-0.5s（计入耗时，SIM_DELAY>0 时生效）
    if [ "${SIM_DELAY:-0}" -gt 0 ] 2>/dev/null; then
        sleep "$(awk 'BEGIN{srand(); printf "%.2f", 0.2 + rand() * 0.3}')"
    fi

    bash -c "$cmd" >> "$logfile" 2>&1
    local ret=$?
    local end_ns=$(date +%s%N 2>/dev/null || date +%s)

    # 耗时（GNU date 纳秒 → 秒保留 2 位；fallback 整数秒）
    local elapsed
    if [ "${#start_ns}" -gt 10 ]; then
        elapsed=$(awk "BEGIN{printf \"%.2f\", ($end_ns-$start_ns)/1000000000}")
    else
        elapsed=$((end_ns - start_ns))
    fi

    echo "# --- output end ---" >> "$logfile"
    echo "# --- exit code: $ret, [ ${elapsed}s ] ---" >> "$logfile"

    # WARN 计数（exit=1 = grep 无匹配，不报警）
    if [ "$ret" -ne 0 ] && [ "$ret" -ne 1 ] && [ "$ret" -ne 127 ]; then
        _MODULE_WARN_COUNT=$((_MODULE_WARN_COUNT + 1))
    fi

    # 终端状态显示（带每条命令耗时：亚秒显示小数 0.20s，≥1s 用 M:SSs）
    local esec=${elapsed%.*}; [ -z "$esec" ] && esec=0
    local fmt_elapsed
    if [ "$esec" -lt 1 ] 2>/dev/null; then
        fmt_elapsed="${elapsed}s"
    else
        fmt_elapsed=$(printf "%d:%02ds" $((esec/60)) $((esec%60)))
    fi
    local fname=$(basename "${logfile%.*}")
    if [ "$QUIET" -eq 1 ]; then
        # 静默模式：只显示 WARN
        if [ "$ret" -ne 0 ] && [ "$ret" -ne 1 ] && [ "$ret" -ne 127 ]; then
            printf "${YELLOW}%-6s${NC} %s (exit=%s)  [ %s ]\n" "[WARN]" "$fname" "$ret" "$fmt_elapsed"
        fi
    else
        if [ "$ret" -eq 0 ]; then
            printf "${GREEN}%-6s${NC} %s  %s  [ %s ]\n" "[OK]" "$fname" "(exit=0)" "$fmt_elapsed"
        elif [ "$ret" -eq 1 ]; then
            printf "%-6s %s  %s  [ %s ]\n" "[~]" "$fname" "(no match)" "$fmt_elapsed"
        elif [ "$ret" -eq 127 ]; then
            printf "${YELLOW}%-6s${NC} %s  %s  [ %s ]\n" "[N/A]" "$fname" "(cmd not found)" "$fmt_elapsed"
        else
            printf "${YELLOW}%-6s${NC} %s  %s  [ %s ]\n" "[WARN]" "$fname" "(exit=$ret)" "$fmt_elapsed"
        fi
    fi
    return $ret
}

# ─── 命令是否存在检查 ───
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ─── WARN 计数器 ───
reset_warn_count() { _MODULE_WARN_COUNT=0; }
get_warn_count()   { echo "$_MODULE_WARN_COUNT"; }

# ─── 模块开始/结束提示 ───
module_start() {
    local name="$1"
    SIM_MOD_START=$(date +%s)   # 模拟模式：记录模块开始
    if [ "$QUIET" -eq 1 ]; then
        echo -e "${CYAN}[${name}]${NC}"
    else
        echo ""
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}[$name] 开始采集...${NC}"
        echo -e "${CYAN}========================================${NC}"
    fi
}

module_end() {
    local name="$1"
    # 模拟模式：模块总时长不足 SIM_DELAY 秒则补足
    if [ "${SIM_DELAY:-0}" -gt 0 ] 2>/dev/null && [ -n "$SIM_MOD_START" ]; then
        _sim_elapsed=$(( $(date +%s) - SIM_MOD_START ))
        if [ "$_sim_elapsed" -lt "$SIM_DELAY" ]; then
            sleep $((SIM_DELAY - _sim_elapsed))
        fi
    fi
    if [ "$QUIET" -eq 1 ]; then
        :  # 静默不输出完成提示
    else
        echo -e "${GREEN}[$name] 采集完成${NC}"
    fi
}

# ─── 写入汇总信息 ───
summary_append() {
    local summary_file="$1"
    local module_name="$2"
    local info="$3"
    {
        echo "[$(date '+%H:%M:%S')] $module_name - $info"
    } >> "$summary_file"
}
