#!/bin/bash
# =============================================================================
# HwScope — 多机横向对比
# tools/batch_compare.sh
# 用法: bash tools/batch_compare.sh <采集目录1> <采集目录2> [...]
#       bash tools/batch_compare.sh --dirs "output/SN1 output/SN2" [-o 输出前缀]
# 功能: 读取各机 hwscope_report.json（程序消费稳定格式），生成同字段横向对比表，
#       差异项 ⚠️ 标注，一眼看出批次差异（固件版本/内存速率/盘型号/GPU 型号等）。
# 场景: 批量交付、批次一致性抽检。
# 输出: batch_compare_<时间戳>.{md,txt,html}（HTML 经 md2html.awk 转换）
# 依赖: 仅 bash/awk/grep/sed（零新依赖）；各目录需已生成 hwscope_report.json
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "用法: $0 <dir1> <dir2> [...] [-o 输出前缀]"
    echo "      $0 --dirs \"output/SN1 output/SN2\" [-o 输出前缀]"
    echo "功能: 多机同字段横向对比（读各机 hwscope_report.json），差异 ⚠️ 标注"
    echo "输出: <前缀>_<时间戳>.{md,txt,html}（默认前缀 batch_compare）"
    exit 0
}

# ─── 参数解析 ───
DIRS=(); OUT_PREFIX="batch_compare"
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --dirs)
            # 空格分隔的目录列表（单参数）
            for _d in $2; do DIRS+=("$_d"); done
            shift 2 ;;
        -o) OUT_PREFIX="$2"; shift 2 ;;
        --*) echo "[WARN] 未知参数: $1"; shift ;;
        *) DIRS+=("$1"); shift ;;
    esac
done

[ "${#DIRS[@]}" -lt 2 ] && { echo -e "\033[0;31m[ERROR] 至少需要 2 个采集目录\033[0m"; usage; }

# ─── 校验各目录 JSON 存在 ───
declare -a FILES=() LABELS=()
for d in "${DIRS[@]}"; do
    d="${d%/}"
    f="${d}/hwscope_report.json"
    if [ ! -f "$f" ]; then
        echo -e "\033[0;31m[ERROR] 缺少报告 JSON: ${f}\033[0m"; exit 1
    fi
    FILES+=("$f")
    LABELS+=("$(basename "$d")")
done
N=${#FILES[@]}
[ "$N" -gt 10 ] && echo -e "\033[1;33m[WARN] ${N} 台机器对比表较宽，建议分批（≤8 台/批）\033[0m"

# ─── JSON 块内字段提取（依赖 report.sh 固定缩进格式；零新依赖） ───
# $1=文件 $2=块 $3=键；输出字符串或数字值
json_get() {
    awk -v blk="$2" -v key="$3" '
        $0 ~ "^  \"" blk "\": \\{" { inblk=1; next }
        inblk && /^  \},?$/ { exit }
        inblk && $0 ~ "\"" key "\":" {
            if ($0 ~ /: *"/) { sub(/.*: *"/, ""); sub(/".*/, ""); print; exit }
            else { sub(/.*: */, ""); sub(/,.*/, ""); gsub(/^ +| +$/, ""); print; exit }
        }
    ' "$1" 2>/dev/null
}
# 块内数组元素计数（如 psu details 条数）
json_count_in_block() {
    awk -v blk="$2" -v key="$3" '
        $0 ~ "^  \"" blk "\": \\{" { inblk=1; next }
        inblk && /^  \},?$/ { exit }
        inblk && $0 ~ "\"" key "\":" { c++ }
        END { print c+0 }
    ' "$1" 2>/dev/null
}

# ─── 字段定义（显示名|键|块；顶层字段块=hwscope） ───
declare -a FIELDS=(
    "主机名|hostname|hwscope"
    "平台|platform|hwscope"
    "采集时间|timestamp|hwscope"
    "主板|manufacturer|motherboard"
    "主板型号|product|motherboard"
    "BIOS|bios|motherboard"
    "CPU|model|cpu"
    "总核心|cores_total|cpu"
    "内存|total|memory"
    "GPU数量|count|gpu"
    "GPU型号|models|gpu"
    "GPU显存|memory_total|gpu"
    "VBIOS|vbios|gpu"
    "盘数|disk_count|storage"
    "存储容量|total_capacity|storage"
    "IB活动口|ib_active|network"
    "IB额定速率|ib_nominal_speed|network"
    "BMC固件|firmware|bmc"
    "固件合规|summary|firmware"
)

TS=$(date '+%Y%m%d%H%M%S')
MD="${OUT_PREFIX}_${TS}.md"
TXT="${OUT_PREFIX}_${TS}.txt"

# 提取一行字段值（$1=文件 $2=entry）
field_vals() {
    local f="$1" entry="$2" fname fkey fblk
    IFS='|' read -r fname fkey fblk <<< "$entry"
    json_get "$f" "$fblk" "$fkey"
}

# ─── 生成对比表 ───
{
    echo "# HwScope 多机横向对比"
    echo ""
    echo "**对比目录:** $(printf '%s、' "${DIRS[@]}" | sed 's/、$//') · **生成时间:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "> 数据来源：各机 hwscope_report.json（只读解析，不重新采集）；⚠️ = 同字段存在差异"
    echo ""
    # 表头（逐标签拼接，避免 printf 多参数无分隔符粘连）
    _hdr=""; _sep=""
    for lbl in "${LABELS[@]}"; do
        _hdr="${_hdr} ${lbl} |"
        _sep="${_sep}------|"
    done
    printf '| 字段 |%s\n' "$_hdr"
    printf '|------|%s\n' "$_sep"
    # 逐字段行
    for entry in "${FIELDS[@]}"; do
        IFS='|' read -r fname fkey fblk <<< "$entry"
        vals=()
        for f in "${FILES[@]}"; do
            vals+=("$(field_vals "$f" "$entry")")
        done
        # 差异判定：与第一台不一致的标记 ⚠️
        base="${vals[0]:-}"
        row_vals=""
        for v in "${vals[@]}"; do
            [ -z "$v" ] && v="N/A"
            if [ "$v" != "$base" ]; then
                row_vals="${row_vals} ${v} ⚠️ |"
            else
                row_vals="${row_vals} ${v} |"
            fi
        done
        printf '| %s |%s\n' "$fname" "$row_vals"
    done
    echo ""
    echo "> 注：N/A = 该机无此数据（模块未采集或旧数据）；差异 ⚠️ 建议人工核对批次一致性"
} > "$MD"

# ─── TXT 版（紧凑） ───
{
    echo "============================================"
    echo "HwScope 多机横向对比"
    echo "============================================"
    echo "对比目录: ${DIRS[*]}    时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    printf '  %-10s' "字段"
    for lbl in "${LABELS[@]}"; do printf '  %-22s' "$lbl"; done
    echo ""
    for entry in "${FIELDS[@]}"; do
        IFS='|' read -r fname fkey fblk <<< "$entry"
        vals=()
        for f in "${FILES[@]}"; do
            vals+=("$(field_vals "$f" "$entry")")
        done
        base="${vals[0]:-}"
        printf '  %-10s' "$fname"
        for v in "${vals[@]}"; do
            [ -z "$v" ] && v="N/A"
            if [ "$v" != "$base" ]; then printf '  %-20s⚠️' "${v:0:20}"; else printf '  %-22s' "${v:0:22}"; fi
        done
        echo ""
    done
    echo ""
    echo "注: N/A = 该机无此数据；⚠️ = 与第一台不一致"
    echo "--------------------------------------------"
} > "$TXT"

# ─── HTML（md2html.awk 转换，交付展示） ───
HTML="${OUT_PREFIX}_${TS}.html"
awk -f "${SCRIPT_DIR}/tools/md2html.awk" "$MD" > "$HTML" 2>/dev/null && \
    echo -e "\033[0;32m[OK] HTML: ${HTML}\033[0m" || echo "[WARN] HTML 生成失败（md2html.awk 不可用，MD/TXT 已生成）"

echo -e "\033[0;32m[OK] MD : ${MD}\033[0m"
echo -e "\033[0;32m[OK] TXT: ${TXT}\033[0m"
