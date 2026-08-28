#!/bin/bash
# =============================================================================
# HwScope - 变量解析：NVLink 状态 + DCGM + 健康文本 + LINKTYPE
# report/sections/50_nvlink_dcgm.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# ─── NVLink 状态（读采集日志，lib/nvlink.sh） ───
nvlink_load_from_logs "$GPU_DIR"
NVLINK_HEALTH="OK"
if [ "${NVLINK_DATA:-0}" -eq 0 ]; then
    NVLINK_HEALTH="N/A"   # 无 NVLink 采集数据（无 GPU/旧采集），判定用 N/A 而非 OK
else
    nvlink_is_healthy || NVLINK_HEALTH="异常"
fi

# ─── DCGM 诊断结果（dcgmi_diag_level1.log：区分硬件 Fail 与配置类 Fail） ───
# Persistence Mode 未开启是环境配置问题（8 卡全 Fail 时常见），不属硬件故障，单独标注
DCGM_SUMMARY="N/A"
DCGM_DIR="${OUT}/dcgm"
load_manifest "${DCGM_DIR}" dcgmi_diag_level1 "dcgmi_diag_level1.log"
load_manifest "${DCGM_DIR}" dcgm_notice "dcgm_notice.log"
DCGM_NOTICE=""
[ -f "${dcgm_notice}" ] && DCGM_NOTICE=$(grep -v "^#" "${dcgm_notice}" | head -1)
if [ -f "${dcgmi_diag_level1}" ]; then
    # 结果列与状态同在一行，精确行匹配统计（-A1 会带上下一行硬件测试，软件失败数被重复计数）
    DCGM_SOFT_FAIL=$(grep -E "^[[:space:]]*\|[[:space:]]*software[[:space:]]*\|" "${dcgmi_diag_level1}" 2>/dev/null | grep -c "Fail")
    DCGM_HW_FAIL=$(grep -E "^\| (memory|pcie|nvlink|diagnostic|compute|graphics|nvswitch)" "${dcgmi_diag_level1}" 2>/dev/null | grep -c "Fail")
    DCGM_PERSIST=$(grep -c "Persistence Mode" "${dcgmi_diag_level1}" 2>/dev/null)
    DCGM_DIAG_VER=$(grep -m1 "DCGM Version" "${dcgmi_diag_level1}" 2>/dev/null | grep -oP 'DCGM Version\s+\|\s*\K[0-9.]+' | head -1)
    if grep -qiE "No available testing entities|Unable to complete diagnostic|Return: \(-30\)|Couldn't find match" "${dcgmi_diag_level1}" 2>/dev/null; then
        if [ "$HEAD_NODE" -eq 1 ]; then
            DCGM_SUMMARY="N/A（HGX 机头无 GPU，模组单独采集）"
        else
            DCGM_SUMMARY="N/A（无 GPU/无测试实体，未运行诊断）"
        fi
    elif [ "$DCGM_SOFT_FAIL" -gt 0 ] || [ "$DCGM_HW_FAIL" -gt 0 ]; then
        DCGM_SUMMARY="Fail (软件:${DCGM_SOFT_FAIL} 硬件:${DCGM_HW_FAIL})"
        # 纯配置类 Fail（仅 Persistence Mode）→ 标注非硬件
        if [ "$DCGM_HW_FAIL" -eq 0 ] && [ "$DCGM_SOFT_FAIL" -gt 0 ] && [ "$DCGM_PERSIST" -ge "$DCGM_SOFT_FAIL" ]; then
            DCGM_SUMMARY="配置项 Fail (Persistence Mode 未开启, 非硬件故障)"
        fi
    else
        DCGM_SUMMARY="通过 (DCGM ${DCGM_DIAG_VER:-?})"
    fi
fi

# 健康检查文本（变量拼接，避免 $( ) 命令替换剥离尾换行导致排版错乱）
HEALTH_TXT=""
if [ "$GPU_COUNT" -eq 0 ]; then
    if [ "$HEAD_NODE" -eq 1 ]; then
        HEALTH_TXT="${HEALTH_TXT}  PCIe链路 : N/A (HGX 机头无本地 GPU，模组单独采集)"$'\n'
    elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
        HEALTH_TXT="${HEALTH_TXT}  PCIe链路 : ⚠️ 检测到 ${GPU_PCI_PRESENT} 个 ${GPU_PCI_VENDOR:-} GPU 但管理工具无数据（驱动未安装或异常）"$'\n'
    else
        HEALTH_TXT="${HEALTH_TXT}  PCIe链路 : N/A (无 GPU)"$'\n'
    fi
else
    HEALTH_TXT="${HEALTH_TXT}  PCIe链路 : ${GPU_DEGRADED:-✓ 全部正常}"$'\n'
fi
if [ "${NVLINK_HEALTH:-N/A}" != "N/A" ]; then
    HEALTH_TXT="${HEALTH_TXT}  NVLink   : ${NVLINK_HEALTH}${NVLINK_CRC:+ (存在CRC错误)}"$'\n'
fi
if [ -n "$DCGM_SUMMARY" ] && [ "$DCGM_SUMMARY" != "N/A" ]; then
    HEALTH_TXT="${HEALTH_TXT}  DCGM诊断 : ${DCGM_SUMMARY}"$'\n'
elif [ "$HEAD_NODE" -eq 1 ]; then
    HEALTH_TXT="${HEALTH_TXT}  DCGM诊断 : N/A（HGX 机头无 GPU，模组单独采集）"$'\n'
fi
if [ -n "$DCGM_NOTICE" ]; then
    HEALTH_TXT="${HEALTH_TXT}  ⚠️ ${DCGM_NOTICE}"$'\n'
fi

# 端口模式汇总（mlxconfig_*_linktype.log：每口 IB/ETH 模式）
LINKTYPE_SUMMARY=""
for f in "${NET_DIR}"/mlxconfig_*_linktype.log; do
    [ -f "$f" ] || continue
    cfg_dev=$(basename "$f" | sed 's/mlxconfig_\(.*\)_linktype.log/\1/')
    [ -z "$cfg_dev" ] && continue
    p1=$(grep "LINK_TYPE_P1" "$f" | awk '{print $2}' | head -1)
    p2=$(grep "LINK_TYPE_P2" "$f" | awk '{print $2}' | head -1)
    [ -z "$p1" ] && [ -z "$p2" ] && continue
    LINKTYPE_SUMMARY="${LINKTYPE_SUMMARY}${cfg_dev}:P1=${p1:-N/A} P2=${p2:-N/A},"
done
LINKTYPE_SUMMARY=$(echo "$LINKTYPE_SUMMARY" | sed 's/,$//')
