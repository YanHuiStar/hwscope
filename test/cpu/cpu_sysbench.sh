#!/bin/bash
# =============================================================================
# cpu_sysbench.sh — CPU 性能基准（sysbench）
# test/cpu/cpu_sysbench.sh
# 用法: bash test/cpu/cpu_sysbench.sh [时长秒]    # 默认 30
#       bash test/cpu/cpu_sysbench.sh -h          # 帮助
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

DUR="${1:-30}"
[[ "$DUR" =~ ^[0-9]+$ ]] || DUR=30

test_init "cpu_sysbench"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/cpu_sysbench_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ CPU 性能基准（sysbench） ━━━${NC}" | tee -a "$REPORT_LOG"
run_and_log "sysbench cpu --cpu-max-prime=20000 --time=30 run 2>&1" "$LOGFILE"
test_record "cpu_sysbench" "$LOGFILE" "$start_ts" "$?"
test_finish "cpu_sysbench"
