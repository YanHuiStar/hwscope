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
#   -j, --jobs N   并行度（v1.55.0 起**默认并行**：nproc/2，限 2..6）
#                  --regression/--update 会共用基线文件，自动降为 -j1 串行
# 输出: 每样本判定一行 + 汇总（agent 直接消费）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# 桌面路径自动探测（Windows git-bash: /c/... 或 C:/...；WSL: /mnt/c/...）
# v1.48.87：不再硬编码用户名——原实现写死 "/mnt/c/Users/yanhu/Desktop"，
#   换机器/换账号（实测本机是 15707）即探测失败 → 报"[ERROR] 无有效样本目录"。
#   改为：① DESKTOP_OVERRIDE 显式指定 ② USERPROFILE 推导（git-bash 下已设）
#         ③ 扫 /mnt/c/Users/*/Desktop（排除 Public/Default 等公共账号）
DESKTOP=""
if [ -n "${DESKTOP_OVERRIDE:-}" ] && [ -d "${DESKTOP_OVERRIDE}" ]; then
    DESKTOP="$DESKTOP_OVERRIDE"
fi
if [ -z "$DESKTOP" ] && [ -n "${USERPROFILE:-}" ]; then
    _up=$(printf '%s' "$USERPROFILE" | sed 's|\\|/|g')          # C:\Users\x -> C:/Users/x
    _up=$(printf '%s' "$_up" | sed 's|^\([A-Za-z]\):|/\L\1|')   # C:/... -> /c/...
    [ -d "${_up}/Desktop" ] && DESKTOP="${_up}/Desktop"
fi
if [ -z "$DESKTOP" ]; then
    # v1.49.14：同机多账号时不能取"第一个非公共账号"——glob 按字典序展开，
    #   实测 /mnt/c/Users/Star/Desktop（另一账号，空目录）排在 yanhu 之前被锁定 →
    #   自动发现 0 份 → [ERROR] 无有效样本目录。改为：优先选**真正含采集目录**的候选，
    #   都为空才退回第一个存在的（保证探测不返回空）。
    _best=""; _fallback=""
    for _cand in /mnt/c/Users/*/Desktop /c/Users/*/Desktop "C:/Users/"*/Desktop; do
        [ -d "$_cand" ] || continue
        case "$_cand" in
            *Public*|*Default*|*"All Users"*) continue ;;
        esac
        [ -z "$_fallback" ] && _fallback="$_cand"
        if ls "$_cand"/*/hwscope_report.md >/dev/null 2>&1; then
            _best="$_cand"; break
        fi
    done 2>/dev/null
    DESKTOP="${_best:-$_fallback}"
fi

# v1.48.27：默认自动发现（隐私红线：真实 SN 不进 git——不硬编码样本 SN；
# 无参数时扫描桌面根下含 hwscope_report.md 的采集目录，或 --samples 指定）
discover_samples() {
    local root="${1:-$DESKTOP}" d
    [ -d "$root" ] || return 0
    for d in "$root"/*/; do
        [ -d "$d" ] || continue
        if [ -f "${d}hwscope_report.md" ] || [ -d "${d}gpu" ]; then
            echo "${d%/}"
        fi
    done 2>/dev/null
}
DEFAULT_SN=""

REGRESSION=0; UPDATE=0; SAMPLES=""; JOBS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --regression) REGRESSION=1; shift ;;
        --update)     UPDATE=1; REGRESSION=1; shift ;;
        -j|--jobs)    [ $# -ge 2 ] || { echo "[ERROR] -j 需要并行数（如 -j4）" >&2; exit 1; }; JOBS="$2"; shift 2 ;;
        # 兼容紧凑写法 -j4 / --jobs=4（实测漏了这条：-j1 被当目录名传下去 → 多算一份、报 FAIL）
        -j[0-9]*|--jobs=[0-9]*) JOBS="${1#-j}"; JOBS="${JOBS#--jobs=}"; shift ;;
        --samples)    [ $# -ge 2 ] || { echo "[ERROR] --samples 需要 SN 列表（如 --samples SN1,SN2）" >&2; exit 1; }; SAMPLES="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) dirs+=("$1"); shift ;;
    esac
done

# ─── 并行度（v1.55.0：默认并行）───────────────────────────────────────────────
# 每份样本只读自己的采集目录、只写自己的报告文件，互不共享状态 → 并行安全。
#   实测（8 核，报告在 Windows 盘上走 9p）：4 份串行 86.8s / 并行 48.1s，约 1.8×；
#   88 份全量从 ~20 分钟降到 ~7 分钟。并行度取 nproc/2 并限制在 2..6（再高只是争 IO）。
# 但 --regression/--update 会写**同一份基线文件**，必须串行。
if [ -z "$JOBS" ]; then
    JOBS=$(( $(nproc 2>/dev/null || echo 2) / 2 ))
    [ "$JOBS" -lt 2 ] 2>/dev/null && JOBS=2
    [ "$JOBS" -gt 6 ] 2>/dev/null && JOBS=6
fi
case "$JOBS" in ''|*[!0-9]*) echo "[ERROR] -j 需要正整数" >&2; exit 1 ;; esac
if [ "$REGRESSION" -eq 1 ] && [ "$JOBS" -gt 1 ]; then
    echo "[INFO] --regression/--update 共用基线文件，本次串行执行（-j1）"
    JOBS=1
fi

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

echo "=== 批量重生成报告（${#TARGETS[@]} 份样本，v1.55.0，并行度 ${JOBS}）==="

# 单份重生成（并行 worker 与串行分支共用）——输出一行 "SN<TAB>OK/FAIL<TAB>判定"
regen_one() {
    local d="$1" sn out_json out_acc verdict
    sn=$(basename "$d")
    # v1.49.14：显式 bash 调用——report.sh 在仓库里没有可执行位（100644），
    #   直接执行报 Permission denied → 输出为空 → grep -c=0 → 明明成功却标 FAIL
    out_json=$(bash "${PROJECT_DIR}/report/report.sh" "$d" 2>&1 | grep -cE "生成完成")
    # v1.49.14：原判据 "验收清单.*(md|html)" 与 report.sh 的实际输出格式不符 → 恒为 0
    #   → 验收明明生成成功却报 "验收: FAIL"。（--acceptance 与默认分支独立，必须单独调用）
    out_acc=$(bash "${PROJECT_DIR}/report/report.sh" "$d" --acceptance 2>&1 | grep -cE "生成完成|验收清单")
    verdict=$(grep -oE "\*\*判定\*\* \| [^|]+" "$d/hwscope_acceptance.md" 2>/dev/null | sed 's/\*\*判定\*\* | //; s/\*\*[[:space:]]*$//; s/^[[:space:]]*\*\*//; s/^[[:space:]]*//')
    [ -z "$verdict" ] && verdict="（验收未生成）"
    if [ "$out_json" -gt 0 ] 2>/dev/null && [ "$out_acc" -gt 0 ] 2>/dev/null; then
        printf '%s\tOK\t%s\n' "$sn" "$verdict"
    else
        printf '%s\tFAIL\t%s\n' "$sn" "$verdict"
    fi
}

pass=0; fail=0
RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/regen_results.XXXXXX")

if [ "$JOBS" -le 1 ]; then
    # ── 串行（--regression/--update 或显式 -j1）──────────────────────────────
    for d in "${TARGETS[@]}"; do
        sn=$(basename "$d")
        echo ""
        echo "── ${sn} ──"
        regen_one "$d" | tee -a "$RESULT_FILE" | awk -F'\t' '{printf "  报告+验收: %s | 判定: %s\n", $2, $3}'
        # 回归对比（可选，串行保证基线不被并发写）
        if [ "$REGRESSION" -eq 1 ]; then
            if [ "$UPDATE" -eq 1 ]; then
                bash "${SCRIPT_DIR}/report_regression.sh" "$d" --update 2>&1 | grep -E "BASELINE" | sed 's/^/  /'
            else
                bash "${SCRIPT_DIR}/report_regression.sh" "$d" 2>&1 | grep -E "\[OK\]|\[DIFF\]|\[WARN\]" | head -2 | sed 's/^/  /'
            fi
        fi
    done
else
    # ── 并行（默认）：信号量控制并发，结果统一收集后按输入顺序打印 ──────────────
    running=0
    for d in "${TARGETS[@]}"; do
        while [ "$running" -ge "$JOBS" ]; do
            wait -n 2>/dev/null || wait
            running=$((running-1))
        done
        ( regen_one "$d" >> "$RESULT_FILE" ) &
        running=$((running+1))
    done
    wait
    while IFS=$'\t' read -r sn st vd; do
        [ -z "$sn" ] && continue
        printf "  %-22s %-5s %s\n" "$sn" "$st" "$vd"
    done < "$RESULT_FILE"
fi

pass=$(grep -c $'\tOK\t' "$RESULT_FILE" 2>/dev/null); pass=${pass:-0}
fail=$(grep -c $'\tFAIL\t' "$RESULT_FILE" 2>/dev/null); fail=${fail:-0}
rm -f "$RESULT_FILE"


echo ""
echo "=== 汇总: ${pass} 成功 / ${fail} 失败（${#TARGETS[@]} 份）==="
[ "$fail" -eq 0 ] || exit 1
