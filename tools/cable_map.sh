#!/bin/bash
# =============================================================================
# HwScope — 线缆拓扑图（自动发现物理连线关系）
# tools/cable_map.sh
# 用法: sudo bash tools/cable_map.sh
# 功能:
#   1. BDF ↔ mlx5 映射（sysfs 权威）
#   2. 线缆配对：两端 EEPROM serial 相同 = 物理相连
#   3. 输出物理连线表（对线神器，不用拔线）
# 注意: 无源铜缆(DAC)部分读不出 serial，会提示改用拔线法
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

if ! check_cmd mlxlink; then
    echo -e "${RED}[ERROR] mlxlink 未安装 (需 MFT)${NC}"
    echo "        安装: bash tools/install_tool.sh (MFT)"
    exit 1
fi

# ─── 1. 设备列表 ───
DEVS=$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5)
if [ -z "$DEVS" ]; then
    echo -e "${YELLOW}[WARN] 未发现 mlx5 设备${NC}"
    exit 1
fi

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  线缆拓扑图${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ─── 2. BDF ↔ mlx5 ↔ netdev 映射 ───
echo -e "${BLUE}── 设备映射 (BDF ↔ mlx5 ↔ netdev) ──${NC}"
for dev in $DEVS; do
    bdf=$(readlink -f "/sys/class/infiniband/${dev}/device" 2>/dev/null | xargs basename 2>/dev/null)
    netdev=$(ls "/sys/class/infiniband/${dev}/device/net/" 2>/dev/null | head -1)
    rate=$(cat "/sys/class/infiniband/${dev}/ports/1/rate" 2>/dev/null)
    printf "  %-10s  BDF:%-14s  netdev:%-14s  %s\n" "$dev" "${bdf:-N/A}" "${netdev:-N/A}" "${rate:-}"
done

# ─── 3. 线缆配对（serial 分组） ───
echo ""
echo -e "${BLUE}── 线缆配对 (EEPROM serial 相同 = 同一根线) ──${NC}"
declare -A CABLE_SERIALS
UNREADABLE=()
PAIRED_DEVS=""
for dev in $DEVS; do
    serial=$(sudo mlxlink -d "$dev" -p 1 2>/dev/null | grep -iE "Serial Number" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
    if [ -z "$serial" ] || [ "$serial" = "N/A" ]; then
        UNREADABLE+=("$dev")
        continue
    fi
    if [ -n "${CABLE_SERIALS[$serial]}" ]; then
        echo -e "  ${GREEN}${CABLE_SERIALS[$serial]} ↔ ${dev}${NC}   (serial: ${serial})"
        # 两端都标记为已配对（第二个设备在配对时加入）
        PAIRED_DEVS="${PAIRED_DEVS} ${CABLE_SERIALS[$serial]} ${dev}"
    else
        CABLE_SERIALS[$serial]="$dev"
    fi
done

# 未配对的单端：serial 可读但只出现一次（另一头未连/未上电），且未读不出 serial
for serial in "${!CABLE_SERIALS[@]}"; do
    first="${CABLE_SERIALS[$serial]}"
    if ! echo "$PAIRED_DEVS" | grep -qw "$first"; then
        UNREADABLE+=("$first(单端)")
    fi
done

if [ ${#UNREADABLE[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}⚠ 以下设备 EEPROM 读不出 serial (常见于无源 DAC):${NC}"
    printf "  %s\n" "${UNREADABLE[@]}"
    echo "  建议: 拔线法确认（拔 P1 看哪个设备 Down）或 ethtool -p 闪灯"
fi

echo ""
echo -e "${GREEN}完成${NC}"
