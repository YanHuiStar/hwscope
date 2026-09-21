#!/bin/bash
# =============================================================================
# HwScope - 报告解析辅助函数
# report/lib/report_common.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
extract() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { echo ""; return; }
    grep -iE "$pattern" "$file" 2>/dev/null | grep -v "^#" | head -1 | cut -d':' -f2- | sed 's/^ *//;s/ *$//' | head -c 200
}

# ─── 过滤日志：去除注释行（行首 #）和空行 ───
filter_log() {
    grep -v "^#" "$1" 2>/dev/null | grep -v "^$"
}

# ─── JSON 字符串转义（v1.49.19）───
# 背景：gen_json.sh 里存在两种拼装风格——awk 分支转义了 `\` 与 `"`，bash 数组与 heredoc 标量
#   没有 → 任一字段含引号/反斜杠（实测触发：nvidia-smi CSV 对含逗号的名称加引号后型号名带 `"`）
#   就产出**不可解析**的 JSON，而 JSON 是机器消费产物（batch_compare.sh 等直接读），
#   报错点还在解析侧、现场很难溯源。
# 只做 JSON 必需的两件事：反斜杠与双引号；顺带去掉会破坏"单行值"的 CR。
# 注意：**不去换行**——多行字段（如 PSU list）在调用点自行 tr 成单行，不在这里处理。
jesc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g'
}

# ─── 清单加载：从 manifest.txt 读取模块输出文件名，回退到默认值 ───
# 用法: load_manifest <目录> <key> [默认文件名]
# 若 <目录>/manifest.txt 存在且含 <key>=<value>，设置 shell 变量 $key 为完整路径；
# 否则使用 <目录>/<默认文件名>（默认文件名 = key 本身）。
load_manifest() {
    local dir="$1" key="$2" default="${3:-$2}"
    local manifest="${dir}/manifest.txt"
    if [ -f "$manifest" ]; then
        local val
        val=$(grep "^${key}=" "$manifest" 2>/dev/null | tail -1 | cut -d'=' -f2-)
        if [ -n "$val" ]; then
            declare -g "${key}=${dir}/${val}"
            return
        fi
    fi
    declare -g "${key}=${dir}/${default}"
}

# ─── CSV 列名动态匹配 ───
# 用法: get_csv_col_index <csv_file> <column_name>
# 返回: 列索引（从 1 开始）；未找到返回**空**（v1.52.1 修复：原返回 "0"，
#   非空 → 调用方 `${col:-6}` 默认列兜底永不生效，且 col=0 时 awk 取 $0 整行输出 N/A）
get_csv_col_index() {
    local csv_file="$1" col_name="$2"
    [ ! -f "$csv_file" ] && return
    local header
    header=$(filter_log "$csv_file" | head -1)
    [ -z "$header" ] && return
    echo "$header" | awk -F',' -v target="$col_name" '{
        for(i=1; i<=NF; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            if($i == target) {
                print i
                exit
            }
        }
        # 未命中：不输出（空返回，让调用方 ${col:-N} 兜底生效）
    }'
}

# ─── 收集基础信息 ───
SUMMARY="${OUT}/summary.txt"
HOSTNAME=$(extract "Hostname" "$SUMMARY")
VERSION=$(extract "Version" "$SUMMARY")
[ -z "$VERSION" ] && VERSION="N/A"   # 老版本采集数据无 Version 行
# 报告生成器版本（单一权威源 = hwscope.sh 的 HWSCOPE_VERSION，动态读取自动跟随升版本，
# 无需 sync_version 参与；与采集版本 VERSION 区分：采集版本=数据何时采集，生成器版本=报告用哪个工具版本生成）
REPORT_VERSION=$(grep '^HWSCOPE_VERSION=' "${SCRIPT_DIR}/hwscope.sh" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$REPORT_VERSION" ]; then
    # 防御：读取失败（hwscope.sh 缺失/HWSCOPE_VERSION 格式异常）如实提示，勿静默 unknown（v1.35.1）
    REPORT_VERSION="unknown"
    echo -e "${YELLOW}[WARN] 报告生成器版本读取失败（${SCRIPT_DIR}/hwscope.sh 缺失或 HWSCOPE_VERSION 格式异常），报告版本将显示 unknown${NC}" >&2
fi
PLATFORM=$(grep -m1 "^Platform" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
# HGX 机头标记（x86_64_head 等：PCIe Fabric 接模组，无本地 GPU；报告与验收清单使用专门文案）
HEAD_NODE=0
PLATFORM_LABEL="$PLATFORM"
case "$PLATFORM" in
    *_head) HEAD_NODE=1; PLATFORM_LABEL="${PLATFORM}（HGX 机头：PCIe Fabric 接模组，模组单独采集）" ;;
    *_OAM)  PLATFORM_LABEL="${PLATFORM}（AMD OAM 模组：xGMI/Infinity Fabric 互联，v1.48.0）" ;;
esac
TIMESTAMP=$(grep -m1 "^Timestamp" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | sed 's/^ //')

# ─── 采集耗时（summary 耗时统计段） ───
TIMING_TOTAL=$(grep -m1 "^总时长" "$SUMMARY" 2>/dev/null | awk '{print $3}')
