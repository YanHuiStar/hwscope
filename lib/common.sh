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

# ─── IPMI/BMC 命令超时（秒） ───
# v1.48.91：由硬编码 10s 提为 30s，并开放环境变量覆盖。
# 起因：技嘉 B200 五台机上各有 10~13 个 IPMI 命令在 10s 内全部超时（exit=124）——
#   ipmi_sensors / sdr / fan_* / psu_* / sensors_temp 全线拿不到，导致风扇、温度、
#   PSU 冗余三项落成「采集失败」N/A，其中一台因此跨过「≥4 项无数据」阈值被
#   判成「数据不足」而无法验收。现场 BMC 响应慢是常见情形，10s 对这类平台不够。
# 代价可控：timeout 只对**卡住的命令**生效——正常命令 1s 内返回就不会等满 30s，
#   所以调大默认值对健康 BMC 的采集耗时几乎无影响，只让慢 BMC 有机会把数据取回来。
# 覆盖方式：HWSCOPE_IPMI_TIMEOUT=90 ./hwscope.sh（调试个别极慢平台时用）
# v1.49.8：默认 30 → 60 秒。实测 DGX A100 的 BMC 很慢——ipmi_fru 22s、ipmi_fru_summary 36s，
#   ipmi_sdr / ipmi_sensors / ipmi_sensors_fan / ipmi_sensors_volt / ipmi_sel_elist
#   在 30s 全部超时（exit 124、0 行）→ 风扇、电压、SDR 类数据整批丢失；
#   ipmi_sensors_power 刚好 17.61s 赶上才保住。30s 对这类平台不够。
#   代价：极慢平台单命令最坏等待翻倍；可用环境变量按需调回。
IPMI_TIMEOUT="${HWSCOPE_IPMI_TIMEOUT:-90}"
export IPMI_TIMEOUT

# ─── 分级 IPMI 超时（v1.49.9）───
# 一刀切超时的根本问题是：不同 IPMI 命令的代价差一个数量级，取一个值必然两头不讨好。
#   实测同一台慢 BMC 上：chassis/guid/power 类 < 1s，fru print 22s，
#   **sdr list / sensor list 200~230s**（逐条读 SDR 仓库，条目越多越慢）。
#   取 30s → 慢命令全被砍（实测 DGX A100 6 条超时整齐卡在 30.01s、0 行）；
#   取 240s → 快命令卡住时白等 4 分钟。
# 故分三级，按命令实际代价给余量：
#   IPMI_TIMEOUT_FAST —— chassis status / chassis power / lan print / bmc guid / user list / mc info
#   IPMI_TIMEOUT      —— sel list / sel elist / fru print
#   IPMI_TIMEOUT_SLOW —— sdr list / sensor list（逐条读 SDR，慢机可达 230s+）
# 另注：并发不解决慢的问题——IPMI 走 KCS 单通道，多个 ipmitool 并发只在 BMC 侧排队，
#   反而互相拖慢；采集端并发已由 4 降到 2，且 sensor list 由 5 次调用减为 1 次（其余派生）。
IPMI_TIMEOUT_FAST="${HWSCOPE_IPMI_TIMEOUT_FAST:-30}"
IPMI_TIMEOUT_SLOW="${HWSCOPE_IPMI_TIMEOUT_SLOW:-240}"
export IPMI_TIMEOUT_FAST IPMI_TIMEOUT_SLOW

# ─── IPMI 快照缓存（v1.49.9）───
# 问题：BMC 上最贵的两条命令 sdr list / sensor list 会**逐条读 SDR 仓库**，慢机单次 200~230s
#   （实测 A100-sample-b 无超时版 sdr list 跑 200.49s）。而全项目对它们的调用点极多：
#   12_bmc(2) + 10_psu(4) + 11_fan(2) + 16_power(2) —— 合计 7 次 sensor list + 3 次 sdr list。
#   慢机上等于把同一个 BMC 反复拷打 1000+ 秒，并把超时概率放到最大。
#   并发也救不了：IPMI 走 KCS 单通道，多个 ipmitool 只在 BMC 侧排队，反而互相拖慢。
# 方案：进程内**惰性缓存**——第一次调用真跑并把结果存到 $OUTPUT_BASE/<mod>/ 下的固定文件，
#   之后的调用直接返回缓存路径（本地 grep，秒级）。不改模块执行顺序，各模块按需调用。
# 用法：ipmi_snapshot sensors   → 回显 ipmi_sensors.log 的路径（不存在或已过期则采集）
#       ipmi_snapshot sdr       → 回显 ipmi_sdr.log 的路径
#       ipmi_snapshot_derive <源文件> <目标文件> <grep 模式>   → 从快照派生一个子集（含 HwScope 头）
#       ipmi_snapshot_cleanup   → 采集结束时清理快照（避免被打进 logs/ 归档）
# 生命周期与隔离：
#   ① 默认落在 $OUTPUT_BASE/.ipmi_snapshot/ —— 而 hwscope.sh 每次采集都会先归档再 rm -rf 该目录，
#      故跨采集天然隔离，不会拿到上次的数据。
#   ② 单独跑某个模块（--modules psu 等）时，惰性缓存让**该模块自己采**，无需别的模块先跑。
#   ③ 过期兜底：手工在固定目录里反复跑模块（不走 hwscope.sh）时，目录不会被清，
#      若不加时效会用上次采的快照。故按 mtime 判过期（默认 3600s，HWSCOPE_IPMI_SNAPSHOT_TTL 可调）。
_ipmi_snapshot_dir() {
    printf '%s' "${IPMI_SNAPSHOT_DIR:-${OUTPUT_BASE:-${OUT:-/tmp}}/.ipmi_snapshot}"
}

# 判断快照是否已过期（$1=快照文件路径）→ 0=过期/不可用，1=仍有效
_ipmi_snapshot_stale() {
    local f="$1" ttl="${HWSCOPE_IPMI_SNAPSHOT_TTL:-3600}"
    [ -s "$f" ] || return 0
    local now mt age
    now=$(date +%s 2>/dev/null || echo 0)
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    [ "$mt" -gt 0 ] 2>/dev/null || return 1        # 取不到 mtime 就不判过期（宁可复用也别丢数据）
    age=$(( now - mt ))
    [ "$age" -gt "$ttl" ] 2>/dev/null && return 0
    return 1
}

# 采集结束清理快照（hwscope.sh 收尾调用；避免被打进 logs/ 归档、也防跨次误用）
ipmi_snapshot_cleanup() {
    local sdir; sdir="$(_ipmi_snapshot_dir)"
    [ -d "$sdir" ] && rm -rf "$sdir" 2>/dev/null
    return 0
}

ipmi_snapshot() {   # $1=sensors|sdr —— 回显该快照的文件路径
    local kind="$1"
    local sdir; sdir="$(_ipmi_snapshot_dir)"
    local cache=""
    case "$kind" in
        sensors) cache="${sdir}/ipmi_sensors.log" ;;
        sdr)     cache="${sdir}/ipmi_sdr.log" ;;
        *) return 1 ;;
    esac
    mkdir -p "$sdir" 2>/dev/null
    if ! _ipmi_snapshot_stale "$cache"; then
        printf '%s' "$cache"; return 0
    fi
    # ─── v1.49.20：加锁 + 原子发布（原实现两个缺陷，都在默认并行模式下必现）───
    # ① 无锁：默认并行模式 10_psu / 11_fan / 12_bmc / 16_power **同时启动**，各自发现无缓存 →
    #    各自跑一遍 240s 的 sensor list。IPMI 走 KCS 单通道，并发只在 BMC 侧排队互相拖慢
    #    （common.sh 顶部已记该教训）——"共享快照" 的优化在慢机上直接归零。
    # ② 非原子写：原实现 `{ ...; } > "$cache"` 从第一毫秒起文件就非空，而 `_ipmi_snapshot_stale`
    #    只判 `-s` + mtime → 并发的 12_bmc 可能复制到一个**只有 header 的进行中文件**，
    #    于是 bmc/ipmi_sensors.log 变成"0 数据行"，且不计 WARN、无 exit code 行
    #    （正是 v1.48.88/v1.48.98「0 条 ≠ 没有」要防的形态）。
    # 用 mkdir 做锁（原子、比 flock 可移植）；写完先落 .tmp.$$ 再 mv 发布。
    local lock="${sdir}/.${kind}.lock"
    if ! mkdir "$lock" 2>/dev/null; then
        # 别人在采：轮询等它写好（最多 SLOW+60s）；持锁者被 SIGKILL 时按 ts 抢占
        local waited=0 got=0
        local max_wait=$(( ${IPMI_TIMEOUT_SLOW:-240} + 60 ))
        local now=0 lt=0 age=0
        while [ "$waited" -lt "$max_wait" ]; do
            sleep 2; waited=$((waited + 2))
            if ! _ipmi_snapshot_stale "$cache"; then
                printf '%s' "$cache"; return 0
            fi
            if [ ! -d "$lock" ]; then
                mkdir "$lock" 2>/dev/null && { got=1; break; }
                continue
            fi
            now=$(date +%s 2>/dev/null || echo 0)
            lt=$(cat "${lock}/ts" 2>/dev/null || echo 0)
            age=$(( now - lt ))
            if [ "${now:-0}" -gt 0 ] && [ "${lt:-0}" -gt 0 ] && [ "$age" -gt "$max_wait" ]; then
                rm -rf "$lock" 2>/dev/null
                mkdir "$lock" 2>/dev/null && { got=1; break; }
            fi
        done
        # 等不到就返回失败——不阻塞整轮采集，缺失的数据由调用方按"未取到"如实标注
        [ "$got" -eq 1 ] || return 1
    fi
    date +%s > "${lock}/ts" 2>/dev/null || true
    # 拿到锁后复查：等锁期间可能已被别的进程采好
    if ! _ipmi_snapshot_stale "$cache"; then
        rm -rf "$lock" 2>/dev/null; printf '%s' "$cache"; return 0
    fi
    if ! check_cmd ipmitool; then rm -rf "$lock" 2>/dev/null; return 1; fi
    local to=""; check_cmd timeout && to="timeout ${IPMI_TIMEOUT_SLOW:-240}"
    local cmd="ipmitool sensor list 2>&1"
    [ "$kind" = "sdr" ] && cmd="ipmitool sdr list 2>&1"
    local tmp="${cache}.tmp.$$"
    # v1.51.2：把「本次真的跑了 ipmitool」打到 stderr（stdout 是本函数的返回通道，
    #   绝不能污染）。让采集输出里能看出快照何时被建、由哪个模块建。
    echo -e "\\033[0;32m[SNAP]\\033[0m ipmi_${kind} 实采（共享快照，其余模块复用）" >&2
    {
        printf '# ============================================================\n'
        printf '# Command  : %s %s\n' "${to:-}" "$cmd"
        printf '# Hostname : %s\n' "$(hostname 2>/dev/null || echo unknown)"
        printf '# Version  : HwScope %s\n' "${HWSCOPE_VERSION:-unknown}"
        printf '# Timestamp: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# Encoding : UTF-8\n'
        printf '# ============================================================\n'
        printf '# --- shared snapshot (ipmi_snapshot, v1.49.9) ---\n'
        printf '# --- output start ---\n'
        if [ -n "$to" ]; then $to bash -c "$cmd" 2>&1; else bash -c "$cmd" 2>&1; fi
        printf '# --- output end ---\n'
    } > "$tmp" 2>/dev/null
    # 只有写完整（含结束标记）才发布；半成品直接丢弃
    if [ -s "$tmp" ] && grep -q '^# --- output end ---' "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cache" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    rm -rf "$lock" 2>/dev/null
    [ -s "$cache" ] && printf '%s' "$cache" || return 1
}

# ─── 采集端「未取到数据」的说明性占位（v1.49.20）───
# 背景：快照派生失败时原来写 `: > file`（0 字节）。0 字节与「该平台本来就没有这类传感器」
#   在报告端**无法区分**，正是 AGENTS v1.48.88「采集失败必须与平台固有形态区分」要防的形态。
#   写一行注释说明原因；报告端一律 `grep -v '^#'` 取数据行，故注释不会被当成数据。
snapshot_na() {   # $1=原因文本  $2=目标文件
    printf '# --- N/A: %s ---\n' "$1" > "$2"
}

ipmi_snapshot_derive() {   # $1=源快照 $2=目标文件 $3=grep 模式（-iE）
    local src="$1" dst="$2" pat="$3"
    [ -f "$src" ] || return 1
    mkdir -p "$(dirname "$dst")"
    {
        # v1.49.20：只拷贝头部 8 行（第 9 行是快照自己的 `# --- output start ---`）——
        #   原来连它一起拷，再打印一次自己的 start marker，派生日志里出现**两个** start
        #   （实测所有 ipmi_*_* 派生文件都有），也让人误以为中间有截断。
        sed -n '1,8p' "$src" 2>/dev/null | grep '^#'
        printf '# --- output start ---\n'
        grep -v '^#' "$src" 2>/dev/null | grep -iE --line-buffered "$pat"
        printf '# --- output end ---\n'
    } > "$dst" 2>/dev/null || return 1
    # v1.51.2：每个派生件打一行，便于在采集输出里核对"这次到底落了哪些文件"
    echo -e "\\033[0;32m[SNAP]\\033[0m $(basename "$dst") 派生（共享快照子集）" >&2
    return 0
}


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

    local start_ns
    start_ns=$(date +%s%N 2>/dev/null || date +%s)

    # 模拟模式：每条命令随机延迟 0.2-0.5s（计入耗时，SIM_DELAY>0 时生效）
    # 用 bash 内置 $RANDOM 生成（0.20-0.50s），零外部依赖——原 awk 方案在精简容器缺 awk 时
    # sleep 拿到空值直接报错，v1.35.1 改为纯 bash
    if [ "${SIM_DELAY:-0}" -gt 0 ] 2>/dev/null; then
        sleep "0.$((20 + RANDOM % 31))"
    fi

    bash -c "$cmd" >> "$logfile" 2>&1
    local ret=$?
    local end_ns
    end_ns=$(date +%s%N 2>/dev/null || date +%s)

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
    local fname
    fname=$(basename "${logfile%.*}")
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

# ─── 灵活命令检测（v1.48.16）：PATH → 候选目录全路径试跑 → ~/.bashrc 环境重试 ───
# 背景：CUDA（/usr/local/cuda）、ROCm（/opt/rocm）等工具装非标准目录 + 环境变量写 ~/.bashrc
# （登录 shell 才生效）——脚本/非交互执行找不到。三阶降级：
#   ① $PATH 直接命中 → CMD_FLEX_PATH=全路径
#   ② 候选目录探测 + 试跑（--version 类，RPATH 好的工具免 bashrc）→ CMD_FLEX_PATH=候选全路径
#   ③ ①②失败 → source ~/.bashrc（静默，最后手段——OFED 冲突等 bashrc 环境变量场景）→ 再找
# 输出全局 CMD_FLEX_PATH（空 = 未找到）；调用方用 ${CMD_FLEX_PATH:-<cmd>} 执行
check_cmd_flex() {
    local _cmd="$1"; shift
    CMD_FLEX_PATH=""
    # ① PATH
    if command -v "$_cmd" >/dev/null 2>&1; then
        CMD_FLEX_PATH=$(command -v "$_cmd")
        return 0
    fi
    # ② 候选目录全路径 + 试跑（--version 无害；不支持则走③）
    local _cand
    for _cand in "$@"; do
        if [ -x "${_cand}/${_cmd}" ]; then
            CMD_FLEX_PATH="${_cand}/${_cmd}"
            if "${_cand}/${_cmd}" --version >/dev/null 2>&1; then
                return 0
            fi
        fi
    done
    # ③ bashrc 环境重试（仅当候选目录找到过——确认工具真实存在才 source，避免白 source）
    if [ -n "$CMD_FLEX_PATH" ] && [ -n "$HOME" ] && [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc" >/dev/null 2>&1 || true
        if command -v "$_cmd" >/dev/null 2>&1; then
            CMD_FLEX_PATH=$(command -v "$_cmd")
            return 0
        fi
    fi
    return 1
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
    local _rlp_tmpdir
    _rlp_tmpdir=$(mktemp -d "${OUTPUT_BASE:-/tmp}/.rlp_XXXXXX" 2>/dev/null || mktemp -d /tmp/.rlp_XXXXXX)
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
        local _rlp_ret
        _rlp_ret=$(cat "${_rlp_tmpdir}/w_${_rlp_i}" 2>/dev/null || echo 0)
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
