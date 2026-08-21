#!/bin/bash
# =============================================================================
# HwScope - HTML 报告生成器 gen_html（md2html.awk 转换）
# report/gen/gen_html.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
gen_html() {
    local f="${OUT}/hwscope_report.md"
    [ -f "$f" ] || return 0
    awk -f "${SCRIPT_DIR}/report/lib/md2html.awk" "$f" > "${OUT}/hwscope_report.html" 2>/dev/null || return 0
    echo -e "${GREEN}[REPORT] HTML: ${OUT}/hwscope_report.html${NC}"
}
