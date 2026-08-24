#!/bin/bash
# =============================================================================
# net_mtr.sh — 网络路径质量（mtr）
# test/network/net_mtr.sh
# 用法: bash test/network/net_mtr.sh [时长秒]    # 默认 10
#       bash test/network/net_mtr.sh -h          # 帮助
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

DUR="${1:-10}"
[[ "$DUR" =~ ^[0-9]+$ ]] || DUR=10

test_init "net_mtr"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/net_mtr_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ 网络路径质量（mtr） ━━━${NC}" | tee -a "$REPORT_LOG"
run_and_log "mtr -rw -c 10 8.8.8.8 2>&1" "$LOGFILE"
test_record "net_mtr" "$LOGFILE" "$start_ts" "$?"
test_finish "net_mtr"
