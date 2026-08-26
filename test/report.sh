#!/bin/bash
# =============================================================================
# 压测报告生成器 — test/report.sh
# 用法: bash test/report.sh <logs/test/<时间戳>/目录> [--channels N --speed MT/s]
#       bash test/report.sh <目录> --channels 8 --speed 5600   # 指定内存通道/速率
# 功能: 从压测 raw 日志生成标准化性能测试报告（hwscope_test_report.{md,html}）
#       ——测试环境/工具方法/理论峰值/结果对比/分析/结论/附录，数据口径科学可追溯
# 依赖: report/lib/md2html.awk（转 HTML，浏览器可打印 PDF）
# 说明: 第一版覆盖 STREAM/sysbench(内存/CPU)/fio/dd/iperf3/perftest/gpu_burn；
#       理论峰值：内存=通道×速率×8B（业界口径），其余组件列参考上限
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"     # test/
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── 参数解析 ───
TEST_DIR=""   # 测试输出目录（logs/test/<时间戳>/）
MEM_CHANNELS=""   # 内存通道数（默认自动探测 dmidecode）
MEM_SPEED=""      # 内存速率 MT/s
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,/^[^#]/p' "$0" | sed 's/^# \?//' | sed '/^$/d'; exit 0 ;;
        --channels) MEM_CHANNELS="$2"; shift 2 ;;
        --speed) MEM_SPEED="$2"; shift 2 ;;
        *) TEST_DIR="$1"; shift ;;
    esac
done
[ -z "$TEST_DIR" ] && { echo "用法: bash test/report.sh <logs/test/<时间戳>/目录> [--channels N --speed MT/s]"; exit 1; }
[ -d "$TEST_DIR" ] || { echo "错误: 目录不存在 $TEST_DIR"; exit 1; }

# ─── 环境段（server_info.log）───
SERVER_INFO="${TEST_DIR}/server_info.log"
SI_MACHINE=$(grep -m1 "Machine ID" "$SERVER_INFO" 2>/dev/null | cut -d: -f2 | xargs)
SI_MODEL=$(grep -m1 "Brand/Model" "$SERVER_INFO" 2>/dev/null | cut -d: -f2 | xargs)
SI_CPU=$(grep -m1 "CPU" "$SERVER_INFO" 2>/dev/null | cut -d: -f2 | xargs)
SI_MEM=$(grep -m1 "Memory" "$SERVER_INFO" 2>/dev/null | cut -d: -f2 | xargs)
SI_GPU=$(grep -m1 "GPU" "$SERVER_INFO" 2>/dev/null | cut -d: -f2 | xargs)
SI_OS=$(grep -m1 "OS/Kernel" "$SERVER_INFO" 2>/dev/null | cut -d: -f2 | xargs)

# ─── 内存通道/速率探测（未指定参数时）───
if [ -z "$MEM_CHANNELS" ] || [ -z "$MEM_SPEED" ]; then
    if command -v dmidecode >/dev/null 2>&1; then
        [ -z "$MEM_CHANNELS" ] && MEM_CHANNELS=$(dmidecode -t memory 2>/dev/null | grep -c "Locator: CPU.*_DIMM\|Locator: DIMM" || true)
        [ -z "$MEM_SPEED" ] && MEM_SPEED=$(dmidecode -t memory 2>/dev/null | grep -m1 "Configured Memory Speed" | awk '{print $NF}')
    fi
fi
MEM_CHANNELS=${MEM_CHANNELS:-8}
MEM_SPEED=${MEM_SPEED:-5600}
# 理论峰值 = 通道 × 速率 × 8 字节（业界口径，示例报告同款公式）
MEM_PEAK=$(awk "BEGIN{printf \"%.1f\", $MEM_CHANNELS * $MEM_SPEED * 8 / 1000}")

# ─── 通用日志段提取：标题 + 结果行 ───
gen_sections() {
    local f
    for f in "$TEST_DIR"/*.log; do
        [ "$(basename "$f")" = "server_info.log" ] && continue
        [ "$(basename "$f")" = "manifest.txt" ] && continue
        local title=$(grep -m1 "━━━" "$f" 2>/dev/null | sed 's/.*━━━ //;s/ ━━━.*//')
        [ -z "$title" ] && title=$(basename "$f" .log)
        local result=$(grep -vE "^\s*$|^=|^HwScope|^Hostname|^Timestamp|^Machine|^Brand|^Serial|^CPU|^Memory|^GPU|^OS|^采集时间|^\[.*\] .*测试开始" "$f" 2>/dev/null | grep -E "通过|失败|PASS|FAIL|OK|Error|WARN|GB/s|MiB|IOPS|MB/s|ms|usec|latency|events" | head -3 | tr '\n' '; ')
        echo "| ${title} | ${result:-见附录} |"
    done
}

# ─── 专项解析：STREAM（内存带宽，业界标准）───
parse_stream() {
    local f
    for f in "$TEST_DIR"/*.log; do
        grep -qE "^(Copy|Scale|Add|Triad):" "$f" 2>/dev/null || continue
        local rows=""
        while IFS= read -r line; do
            local val=$(echo "$line" | awk '{print $2}')
            case "$line" in
                Copy:*) rows="${rows}| COPY | ${val} |\n" ;;
                Scale:*) rows="${rows}| SCALE | ${val} |\n" ;;
                Add:*) rows="${rows}| ADD | ${val} |\n" ;;
                Triad:*) rows="${rows}| TRIAD | ${val} |\n" ;;
            esac
        done < <(grep -E "^(Copy|Scale|Add|Triad):" "$f")
        # 与理论峰值比 + 利用率（val 为纯数字 GB/s）
        local out=""
        while IFS= read -r r; do
            local name val pct
            name=$(echo "$r" | cut -d'|' -f2 | xargs); val=$(echo "$r" | cut -d'|' -f3 | xargs)
            pct=$(awk "BEGIN{printf \"%.1f\", $val / $MEM_PEAK * 100}")
            out="${out}| ${name} | ${val} GB/s | ${pct}% |\n"
        done < <(printf '%b' "$rows")
        printf '%b' "$out"
        return 0
    done
    return 1
}

# ─── 专项解析：sysbench 内存 / CPU ───
parse_sysbench() {
    local f kind="$1"
    for f in "$TEST_DIR"/*.log; do
        case "$kind" in
            mem)
                grep -q "Total operations\|MiB/sec" "$f" 2>/dev/null || continue
                local ops=$(grep -m1 "Total operations" "$f" | grep -oE "[0-9]+")
                local rate=$(grep -m1 "MiB/sec" "$f" | grep -oE "[0-9.]+")
                echo "| sysbench 内存吞吐 | ${rate:-N/A} MiB/s |（总操作 ${ops:-N/A}，参考指标）|"
                return 0 ;;
            cpu)
                grep -q "events per second" "$f" 2>/dev/null || continue
                local eps=$(grep -m1 "events per second" "$f" | grep -oE "[0-9.]+")
                echo "| sysbench CPU | ${eps:-N/A} events/s |（参考指标）|"
                return 0 ;;
        esac
    done
    return 1
}

# ─── 专项解析：fio（磁盘 IOPS/带宽）───
parse_fio() {
    local f
    for f in "$TEST_DIR"/*.log; do
        grep -q "IOPS\|BW=" "$f" 2>/dev/null || continue
        local iops=$(grep -m1 "IOPS" "$f" | grep -oE "IOPS=[0-9.]+[kKM]?" | head -1)
        local bw=$(grep -m1 "BW=" "$f" | grep -oE "BW=[0-9.]+[kKM]?i?B/s" | head -1)
        echo "| fio | ${iops:-N/A} / ${bw:-N/A} |（参考指标，详见附录）|"
        return 0
    done
    return 1
}

# ─── 专项解析：iperf3（网卡吞吐）───
parse_iperf() {
    local f
    for f in "$TEST_DIR"/*.log; do
        grep -q "sender\|receiver" "$f" 2>/dev/null || continue
        local rx=$(grep -m1 "receiver" "$f" | grep -oE "[0-9.]+ [GM]bits/sec" | head -1)
        echo "| iperf3 吞吐 | ${rx:-N/A}（receiver）|（参考指标，详见附录）|"
        return 0
    done
    return 1
}

# ─── 专项解析：IB perftest（带宽/延迟）───
parse_perftest() {
    local f
    for f in "$TEST_DIR"/*.log; do
        grep -q "BW average\|Latency average" "$f" 2>/dev/null || continue
        local bw=$(grep -m1 "BW average" "$f" | grep -oE "[0-9.]+ [MG]b/sec" | head -1)
        local lat=$(grep -m1 "Latency average" "$f" | grep -oE "[0-9.]+ usec" | head -1)
        echo "| IB perftest | ${bw:-N/A} · 延迟 ${lat:-N/A} |（参考指标，详见附录）|"
        return 0
    done
    return 1
}

# ─── 专项解析：gpu_burn 通过性 ───
parse_gpuburn() {
    local f
    for f in "$TEST_DIR"/*.log; do
        grep -q "gpu_burn" "$f" 2>/dev/null || continue
        local r=$(grep -m1 "gpu_burn:" "$f" | sed 's/.*gpu_burn: //')
        [ -n "$r" ] && { echo "| GPU 压测 | ${r} |（稳定性测试，通过=无 ECC 错误）|"; return 0; }
    done
    return 1
}

# ─── 组装报告 ───
STREAM_ROWS=$(parse_stream)
SYSBENCH_MEM=$(parse_sysbench mem)
SYSBENCH_CPU=$(parse_sysbench cpu)
FIO_ROWS=$(parse_fio)
IPERF_ROWS=$(parse_iperf)
PERFTEST_ROWS=$(parse_perftest)
GPUBURN_ROWS=$(parse_gpuburn)

# 内存结论（有 STREAM 时基于利用率）
MEM_CONCLUSION="已测试（详见各工具结果与附录）；有 STREAM 数据时以 TRIAD 利用率评价。"
MEM_ANALYSIS=""
if [ -n "$STREAM_ROWS" ]; then
    TRIAD_PCT=$(printf '%b' "$STREAM_ROWS" | grep "TRIAD" | grep -oE "[0-9.]+%" | tr -d '%')
    if [ -n "$TRIAD_PCT" ]; then
        if awk "BEGIN{exit !($TRIAD_PCT >= 90)}"; then
            MEM_CONCLUSION="内存带宽利用率 ${TRIAD_PCT}%（TRIAD），达理论峰值 ${MEM_PEAK} GB/s 的 90% 以上——内存子系统工作正常、无性能瓶颈。"
        elif awk "BEGIN{exit !($TRIAD_PCT >= 70)}"; then
            MEM_CONCLUSION="内存带宽利用率 ${TRIAD_PCT}%（TRIAD），处于正常区间（70-90%）；如低于预期可核查通道配置/BIOS 设置。"
        else
            MEM_CONCLUSION="内存带宽利用率 ${TRIAD_PCT}%（TRIAD），低于正常区间（<70%）——建议核查内存通道/速率配置是否达标。"
        fi
        MEM_ANALYSIS="理论峰值 ${MEM_PEAK} GB/s = ${MEM_CHANNELS} 通道 × ${MEM_SPEED} MT/s × 8 字节（业界口径）；COPY/SCALE 为纯读写单侧流量，高于峰值口径属正常；TRIAD（读-乘-加）综合操作最能代表实际负载。"
    fi
fi

# 结论汇总（按有数据的组件）
CONCLUSIONS=""
[ -n "$STREAM_ROWS" ] && CONCLUSIONS="${CONCLUSIONS}1. 内存带宽：${MEM_CONCLUSION}\n"
[ -n "$SYSBENCH_CPU" ] && CONCLUSIONS="${CONCLUSIONS}2. CPU 计算：已完成基准测试（sysbench events/s），详见结果表。\n"
[ -n "$FIO_ROWS" ] && CONCLUSIONS="${CONCLUSIONS}3. 磁盘性能：已完成 fio 基准测试，详见结果表与附录。\n"
[ -n "$GPUBURN_ROWS" ] && CONCLUSIONS="${CONCLUSIONS}4. GPU 稳定性：$(echo "$GPUBURN_ROWS" | cut -d'|' -f3 | xargs)（通过=无 ECC 错误）。\n"
[ -z "$CONCLUSIONS" ] && CONCLUSIONS="本目录测试已完成，各组件结果见附录原始日志。\n"

REPORT_MD="${TEST_DIR}/hwscope_test_report.md"
{
    echo "# 硬件性能测试报告"
    echo ""
    echo "测试日期: $(stat -c %y "$TEST_DIR" 2>/dev/null | cut -d. -f1 || date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "## 一、测试环境"
    echo ""
    echo "| 项目 | 配置 |"
    echo "|------|------|"
    [ -n "$SI_MACHINE" ] && echo "| 机器 ID | ${SI_MACHINE} |"
    [ -n "$SI_MODEL" ] && echo "| 型号 | ${SI_MODEL} |"
    [ -n "$SI_CPU" ] && echo "| CPU | ${SI_CPU} |"
    [ -n "$SI_MEM" ] && echo "| 内存 | ${SI_MEM} |"
    [ -n "$SI_GPU" ] && echo "| GPU | ${SI_GPU} |"
    [ -n "$SI_OS" ] && echo "| OS/内核 | ${SI_OS} |"
    echo ""
    echo "## 二、测试工具与方法"
    echo ""
    echo "| 工具 | 用途 | 参数 |"
    echo "|------|------|------|"
    [ -n "$STREAM_ROWS" ] && echo "| STREAM | 内存带宽基准（业界标准） | 标准编译默认参数 |"
    [ -n "$SYSBENCH_MEM" ] && echo "| sysbench memory | 内存综合吞吐 | 见测试脚本 |"
    [ -n "$SYSBENCH_CPU" ] && echo "| sysbench cpu | CPU 计算基准 | 见测试脚本 |"
    [ -n "$FIO_ROWS" ] && echo "| fio | 磁盘 IOPS/带宽 | 见测试脚本 |"
    [ -n "$IPERF_ROWS" ] && echo "| iperf3 | 网络吞吐 | 见测试脚本 |"
    [ -n "$PERFTEST_ROWS" ] && echo "| perftest | IB 带宽/延迟 | 见测试脚本 |"
    [ -n "$GPUBURN_ROWS" ] && echo "| gpu_burn | GPU 稳定性 | 标准运行 |"
    [ -z "$STREAM_ROWS$SYSBENCH_MEM$SYSBENCH_CPU$FIO_ROWS$IPERF_ROWS$PERFTEST_ROWS$GPUBURN_ROWS" ] && echo "| （无标准工具数据） | | |"
    echo ""
    echo "## 三、理论峰值"
    echo ""
    if [ -n "$STREAM_ROWS" ]; then
        echo "| 指标 | 理论峰值 | 公式 |"
        echo "|------|---------|------|"
        echo "| 内存带宽 | ${MEM_PEAK} GB/s | ${MEM_CHANNELS} 通道 × ${MEM_SPEED} MT/s × 8 字节 |"
    else
        echo "内存理论峰值 ${MEM_PEAK} GB/s（${MEM_CHANNELS} 通道 × ${MEM_SPEED} MT/s × 8 字节）——本次未采集 STREAM 数据，仅作环境参考。"
    fi
    echo ""
    echo "## 四、测试结果"
    echo ""
    [ -n "$STREAM_ROWS" ] && {
        echo "### 4.1 内存带宽（STREAM，核心指标）"
        echo ""
        echo "| 项目 | 带宽 | 与理论峰值比 |"
        echo "|------|------|------------|"
        printf '%b' "$STREAM_ROWS"
        echo ""
    }
    [ -n "$SYSBENCH_MEM" ] && {
        echo "### 4.2 辅助指标"
        echo ""
        echo "| 测试 | 结果 | 说明 |"
        echo "|------|------|------|"
        echo "| ${SYSBENCH_MEM} |"
        echo ""
    }
    [ -n "$SYSBENCH_CPU$FIO_ROWS$IPERF_ROWS$PERFTEST_ROWS$GPUBURN_ROWS" ] && {
        echo "### 4.3 其他组件"
        echo ""
        echo "| 测试 | 结果 | 说明 |"
        echo "|------|------|------|"
        [ -n "$SYSBENCH_CPU" ] && echo "$SYSBENCH_CPU"
        [ -n "$FIO_ROWS" ] && echo "$FIO_ROWS"
        [ -n "$IPERF_ROWS" ] && echo "$IPERF_ROWS"
        [ -n "$PERFTEST_ROWS" ] && echo "$PERFTEST_ROWS"
        [ -n "$GPUBURN_ROWS" ] && echo "$GPUBURN_ROWS"
        echo ""
    }
    echo "## 五、结果分析"
    echo ""
    [ -n "$MEM_ANALYSIS" ] && echo "${MEM_ANALYSIS}"
    [ -z "$MEM_ANALYSIS" ] && echo "本次测试结果已记录；标准工具（STREAM/fio/iperf3）数据齐全时按理论峰值与利用率评价。"
    echo ""
    echo "## 六、结论"
    echo ""
    printf '%b' "$CONCLUSIONS"
    echo ""
    echo "## 附录"
    echo ""
    echo "原始输出见同目录（全部测试日志，含工具版本/参数/完整输出）："
    for f in "$TEST_DIR"/*.log; do
        [ "$(basename "$f")" = "server_info.log" ] && continue
        echo "- \`$(basename "$f")\`"
    done
} > "$REPORT_MD"

# HTML 转换（复用 report/lib/md2html.awk，零依赖）
if [ -f "${PROJECT_DIR}/report/lib/md2html.awk" ]; then
    awk -f "${PROJECT_DIR}/report/lib/md2html.awk" "$REPORT_MD" > "${TEST_DIR}/hwscope_test_report.html" 2>/dev/null \
        && echo "[OK] 报告已生成: ${TEST_DIR}/hwscope_test_report.{md,html}"
else
    echo "[OK] 报告已生成: ${REPORT_MD}（未找到 md2html.awk，HTML 跳过）"
fi
