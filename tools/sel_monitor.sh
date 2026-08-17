#!/bin/bash
# =============================================================================
# HwScope — SEL 事件对比巡检
# tools/sel_monitor.sh
# 用法: sudo bash tools/sel_monitor.sh [--reset]
# 功能: 记录 SEL 基线，后续运行只报告新增事件（故障定位关键）
#   --reset  重新建立基线（忽略历史）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

if ! check_cmd ipmitool; then
    echo -e "${RED}[ERROR] ipmitool 未安装${NC}"
    echo "        apt/yum install ipmitool"
    exit 1
fi

BASE_DIR="${SCRIPT_DIR}/logs/sel_monitor"
mkdir -p "$BASE_DIR"
BASELINE="${BASE_DIR}/sel_baseline.txt"
LAST_SEEN="${BASE_DIR}/sel_last.txt"
NOW="${BASE_DIR}/sel_now.txt"
REPORT="${BASE_DIR}/sel_report_$(date '+%Y%m%d%H%M%S').txt"

# ─── 抓取当前 SEL（过滤词只匹配 ipmitool 自身报错，不能过滤事件内容里的 "Error"） ───
ipmitool sel elist 2>&1 | grep -vE "Could not open|Unable|No such file|command failed|device at /dev" > "$NOW" || true
SEL_COUNT=$(wc -l < "$NOW")

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  SEL 事件巡检${NC}"
echo -e "${CYAN}========================================${NC}"
echo "当前 SEL 事件数: ${SEL_COUNT}"

# ─── 首次运行 / 重置：建立基线 ───
if [ "$1" = "--reset" ] || [ ! -f "$BASELINE" ]; then
    cp "$NOW" "$BASELINE"
    cp "$NOW" "$LAST_SEEN"
    echo -e "${GREEN}[OK] 已建立 SEL 基线 (${SEL_COUNT} 条)${NC}"
    echo "     下次运行将只报告新增事件"
    exit 0
fi

# ─── 增量对比：基线 vs 当前 ───
# SEL 只追加不删除：ID 单调递增，新增 = ID 大于上次最大 ID 的所有行
# （比整行匹配可靠：事件内容/时间戳不变，只有 ID 会滚动）
LAST_MAX_ID=$(grep -oE "^[[:space:]]*[0-9]+" "$LAST_SEEN" 2>/dev/null | sort -n | tail -1)
LAST_MAX_ID=${LAST_MAX_ID:-0}
NEW_EVENTS=$(awk -v min="$LAST_MAX_ID" '
    match($0, /^[[:space:]]*[0-9]+/) {
        id = substr($0, RSTART, RLENGTH) + 0
        if (id > min) print
    }' "$NOW")
NEW_COUNT=$(echo -n "$NEW_EVENTS" | grep -c . || true)

if [ "$NEW_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}⚠ 检测到 ${NEW_COUNT} 条新增 SEL 事件:${NC}"
    echo "--------------------------------------------"
    echo "$NEW_EVENTS" | tee "$REPORT"
    echo "--------------------------------------------"
    # 分类统计（严重事件高亮）
    CRIT=$(echo "$NEW_EVENTS" | grep -ciE "critical|fatal|assert|uncorrectable")
    PCIE=$(echo "$NEW_EVENTS" | grep -ciE "pcie|aer")
    [ "$CRIT" -gt 0 ] && echo -e "${RED}  其中严重事件: ${CRIT} 条${NC}"
    [ "$PCIE" -gt 0 ] && echo -e "${YELLOW}  其中 PCIe 相关: ${PCIE} 条${NC}"
else
    echo -e "${GREEN}[OK] 无新增事件 (上次巡检后 SEL 无变化)${NC}"
fi

# ─── 更新 LAST_SEEN ───
cp "$NOW" "$LAST_SEEN"
echo ""
echo "基线: $BASELINE   巡检报告: $REPORT"
