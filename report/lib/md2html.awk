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
    print ".layout{max-width:1400px;margin:0 auto;display:flex;flex-wrap:wrap;align-items:flex-start;gap:16px;}"
    # v1.53.24：header 必须占满整行（否则 flex-wrap 会把侧边栏挤到它右边）；
    #   宽度与正文容器对齐交给内部子元素各自限宽居中
    print ".pagehead{flex:1 1 100%;}"
    print ".pagehead>*{max-width:1150px;margin-left:auto;margin-right:auto;}"
    # v1.53.25：宽屏下页头让出侧边栏占位（140 栏宽 + 16 间距），使其内部容器与正文 .container
    #   同起点 —— 否则页头按整行居中、正文按 main 居中，两者左边界差 78px（信息行看起来「漂」到偏左）
    print "@media (min-width:900px){.pagehead{padding-left:156px;}}"
    print ".toc{position:sticky;top:16px;flex:0 0 140px;box-sizing:border-box;display:flex;flex-direction:column;overflow:hidden;max-height:calc(100vh - 32px);background:#fff;border-radius:10px;box-shadow:0 2px 10px rgba(30,58,95,.08);padding:10px 6px;font-size:12.5px;}"
    print ".toc-title{font-weight:600;color:#1e3a5f;margin:0 0 8px;padding-left:4px;border-left:3px solid #1e3a5f;}"
    print ".toc ul{list-style:none;margin:0;padding:0;flex:1 1 auto;overflow-y:auto;min-height:0;}"
    print ".toc li{margin:1px 0;}"
    print ".toc a{display:block;padding:3px 8px;color:#4a5568;text-decoration:none;border-radius:5px;line-height:1.5;text-align:center;}"
    print ".toc a:hover{background:#eef3fa;color:#1e3a5f;}"
    print ".toc li.sep{margin:8px 0 2px;padding:8px 0 0;border-top:1px solid #e2e8f0;font-size:11px;color:#a0aec0;letter-spacing:2px;text-align:center;}"
    print ".main{flex:1 1 auto;min-width:0;}"
    # v1.53.23：首张卡片上边距归零 —— 侧边栏与第一张卡片从同一条顶线开始（纯 CSS，不靠 JS 挪位置）
    print ".main .container > section.card:first-of-type{margin-top:0;}"
    print "html{scroll-behavior:smooth;}"
    print ".top{position:fixed;right:18px;bottom:18px;background:#1e3a5f;color:#fff;padding:7px 12px;border-radius:20px;font-size:12px;text-decoration:none;opacity:.85;}"
    print ".top:hover{opacity:1;}"
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
    print "@media print{body{background:#fff;padding:0;} .card{box-shadow:none;border:1px solid #dde3ea;break-inside:avoid;} th{background:#333;} .toc,.top{display:none;} .layout{display:block;max-width:none;} .main{width:100%;}}"
    print "</style>"
    print "</head>"
    # 两遍扫描：先收集 ## 段标题生成侧边目录，再输出正文（纯 awk，无外部依赖）
    ARGV[ARGC++] = ARGV[1]
    pass = 0; ntoc = 0; nsec = 0; toc_done = 0
    # v1.53.21：标题区（h1/副标题/采集信息行）先放进通栏 header，等第一个 ## 出现时再开 nav+main，
    #   这样侧边栏与右侧第一张卡片从同一行开始（原来侧边栏贴在页面最上方，与卡片错开一个标题区的高度）
    print "<body><div class='layout'><header class='pagehead'>"
    in_table = 0
}

# 第二遍开头：输出目录项并打开正文容器
FNR == 1 {
    pass++
    # v1.53.21：侧边栏/正文容器的开启点移到第一个 ## 处（见下），此处只切换 pass
}

# 第一遍：只收集 ## 标题，其余一律不输出
pass == 1 {
    if (/^## /) {
        t = substr($0, 4)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        toc[++ntoc] = t                     # 存原始标题，输出目录时再转义/取短名
        isapp[ntoc] = (t == "PCIe 链路明细（附录）" || t == "术语说明") ? 1 : 0
    }
    next
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

# H2 段标题 → 卡片（带 id 供侧边目录跳转）
/^## / {
    close_table()
    # v1.53.21：第一个章节标题处收口标题区，并开启侧边栏 + 正文容器
    if (!toc_done) {
        print "</header><nav class='toc'><div class='toc-title'>目录</div><ul class='toc-list'>"
        sep_done = 0
        for (i = 1; i <= ntoc; i++) {
            if (isapp[i] && !sep_done) { print "<li class='sep'>附录</li>"; sep_done = 1 }
            print "<li><a href='#sec-" i "' title='" attr_esc(toc[i]) "'>" esc_html(toc_short(toc[i])) "</a></li>"
        }
        print "</ul></nav><main class='main'><div class='container'>"
        toc_done = 1
    }
    if (in_section) print "</section>"
    in_section = 1
    nsec++
    sec = substr($0, 4)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", sec)
    print "<section class='card'><h2 id='sec-" nsec "'>" sec "</h2>"
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
            c = trim_cell(cells[i])
            print "<th>" inline_md(esc_html(c)) "</th>"
        }
        print "</tr></thead><tbody>"
        in_table = 1
        next
    }
    print "<tr>"
    for (i = 1; i <= n; i++) {
        c = trim_cell(cells[i])
        cls = cell_class(c)
        if (cls != "") print "<td class='" cls "'>" inline_md(esc_html(c)) "</td>"
        else print "<td>" inline_md(esc_html(c)) "</td>"
    }
    print "</tr>"
    next
}

# 引用块（注释/提示）
/^> / {
    note = substr($0, 3)
    print "<blockquote>" inline_md(esc_html(note)) "</blockquote>"
    next
}

# 列表
/^- / {
    item = substr($0, 3)
    print "<li>" inline_md(esc_html(item)) "</li>"
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
    print "<p>" inline_md(esc_html($0)) "</p>"
}

function close_table() {
    if (in_table) { print "</tbody></table>"; in_table = 0 }
}

function trim_cell(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}

# HTML 转义（先 & 后 < > "，防二次转义）；cell_class 在转义前调用（用原始文本判色）
function esc_html(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    gsub(/"/, "\\&quot;", s)
    return s
}

# 内联 Markdown：`code` → <code>、**bold** → <strong>、[text](url) → <a>
# 在 esc_html 之后调用（输入已防注入；code 先于 bold，防代码内 ** 误渲染）
function inline_md(s) {
    while (match(s, /`[^`]+`/)) {
        s = substr(s, 1, RSTART-1) "<code>" substr(s, RSTART+1, RLENGTH-2) "</code>" substr(s, RSTART+RLENGTH)
    }
    while (match(s, /\*\*[^*]+\*\*/)) {
        s = substr(s, 1, RSTART-1) "<strong>" substr(s, RSTART+2, RLENGTH-4) "</strong>" substr(s, RSTART+RLENGTH)
    }
    while (match(s, /\[[^]]+\]\([^)]+\)/)) {
        link = substr(s, RSTART, RLENGTH)
        t = link; sub(/^\[/, "", t); sub(/\]\(.*/, "", t)
        u = link; sub(/^[^]]*\]\(/, "", u); sub(/\)$/, "", u)
        s = substr(s, 1, RSTART-1) "<a href='" u "'>" t "</a>" substr(s, RSTART+RLENGTH)
    }
    return s
}

# 侧栏短标签：已知章节用统一短名（正文标题完全不受影响，完整标题见悬停 title）
#   新增章节若要短名，在此加一行；未命中的按原样显示
function toc_short(s) {
    if (s == "硬件概览（配置单，自动生成自检测数据）") return "硬件概览"
    if (s == "PCIe 链路明细（附录）") return "链路明细"
    if (s == "PCIe 拓扑与链路")      return "链路"
    if (s == "NVSwitch 域（Fabric）") return "交换域"
    if (s == "板载与外部接口")        return "板载"
    if (s == "电源 PSU")             return "电源"
    if (s == "RAID 控制器")           return "RAID"
    if (s == "验收项")               return "验收项目"
    if (s == "结论")                 return "验收结论"
    return s
}

# 属性值转义（单引号属性里不能出现 '）
function attr_esc(s) {
    s = esc_html(s)
    gsub(/'/, "&#39;", s)
    return s
}

function cell_class(s) {
    if (s ~ /FAIL|不合格|❌/) return "fail"
    if (s ~ /WARN|⚠️/) return "warn"
    if (s ~ /PASS|✅|合格/) return "pass"
    if (s ~ /N\/A$|^—$|^无$|数据不足/) return "na"   # N/A 锚定结尾：匹配 "N/A" 与 "— N/A"，不误伤 "N/A（...）" 说明
    return ""
}

END {
    close_table()
    if (in_section) print "</section>"
    if (!toc_done) print "</header><main class='main'><div class='container'>"
    print "</div></main><a class='top' href='#'>↑ 顶部</a></div><script>(function(){function f(){var t=document.querySelector('.toc');if(!t)return;var r=t.getBoundingClientRect();var h=r.top<=17?(innerHeight-32):(innerHeight-r.top-16);t.style.height=Math.max(200,Math.round(h))+'px';}window.addEventListener('scroll',f,{passive:true});window.addEventListener('resize',f);if(document.readyState!=='loading'){f();}else{document.addEventListener('DOMContentLoaded',f);}})()</script></body></html>"
}
