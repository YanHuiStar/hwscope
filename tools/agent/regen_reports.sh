#!/bin/bash
# =============================================================================
# HwScope - 批量重新生成报告（agent 专用，v1.48.18）
# tools/agent/regen_reports.sh
# 用法:
#   bash tools/agent/regen_reports.sh                       # 桌面 6 份默认样本
#   bash tools/agent/regen_reports.sh <目录...>             # 指定样本（任意路径）
#   bash tools/agent/regen_reports.sh --samples SN1,SN2     # 桌面按 SN 选跑
# 选项:
#   --regression   生成后跑报告回归对比（与 tools/agent/baseline/ 比对）
#   --update       生成后更新回归基线（确认改动正确后）
#   --acceptance   生成验收清单（默认已含）
# 输出: 每样本判定一行 + 汇总（agent 直接消费）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# 桌面路径自动探测（Windows git-bash: /c/... 或 C:/...；WSL: /mnt/c/...）
DESKTOP=""
for _cand in "/mnt/c/Users/yanhu/Desktop" "/c/Users/yanhu/Desktop" "C:/Users/yanhu/Desktop"; do
    [ -d "$_cand" ] && DESKTOP="$_cand" && break
done
[ -z "$DESKTOP" ] && DESKTOP="${DESKTOP_OVERRIDE:-}"

# v1.48.27：默认自动发现（隐私红线：真实 SN 不进 git——不硬编码样本 SN；
# 无参数时扫描桌面根下含 hwscope_report.md 的采集目录，或 --samples 指定）
discover_samples() {
    local root="${1:-$DESKTOP}" d
    for d in "$root"/*/; do
        [ -d "$d" ] || continue
        [ -f "${d}hwscope_report.md" ] || [ -d "${d}gpu" ] && echo "${d%/}"
    done 2>/dev/null
}
DEFAULT_SN=""

REGRESSION=0; UPDATE=0; SAMPLES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --regression) REGRESSION=1; shift ;;
        --update)     UPDATE=1; REGRESSION=1; shift ;;
        --samples)    SAMPLES="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) dirs+=("$1"); shift ;;
    esac
done

# ─── 样本目录解析：参数目录 > --samples SN > 桌面默认（自动发现）───
declare -a TARGETS=()
if [ "${#dirs[@]}" -gt 0 ]; then
    TARGETS=("${dirs[@]}")
elif [ -n "$SAMPLES" ]; then
    for sn in ${SAMPLES//,/ }; do
        [ -d "${DESKTOP}/${sn}" ] && TARGETS+=("${DESKTOP}/${sn}") || echo "[WARN] 样本不存在: ${DESKTOP}/${sn}"
    done
else
    DEFAULT_SN="$(discover_samples "$DESKTOP" | while read -r d; do basename "$d"; done | tr '\n' ' ')"
    for sn in $DEFAULT_SN; do
        [ -d "${DESKTOP}/${sn}" ] && TARGETS+=("${DESKTOP}/${sn}") || echo "[WARN] 样本不存在: ${DESKTOP}/${sn}"
    done
fi

[ "${#TARGETS[@]}" -eq 0 ] && { echo "[ERROR] 无有效样本目录"; exit 2; }

echo "=== 批量重生成报告（${#TARGETS[@]} 份样本，v1.48.18）==="
pass=0; fail=0
for d in "${TARGETS[@]}"; do
    sn=$(basename "$d")
    echo ""
    echo "── ${sn} ──"
    # 报告四件套 + 验收（capture 输出，失败不影响下一份）
    out_json=$("${PROJECT_DIR}/report/report.sh" "$d" 2>&1 | grep -cE "生成完成" )
    out_acc=$("${PROJECT_DIR}/report/report.sh" "$d" --acceptance 2>&1 | grep -cE "验收清单.*(md|html)" )
    verdict=$(grep -oE "\*\*判定\*\* \| [^|]+" "$d/hwscope_acceptance.md" 2>/dev/null | sed 's/\*\*判定\*\* | //')
    [ -z "$verdict" ] && verdict="（验收未生成）"
    echo "  报告: $([ "$out_json" -gt 0 ] 2>/dev/null && echo OK || echo FAIL) | 验收: $([ "$out_acc" -gt 0 ] 2>/dev/null && echo OK || echo FAIL)"
    echo "  判定: $verdict"
    if [ "$out_json" -gt 0 ] 2>/dev/null && [ "$out_acc" -gt 0 ] 2>/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
    fi
    # 回归对比（可选）
    if [ "$REGRESSION" -eq 1 ]; then
        if [ "$UPDATE" -eq 1 ]; then
            bash "${SCRIPT_DIR}/report_regression.sh" "$d" --update 2>&1 | grep -E "BASELINE" | sed 's/^/  /'
        else
            bash "${SCRIPT_DIR}/report_regression.sh" "$d" 2>&1 | grep -E "\[OK\]|\[DIFF\]|\[WARN\]" | head -2 | sed 's/^/  /'
        fi
    fi
done

echo ""
echo "=== 汇总: ${pass} 成功 / ${fail} 失败（${#TARGETS[@]} 份）==="
[ "$fail" -eq 0 ] || exit 1
