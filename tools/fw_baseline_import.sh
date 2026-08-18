#!/bin/bash
# =============================================================================
# HwScope — 固件基线自动导入
# tools/fw_baseline_import.sh
# 用法: bash tools/fw_baseline_import.sh <基准机采集目录> [--diff|--apply]
#       bash tools/fw_baseline_import.sh --file baseline.tsv [--diff|--apply]
# 功能: 从基准机采集目录（firmware/fw_compliance.csv）或手工表格文件生成
#       conf/fw_required.txt 推荐版本基线，替代人工逐条录入。
# 场景: 批量交付——先采一台"标准机"（厂商验收通过），把它的固件版本固化为基线，
#       其余机器由 15_firmware 对照该基线判 合规/落后。
# 模式: --diff  仅显示将生成/变化的条目（默认）
#       --apply 写入 conf/fw_required.txt（自动备份 .bak）
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FW_REQUIRED="${SCRIPT_DIR}/conf/fw_required.txt"

usage() {
    echo "用法: $0 <基准机采集目录> [--diff|--apply]"
    echo "      $0 --file baseline.tsv [--diff|--apply]"
    echo "来源: 基准机采集目录的 firmware/fw_compliance.csv，或表格文件（组件|型号模式|版本|备注）"
    echo "模式: --diff 显示差异（默认） | --apply 写入 conf/fw_required.txt（备份 .bak）"
    exit 0
}

# ─── 参数解析 ───
SRC_DIR=""; SRC_FILE=""; MODE="diff"
while [ $# -gt 0 ]; do
    case "$1" in
        --file) SRC_FILE="$2"; shift 2 ;;
        --diff) MODE="diff"; shift ;;
        --apply) MODE="apply"; shift ;;
        -h|--help) usage ;;
        *) [ -z "$SRC_DIR" ] && SRC_DIR="$1"; shift ;;
    esac
done
[ -z "$SRC_DIR" ] && [ -z "$SRC_FILE" ] && { echo -e "\033[0;31m[ERROR] 需要基准机采集目录或 --file 表格文件\033[0m"; usage; }

TMP_GEN=$(mktemp)
trap 'rm -f "$TMP_GEN"' EXIT

# ─── 生成基线条目（组件|型号模式|版本|来源） ───
if [ -n "$SRC_FILE" ]; then
    # 表格文件：组件|型号模式|版本|备注（跳过 # 注释与空行）
    [ ! -f "$SRC_FILE" ] && { echo -e "\033[0;31m[ERROR] 表格文件不存在: ${SRC_FILE}\033[0m"; exit 1; }
    grep -vE '^\s*#|^\s*$' "$SRC_FILE" > "$TMP_GEN"
else
    CSV="${SRC_DIR}/firmware/fw_compliance.csv"
    [ ! -f "$CSV" ] && { echo -e "\033[0;31m[ERROR] 缺少固件合规数据: ${CSV}（请先对基准机跑 15_firmware）\033[0m"; exit 1; }
    # fw_compliance.csv 行: component|device|current|baseline|status|note
    # 设备 → 型号模式：提取设备名中的型号特征（GPU0 (NVIDIA B300) → NVIDIA B300；BDF ConnectX-8 → ConnectX-8；本地BMC → 空=全部）
    while IFS='|' read -r comp dev cur base st note; do
        [ -z "$comp" ] && continue
        case "$comp" in \#*) continue ;; esac
        [ -z "$cur" ] || [ "$cur" = "N/A" ] && continue
        pat=""
        case "$comp" in
            GPU_VBIOS) pat=$(echo "$dev" | grep -oE "NVIDIA [A-Za-z0-9]+|RTX [A-Za-z0-9]+|Tesla [A-Za-z0-9]+|Quadro [A-Za-z0-9]+" | head -1) ;;
            NIC)       pat=$(echo "$dev" | grep -oE "ConnectX-[0-9]+( Lx| Dx)?|BlueField[^ ]*" | head -1) ;;
            BMC|NVSWITCH) pat="" ;;
            *)         pat="" ;;
        esac
        echo "${comp}|${pat}|${cur}|自动导入自基准机 ${SRC_DIR}" >> "$TMP_GEN"
    done < <(grep -v "^#" "$CSV" 2>/dev/null | grep -v "^$" | grep -v "^summary:")
    # 去重（同组件+型号模式只留一条）
    awk -F'|' '!seen[$1"|"$2]++' "$TMP_GEN" > "${TMP_GEN}.u" && mv "${TMP_GEN}.u" "$TMP_GEN"
fi

[ ! -s "$TMP_GEN" ] && { echo -e "\033[0;31m[ERROR] 未生成任何基线条目（数据为空）\033[0m"; exit 1; }

echo -e "\033[0;36m========================================\033[0m"
echo -e "\033[0;36m  固件基线导入（$( [ "$MODE" = "apply" ] && echo APPLY || echo DIFF )）\033[0m"
echo -e "\033[0;36m========================================\033[0m"
echo "将生成的基线条目:"
echo ""
printf '%-12s %-24s %-16s %s\n' "组件" "型号模式" "推荐版本" "来源"
printf '%-12s %-24s %-16s %s\n' "----" "--------" "--------" "----"
cat "$TMP_GEN" | while IFS='|' read -r c p v src; do
    printf '%-12s %-24s %-16s %s\n' "$c" "${p:--}" "$v" "$src"
done
echo ""

# ─── 差异对比（与现有基线） ───
CHANGED=0; NEW=0
declare -A EXIST
if [ -f "$FW_REQUIRED" ]; then
    while IFS= read -r line; do
        case "$line" in \#*|"") continue ;; esac
        IFS='|' read -r bc bp br bn <<< "$line"
        EXIST["${bc}|${bp}"]="$br"
    done < "$FW_REQUIRED"
fi
DIFF_LINES=""
while IFS='|' read -r c p v src; do
    key="${c}|${p}"
    if [ -n "${EXIST[$key]:-}" ]; then
        if [ "${EXIST[$key]}" != "$v" ]; then
            CHANGED=$((CHANGED+1))
            DIFF_LINES="${DIFF_LINES}  ~ ${c} ${p:--}: ${EXIST[$key]} → ${v}"$'\n'
        fi
    else
        NEW=$((NEW+1))
        DIFF_LINES="${DIFF_LINES}  + ${c} ${p:--}: ${v}"$'\n'
    fi
done < "$TMP_GEN"
echo "差异: 新增 ${NEW} 条, 变化 ${CHANGED} 条"
[ -n "$DIFF_LINES" ] && echo -e "${DIFF_LINES}"

if [ "$MODE" = "diff" ]; then
    echo -e "\033[1;33m[INFO] 预览模式（默认）：加 --apply 写入 ${FW_REQUIRED}\033[0m"
    exit 0
fi

# ─── 写入（备份原文件） ───
[ -f "$FW_REQUIRED" ] && cp "$FW_REQUIRED" "${FW_REQUIRED}.bak"
{
    echo "# ============================================================================="
    echo "# HwScope 固件推荐版本基线（conf/fw_required.txt）— 自动导入生成 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 来源: $( [ -n "$SRC_FILE" ] && echo "表格 ${SRC_FILE}" || echo "基准机采集 ${SRC_DIR}" )"
    echo "# 格式: 组件|型号模式|推荐版本|备注（# 注释跳过；型号模式空 = 该组件全部设备）"
    echo "# 旧基线已备份: ${FW_REQUIRED}.bak"
    echo "# ============================================================================="
    echo ""
    cat "$TMP_GEN"
    echo ""
    echo "# 如需手动补充厂商手册条目，按同样格式追加即可"
} > "$FW_REQUIRED"
echo -e "\033[0;32m[OK] 已写入 ${FW_REQUIRED}（${NEW} 新增 / ${CHANGED} 变化；旧文件 → .bak）\033[0m"
