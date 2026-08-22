#!/bin/bash
# =============================================================================
# HwScope — CPU 硬件测试
# test/cpu_test.sh
# 用法: bash test/cpu_test.sh
# 功能: stress-ng / sysbench / mprime CPU 压测
# 日志: logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

TOOLS=(
    "stress-ng:stress-ng:通用 CPU/内存压测"
    "sysbench:sysbench:CPU 性能基准测试"
    "mprime:mprime:大规模素数计算(散热验证)"
)

test_menu TOOLS || exit 0
test_init "cpu"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true

IFS=',' read -ra SELECTED <<< "$TEST_CHOICES"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for entry in "${TEST_AVAILABLE[@]}"; do
        IFS='|' read -r idx name desc cmd <<< "$entry"
        [ "$sel" != "$idx" ] && continue
        echo "" | tee -a "$REPORT_LOG"
        echo -e "${CYAN}━━━ ${name} 测试 ━━━${NC}" | tee -a "$REPORT_LOG"
        start_ts=$(date +%s)
        LOGFILE="${REPORT_DIR}/${name// /_}_detail.log"

        case "$name" in
            stress-ng)
                run_and_log "stress-ng --cpu 0 --cpu-method all --timeout 30s --metrics-brief 2>&1" "$LOGFILE"
                ;;
            sysbench)
                run_and_log "sysbench cpu --cpu-max-prime=20000 --time=30 run 2>&1" "$LOGFILE"
                ;;
            mprime)
                # mprime torture 默认无限运行，外层 timeout 300s 限制（与 stress-ng/sysbench 的 30s 上限对齐——v1.33.3）
                run_and_log "timeout 300 mprime -t -w${REPORT_DIR} 2>&1" "$LOGFILE"
                ;;
        esac
        test_record "$name" "$LOGFILE" "$start_ts" "$?"
    done
done

test_finish "cpu"
