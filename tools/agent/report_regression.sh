#!/bin/bash
# =============================================================================
# 报告解析回归测试 — tools/agent/report_regression.sh（agent 开发验证工具）
# 用法: bash tools/agent/report_regression.sh <采集目录> [--update] [--keep] [--samples SN1,SN2]
#       bash tools/agent/report_regression.sh --all [--update]
#       HWSCOPE_SAMPLE_ROOT=<多机样本根> bash tools/agent/report_regression.sh --all
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
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE_DIR="${SCRIPT_DIR}/baseline"

UPDATE=0; ALL=0; KEEP=0; SAMPLE=""; SAMPLES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --update) UPDATE=1; shift ;;
        --all)    ALL=1; shift ;;
        --samples) [ $# -ge 2 ] || { echo "[ERROR] --samples 需要 SN 列表（如 --samples SN1,SN2）" >&2; exit 1; }; SAMPLES="$2"; shift 2 ;;
        --keep)   KEEP=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) [ -z "$SAMPLE" ] && SAMPLE="$1"; shift ;;
    esac
done

# v1.48.27：SN→平台语义名映射（隐私红线：真实 SN 不进 git——基线文件按语义名命名
# h200/a100/b200/b300/amd_oam/headless，脚本内零硬编码 SN；采集目录名仍可作参数）
sn_to_semantic() {
    local dir="$1" json model cnt
    json="${dir}/hwscope_report.json"
    [ -f "$json" ] && {
        model=$(grep -oE '"models": "[^"]*"' "$json" 2>/dev/null | head -1 | cut -d'"' -f4)
        cnt=$(awk '/"gpu":[[:space:]]*\{/{f=1;next} f&&/"count":[[:space:]]*"/{s=$0; sub(/.*"count":[[:space:]]*"/,"",s); sub(/".*/,"",s); print s+0; exit}' "$json" 2>/dev/null)
    }
    [ -z "$model" ] && [ -f "${dir}/gpu/gpu_inventory.csv" ] && model=$(grep -m1 -iE "H200|A100|B200|B300|MI300|MI250" "${dir}/gpu/gpu_inventory.csv" 2>/dev/null | head -c 200)
    case "$model" in
        *H200*)   echo "h200" ;;
        *B200*)   echo "b200" ;;
        *B300*)   echo "b300" ;;
        *A100*)   echo "a100" ;;
        *MI300*|*MI250*|*MI325*|*AMD*) echo "amd_oam" ;;
        *) echo "headless" ;;
    esac
}

# ─── 指标提取：从生成报告提取关键指标（一行一项，可 diff 比对）───
extract_metrics() {
    local dir="$1"
    local md="${dir}/hwscope_report.md"
    local json="${dir}/hwscope_report.json"
    local html="${dir}/hwscope_report.html"
    local acc="${dir}/hwscope_acceptance.md"

    echo "# 报告解析回归指标（tools/agent/report_regression.sh）"

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

    # 4b. 明细表「真值 → 占位符」防回归（v1.49.23）
    #   为什么需要：行数/字节数类指标**完全看不出**"整列真实值集体变成 —" 这种回归——本项目已两次踩到
    #   （PSU「当前功耗」列因命名不匹配整列丢失、NIC PSID 因坏兜底整列 N/A），而 psu_rows / json_bytes
    #   都没变。这里数"该列有多少个非占位符值"：值变少即说明解析退回了占位符，回归立刻可见。
    echo "[values]"
    echo "  psu_power_values=$(awk -F'|' '/^### 电源模块明细/{f=1;next} f&&/^\| [0-9]+ \|/{v=$(NF-1); gsub(/^[ \t]+|[ \t]+$/,"",v); if (v!="" && v!="—" && v!="N/A" && v!="-") c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"
    echo "  nic_psid_values=$(awk -F'|' '/^### 网络适配器明细（NIC）$/{f=1;next} f&&/^\| [0-9]+ \|/{v=$12; gsub(/^[ \t]+|[ \t]+$/,"",v); if (v!="" && v!="—" && v!="N/A" && v!="-") c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"
    echo "  nic_sn_values=$(awk -F'|' '/^### 网络适配器明细（NIC）$/{f=1;next} f&&/^\| [0-9]+ \|/{v=$7; gsub(/^[ \t]+|[ \t]+$/,"",v); if (v!="" && v!="—" && v!="N/A" && v!="-") c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"
    echo "  dimm_sn_values=$(awk -F'|' '/^### 内存模块明细/{f=1;next} f&&/^\| [0-9]+ \|/{v=$6; gsub(/^[ \t]+|[ \t]+$/,"",v); if (v!="" && v!="—" && v!="N/A" && v!="-") c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"
    echo "  nic_link_state_values=$(awk -F'|' '/^### 网络适配器明细（NIC）$/{f=1;next} f&&/^\| [0-9]+ \|/{v=$13; gsub(/^[ \t]+|[ \t]+$/,"",v); if (v!="" && v!="—" && v!="N/A" && v!="-") c++} f&&/^#/{f=0} END{print c+0}' "$md" 2>/dev/null)"

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

    # 11. 硬件概览（v1.49.9 补盲区）
    #   原指标集只覆盖行数类（rows/bytes），「硬件概览」整块**不在回归保护内**——
    #   实测把网卡单位由「口」改「张」后回归 0 差异，是手工核验才发现的。
    #   而硬件概览恰是客户最先看、也最该防误改的部分（配置单对账依据）。
    #   只取「项目|单位|数量」三列，**跳过描述列**——描述里含机箱 SN 等机器标识，
    #   纳入基线会违反"文档/指标不含真实标识"的红线。
    echo "[acceptance_hw]"
    if [ -f "$acc" ]; then
        sed -n '/硬件概览/,/验收信息/p' "$acc" 2>/dev/null \
            | grep -E '^\| ' \
            | awk -F'|' '{
                p=$2; u=$4; c=$5
                gsub(/^[ \t]+|[ \t]+$/, "", p)
                gsub(/^[ \t]+|[ \t]+$/, "", u)
                gsub(/^[ \t]+|[ \t]+$/, "", c)
                if (p == "项目" || p == "") next
                printf "  %s | %s | %s\n", p, u, c
              }'
    fi
}

# ─── v1.48.74：机器指纹（同源判定）───
# 同型号多台机器共用一个语义名基线文件（如桌面 3 台 B300 → 都映射 baseline/b300.txt）；
# 拿 B 台样本比 A 台基线必然满屏差异（网卡/盘/PCIe 数量本来就不同），但那不是解析回归。
# 办法：比对前先查"机器指纹"（报告里的硬件计数，不含 SN/机器标识）——
#   指纹一致 → 同源，差异 = 真回归候选（照常报警）
#   指纹不符 → 不同源，跳过并提示（不误报）
# 向后兼容：旧基线（指标行齐全）同样能提取到指纹；提不到则不判同源（退回原比对行为）
source_fingerprint() {
    grep -E "^  (gpu_json_count|nic_rows|dimm_rows|disk_rows|psu_rows|pcie_appendix_rows)=" "$1" 2>/dev/null | sort
}

# ─── 单样本执行 ───
run_one() {
    local sample="$1" rc=0
    LAST_RESULT="ok"
    [ -d "$sample" ] || { echo "[ERROR] 目录不存在: $sample"; return 1; }
    local sn sem
    sn=$(basename "$sample")
    sem=$(sn_to_semantic "$sample")
    echo "样本: ${sn}（语义: ${sem}）"

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
    local base="${BASELINE_DIR}/${sem}.txt"

    if [ "$UPDATE" -eq 1 ]; then
        mkdir -p "$BASELINE_DIR"
        cp "$cur" "$base"
        LAST_RESULT="update"
        echo "  [BASELINE] 已写入: ${base}（$(wc -l < "$base" | tr -d ' ') 行指标）"
    elif [ -f "$base" ]; then
        # v1.48.74：先判同源（机器指纹）——不同源时差异属机器固有，不报为回归
        local fp_base fp_cur
        fp_base=$(source_fingerprint "$base")
        fp_cur=$(source_fingerprint "$cur")
        if [ -n "$fp_base" ] && [ -n "$fp_cur" ] && [ "$fp_base" != "$fp_cur" ]; then
            LAST_RESULT="skip"
            echo "  [SKIP] 与基线不同源（同型号不同机器/配置变动）——差异属机器固有，不判为解析回归："
            diff <(printf '%s\n' "$fp_base") <(printf '%s\n' "$fp_cur") 2>/dev/null \
                | grep -E "^[<>]" | head -10 | sed 's/^/    /'
            echo "    → 该样本若应作为此语义的比对源：--samples <样本> --update（覆盖该语义基线）"
        elif diff -q "$base" "$cur" >/dev/null 2>&1; then
            echo "  [OK] 与基线一致（无解析回归）"
        else
            LAST_RESULT="diff"
            echo "  [DIFF] 与基线存在差异（解析回归候选）:"
            diff "$base" "$cur" 2>/dev/null | head -30 | sed 's/^/    /'
            rc=1
        fi
    else
        LAST_RESULT="nobase"
        echo "  [WARN] 无基线（先跑 --update 建立）"
        rc=2
    fi

    [ "$KEEP" -eq 1 ] && cp "$cur" "${BASELINE_DIR}/${sem}.candidate.txt" 2>/dev/null
    [ "$KEEP" -eq 1 ] || rm -rf "$tmp"
    return $rc
}

# ─── 主流程 ───
if [ "$ALL" -eq 1 ]; then
    root="${HWSCOPE_SAMPLE_ROOT:-${PROJECT_DIR}/output}"
    found=0; fail=0; skipn=0
    # v1.48.50：同语义名去重——多台同机型机器（如桌面两台 MI300X）经 sn_to_semantic 映射到同一
    # 基线文件，逐台比对会把机器间固有差异（网卡/盘数不同）当成解析回归误报；本次只比对首台，
    # 后续同名样本跳过并提示（要单独验证某台用 --samples <SN> 显式指定）
    _seen_sem=""
    # v1.50.6：默认根（output/）下排除明显非样本目录——曾把 output/testdata/ 当成一个样本，
    #   语义误配成 headless 后只吐「1 个样本，0 个差异，1 个跳过」，**看着像通过其实零覆盖**。
    #   机器样本目录名是 SN（字母数字串），不会与下列名字冲突；确需比对时用 HWSCOPE_SAMPLE_ROOT 显式指定。
    _SKIP_DIR_RE='^(testdata|tmp|temp|test|tests|bak|backup|archive|old|logs|report|reports)$'
    _skipped_dir=""
    for d in "${root}"/*/; do
        [ -d "$d" ] || continue
        if [ ! -d "${d}gpu" ] && [ ! -d "${d}motherboard" ] && [ ! -f "${d}hwscope_report.md" ]; then
            continue
        fi
        _bn=$(basename "${d%/}")
        if printf '%s' "$_bn" | grep -qE "$_SKIP_DIR_RE"; then
            _skipped_dir="${_skipped_dir}${_skipped_dir:+, }${_bn}"
            continue
        fi
        _sem_cur=$(sn_to_semantic "${d%/}")
        case ",${_seen_sem}," in
            *",${_sem_cur},"*)
                echo "样本: $(basename "${d%/}")（语义: ${_sem_cur}）—— 同名样本跳过（该语义基线已在本次由首台覆盖；要单独验证请用 --samples）"
                echo ""
                continue ;;
        esac
        _seen_sem="${_seen_sem}${_seen_sem:+,}${_sem_cur}"
        found=$((found+1))
        run_one "${d%/}" || fail=$((fail+1))
        [ "$LAST_RESULT" = "skip" ] && skipn=$((skipn+1))
        echo ""
    done
    [ -n "$_skipped_dir" ] && echo "[SKIP] 已跳过非样本目录: ${_skipped_dir}（默认根下的临时/测试目录；确需比对请用 HWSCOPE_SAMPLE_ROOT 显式指定）"
    if [ "$found" -eq 0 ]; then
        echo "[WARN] 未找到采集样本目录（可用 HWSCOPE_SAMPLE_ROOT=<目录> 指定多机样本根；root=${root}）"
        exit 2
    fi
    # v1.50.6：样本数过少时告警——默认根 output/ 常不是多机样本目录，此时「0 个差异」几乎不具覆盖力
    if [ "$found" -eq 1 ]; then
        echo "[WARN] 仅发现 1 个样本（root=${root}）——若预期为多机样本，请用 HWSCOPE_SAMPLE_ROOT=<目录> 指定；单样本结果不具横向覆盖力"
    fi
    echo "汇总: ${found} 个样本，${fail} 个差异，${skipn} 个不同源跳过（同型号其他机器，机器固有差异非回归）"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

# v1.48.14：--samples 选跑（只跑指定样本——GPU 改动跑 GPU 样本等，不跑全量省时间）
if [ -n "$SAMPLES" ]; then
    root="${HWSCOPE_SAMPLE_ROOT:-${PROJECT_DIR}/output}"
    found=0; fail=0; skipn=0
    for sn in ${SAMPLES//,/ }; do
        d="${root}/${sn}"
        [ -d "$d" ] || { echo "[WARN] 样本不存在: $sn（root=$root）"; continue; }
        found=$((found+1))
        run_one "$d" || fail=$((fail+1))
        [ "$LAST_RESULT" = "skip" ] && skipn=$((skipn+1))
        echo ""
    done
    [ "$found" -gt 0 ] || exit 2
    echo "汇总: ${found} 个样本，${fail} 个差异，${skipn} 个不同源跳过"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

[ -z "$SAMPLE" ] && { echo "用法: bash tools/agent/report_regression.sh <采集目录> [--update] [--keep] [--samples SN1,SN2]"; echo "     bash tools/agent/report_regression.sh --all [--update]"; exit 1; }
run_one "${SAMPLE%/}"
exit $?
