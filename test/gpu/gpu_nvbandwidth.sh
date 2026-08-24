#!/bin/bash
# =============================================================================
# gpu_nvbandwidth.sh — GPU 带宽基准（nvbandwidth）
# test/gpu/gpu_nvbandwidth.sh
# 用法: bash test/gpu/gpu_nvbandwidth.sh
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

# ─── 查找 GPU 测试程序（PATH + 常见路径） ───
find_gpu_tool() {
    local tool="$1"
    command -v "$tool" 2>/dev/null && return 0
    for d in /usr/local/cuda/samples /opt /usr/local; do
        [ -x "$d/bin/$tool" ] && { echo "$d/bin/$tool"; return 0; }
        [ -x "$d/$tool" ] && { echo "$d/$tool"; return 0; }
    done
    find /usr /opt /root /home -maxdepth 4 -name "$tool" -type f -executable 2>/dev/null | head -1
    return 0
}

test_init "gpu_nvbandwidth"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/gpu_nvbandwidth_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ GPU 带宽基准（nvbandwidth） ━━━${NC}" | tee -a "$REPORT_LOG"
FOUND=$(find_gpu_tool nvbandwidth)
if [ -z "$FOUND" ]; then echo -e "${RED}[ERROR] nvbandwidth 未找到${NC}"; exit 1; fi
run_and_log "${FOUND} 2>&1" "$LOGFILE"
test_record "nvbandwidth" "$LOGFILE" "$start_ts" "$?"
test_finish "gpu_nvbandwidth"
