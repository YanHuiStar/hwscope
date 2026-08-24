#!/bin/bash
# =============================================================================
# cpu_mprime.sh — 大规模素数计算散热验证（mprime）
# test/cpu/cpu_mprime.sh
# 用法: bash test/cpu/cpu_mprime.sh [时长秒]    # 默认 300
#       bash test/cpu/cpu_mprime.sh -h          # 帮助
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

DUR="${1:-300}"
[[ "$DUR" =~ ^[0-9]+$ ]] || DUR=300

test_init "cpu_mprime"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/cpu_mprime_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ 大规模素数计算散热验证（mprime） ━━━${NC}" | tee -a "$REPORT_LOG"
run_and_log "timeout 300 mprime -t -w${REPORT_DIR} 2>&1" "$LOGFILE"
test_record "cpu_mprime" "$LOGFILE" "$start_ts" "$?"
test_finish "cpu_mprime"
