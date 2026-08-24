#!/bin/bash
# =============================================================================
# net_iperf3.sh — TCP 吞吐（iperf3）
# test/network/net_iperf3.sh
# 用法: bash test/network/net_iperf3.sh [时长秒]    # 默认 10
#       bash test/network/net_iperf3.sh -h          # 帮助
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

DUR="${1:-10}"
[[ "$DUR" =~ ^[0-9]+$ ]] || DUR=10

test_init "net_iperf3"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/net_iperf3_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ TCP 吞吐（iperf3） ━━━${NC}" | tee -a "$REPORT_LOG"
read -p "  iperf3 服务端地址 (回车跳过): " -r iperf_host; if [ -n "$iperf_host" ]; then run_and_log "iperf3 -c ${iperf_host} -t 10 -P 4 2>&1" "$LOGFILE"; else echo "[SKIP] 未提供服务端地址" | tee -a "$LOGFILE"; fi
test_record "net_iperf3" "$LOGFILE" "$start_ts" "$?"
test_finish "net_iperf3"
