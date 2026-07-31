#!/bin/bash
# =============================================================================
# HwScope — 内存硬件测试
# test/memory_test.sh
# 用法: bash test/memory_test.sh
# 功能: stress-ng vm / memtester / sysbench memory 内存压测
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

TOOLS=(
    "stress-ng:stress-ng:内存压力测试 (--vm)"
    "memtester:memtester:传统内存位翻转测试"
    "sysbench:sysbench:内存带宽基准测试"
)

test_menu TOOLS || exit 0
test_init "memory"

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
                # 可用内存的 80%，多线程
                run_and_log "stress-ng --vm 4 --vm-bytes 80% --vm-method all --timeout 30s --metrics-brief 2>&1" "$LOGFILE"
                ;;
            memtester)
                # 探测可用内存的一半（MB），2 轮
                mem_mb=$(free -m | awk '/Mem:/{print int($7*0.5)}')
                [ "$mem_mb" -lt 100 ] && mem_mb=256
                run_and_log "memtester ${mem_mb}M 2 2>&1" "$LOGFILE"
                ;;
            sysbench)
                run_and_log "sysbench memory --memory-block-size=1M --memory-total-size=10G --threads=4 run 2>&1" "$LOGFILE"
                ;;
        esac
        test_record "$name" "$LOGFILE" "$start_ts"
    done
done

test_finish "memory"
