#!/bin/bash
# =============================================================================
# HwScope — 报告在线预览
# report/tools/report_server.sh
# 用法: bash report/tools/report_server.sh [--port 8080] [--open] [--stop]
# 功能: 本地 HTTP 服务浏览历次报告归档（logs/report/）：自动解包各
#       <SN>-<时间戳>-report.tar.gz 到 web 缓存目录，生成索引页，点开即见 HTML 报告。
# 场景: 交付现场/内部巡检快速翻阅历史报告，无需逐个解压。
# 依赖: python3（http.server，系统自带）— 零新依赖
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE_DIR="${SCRIPT_DIR}/logs/report"
WEB_DIR="${ARCHIVE_DIR}/web"
PORT=8080; OPEN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --open) OPEN=1; shift ;;
        --stop) ACTION=stop; shift ;;
        -h|--help) ACTION=help; shift ;;   # v1.35.0: 补 shift 修复 --help 死循环（原版无 shift 致 $# 不减无限循环）
        *) ACTION="${1:-start}"; shift ;;
    esac
done
[ -z "${ACTION:-}" ] && ACTION=start
PID_FILE="${WEB_DIR}/report_server.pid"

usage() {
    echo "用法: bash tools/report_server.sh [--port 8080] [--open] [--stop]"
    echo "  --port N    HTTP 端口（默认 8080）"
    echo "  --open      自动打开浏览器"
    echo "  --stop      停止服务"
    echo "服务目录: ${ARCHIVE_DIR}/（自动解包各 -report.tar.gz 到 web/ 缓存）"
}

# ─── 构建 web 缓存 + 索引页 ───
build_web() {
    mkdir -p "$WEB_DIR"
    # 解包各报告归档（已存在则跳过）
    local n=0
    for f in "${ARCHIVE_DIR}"/*-report.tar.gz; do
        [ -f "$f" ] || continue
        base=$(basename "$f" .tar.gz)
        if [ ! -d "${WEB_DIR}/${base}" ]; then
            mkdir -p "${WEB_DIR}/${base}"
            tar xzf "$f" -C "${WEB_DIR}/${base}" 2>/dev/null
            n=$((n+1))
        fi
    done
    # 索引页
    {
        echo "<!DOCTYPE html><html lang=zh><head><meta charset=utf-8>"
        echo "<title>HwScope 报告归档</title>"
        echo "<style>body{font-family:system-ui,sans-serif;margin:2em;max-width:900px}"
        echo "h1{color:#0b5394}table{border-collapse:collapse;width:100%}"
        echo "th,td{border:1px solid #ccc;padding:8px;text-align:left}"
        echo "th{background:#e8f0fe}a{color:#0b5394;text-decoration:none}"
        echo ".na{color:#999}</style></head><body>"
        echo "<h1>HwScope 报告归档</h1><p>生成时间: $(date '+%Y-%m-%d %H:%M:%S') · 服务: report_server.sh</p>"
        echo "<table><tr><th>机器/归档</th><th>报告</th><th>验收清单</th></tr>"
        for d in "${WEB_DIR}"/*/; do
            [ -d "$d" ] || continue
            name=$(basename "$d")
            # 机器名 = SN（归档名格式 <SN>-<TS>-report）
            sn=$(echo "$name" | sed 's/-[0-9]\{14\}-report$//')
            html="<span class=na>—</span>"; acc="<span class=na>—</span>"
            [ -f "${d}/hwscope_report.html" ] && html="<a href='${name}/hwscope_report.html'>HTML</a>"
            [ -f "${d}/hwscope_report.md" ] && html="${html} <a href='${name}/hwscope_report.md'>MD</a>"
            [ -f "${d}/hwscope_acceptance.html" ] && acc="<a href='${name}/hwscope_acceptance.html'>HTML</a>"
            [ -f "${d}/hwscope_acceptance.md" ] && acc="${acc} <a href='${name}/hwscope_acceptance.md'>MD</a>"
            echo "<tr><td>${sn}</td><td>${html}</td><td>${acc}</td></tr>"
        done
        echo "</table></body></html>"
    } > "${WEB_DIR}/index.html"
    echo -e "\033[0;32m[OK] 索引页: ${WEB_DIR}/index.html（本次新解包 ${n} 个归档）\033[0m"
}

case "$ACTION" in
    help) usage ;;
    stop)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            kill "$(cat "$PID_FILE")" 2>/dev/null
            rm -f "$PID_FILE"
            echo -e "\033[0;32m[OK] 已停止报告服务\033[0m"
        else
            rm -f "$PID_FILE"
            echo -e "\033[1;33m[INFO] 服务未在运行\033[0m"
        fi
        ;;
    start)
        command -v python3 >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] 未安装 python3（需要 http.server）\033[0m"; exit 1; }
        [ -d "$ARCHIVE_DIR" ] || { echo -e "\033[1;33m[WARN] 归档目录不存在: ${ARCHIVE_DIR}（先跑一次采集生成报告归档）\033[0m"; mkdir -p "$ARCHIVE_DIR"; }
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo -e "\033[1;33m[WARN] 服务已在运行（pid $(cat "$PID_FILE")）；--stop 先停\033[0m"; exit 0
        fi
        build_web
        # 必须 --bind 127.0.0.1：python http.server 默认监听 0.0.0.0，会把含 SN/MAC 的报告无鉴权暴露局域网（v1.33.1 安全修复）
        nohup python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WEB_DIR" > "${WEB_DIR}/server.log" 2>&1 &
        echo $! > "$PID_FILE"
        sleep 1
        if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo -e "\033[0;32m[OK] 报告预览服务: http://127.0.0.1:${PORT}/\033[0m"
            [ "$OPEN" -eq 1 ] && { command -v xdg-open >/dev/null 2>&1 && xdg-open "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 || true; }
        else
            echo -e "\033[0;31m[ERROR] 启动失败，日志: ${WEB_DIR}/server.log\033[0m"; rm -f "$PID_FILE"; exit 1
        fi
        ;;
    *) echo "未知动作: $ACTION"; usage; exit 1 ;;
esac
