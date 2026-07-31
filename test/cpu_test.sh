#!/bin/bash
# =============================================================================
# HwScope — CPU 硬件测试
# test/cpu_test.sh
# 用法: bash test/cpu_test.sh
# 功能: stress-ng / sysbench / mprime CPU 压测
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

REPORT_DIR="${SCRIPT_DIR}/logs/test/$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$REPORT_DIR"
REPORT_LOG="${REPORT_DIR}/cpu_test.log"
REPORT_MD="${REPORT_DIR}/cpu_report.md"
HOSTNAME=$(hostname 2>/dev/null || echo "unknown")

# ─── 工具检测 ───
TOOLS=(
    "stress-ng:stress-ng:通用 CPU/内存压测"
    "sysbench:sysbench:CPU 性能基准测试"
    "mprime:mprime:大规模素数计算(散热验证)"
)

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  CPU 硬件测试工具选择${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

AVAILABLE=()
UNAVAILABLE=()
IDX=0

for entry in "${TOOLS[@]}"; do
    IFS=':' read -r cmd name desc <<< "$entry"
    if check_cmd "$cmd"; then
        AVAILABLE+=("${IDX}|${name}|${desc}|${cmd}")
        echo -e "  ${GREEN}[${IDX}]${NC} ${name} — ${desc}"
    else
        UNAVAILABLE+=("${name}|${desc}|${cmd}")
        echo -e "  ${RED}[${IDX}]${NC} ${name} — ${desc}  (${YELLOW}未安装${NC}: apt install $cmd)"
    fi
    ((IDX++))
done

echo ""
echo "  输入编号选择测试（多个用逗号: 0,1），Enter 跳过"
echo   ...

[ -z "${AVAILABLE[*]}" ] && echo -e "${YELLOW}没有已安装的测试工具${NC}" && exit 1

read -p "> " -r choices
[ -z "$choices" ] && echo "跳过" && exit 0

# ─── 初始化报告 ───
{
    echo "# CPU 测试报告"
    echo ""
    echo "**主机名:** $HOSTNAME"
    echo "**时间:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo "**HwScope:** ${HWSCOPE_VERSION:-v1.1.1}"
    echo ""
    echo "## 测试结果"
    echo ""
    echo "| 测试项 | 状态 | 耗时 | 关键指标 |"
    echo "|--------|------|------|----------|"
} > "$REPORT_MD"

echo "[$(date '+%H:%M:%S')] CPU 测试开始" | tee -a "$REPORT_LOG"

IFS=',' read -ra SELECTED <<< "$choices"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for entry in "${AVAILABLE[@]}"; do
        IFS='|' read -r idx name desc cmd <<< "$entry"
        if [ "$sel" = "$idx" ]; then
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
                    run_and_log "mprime -t -w${REPORT_DIR} 2>&1" "$LOGFILE"
                    ;;
            esac
            end_ts=$(date +%s); elapsed=$((end_ts - start_ts))

            result=$(grep -i "events per second\|events (avg/stddev)\|passed\|errors\|warning" "$LOGFILE" | head -1)
            [ -z "$result" ] && result="查看详情: $(basename "$LOGFILE")"

            status="${GREEN}通过${NC}"
            grep -qi "error\|fail\|warning" "$LOGFILE" 2>/dev/null && status="${YELLOW}异常${NC}"

            echo "  ${status} 耗时: ${elapsed}s" | tee -a "$REPORT_LOG"
            echo "" | tee -a "$REPORT_LOG"
            # 写入 MD 报告
            echo "| ${name} | ${status} | ${elapsed}s | ${result} |" >> "$REPORT_MD"
        fi
    done
done

{
    echo ""
    echo "---"
    echo "*报告由 HwScope ${HWSCOPE_VERSION:-v1.1.1} 于 $(date '+%Y-%m-%d %H:%M:%S') 生成*"
} >> "$REPORT_MD"

echo ""
echo -e "${GREEN}测试完成${NC}"
echo "报告: $REPORT_MD"
echo "日志: $REPORT_LOG"
