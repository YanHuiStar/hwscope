#!/bin/bash
# =============================================================================
# HwScope - 生成辅助：术语表 glossary_md/txt + 网卡 net_extra_txt/md
# report/gen/gen_common.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
glossary_md() {
    local out=""
    local i=0
    for entry in "${GLOSSARY_ENTRIES[@]}"; do
        IFS='|' read -r term def <<< "$entry"
        out="${out}| **${term}** | ${def} |"$'\n'
        ((i++))
    done
    printf '%s' "$out"
}

glossary_txt() {
    local out=""
    for entry in "${GLOSSARY_ENTRIES[@]}"; do
        IFS='|' read -r term def <<< "$entry"
        out="${out}  ${term}: ${def}"$'\n'
    done
    printf '%s' "$out"
}

# 网络段附加行（线缆/配对/端口模式；PSID/MST 提示已并入 nic_details_txt 开头）
net_extra_txt() {
    local out=""
    [ -n "$CABLE_SUMMARY" ]   && [ "$CABLE_SUMMARY" != "N/A" ]   && out="${out}  线缆   : ${CABLE_SUMMARY}"$'\n'
    [ -n "$CABLE_PAIRS" ]     && [ "$CABLE_PAIRS" != "N/A" ]     && out="${out}  配对   : ${CABLE_PAIRS}"$'\n'
    [ -n "$LINKTYPE_SUMMARY" ] && [ "$LINKTYPE_SUMMARY" != "N/A" ] && out="${out}  端口模式: ${LINKTYPE_SUMMARY}"$'\n'
    [ -n "$out" ] && printf '\n%s' "$out"
}

# 网络段附加行（Markdown 表格版；空值不产生空行）
net_extra_md() {
    local out=""
    [ -n "$CABLE_SUMMARY" ]   && [ "$CABLE_SUMMARY" != "N/A" ]   && out="${out}| 线缆类型 | ${CABLE_SUMMARY} |"$'\n'
    [ -n "$CABLE_PAIRS" ]     && [ "$CABLE_PAIRS" != "N/A" ]     && out="${out}| 线缆配对 | ${CABLE_PAIRS} |"$'\n'
    [ -n "$LINKTYPE_SUMMARY" ] && [ "$LINKTYPE_SUMMARY" != "N/A" ] && out="${out}| 端口模式 | ${LINKTYPE_SUMMARY} |"$'\n'
    [ -n "$MST_NOTICE" ]      && out="${out}| ⚠️ 提示 | ${MST_NOTICE} |"$'\n'
    [ -n "$PSID_NOTICE" ]     && out="${out}| ⚠️ PSID | ${PSID_NOTICE} |"$'\n'
    printf '%s' "$out"
}
