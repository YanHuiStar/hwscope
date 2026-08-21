#!/bin/bash
# =============================================================================
# HwScope - BMC 一致性核验报告 gen_bmc_verify
# report/gen/gen_bmc_verify.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
gen_bmc_verify() {
    local f="${OUT}/hwscope_bmc_verify.md"
    {
        echo "# BMC 数据一致性核验报告"
        echo ""
        echo "- 机器: ${MB_MANUFACTURER:-N/A} ${MB_PRODUCT:-N/A}（SN: ${MB_SN:-N/A}）"
        echo "- 生成: $(date '+%Y-%m-%d %H:%M:%S') · 报告生成器: ${REPORT_VERSION:-unknown}"
        echo "- 说明: OS 层采集 vs BMC 层（IPMI FRU / Redfish）交叉校验，只读既有日志、零新采集；"
        echo "  不一致 = 潜在刷 SN/换件/固件不匹配风险"
        echo ""
        if [ -n "$BMC_CONSISTENCY" ]; then
            echo "| 对比项 | OS 侧 | BMC 侧 | 结果 |"
            echo "|--------|-------|--------|------|"
            echo "$BMC_CONSISTENCY" | while IFS='|' read -r bitem bos bbmc bres; do
                [ -z "$bitem" ] && continue
                echo "| ${bitem} | ${bos} | ${bbmc} | ${bres} |"
            done
        else
            echo "无 BMC 对比数据（机器无 BMC / IPMI 采集失败 / 旧采集）——无法核验"
        fi
        echo ""
        if printf '%s\n' "$BMC_CONSISTENCY" | grep -q "⚠️ 不一致"; then
            echo "**结论: ⚠️ 存在不一致项，需人工核实（刷 SN/换件/固件不匹配风险）**"
        elif printf '%s\n' "$BMC_CONSISTENCY" | grep -qE "仅(OS|BMC)侧数据"; then
            echo "**结论: 部分对比项仅单侧数据，建议补采 Redfish 完整核验**"
        elif [ -n "$BMC_CONSISTENCY" ]; then
            echo "**结论: OS 与 BMC 口径一致**"
        else
            echo "**结论: 无法核验（无 BMC 数据）**"
        fi
    } > "$f"
    echo -e "${GREEN}[REPORT] BMC 核验报告: ${f}${NC}"
}
