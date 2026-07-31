#!/bin/bash
# =============================================================================
# HwScope — BMC 运维工具
# tools/bmc_tool.sh
# 用法: sudo bash tools/bmc_tool.sh
# 功能: IPMI 日志清理/密码重置/状态查询
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")

# ─── 工具检查 ───
if ! check_cmd ipmitool; then
    echo -e "${RED}[ERROR] ipmitool 未安装${NC}"
    echo "        apt/yum install ipmitool"
    exit 1
fi

# ─── 参数文件（可选） ───
CONF="${SCRIPT_DIR}/conf/hwscope.conf"
[ -f "$CONF" ] && source "$CONF"

BMC_IP="${BMC_IP:-}"
BMC_USER="${BMC_USER:-admin}"
BMC_PASS="${BMC_PASS:-admin}"
LOCAL=""
[ -z "$BMC_IP" ] && LOCAL=1 && echo -e "${CYAN}[INFO] BMC_IP 为空，使用本地 IPMI${NC}" || echo -e "${CYAN}[INFO] 远程 BMC: ${BMC_USER}@${BMC_IP}${NC}"

IPMI_CMD="ipmitool"
[ -n "$BMC_IP" ] && IPMI_CMD="ipmitool -H ${BMC_IP} -U ${BMC_USER} -P ${BMC_PASS} -I lanplus"

# ─── 功能表 ───
OPS=(
    "1:查看 FRU:${IPMI_CMD} fru print 2>&1 | head -40:只读"
    "2:查看传感器:${IPMI_CMD} sensor list 2>&1 | head -30:只读"
    "3:查看 SEL:${IPMI_CMD} sel elist 2>&1 | head -20:只读"
    "4:清空 SEL:${IPMI_CMD} sel clear 2>&1:写入操作"
    "5:查看 BMC 信息:${IPMI_CMD} mc info 2>&1 | head -15:只读"
    "6:重启 BMC:${IPMI_CMD} mc reset cold 2>&1:写入操作"
    "7:修改密码:${IPMI_CMD} user set password 2 2>&1:写入操作"
    "8:查看网络:${IPMI_CMD} lan print 1 2>&1 | head -20:只读"
)

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  BMC 运维工具${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

for op in "${OPS[@]}"; do
    IFS=':' read -r num name cmd warn <<< "$op"
    echo -e "  ${GREEN}[${num}]${NC} ${name}  ${YELLOW}(${warn})${NC}"
done

echo ""
read -p "选择操作 (1-8, 多个用逗号): " -r choices
[ -z "$choices" ] && echo "跳过" && exit 0

REPORT_DIR="${SCRIPT_DIR}/output/bmc_tool_$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$REPORT_DIR"

IFS=',' read -ra SELECTED <<< "$choices"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for op in "${OPS[@]}"; do
        IFS=':' read -r num name cmd warn <<< "$op"
        if [ "$sel" = "$num" ]; then
            echo -e "${CYAN}━━━ ${name} ━━━${NC}"
            if [ "$warn" = "写入操作" ]; then
                read -p " ${YELLOW}⚠ 此操作会修改 BMC，确认? (y/N)${NC} " -r confirm
                [[ ! "$confirm" =~ ^[Yy] ]] && echo "  跳过" && continue
            fi
            LOGFILE="${REPORT_DIR}/${name// /_}.log"
            bash -c "$cmd" | tee "$LOGFILE"
            echo ""
        fi
    done
done

echo -e "${GREEN}操作完成${NC}"
echo "日志: $REPORT_DIR/"
