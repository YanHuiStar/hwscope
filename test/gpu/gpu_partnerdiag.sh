#!/bin/bash
# =============================================================================
# gpu_partnerdiag.sh — NVIDIA 出厂诊断（partnerdiag）
# test/gpu/gpu_partnerdiag.sh
# 用法: bash test/gpu/gpu_partnerdiag.sh
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

test_init "gpu_partnerdiag"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/gpu_partnerdiag_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ NVIDIA 出厂诊断（partnerdiag） ━━━${NC}" | tee -a "$REPORT_LOG"
FOUND=$(find_gpu_tool partnerdiag)
if [ -z "$FOUND" ]; then echo -e "${RED}[ERROR] partnerdiag 未找到（FLD 包）${NC}"; exit 1; fi
read -p "  参数 (默认 --field --level1 --run_on_error --no_bmc): " -r pdiag_args
[ -z "$pdiag_args" ] && pdiag_args="--field --level1 --run_on_error --no_bmc"
run_and_log "sudo ${FOUND} ${pdiag_args} 2>&1" "$LOGFILE"
test_record "partnerdiag" "$LOGFILE" "$start_ts" "$?"
test_finish "gpu_partnerdiag"
