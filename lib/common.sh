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

# ─── 脚本帮助（统一 -h/--help：打印脚本头部注释块） ───
# 提取 $0 的注释头（跳过 shebang 与 ==== 装饰线），作为帮助文本；调用后 exit 0
show_script_help() {
    awk '
        /^#!/ { next }
        /^# ====+$/ { if (seen) exit; next }
        /^#/ { seen=1; sub(/^# ?/, ""); print; next }
        { exit }
    ' "$0"
    echo ""
    exit 0
}
# 统一帮助入口：脚本 source common.sh 后调用 `parse_help "$@"` 即可获得 -h/--help 支持
parse_help() {
    case "${1:-}" in
        -h|--help|-help) show_script_help ;;
    esac
}

# WSL 下 sudo 会重置 PATH（secure_path 不含 /usr/lib/wsl/lib），导致 nvidia-smi 检测失败
# 兜底：nvidia-smi 不在 PATH 但存在于 WSL 路径时显式加入（真机 Linux 无此路径，条件不满足，无副作用）
if ! command -v nvidia-smi >/dev/null 2>&1 && [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    PATH="/usr/lib/wsl/lib:${PATH}"
    export PATH
fi

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

run_and_log_parallel() {
    local max_jobs=$1; shift
    local _rlp_has_error=0

    # 串行模式：降级为逐条执行（模块或全局禁用并行时）
    if [ "${MODULE_PARALLEL:-1}" -ne 1 ]; then
        while [ $# -ge 2 ]; do
            run_and_log "$1" "$2"
            local ret=$?
            [ "$ret" -ne 0 ] && [ "$ret" -ne 1 ] && [ "$ret" -ne 127 ] && _rlp_has_error=1
            shift 2
        done
        return $_rlp_has_error
    fi

    local _rlp_pids=()
    local _rlp_tmpdir=$(mktemp -d "${OUTPUT_BASE:-/tmp}/.rlp_XXXXXX" 2>/dev/null || mktemp -d /tmp/.rlp_XXXXXX)
    local _rlp_idx=0

    while [ $# -ge 2 ]; do
        local cmd="$1" logfile="$2"; shift 2
        mkdir -p "$(dirname "$logfile")"
        local this_idx=$_rlp_idx

        (
            run_and_log "$cmd" "$logfile"
            echo $? > "${_rlp_tmpdir}/w_${this_idx}"
        ) &
        _rlp_pids+=($!)
        _rlp_idx=$((_rlp_idx + 1))

        # 限流：等待槽位释放
        local _rlp_running=0
        for p in "${_rlp_pids[@]}"; do kill -0 "$p" 2>/dev/null && _rlp_running=$((_rlp_running + 1)); done
        while [ "$_rlp_running" -ge "$max_jobs" ]; do
            wait -n 2>/dev/null || sleep 0.1
            _rlp_running=0
            for p in "${_rlp_pids[@]}"; do kill -0 "$p" 2>/dev/null && _rlp_running=$((_rlp_running + 1)); done
        done
    done

    for p in "${_rlp_pids[@]}"; do wait "$p" 2>/dev/null; done

    # 汇总 WARN 计数（从临时文件收集，避免并发写 _MODULE_WARN_COUNT）
    local _rlp_i=0
    while [ "$_rlp_i" -lt "$_rlp_idx" ]; do
        local _rlp_ret=$(cat "${_rlp_tmpdir}/w_${_rlp_i}" 2>/dev/null || echo 0)
        if [ "$_rlp_ret" -ne 0 ] && [ "$_rlp_ret" -ne 1 ] && [ "$_rlp_ret" -ne 127 ]; then
            _MODULE_WARN_COUNT=$((_MODULE_WARN_COUNT + 1))
            _rlp_has_error=1
        fi
        _rlp_i=$((_rlp_i + 1))
    done

    rm -rf "$_rlp_tmpdir"
    return $_rlp_has_error
}

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
    # WARN 计数落盘（供主脚本跨进程读取；模块独立跑/并行子进程均可靠）
    if [ -n "${OUTPUT_DIR:-}" ]; then
        echo "$_MODULE_WARN_COUNT" > "${OUTPUT_DIR}/.warn_count" 2>/dev/null
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

# ─── 模块输出清单（manifest）───
# 格式：bash key=value（可直接 source）
# 用法：write_manifest "${dir}/manifest.txt" "gpu_full" "gpu_full.log" "gpu_inventory" "gpu_inventory.csv" ...
#       write_manifest --append "${dir}/manifest.txt" "extra_key" "extra.log"   # 追加条目（不清空已有内容）
write_manifest() {
    local append=0
    if [ "$1" = "--append" ]; then append=1; shift; fi
    local manifest_file="$1"; shift
    if [ "$append" -eq 1 ]; then
        while [ $# -ge 2 ]; do
            echo "${1}=${2}"
            shift 2
        done >> "$manifest_file"
    else
        {
            echo "# HwScope module output manifest"
            echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            while [ $# -ge 2 ]; do
                echo "${1}=${2}"
                shift 2
            done
        } > "$manifest_file"
    fi
}
