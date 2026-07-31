#!/bin/bash
# =============================================================================
# HwScope — test/ 公共函数库
# test/test_common.sh
# 功能：日志目录初始化、工具菜单、结果记录
# =============================================================================

# 初始化日志目录（输出到 logs/test/<时间戳>/）
test_init() {
    local test_name="$1"
    local base="${SCRIPT_DIR}/logs/test/$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$base"
    REPORT_DIR="$base"
    REPORT_LOG="${base}/${test_name}.log"
    {
        echo "============================================================"
        echo "HwScope ${HWSCOPE_VERSION:-unknown} — ${test_name} 测试"
        echo "Hostname : $(hostname 2>/dev/null || echo unknown)"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "============================================================"
        echo ""
    } > "$REPORT_LOG"
    echo "[$(date '+%H:%M:%S')] ${test_name} 测试开始" >> "$REPORT_LOG"
}

# 工具菜单：显示已装/未装，返回可用列表到 TEST_AVAILABLE
test_menu() {
    # $1 = TOOLS 数组名（"name:cmd:desc" 或 "name:cmd:desc:extra"）
    local -n _tools=$1
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  测试工具选择${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    TEST_AVAILABLE=()
    local idx=0
    for entry in "${_tools[@]}"; do
        IFS=':' read -r name cmd desc <<< "$entry"
        if check_cmd "$cmd"; then
            TEST_AVAILABLE+=("${idx}|${name}|${desc}|${cmd}")
            echo -e "  ${GREEN}[${idx}]${NC} ${name} — ${desc}"
        else
            echo -e "  ${RED}[${idx}]${NC} ${name} — ${desc}  (${YELLOW}未安装${NC}: apt install $cmd)"
        fi
        ((idx++))
    done
    echo ""
    [ -z "${TEST_AVAILABLE[*]}" ] && echo -e "${YELLOW}没有已安装的测试工具${NC}" && return 1
    read -p "> 输入编号选择（多个用逗号: 0,1），Enter 跳过: " -r TEST_CHOICES
    [ -z "$TEST_CHOICES" ] && echo "跳过" && return 1
    return 0
}

# 记录一条测试结果
test_record() {
    local name="$1" logfile="$2" start_ts="$3"
    local end_ts=$(date +%s) elapsed=$((end_ts - start_ts))
    local status
    if grep -qiE "error|fail" "$logfile" 2>/dev/null; then
        status="异常"
    else
        status="通过"
    fi
    echo "[$(date '+%H:%M:%S')] ${name}: ${status} (${elapsed}s) — 详情: $(basename "$logfile")" >> "$REPORT_LOG"
    echo "  ${status} 耗时: ${elapsed}s" | tee -a "$REPORT_LOG"
}

# 结束报告
test_finish() {
    local test_name="$1"
    {
        echo ""
        echo "[$(date '+%H:%M:%S')] ${test_name} 测试结束"
    } >> "$REPORT_LOG"
    echo ""
    echo -e "${GREEN}测试完成${NC}"
    echo "日志: $REPORT_LOG"
}
