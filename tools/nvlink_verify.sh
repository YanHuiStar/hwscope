#!/bin/bash
# =============================================================================
# HwScope — NVLink 完整性校验
# tools/nvlink_verify.sh
# 用法: bash tools/nvlink_verify.sh
# 功能:
#   1. 解析 nvidia-smi topo -m：找出非 NVLink 降级链路
#   2. nvlink --status：CRC 错误 / 链路 down 检测
#   3. 输出健康结论（解析逻辑在 lib/nvlink.sh，与 report.sh 共用）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/nvlink.sh" 2>/dev/null || true

if ! check_cmd nvidia-smi; then
    echo -e "${RED}[ERROR] nvidia-smi 未安装${NC}"
    exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
[ "$GPU_COUNT" -eq 0 ] && echo -e "${RED}[ERROR] 未检测到 GPU${NC}" && exit 1

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  NVLink 完整性校验 (${GPU_COUNT} GPU)${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ─── 1. 拓扑矩阵 ───
echo -e "${BLUE}── GPU 互联拓扑 (nvidia-smi topo -m) ──${NC}"
TOPO=$(nvidia-smi topo -m 2>/dev/null)
echo "$TOPO" | head -20
echo ""

# ─── 2. 降级链路检测 ───
echo -e "${BLUE}── 链路完整性 ──${NC}"
NVLINK_DEGRADED=$(nvlink_parse_topo "$TOPO")
if [ -z "$NVLINK_DEGRADED" ]; then
    echo -e "  ${GREEN}✓ 所有 GPU 间均为 NVLink 互联${NC}"
else
    echo -e "  ${YELLOW}⚠ 检测到非 NVLink 降级链路:${NC}"
    echo "$NVLINK_DEGRADED" | sed 's/^/    /'
fi

# ─── 3. CRC 错误 ───
echo ""
echo -e "${BLUE}── NVLink CRC 错误 ──${NC}"
NVSTATUS=$(nvidia-smi nvlink --status 2>/dev/null)
NVLINK_CRC=$(nvlink_parse_crc "$NVSTATUS")
if [ -z "$NVLINK_CRC" ]; then
    echo -e "  ${GREEN}✓ 全部链路 CRC 错误 = 0${NC}"
else
    echo -e "  ${YELLOW}⚠ 存在 CRC 错误:${NC}"
    echo "$NVLINK_CRC" | sed 's/^/    /'
fi

# ─── 4. 链路 down 检测 ───
NVLINK_DOWN=$(nvlink_parse_down "$NVSTATUS")
echo ""
if [ -n "$NVLINK_DOWN" ]; then
    echo -e "${YELLOW}⚠ 检测到异常链路:${NC}"
    echo "$NVLINK_DOWN" | sed 's/^/  /'
else
    echo -e "${GREEN}✓ 无 down/degraded 链路${NC}"
fi

# ─── 5. 综合结论 ───
echo ""
if nvlink_is_healthy; then
    echo -e "${GREEN}结论: NVLink 健康${NC}"
else
    echo -e "${YELLOW}结论: NVLink 存在异常，请排查上述链路${NC}"
fi
echo "参考: NV18 = 18 条 NVLink 全互联 (B300)；NV12/NV6 为部分互联；PIX/PHB/SYS 为 PCIe 路径"
