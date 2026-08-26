#!/bin/bash
# =============================================================================
# HwScope — test/ 公共函数库
# test/test_common.sh
# 功能：日志目录初始化、工具菜单、结果记录
# =============================================================================

# 新建测试目录（v1.45.3：logs/test/<SN>-<时间戳>/——SN 标识机器（同采集 output/<SN>），时间戳区分多次压测；
# 无 SN 平台（WSL/开发机）兜底纯时间戳，与 detect_machine_id 语义一致）
test_new_dir() {
    local _mid=""
    if command -v dmidecode >/dev/null 2>&1; then
        _mid=$(dmidecode -t system 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        [ -z "$_mid" ] && _mid=$(dmidecode -t baseboard 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        echo "$_mid" | grep -qiE "To Be Filled|O\.E\.M\.|Default string|Not Specified|Unknown|None" && _mid=""
        _mid=$(echo "$_mid" | tr -cd 'A-Za-z0-9_-')
    fi
    local base="${SCRIPT_DIR}/logs/test/${_mid:+${_mid}-}$(date '+%Y%m%d%H%M%S')"
    mkdir -p "$base"
    echo "$base"
}

# 初始化日志目录：会话共享（HW_TEST_SESSION_DIR 已设 = test_all 聚合会话，复用不新建——所有测试累积到一个目录，
# 避免连续单测/--all 产生碎片目录）或独立新建
test_init() {
    local test_name="$1"
    local base
    if [ -n "${HW_TEST_SESSION_DIR:-}" ] && [ -d "$HW_TEST_SESSION_DIR" ]; then
        base="$HW_TEST_SESSION_DIR"
    else
        base="$(test_new_dir)"
    fi
    mkdir -p "$base"
    REPORT_DIR="$base"
    REPORT_LOG="${base}/${test_name}.log"
    TEST_SEQ=0
    # manifest.txt：供 report/report.sh --test-dir 读 manifest 解耦（压测归档章节）
    {
        echo "# HwScope test output manifest"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "test_name=${test_name}"
    } > "${base}/manifest.txt"
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

# 记录一条测试结果（状态按命令 exit code 判定，避免日志内容误判）
test_record() {
    local name="$1" logfile="$2" start_ts="$3" exit_code="${4:-0}"
    local end_ts
    local elapsed
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    local status
    if [ "$exit_code" -eq 0 ]; then
        status="通过"
    elif [ "$exit_code" -eq 127 ]; then
        status="工具缺失"
    else
        status="异常 (exit=$exit_code)"
    fi
    echo "[$(date '+%H:%M:%S')] ${name}: ${status} (${elapsed}s) — 详情: $(basename "$logfile")" >> "$REPORT_LOG"
    echo "  ${status} 耗时: ${elapsed}s" | tee -a "$REPORT_LOG"
    # manifest 登记详情文件（report --test-dir 读 manifest 解耦；测试名唯一化）
    TEST_SEQ=$((TEST_SEQ + 1))
    echo "test$(printf '%02d' "$TEST_SEQ")=$(basename "$logfile")" >> "${REPORT_DIR}/manifest.txt"
}

# 结束报告
test_finish() {
    local test_name="$1"
    {
        echo ""
        echo "[$(date '+%H:%M:%S')] ${test_name} 测试结束"
    } >> "$REPORT_LOG"
    # manifest 收尾：声明汇总日志（report --test-dir 解析入口）
    echo "summary=$(basename "$REPORT_LOG")" >> "${REPORT_DIR}/manifest.txt"
    echo ""
    echo -e "${GREEN}测试完成${NC}"
    echo "日志: $REPORT_LOG"
}
