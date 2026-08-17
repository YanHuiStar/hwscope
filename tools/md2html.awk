# md2html.awk — HwScope 报告 Markdown → HTML 转换器
# 用法: awk -f md2html.awk hwscope_report.md > hwscope_report.html
# 特性: 卡片分区（## 段）、表格状态着色（PASS/WARN/FAIL/N/A）、斑马纹、引用块、打印友好
# 依赖: 仅 awk（gawk/mawk 均可），无外部工具

BEGIN {
    print "<!DOCTYPE html>"
    print "<html lang='zh'>"
    print "<head>"
    print "<meta charset='UTF-8'>"
    print "<meta name='viewport' content='width=device-width, initial-scale=1.0'>"
    print "<title>HwScope 硬件巡检报告</title>"
    print "<style>"
    print "body{font-family:'Microsoft YaHei','PingFang SC','Noto Sans SC',sans-serif;background:#eef1f6;color:#2d3748;margin:0;padding:24px 16px;}"
    print ".container{max-width:1150px;margin:0 auto;}"
    print "h1{text-align:center;color:#1e3a5f;font-size:24px;margin:0 0 6px;letter-spacing:2px;}"
    print ".subtitle{text-align:center;color:#718096;font-size:12px;margin:0 0 24px;}"
    print ".card{background:#fff;border-radius:10px;box-shadow:0 2px 10px rgba(30,58,95,.08);padding:14px 22px;margin:14px 0;}"
    print ".card h2{color:#1e3a5f;font-size:16px;margin:0 0 10px;border-left:4px solid #1e3a5f;padding-left:10px;}"
    print ".card h3{color:#4a5568;font-size:13px;margin:12px 0 6px;}"
    print "table{width:100%;border-collapse:collapse;font-size:12.5px;margin:6px 0 10px;}"
    print "th{background:#1e3a5f;color:#fff;padding:7px 10px;text-align:left;font-weight:500;white-space:nowrap;}"
    print "td{padding:6px 10px;border-bottom:1px solid #e8ecf2;word-break:break-all;}"
    print "tr:nth-child(even) td{background:#f7f9fc;}"
    print "tr:hover td{background:#eef3fa;}"
    print ".pass{color:#1a7f37;font-weight:600;}"
    print ".warn{color:#b45309;font-weight:600;}"
    print ".fail{color:#dc2626;font-weight:600;}"
    print ".na{color:#9ca3af;}"
    print "blockquote{background:#fffaf0;border-left:4px solid #ed8936;padding:8px 14px;margin:8px 0;color:#7c5314;font-size:12.5px;border-radius:0 6px 6px 0;}"
    print "li{margin:3px 0;font-size:13px;}"
    print "hr{border:none;border-top:1px solid #e2e8f0;margin:14px 0;}"
    print "@media print{body{background:#fff;padding:0;} .card{box-shadow:none;border:1px solid #dde3ea;break-inside:avoid;} th{background:#333;}}"
    print "</style>"
    print "</head>"
    print "<body><div class='container'>"
    in_table = 0
}

# 空行：关闭表格
/^[[:space:]]*$/ {
    if (in_table) { print "</tbody></table>"; in_table = 0 }
    next
}

# H1 标题
/^# / {
    close_table()
    title = substr($0, 3)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", title)
    print "<h1>" title "</h1>"
    if (title ~ /HwScope/) print "<p class='subtitle'>硬件巡检与验收报告</p>"
    next
}

# H2 段标题 → 卡片
/^## / {
    close_table()
    if (in_section) print "</section>"
    in_section = 1
    sec = substr($0, 4)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", sec)
    print "<section class='card'><h2>" sec "</h2>"
    next
}

# H3 明细表标题
/^### / {
    close_table()
    subsec = substr($0, 5)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", subsec)
    print "<h3>" subsec "</h3>"
    next
}

# 表格行
/^\|/ {
    line = $0
    gsub(/^[[:space:]]*\||[[:space:]]*\|[[:space:]]*$/, "", line)
    # 分隔行（| --- | --- |）跳过
    if (line ~ /^[-:|[:space:]]+$/) next
    n = split(line, cells, "|")
    if (in_table == 0) {
        print "<table><thead><tr>"
        for (i = 1; i <= n; i++) {
            trim_cell(cells[i])
            print "<th>" cells[i] "</th>"
        }
        print "</tr></thead><tbody>"
        in_table = 1
        next
    }
    print "<tr>"
    for (i = 1; i <= n; i++) {
        trim_cell(cells[i])
        cls = cell_class(cells[i])
        if (cls != "") print "<td class='" cls "'>" cells[i] "</td>"
        else print "<td>" cells[i] "</td>"
    }
    print "</tr>"
    next
}

# 引用块（注释/提示）
/^> / {
    note = substr($0, 3)
    print "<blockquote>" note "</blockquote>"
    next
}

# 列表
/^- / {
    item = substr($0, 3)
    print "<li>" item "</li>"
    next
}

# 水平线
/^---[[:space:]]*$/ {
    close_table()
    print "<hr>"
    next
}

# 普通段落
{
    close_table()
    print "<p>" $0 "</p>"
}

function close_table() {
    if (in_table) { print "</tbody></table>"; in_table = 0 }
}

function trim_cell(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}

function cell_class(s) {
    if (s ~ /FAIL|不合格|❌/) return "fail"
    if (s ~ /WARN|⚠️/) return "warn"
    if (s ~ /PASS|✅|合格/) return "pass"
    if (s ~ /^N\/A$|^—$|^无$|数据不足/) return "na"
    return ""
}

END {
    close_table()
    if (in_section) print "</section>"
    print "</div></body></html>"
}
