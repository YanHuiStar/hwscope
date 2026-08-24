#!/bin/bash
# =============================================================================
# mem_memtester.sh — 内存位翻转测试（memtester）
# test/memory/mem_memtester.sh
# 用法: bash test/memory/mem_memtester.sh [时长秒]    # 默认 60
#       bash test/memory/mem_memtester.sh -h          # 帮助
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

DUR="${1:-60}"
[[ "$DUR" =~ ^[0-9]+$ ]] || DUR=60

test_init "mem_memtester"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/mem_memtester_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ 内存位翻转测试（memtester） ━━━${NC}" | tee -a "$REPORT_LOG"
MEM_BYTES=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024/2}' /proc/meminfo); run_and_log "memtester ${MEM_BYTES}G 2 2>&1" "$LOGFILE"
test_record "mem_memtester" "$LOGFILE" "$start_ts" "$?"
test_finish "mem_memtester"
