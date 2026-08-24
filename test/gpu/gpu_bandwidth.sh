#!/bin/bash
# =============================================================================
# gpu_bandwidth.sh — GPU 带宽测试（bandwidthTest 逐卡+P2P）
# test/gpu/gpu_bandwidth.sh
# 用法: bash test/gpu/gpu_bandwidth.sh
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

test_init "gpu_bandwidth"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/gpu_bandwidth_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ GPU 带宽测试（bandwidthTest 逐卡+P2P） ━━━${NC}" | tee -a "$REPORT_LOG"
GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
FOUND=$(find_gpu_tool bandwidthTest)
if [ -z "$FOUND" ]; then echo -e "${RED}[ERROR] bandwidthTest 未找到（编译 CUDA samples）${NC}"; exit 1; fi
for ((gi=0; gi<GPU_COUNT; gi++)); do
    run_and_log "${FOUND} --device=${gi} --mode=quick 2>&1" "${REPORT_DIR}/bandwidthTest_gpu${gi}.log"
    test_record "bandwidthTest_gpu${gi}" "${REPORT_DIR}/bandwidthTest_gpu${gi}.log" "$start_ts" "$?"
done
if [ "$GPU_COUNT" -ge 2 ]; then
    run_and_log "${FOUND} --device=0 --device=1 --mode=peertopeer 2>&1" "${REPORT_DIR}/bandwidthTest_p2p.log"
    test_record "bandwidthTest_p2p" "${REPORT_DIR}/bandwidthTest_p2p.log" "$start_ts" "$?"
fi
echo "bandwidth 测试完成（逐卡 + P2P 已记录）" | tee -a "$REPORT_LOG"
