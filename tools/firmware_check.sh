#!/bin/bash
# =============================================================================
# HwScope — 固件版本核对
# tools/firmware_check.sh
# 用法: sudo bash tools/firmware_check.sh [--save-baseline] [--diff]
# 功能: GPU VBIOS / BMC FW / CX8 NIC FW / NVSwitch FW 一键汇总
#   --save-baseline  保存当前版本为基线（验收时用）
#   --diff           与基线对比，标出变化
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"

BASE_DIR="${SCRIPT_DIR}/logs/fw_check"
mkdir -p "$BASE_DIR"
BASELINE="${BASE_DIR}/fw_baseline.txt"
NOW="${BASE_DIR}/fw_now_$(date '+%Y%m%d%H%M%S').txt"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  固件版本核对${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

{
    echo "# 固件清单 $(date '+%Y-%m-%d %H:%M:%S')"

    # ─── 1. GPU VBIOS ───
    echo "[GPU]"
    if check_cmd nvidia-smi; then
        nvidia-smi --query-gpu=index,vbios_version,driver_version --format=csv,noheader 2>/dev/null \
            | sed 's/^/  /'
    else
        echo "  (nvidia-smi 不存在)"
    fi

    # ─── 2. BMC ───
    echo "[BMC]"
    if check_cmd ipmitool; then
        ipmitool mc info 2>/dev/null | grep -E "Firmware Revision|Manufacturer ID" | sed 's/^/  /'
    else
        echo "  (ipmitool 不存在)"
    fi

    # ─── 3. NIC 固件 (CX5/CX6/CX7/CX8) ───
    echo "[NIC]"
    if check_cmd mlxfwmanager; then
        mlxfwmanager --query 2>/dev/null | grep -E "Device Type|Description|Firmware Version|PSID" | sed 's/^/  /'
    else
        echo "  (mlxfwmanager 不存在)"
    fi

    # ─── 4. NVSwitch ───
    echo "[NVSwitch]"
    if check_cmd nvswitch; then
        nvswitch --version 2>&1 | sed 's/^/  /'
    else
        echo "  (nvswitch 不存在)"
    fi
} > "$NOW"

cat "$NOW"
echo ""

# ─── 模式处理 ───
case "$1" in
    --save-baseline)
        if [ -f "$BASELINE" ]; then
            read -p "  ⚠ 已有基线 $BASELINE，覆盖? (y/N) " -r confirm
            [[ ! "$confirm" =~ ^[Yy] ]] && { echo "  已取消"; exit 0; }
            cp "$BASELINE" "${BASELINE}.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null   # 旧基线备份防误覆盖
        fi
        cp "$NOW" "$BASELINE"
        echo -e "${GREEN}[OK] 已保存为基线: $BASELINE${NC}"
        ;;
    --diff)
        if [ ! -f "$BASELINE" ]; then
            echo -e "${YELLOW}[WARN] 无基线，先用 --save-baseline 保存${NC}"
        else
            DIFF=$(diff "$BASELINE" "$NOW" | grep -E "^[<>]" | grep -v "^[<>] #")
            if [ -n "$DIFF" ]; then
                echo -e "${YELLOW}⚠ 与基线差异:${NC}"
                echo "$DIFF" | sed 's/^/  /'
            else
                echo -e "${GREEN}✓ 与基线完全一致${NC}"
            fi
        fi
        ;;
    *)
        echo "提示: --save-baseline 存基线 (验收时用) | --diff 对比基线"
        ;;
esac
echo ""
echo "本次清单: $NOW   基线: $BASELINE"
