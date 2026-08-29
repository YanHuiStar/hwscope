#!/bin/bash
# =============================================================================
# 报告解析回归测试 — test/report_regression.sh
# 用法: bash test/report_regression.sh <采集目录> [--update] [--keep]
#       bash test/report_regression.sh --all [--update]
#       HWSCOPE_SAMPLE_ROOT=<多机样本根> bash test/report_regression.sh --all
# 功能: 用固定采集样本跑报告生成，提取关键指标与基线比对——防解析器改动引入静默回归
#       （历史教训：AMD 多卡明细全显示 card0、内存通道数算成插槽数、表格列错位、1T9
#        容量误判——均只能靠真机样本发现；本脚本把真机验证固化为可重复的一条命令）
# 设计:
#   - 样本零污染：复制样本到临时目录再生成报告，原采集目录不动
#   - 基线只存指标摘要（几 KB，入库），采集数据不入仓库（output/ 已 gitignore）
#   - 纯 bash/awk 实现（与项目依赖一致，不引入 python）
# 指标（10 组）: 表格列数一致 / GPU / 内存 / PSU / PCIe 链路统计 / 磁盘 / NIC /
#                 JSON 字段与体积 / HTML 标签闭合 / 验收清单判定结果
# 退出码: 0=一致（或已更新） 1=存在差异 2=无基线/无样本
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_DIR="${SCRIPT_DIR}/baseline"

UPDATE=0; ALL=0; KEEP=0; SAMPLE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --update) UPDATE=1; shift ;;
        --all)    ALL=1; shift ;;
        --keep)   KEEP=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) [ -z "$SAMPLE" ] && SAMPLE="$1"; shift ;;
    esac
done

# ─── 指标提取：从生成报告提取关键指标（一行一项，可 diff 比对）───
extract_metrics() {
    local dir="$1"
    local md="${dir}/hwscope_report.md"
    local json="${dir}/hwscope_report.json"
    local html="${dir}/hwscope_report.html"
    local acc="${dir}/hwscope_acceptance.md"

    echo "# 报告解析回归指标（test/report_regression.sh）"

    # 1. 表格列数一致性（表头 vs 分隔行 vs 数据行——抓列错位/重复列/分隔段数不符）
    echo "[table_columns]"
    [ -f "$md" ] && awk '
        function ncols(s,  n,a) { n = split(s, a, "|"); return (n >= 2 ? n - 2 : 0) }
        /^\|/ {
            if (!in_tbl) { hdr = ncols($0); in_tbl = 1; seen_sep = 0; next }
            if (seen_sep == 0) {
                sep = ncols($0); seen_sep = 1
                if (sep != hdr) printf "  MISMATCH line %d: header %d cols, separator %d segs\n", NR, hdr, sep
                next
            }
            r = ncols($0)
            if (r != hdr) printf "  MISMATCH line %d: header %d cols, row %d cols: %.60s\n", NR, hdr, r, $0
            next
        }
        { in_tbl = 0 }
    ' "$md"
    echo "  table_rows=$(grep -c '^|' "$md" 2>/dev/null)"

    # 2. GPU（明细行数/型号/JSON 卡数——抓多卡全显示同一张卡）
    echo "[gpu]"
    echo "  gpu_detail_rows=$(awk '/^## GPU/{f=1;next} f&&/^\| [0-9]+ \|/{c++} f&&/^## /{f=0} END{print c+0}' "$md" 2>/dev/null)"
    # v1.48.6：model 从 JSON gpu.models 提取——全文 grep 会被术语表污染（机头报告术语表 NVLink/SXM 说明含 B300 字样 → 假型号）
    grep -oE '"models": "[^"]*"' "$json" 2>/dev/null | head -1 | cut -d'"' -f4 | sed 's/^/  model: /'
    # v1.48.13：改回纯 awk（零依赖——回归脚本不引入 python，与项目工具链一致）：
    #   gpu 段首个 count 字段即 GPU 数（v1.48.6 用 python 解析 details 数组，引入依赖且 Windows 需
    #   cygpath 转换；count 字段直取语义等价、无平台差异）
    echo "  gpu_json_count=$(awk '/"gpu":[[:space:]]*\{/{f=1;next} f&&/"count":[[:space:]]*"/{s=$0; sub(/.*"count":[[:space:]]*"/,"",s); sub(/".*/,"",s); print s+0; exit}' "$json" 2>/dev/null)"

    # 3. 内存（DIMM 行数/表头列/额定总量——抓位宽列与通道数解析）
    echo "[memory]"
    echo "  dimm_rows=$(awk '/^### 内存模块明细/{f=1;next} f&&/^\| [0-9]+ \|/{c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"
    grep -m1 '^| # | 插槽 | 容量' "$md" 2>/dev/null | sed 's/^/  header: /'
    grep -m1 '^| 物理额定总量' "$md" 2>/dev/null | sed 's/^/  /'

    # 4. PSU（行数——抓 PSU 三级回退解析失败）
    echo "[psu]"
    echo "  psu_rows=$(awk '/^### 电源模块明细/{f=1;next} f&&/^\| [0-9]+ \|/{c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"

    # 5. PCIe 链路统计（抓 bridge 判定/降速数变化）
    echo "[pcie]"
    grep -m1 '^| 链路统计 |' "$md" 2>/dev/null | sed 's/^/  /'
    echo "  pcie_appendix_rows=$(awk '/^## PCIe 链路明细（附录）/{f=1;next} f&&/^\| [0-9a-f][0-9a-f]:/{c++} f&&/^---$/{f=0} END{print c+0}' "$md" 2>/dev/null)"

    # 6. 磁盘（行数/容量——抓 1T9 等容量口径误判）
    echo "[disk]"
    echo "  disk_rows=$(awk '/^### 存储盘明细/{f=1;next} f&&/^\| [0-9]+ \|/{c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"
    grep -oE '\| (sd[a-z]+|nvme[0-9]+n[0-9]+) \|[^|]*\| [0-9.]+ ?[TG]B' "$md" 2>/dev/null | sort -u | head -6 | sed 's/^/  /'

    # 7. NIC（行数/表头列——抓端口列与 Link 状态列）
    echo "[nic]"
    echo "  nic_rows=$(awk '/^### 网络适配器明细/{f=1;next} f&&/^\| [0-9]+ \|/{c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"
    grep -m1 '^| # | 接口 | BDF |' "$md" 2>/dev/null | sed 's/^/  header: /'

    # 8. JSON 完整性与关键字段（抓占位/丢失字段）
    echo "[json]"
    echo "  json_bytes=$(wc -c < "$json" 2>/dev/null | tr -d ' ')"
    grep -oE '"(machine_id|platform|gpu_count|mem_total|psu_count|disk_count)"' "$json" 2>/dev/null | sort | uniq -c | head -6 | sed 's/^/  /'

    # 9. HTML 标签闭合（改 MD 模板后须回归——AGENTS.md 要求）
    echo "[html]"
    if [ -f "$html" ]; then
        echo "  html_table_open=$(grep -o '<table>' "$html" 2>/dev/null | wc -l)"
        echo "  html_table_close=$(grep -o '</table>' "$html" 2>/dev/null | wc -l)"
        echo "  html_bytes=$(wc -c < "$html" 2>/dev/null | tr -d ' ')"
    fi

    # 10. 验收清单判定结果（15 项结果分布）
    echo "[acceptance]"
    [ -f "$acc" ] && grep -oE '(PASS|FAIL|WARN|N/A)' "$acc" 2>/dev/null | sort | uniq -c | head -6 | sed 's/^/  /'
}

# ─── 单样本执行 ───
run_one() {
    local sample="$1" rc=0
    [ -d "$sample" ] || { echo "[ERROR] 目录不存在: $sample"; return 1; }
    local sn
    sn=$(basename "$sample")
    echo "样本: ${sn}"

    # 样本零污染：只备份/恢复报告文件（不复制整个采集目录——数百日志文件在 Windows 下
    # cp -r 极慢，实测 180s 都跑不完；报告文件仅 6 个，秒级完成）
    local tmp
    tmp=$(mktemp -d 2>/dev/null || echo "/tmp/hwscope_reg_$$")
    local bak="${tmp}/orig_reports"
    mkdir -p "$bak"
    local f
    for f in hwscope_report.md hwscope_report.json hwscope_report.txt hwscope_report.html \
             hwscope_acceptance.md hwscope_acceptance.html; do
        [ -f "${sample}/${f}" ] && cp "${sample}/${f}" "${bak}/" 2>/dev/null
    done

    bash "${PROJECT_DIR}/report/report.sh" "$sample" >/dev/null 2>&1
    bash "${PROJECT_DIR}/report/report.sh" "$sample" --acceptance >/dev/null 2>&1

    local cur="${tmp}/${sn}.metrics"
    extract_metrics "$sample" > "$cur"
    # 还原原有报告文件（样本目录回到跑测前状态）
    for f in "${bak}"/*; do
        [ -f "$f" ] && cp "$f" "${sample}/$(basename "$f")" 2>/dev/null
    done
    local base="${BASELINE_DIR}/${sn}.txt"

    if [ "$UPDATE" -eq 1 ]; then
        mkdir -p "$BASELINE_DIR"
        cp "$cur" "$base"
        echo "  [BASELINE] 已写入: test/baseline/${sn}.txt（$(wc -l < "$base" | tr -d ' ') 行指标）"
    elif [ -f "$base" ]; then
        if diff -q "$base" "$cur" >/dev/null 2>&1; then
            echo "  [OK] 与基线一致（无解析回归）"
        else
            echo "  [DIFF] 与基线存在差异（解析回归候选）:"
            diff "$base" "$cur" 2>/dev/null | head -30 | sed 's/^/    /'
            rc=1
        fi
    else
        echo "  [WARN] 无基线（先跑 --update 建立）"
        rc=2
    fi

    [ "$KEEP" -eq 1 ] && cp "$cur" "${BASELINE_DIR}/${sn}.candidate.txt" 2>/dev/null
    [ "$KEEP" -eq 1 ] || rm -rf "$tmp"
    return $rc
}

# ─── 主流程 ───
if [ "$ALL" -eq 1 ]; then
    root="${HWSCOPE_SAMPLE_ROOT:-${PROJECT_DIR}/output}"
    found=0; fail=0
    for d in "${root}"/*/; do
        [ -d "$d" ] || continue
        if [ ! -d "${d}gpu" ] && [ ! -d "${d}motherboard" ] && [ ! -f "${d}hwscope_report.md" ]; then
            continue
        fi
        found=$((found+1))
        run_one "${d%/}" || fail=$((fail+1))
        echo ""
    done
    if [ "$found" -eq 0 ]; then
        echo "[WARN] 未找到采集样本目录（可用 HWSCOPE_SAMPLE_ROOT=<目录> 指定多机样本根）"
        exit 2
    fi
    echo "汇总: ${found} 个样本，${fail} 个差异"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

[ -z "$SAMPLE" ] && { echo "用法: bash test/report_regression.sh <采集目录> [--update] [--keep]"; echo "     bash test/report_regression.sh --all [--update]"; exit 1; }
run_one "${SAMPLE%/}"
exit $?
