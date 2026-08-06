#!/bin/bash
# =============================================================================
# HwScope — NVLink 完整性校验
# tools/nvlink_verify.sh
# 用法: bash tools/nvlink_verify.sh
# 功能:
#   1. 解析 nvidia-smi topo -m：校验全互联 (NV18 类) / 找出降级链路
#   2. nvlink --status：CRC 错误 / 链路状态
#   3. 输出健康结论
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

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

# ─── 1. 拓扑矩阵解析 ───
echo -e "${BLUE}── GPU 互联拓扑 (nvidia-smi topo -m) ──${NC}"
TOPO=$(nvidia-smi topo -m 2>/dev/null)
echo "$TOPO" | head -20
echo ""

# ─── 2. 全互联校验 ───
echo -e "${BLUE}── 链路完整性 ──${NC}"
# 提取矩阵：跳过表头和 CPU Affinity 部分
MATRIX=$(echo "$TOPO" | awk '/^GPU[0-9]/{print}' | head -10)
DEGRADED=0
UNEXPECTED=0

# 期望: 同构平台所有 GPU 间应为 NVLink 类 (NV 前缀)
# NV18/NV12/NV6/NV4 都是 NVLink；PIX/PHB/SYS 是非 NVLink 路径
NV_PATTERN='NV[0-9]+'
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # 拆字段: GPU0  X  NV18 NV18 ...
    src=$(echo "$line" | awk '{print $1}')
    for ((i=2; i<=GPU_COUNT+1; i++)); do
        val=$(echo "$line" | awk -v idx=$i '{print $idx}')
        # 跳过对角线的 X
        [ "$val" = "X" ] && continue
        # 期望 NVLink，出现 PIX/PHB/SYS 说明降级
        if ! echo "$val" | grep -qE "$NV_PATTERN"; then
            dst=$(echo "$TOPO" | awk -v idx=$i 'NR==1{for(j=2;j<=NF;j++) if(j==idx) print $j}' 2>/dev/null)
            # 从表头行取列名（GPU0..N）
            if [ -z "$dst" ]; then
                dst="GPU$((i-2))"
            fi
            echo -e "  ${YELLOW}⚠ ${src} → ${dst}: ${val} (非 NVLink)${NC}"
            DEGRADED=1
        fi
    done
done <<< "$MATRIX"

if [ "$DEGRADED" -eq 0 ]; then
    echo -e "  ${GREEN}✓ 所有 GPU 间均为 NVLink 互联${NC}"
fi

# ─── 3. CRC 错误检查 ───
echo ""
echo -e "${BLUE}── NVLink CRC 错误 ──${NC}"
NVSTATUS=$(nvidia-smi nvlink --status 2>/dev/null)
CRC=$(echo "$NVSTATUS" | grep -iE "CRC errors" | grep -vE ": 0$")
if [ -z "$CRC" ]; then
    echo -e "  ${GREEN}✓ 全部链路 CRC 错误 = 0${NC}"
else
    echo -e "  ${YELLOW}⚠ 存在 CRC 错误:${NC}"
    echo "$CRC" | sed 's/^/  /'
fi

# ─── 4. 链路 down 检查 ───
DOWN=$(echo "$NVSTATUS" | grep -iE "down|degraded" | head -10)
if [ -n "$DOWN" ]; then
    echo ""
    echo -e "${YELLOW}⚠ 检测到异常链路:${NC}"
    echo "$DOWN" | sed 's/^/  /'
else
    echo ""
    echo -e "${GREEN}✓ 无 down/degraded 链路${NC}"
fi

echo ""
echo -e "${GREEN}校验完成${NC}"
echo "参考: NV18 = 18 条 NVLink 全互联 (B300)；NV12/NV6 为部分互联；PIX/PHB/SYS 为 PCIe 路径"
