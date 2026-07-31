#!/bin/bash
# =============================================================================
# HwScope — 网卡运维工具
# tools/nic_tool.sh
# 用法: sudo bash tools/nic_tool.sh
# 功能: IB 端口状态/重置、固件查询、mlxconfig 配置查看
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

# ─── 工具检查 ───
if ! check_cmd mlxlink && ! check_cmd mlxfwmanager; then
    echo -e "${RED}[ERROR] 未找到 MFT 工具 (mlxlink/mlxfwmanager)${NC}"
    echo "        安装: bash tools/install_tool.sh (MFT)"
    exit 1
fi

# ─── 设备列表 ───
DEVS=$(ls /sys/class/infiniband/ 2>/dev/null | grep -E 'mlx5_' | head -8)
if [ -z "$DEVS" ]; then
    echo -e "${YELLOW}[WARN] 未发现 mlx5 IB 设备${NC}"
    echo "      非 IB 服务器可跳过本工具"
    exit 1
fi
echo -e "${CYAN}发现 IB 设备:${NC} $DEVS"

# ─── 功能表 ───
OPS=(
    "1:查看所有设备状态:mlxlink -d DEV 2>&1 | head -25:只读"
    "2:查看光模块信息:mlxlink -d DEV -m 2>&1 | head -25:只读"
    "3:查询固件版本:mlxfwmanager --query 2>&1 | grep -E 'Device|Firmware|PSID' | head -10:只读"
    "4:查看配置:mlxconfig query -d DEV 2>&1 | head -20:只读"
    "5:端口复位:mlxlink -d DEV -r 2>&1:写入操作"
    "6:设置 MTU (9000):ip link set DEV mtu 9000 2>&1:写入操作"
)

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  网卡运维工具${NC}"
echo -e "${CYAN}========================================${NC}"
for op in "${OPS[@]}"; do
    IFS=':' read -r num name cmd warn <<< "$op"
    echo -e "  ${GREEN}[${num}]${NC} ${name}  ${YELLOW}(${warn})${NC}"
done
echo ""
read -p "选择操作 (1-6, 逗号分隔): " -r choices
[ -z "$choices" ] && echo "跳过" && exit 0

# ─── 选择设备 ───
read -p "选择设备 (默认 ${DEVS%% *}): " -r dev
[ -z "$dev" ] && dev="${DEVS%% *}"
[ ! -d "/sys/class/infiniband/${dev}" ] && echo -e "${RED}[ERROR] 无效设备 ${dev}${NC}" && exit 1

REPORT_DIR="${SCRIPT_DIR}/output/nic_tool_$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$REPORT_DIR"

IFS=',' read -ra SELECTED <<< "$choices"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for op in "${OPS[@]}"; do
        IFS=':' read -r num name cmd warn <<< "$op"
        [ "$sel" != "$num" ] && continue
        echo -e "${CYAN}━━━ ${name} (${dev}) ━━━${NC}"
        if [ "$warn" = "写入操作" ]; then
            read -p " ${YELLOW}⚠ 此操作会修改网卡配置，确认? (y/N)${NC} " -r confirm
            [[ ! "$confirm" =~ ^[Yy] ]] && echo "  跳过" && continue
        fi
        final_cmd=$(echo "$cmd" | sed "s/DEV/${dev}/g")
        LOGFILE="${REPORT_DIR}/${name// /_}.log"
        bash -c "$final_cmd" | tee "$LOGFILE"
        echo ""
    done
done

echo -e "${GREEN}操作完成${NC}"
echo "日志: $REPORT_DIR/"
