#!/bin/bash
# =============================================================================
# HwScope 采集工具 - 公共函数库
# lib/common.sh
# 功能：日志Header生成、命令执行并记录、目录创建
# =============================================================================

# ─── 颜色输出 ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")

# ─── 日志 Header 写入 ───
# 用法：write_header "输出文件路径" "执行的命令原文"
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
# 用法：run_and_log "命令原文" "输出文件路径"
# 说明：命令原文和执行结果都会写入日志，同时终端显示进度
run_and_log() {
    local cmd="$1"
    local logfile="$2"

    # 确保目录存在
    mkdir -p "$(dirname "$logfile")"

    # 写入 Header
    write_header "$logfile" "$cmd"

    # 追加分隔行
    echo "# --- output start ---" >> "$logfile"

    # 执行命令，结果追加到日志（同时保留 stderr）
    # 使用 bash -c 而非 eval：避免 awk/sed 内的 $1/$2 被 shell 变量展开
    bash -c "$cmd" >> "$logfile" 2>&1
    local ret=$?

    # 追加结束标记
    echo "# --- output end (exit code: $ret) ---" >> "$logfile"

    # 终端显示状态（根据 exit code 颜色区分）
    local fname=$(basename "${logfile%.*}")
    if [ "$ret" -eq 0 ]; then
        echo -e "${GREEN}[OK]${NC} ${fname}  (exit=0)"
    elif [ "$ret" -eq 127 ]; then
        echo -e "${YELLOW}[N/A]${NC} ${fname}  (cmd not found)"
    else
        echo -e "${YELLOW}[WARN]${NC} ${fname}  (exit=$ret)"
    fi
    return $ret
}

# ─── 命令是否存在检查 ───
# 用法：check_cmd "命令名"  → 返回 0/1
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ─── 模块开始/结束提示 ───
module_start() {
    local name="$1"
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}[$name] 开始采集...${NC}"
    echo -e "${CYAN}========================================${NC}"
}

module_end() {
    local name="$1"
    echo -e "${GREEN}[$name] 采集完成${NC}"
}

# ─── 输出目录初始化 ───
# 用法：init_output_dir "/base/path"
# 返回：OUTPUT_DIR 路径
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
    local count="$3"
    {
        echo "[$(date '+%H:%M:%S')] $module_name - $count files"
    } >> "$summary_file"
}
