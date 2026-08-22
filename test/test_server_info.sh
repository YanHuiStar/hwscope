#!/bin/bash
# =============================================================================
# test_server_info.sh — 测试前服务器信息采集（独立可执行）
# test/test_server_info.sh
#
# 背景: 参考 Dell/华为等厂商 FLD 现场日志——测试日志头部先记录服务器信息，
#       使单测一项（如 memory_test）时日志也自包含机器身份（"这是哪台机器"）。
#
# 用法:
#   bash test/test_server_info.sh                    # 打印服务器信息到终端
#   bash test/test_server_info.sh --append <文件>    # 追加到指定日志文件（测试脚本接入用）
#   bash test/test_server_info.sh --out <目录>       # 另写 <目录>/server_info.log + manifest 登记
#   bash test/test_server_info.sh --help
#
# 设计: 轻量只读（几秒），工具缺失自动跳过（[SKIP] 风格，零中断）；
#       复用 lib/platform.sh 的 detect_machine_id（SN→主板SN→UUID→时间戳四层兜底）；
#       与采集模块（modules/*.sh 全量采集）和报告模块（report/ 出报告）场景不同——
#       本脚本是"压测日志自包含身份"的前置伴侣，独立工具。
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/../lib/platform.sh" 2>/dev/null || true
parse_help "$@"

APPEND=""      # --append 目标文件
OUT_DIR=""     # --out 输出目录
while [ $# -gt 0 ]; do
    case "$1" in
        --append) APPEND="$2"; shift 2 ;;
        --out)    OUT_DIR="$2"; shift 2 ;;
        --*)      echo -e "${YELLOW}[WARN] 未知参数: $1${NC}" >&2; shift ;;
        *)        break ;;
    esac
done

# ─── 采集（轻量只读，工具缺失跳过，零中断） ───
MID=$(detect_machine_id 2>/dev/null)

MB_MFR="N/A"; MB_PROD="N/A"; MB_SN="N/A"
if check_cmd dmidecode; then
    MB_MFR=$(dmidecode -t system 2>/dev/null | grep -m1 "Manufacturer" | cut -d: -f2- | sed 's/^ *//;s/ *$//')
    MB_PROD=$(dmidecode -t system 2>/dev/null | grep -m1 "Product Name" | cut -d: -f2- | sed 's/^ *//;s/ *$//')
    MB_SN=$(dmidecode -t system 2>/dev/null | grep -m1 "Serial Number" | cut -d: -f2- | sed 's/^ *//;s/ *$//')
    [ -z "$MB_SN" ] || echo "$MB_SN" | grep -qiE "Not Specified|To Be Filled|Default string" && MB_SN="N/A"
fi

CPU_MODEL="N/A"; CPU_SOCKS="0"; CPU_CORES="0"
if check_cmd lscpu; then
    CPU_MODEL=$(lscpu 2>/dev/null | grep -m1 "Model name" | cut -d: -f2- | sed 's/^ *//;s/ *$//')
    CPU_SOCKS=$(lscpu 2>/dev/null | grep -m1 "^Socket(s)" | awk '{print $NF}')
    CPU_CORES=$(lscpu 2>/dev/null | grep -m1 "^Core(s) per socket" | awk '{print $NF}')
fi
[ -z "$CPU_SOCKS" ] && CPU_SOCKS=0; [ -z "$CPU_CORES" ] && CPU_CORES=0

MEM_TOTAL="N/A"
if check_cmd free; then
    MEM_TOTAL=$(free -g 2>/dev/null | awk '/^Mem:/{print $2" GiB"}')
fi

GPU_INFO="N/A"
if check_cmd nvidia-smi; then
    GPU_CNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
    GPU_CNT=$(echo "$GPU_CNT" | head -1 | tr -dc '0-9')
    if [ -n "$GPU_CNT" ] && [ "$GPU_CNT" -gt 0 ] 2>/dev/null; then
        GPU_MODELS=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
        GPU_INFO="${GPU_CNT}× ${GPU_MODELS}"
    fi
fi

OS_NAME="N/A"; KERNEL="N/A"
[ -f /etc/os-release ] && OS_NAME=$(grep -m1 '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2)
KERNEL=$(uname -r 2>/dev/null)

# ─── 生成段文本（参考厂商 FLD 日志的 Server Information 段） ───
gen_section() {
    echo "=== Server Info ==="
    echo "Machine ID : ${MID:-N/A}"
    echo "Brand/Model: ${MB_MFR:-N/A} ${MB_PROD:-N/A}"
    echo "Serial     : ${MB_SN:-N/A}"
    if [ "${CPU_SOCKS:-0}" -gt 0 ] 2>/dev/null; then
        echo "CPU        : ${CPU_SOCKS}× ${CPU_MODEL:-N/A}（${CPU_CORES:-0} 核/颗）"
    else
        echo "CPU        : ${CPU_MODEL:-N/A}"
    fi
    echo "Memory     : ${MEM_TOTAL:-N/A}"
    echo "GPU        : ${GPU_INFO:-N/A}"
    echo "OS/Kernel  : ${OS_NAME:-N/A} · ${KERNEL:-N/A}"
    echo "采集时间   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

SECTION="$(gen_section)"

# ─── 输出（命令替换会剥尾换行，此处统一补足，防与后续内容连行） ───
if [ -n "$APPEND" ]; then
    printf '%s\n\n' "$SECTION" >> "$APPEND"
fi
if [ -n "$OUT_DIR" ]; then
    mkdir -p "$OUT_DIR"
    printf '%s\n\n' "$SECTION" > "${OUT_DIR}/server_info.log"
    # manifest 登记（供 report.sh --test-dir 压测段读；沿用 write_manifest 惯例）
    echo "server_info=server_info.log" >> "${OUT_DIR}/manifest.txt" 2>/dev/null || true
fi
if [ -z "$APPEND" ] && [ -z "$OUT_DIR" ]; then
    printf '%s\n\n' "$SECTION"
fi

exit 0
