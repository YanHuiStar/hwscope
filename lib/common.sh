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

    bash -c "$cmd" >> "$logfile" 2>&1
    local ret=$?

    echo "# --- output end (exit code: $ret) ---" >> "$logfile"

    # WARN 计数（exit=1 = grep 无匹配，不报警）
    if [ "$ret" -ne 0 ] && [ "$ret" -ne 1 ] && [ "$ret" -ne 127 ]; then
        _MODULE_WARN_COUNT=$((_MODULE_WARN_COUNT + 1))
    fi

    # 终端状态显示
    local fname=$(basename "${logfile%.*}")
    if [ "$QUIET" -eq 1 ]; then
        # 静默模式：只显示 WARN
        if [ "$ret" -ne 0 ] && [ "$ret" -ne 1 ] && [ "$ret" -ne 127 ]; then
            echo -e "${YELLOW}WARN${NC} ${fname} (exit=$ret)"
        fi
    else
        if [ "$ret" -eq 0 ]; then
            echo -e "${GREEN}[OK]${NC} ${fname}  (exit=0)"
        elif [ "$ret" -eq 1 ]; then
            echo -e "[~] ${fname}  (no match)"
        elif [ "$ret" -eq 127 ]; then
            echo -e "${YELLOW}[N/A]${NC} ${fname}  (cmd not found)"
        else
            echo -e "${YELLOW}[WARN]${NC} ${fname}  (exit=$ret)"
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
    if [ "$QUIET" -eq 1 ]; then
        :  # 静默不输出完成提示
    else
        echo -e "${GREEN}[$name] 采集完成${NC}"
    fi
}

# ─── 输出目录初始化 ───
init_output_dir() {
    local base="$1"
    if [ -z "$base" ]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        base="./output/${timestamp}"
    fi
    mkdir -p "$base"
    echo "$base"
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
