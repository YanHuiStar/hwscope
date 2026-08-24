#!/bin/bash
# =============================================================================
# cpu_stress_ng.sh — CPU 满载压测（stress-ng 全核）
# test/cpu/cpu_stress_ng.sh
# 用法: bash test/cpu/cpu_stress_ng.sh [时长秒]    # 默认 30
#       bash test/cpu/cpu_stress_ng.sh -h          # 帮助
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

DUR="${1:-30}"
[[ "$DUR" =~ ^[0-9]+$ ]] || DUR=30

test_init "cpu_stress_ng"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/cpu_stress_ng_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ CPU 满载压测（stress-ng 全核） ━━━${NC}" | tee -a "$REPORT_LOG"
run_and_log "stress-ng --cpu 0 --cpu-method all --timeout ${DUR}s --metrics-brief 2>&1" "$LOGFILE"
test_record "cpu_stress_ng" "$LOGFILE" "$start_ts" "$?"
test_finish "cpu_stress_ng"
