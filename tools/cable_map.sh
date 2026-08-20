#!/bin/bash
# shellcheck disable=SC2010  # /sys/class 接口名无空格，ls|grep 过滤安全
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
parse_help "$@"

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

# ─── 4. 断口联动验证（serial 读不出的 DAC 场景；借鉴 NVIDIA onediagfield 引擎逻辑） ───
# 原理: 把一端 link down（mlxlink -a DN），若另一端"联动 down"（Recommendation 变化）→ 物理相连
# 仅对 serial 不可读且未配对的设备执行（避免打断已确认的配对）；全程自动恢复
# 注意：这是对真实物理端口的写操作（逐口 down，生产 IB 网短暂断流），必须显式确认（v1.33.3）
if [ ${#UNREADABLE[@]} -gt 0 ]; then
    echo ""
    echo -e "${BLUE}── 断口联动验证 (DAC 无 serial 场景) ──${NC}"
    echo -e "${YELLOW}  将逐口 down 再恢复（每个口约 3-5 秒），生产 IB 网会短暂断流${NC}"
    read -rp "确认执行联动验证? (y/N) " confirm
    [[ ! "$confirm" =~ ^[Yy] ]] && { echo -e "  ${YELLOW}跳过联动验证（未配对设备请用拔线法确认）${NC}"; }
    if [[ "$confirm" =~ ^[Yy] ]]; then
    declare -A LINK_VERIFIED
    # 记录各口原始状态，中断时按原状恢复（无条件置 UP 会误拉起运维主动禁用的口——v1.33.3）
    declare -A ORIG_STATE
    for _d in $DEVS; do
        _st=$(sudo mlxlink -d "$_d" -p 1 2>/dev/null | grep -iE "^State|Active|Link" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        ORIG_STATE[$_d]="${_st:-UP}"
    done
    trap 'for _d in $DEVS; do sudo mlxlink -d "$_d" -p 1 -a "${ORIG_STATE[$_d]:-UP}" >/dev/null 2>&1; done; exit 130' INT TERM
    for dev in $DEVS; do
        # 只验证 serial 不可读 且 未配对 的设备（跳过已通过 serial 配对的）
        if echo "$PAIRED_DEVS" | grep -qw "$dev"; then continue; fi
        # 检查该口是否可管理（有 mlxlink 权限且状态非 Down/disabled——注释原意，补状态判断）
        cur_state=$(sudo mlxlink -d "$dev" -p 1 2>/dev/null | grep -iE "^State|Active|Link" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        [ -z "$cur_state" ] && continue
        echo "$cur_state" | grep -qiE "down|disabled" && continue
        # 记录当前 Recommendation（联动基线）
        base_rec=$(sudo mlxlink -d "$dev" -p 1 2>/dev/null | grep -i "Recommendation" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        # 对每个其他未配对口做联动测试（只测 serial 不可读的，减少打扰）
        for other in $DEVS; do
            [ "$other" = "$dev" ] && continue
            echo "$PAIRED_DEVS" | grep -qw "$other" && continue
            [ -n "${LINK_VERIFIED[$other]:-}" ] && continue
            # down 掉 other → 看 dev 是否联动变化
            sudo mlxlink -d "$other" -p 1 -a DN >/dev/null 2>&1
            sleep 1
            new_rec=$(sudo mlxlink -d "$dev" -p 1 2>/dev/null | grep -i "Recommendation" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
            sudo mlxlink -d "$other" -p 1 -a UP >/dev/null 2>&1
            if [ -n "$base_rec" ] && [ -n "$new_rec" ] && [ "$base_rec" != "$new_rec" ]; then
                echo -e "  ${GREEN}$dev ↔ $other${NC}  (联动验证通过)"
                LINK_VERIFIED[$dev]="1"; LINK_VERIFIED[$other]="1"
                break
            fi
        done
    done
    # 未验证的（可能单端/未接）
    for dev in $DEVS; do
        if [ -z "${LINK_VERIFIED[$dev]:-}" ] && ! echo "$PAIRED_DEVS" | grep -qw "$dev"; then
            echo -e "  ${YELLOW}$dev: 未能验证配对（可能未连线或对端未上电）${NC}"
        fi
    done
    fi
fi

echo ""
echo -e "${GREEN}完成${NC}"
