#!/bin/bash
# =============================================================================
# nccl_test.sh — NCCL 集合通信带宽验证
# test/nccl/nccl_test.sh
# 用法: bash test/nccl/nccl_test.sh
# 功能: all_reduce_perf / all_gather_perf / all_to_all_perf 带宽验证
# 依赖: nccl-tests（编译产物）
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

# ─── 查找 nccl-tests 编译产物（限常见路径，避免全盘扫描） ───
BIN_DIR=""
PERF_BIN=""
for cand in \
    "${SCRIPT_DIR}/nccl-tests/build" \
    "/opt/nccl-tests/build" \
    "/usr/local/nccl-tests/build" \
    "/usr/local/cuda/samples/CompilerRules" \
    "/root/nccl-tests/build" \
    "/home/"*/nccl-tests/build; do
    [ -x "$cand/all_reduce_perf" ] && { BIN_DIR="$cand"; PERF_BIN="$cand/all_reduce_perf"; break; }
done
if [ -z "$PERF_BIN" ]; then
    PERF_BIN=$(command -v all_reduce_perf 2>/dev/null)
    [ -n "$PERF_BIN" ] && BIN_DIR=$(dirname "$PERF_BIN")
fi
if [ -z "$PERF_BIN" ]; then
    echo -e "${RED}[ERROR] nccl-tests 编译产物未找到（先编译 nccl-tests）${NC}"
    echo "        git clone https://github.com/NVIDIA/nccl-tests && cd nccl-tests && make NCCL_HOME=/usr/local/nccl2"
    exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
[ "$GPU_COUNT" -eq 0 ] && { echo -e "${RED}[ERROR] 无 GPU${NC}"; exit 1; }

test_init "nccl"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true

for perf in all_reduce_perf all_gather_perf all_to_all_perf; do
    bin="${BIN_DIR}/${perf}"
    [ -x "$bin" ] || continue
    start_ts=$(date +%s)
    LOGFILE="${REPORT_DIR}/${perf}_detail.log"
    echo "" | tee -a "$REPORT_LOG"
    echo -e "${CYAN}━━━ ${perf} ━━━${NC}" | tee -a "$REPORT_LOG"
    run_and_log "${bin} -b 1G -e 4G -f 2 -g ${GPU_COUNT} -n 20 -w 5 2>&1" "$LOGFILE"
    test_record "$perf" "$LOGFILE" "$start_ts" "$?"
done

test_finish "nccl"
