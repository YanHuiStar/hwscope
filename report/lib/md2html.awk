# md2html.awk — HwScope 报告 Markdown → HTML 转换器
# 用法: awk -f md2html.awk hwscope_report.md > hwscope_report.html
# 特性: 卡片分区（## 段）、表格状态着色（PASS/WARN/FAIL/N/A）、斑马纹、引用块、打印友好
# 依赖: 仅 awk（gawk/mawk 均可），无外部工具
#
# ⚠️ CSS 输出顺序 = 源序（BEGIN 里 print 的先后就是样式表里的先后）。
#   同特异度的规则**后打印的覆盖先打印的** —— 媒体查询要覆盖基础规则时必须打印在
#   基础规则**之后**，否则会被静默吃掉（v1.53.33 的 ≤1400px 断词规则就因此失效，v1.54.0 修正）。

BEGIN {
    print "<!DOCTYPE html>"
    print "<html lang='zh'>"
    print "<head>"
    print "<meta charset='UTF-8'>"
    print "<meta name='viewport' content='width=device-width, initial-scale=1.0'>"
    print "<title>HwScope 硬件巡检报告</title>"
    print "<style>"
    print "body{font-family:'Microsoft YaHei','PingFang SC','Noto Sans SC',sans-serif;background:#eef1f6;color:#2d3748;margin:0;padding:24px 16px;}"
    print ".container{max-width:1280px;margin:0 auto;}"
    # v1.53.29：三段式改 grid —— 页头跨满两列独占一行，侧边栏与正文同处第二行，
    #   既不换行、也不会互相覆盖（flex 的 wrap/basis 组合在窄屏会错位）
    print ".layout{max-width:1500px;margin:0 auto;display:grid;grid-template-columns:130px minmax(0,1fr);gap:16px;align-items:start;}"
    print ".pagehead{grid-column:1 / -1;grid-row:1;}"
    print ".toc{grid-column:1;grid-row:2;}"
    print ".main{grid-column:2;grid-row:2;}"
    # v1.53.24：header 必须占满整行（否则 flex-wrap 会把侧边栏挤到它右边）；
    #   宽度与正文容器对齐交给内部子元素各自限宽居中
    print ".pagehead>*{max-width:1280px;margin-left:auto;margin-right:auto;}"
    # v1.53.26：页头三段（标题/副标题/采集信息行）统一以卡片区中线居中 ——
    #   此前标题居中而信息行左对齐，两条视觉轴不一致，看起来「歪」
    print ".pagehead>p{text-align:center;}"
    # v1.53.25：宽屏下页头让出侧边栏占位（140 栏宽 + 16 间距），使其内部容器与正文 .container
    #   同起点 —— 否则页头按整行居中、正文按 main 居中，两者左边界差 78px（信息行看起来「漂」到偏左）
    print "@media (min-width:900px){.pagehead{padding-left:146px;}}"
    print ".toc{position:sticky;top:16px;flex:0 0 140px;box-sizing:border-box;display:flex;flex-direction:column;overflow:hidden;max-height:calc(100vh - 32px);background:#fff;border-radius:10px;box-shadow:0 2px 10px rgba(30,58,95,.08);padding:10px 6px;font-size:12.5px;}"
    print ".toc-title{font-weight:600;color:#1e3a5f;margin:0 0 8px;padding-left:4px;border-left:3px solid #1e3a5f;}"
    print ".toc ul{list-style:none;margin:0;padding:0;flex:1 1 auto;overflow-y:auto;min-height:0;}"
    print ".toc li{margin:1px 0;}"
    print ".toc a{display:block;padding:3px 8px;color:#4a5568;text-decoration:none;border-radius:5px;line-height:1.5;text-align:center;}"
    print ".toc a:hover{background:#eef3fa;color:#1e3a5f;}"
    print ".toc li.sep{margin:8px 0 2px;padding:8px 0 0;border-top:1px solid #e2e8f0;font-size:11px;color:#a0aec0;letter-spacing:2px;text-align:center;}"
    # v1.53.23：首张卡片上边距归零 —— 侧边栏与第一张卡片从同一条顶线开始（纯 CSS，不靠 JS 挪位置）
    print ".main .container > section.card:first-of-type{margin-top:0;}"
    # v1.53.27：目录跳转后卡片停在距视口顶 16px（与 .toc 的 sticky top 一致），不再顶到 0
    print "section.card{scroll-margin-top:16px;}"
    # v1.53.32：窄屏 / 笔记本半屏 —— 取消原「zoom 等比微缩」方案（Firefox 不支持 zoom，
    #   且连字体一起缩小、半屏下字变得很小），改为常规响应式三档：
    #   ≥1201 目录+正文并排 ｜ ≤1200 收窄目录列 ｜ ≤1024 目录变**顶部横向吸附条**（导航不再消失）
    #   宽表格不再靠 table{display:block} 硬压，改由 .tw 容器横向滚动（列宽保持自然）
    print "@media (max-width:1200px){.layout{grid-template-columns:120px minmax(0,1fr);}.pagehead{padding-left:136px;}}"
    print "@media (max-width:1024px){.layout{display:block;max-width:none;}}"
    print "@media (max-width:1024px){.pagehead{grid-column:1;grid-row:1;padding-left:0;}}"
    print "@media (max-width:1024px){.toc{grid-column:1;grid-row:2;position:sticky;top:0;height:auto;max-height:none;margin:0 0 10px;flex-direction:row;flex-wrap:wrap;align-items:center;gap:6px;padding:8px 10px;z-index:5;}}"
    print "@media (max-width:1024px){.toc-title{margin:0;padding:0 8px 0 0;border-left:none;border-right:3px solid #1e3a5f;white-space:nowrap;}}"
    print "@media (max-width:1024px){.toc ul{display:flex;flex-wrap:wrap;gap:3px;overflow:visible;flex:1 1 100%;width:100%;min-height:0;min-width:0;}}"
    print "@media (max-width:1024px){.toc li{margin:0;}.toc a{padding:2px 8px;border:1px solid #e3e9f2;}.toc li.sep{display:none;}}"
    print "@media (max-width:1400px){.tw{overflow-x:auto;-webkit-overflow-scrolling:touch;margin:6px 0 10px;}}"
    # v1.54.28：只有列数多的「宽表」才按 max-content 撑开横向滚动；
    #   窄表（≤5 列，如验收项/硬件概览/结论）改用正常换行——
    #   实测 B200 验收项表被 182 字的说明撑到 1843px（容器 1129px），
    #   结果/说明两列被推出屏幕，看起来像排版坏了。
    print "@media (max-width:1400px){.tw>table{margin:0;}}"
    print "@media (max-width:1400px){.tw.wide>table{margin:0;min-width:max-content;}}"
    print "@media (max-width:1024px){.main{grid-column:auto;grid-row:auto;}}"
    print "@media (max-width:760px){body{padding:12px 8px;}.card{padding:12px 14px;}h1{font-size:20px;}.subtitle{margin-bottom:14px;}table{font-size:12px;}th,td{padding:5px 7px;}.top{right:10px;bottom:10px;}}"
    print "html{scroll-behavior:smooth;}"
    print ".top{position:fixed;right:18px;bottom:18px;background:#1e3a5f;color:#fff;padding:7px 12px;border-radius:20px;font-size:12px;text-decoration:none;opacity:.85;}"
    print ".top:hover{opacity:1;}"
    print "h1{text-align:center;color:#1e3a5f;font-size:24px;margin:0 0 6px;letter-spacing:2px;}"
    print ".subtitle{text-align:center;color:#718096;font-size:12px;margin:0 auto 24px;}"
    print ".card{background:#fff;border-radius:10px;box-shadow:0 2px 10px rgba(30,58,95,.08);padding:14px 22px;margin:14px 0;}"
    print ".card h2{color:#1e3a5f;font-size:16px;margin:0 0 10px;border-left:4px solid #1e3a5f;padding-left:10px;}"
    print ".card h3{color:#4a5568;font-size:13px;margin:12px 0 6px;}"
    # v1.53.32：.tw 默认**不改变任何布局**（不形成 BFC、不动外边距折叠）——宽屏与修复前逐像素一致；
    #   只在需要横向滚动的窄屏才打开 overflow（见 1400/1024 断点）
    print ".tw{max-width:100%;}"
    print "table{width:100%;border-collapse:collapse;font-size:12.5px;margin:6px 0 10px;}"
    print "th{background:#1e3a5f;color:#fff;padding:7px 10px;text-align:left;font-weight:500;white-space:nowrap;}"
    print "td{padding:6px 10px;border-bottom:1px solid #e8ecf2;word-break:break-all;}"
    # v1.54.28：序号列与结果状态列不换行 —— 窄表改自动换行后，长说明会把这些短列挤到逐字折行
    #   （实测「10」被拆成「1 / 0」、「✅ PASS」被拆两行），加 nowrap 后只让说明列换行。
    print "td:first-child,th:first-child{white-space:nowrap;}"
    print "td.pass,td.warn,td.fail,td.na{white-space:nowrap;}"
    # P3-5：必须在上面基础 td 规则**之后**才能生效（同特异度按源序，后者胜）
    print "@media (max-width:1400px){td{word-break:normal;overflow-wrap:anywhere;}}"
    # P3-6：窄屏（≤1024）toc 变成顶部吸附条（高 64~121px），锚点跳转需要更大的顶部留白，
    #   否则目标卡片标题会被吸附条盖住；宽屏沿用 16px（= 侧栏 sticky top）
    print "@media (max-width:1024px){section.card{scroll-margin-top:130px;}}"
    print "tr:nth-child(even) td{background:#f7f9fc;}"
    print "tr:hover td{background:#eef3fa;}"
    print ".pass{color:#1a7f37;font-weight:600;}"
    print ".warn{color:#b45309;font-weight:600;}"
    print ".fail{color:#dc2626;font-weight:600;}"
    print ".na{color:#9ca3af;}"
    print "blockquote{background:#fffaf0;border-left:4px solid #ed8936;padding:8px 14px;margin:8px 0;color:#7c5314;font-size:12.5px;border-radius:0 6px 6px 0;}"
    print "li{margin:3px 0;font-size:13px;}"
    print "hr{border:none;border-top:1px solid #e2e8f0;margin:14px 0;}"
    # v1.53.31：打印 / PDF 版式整备（此前 PDF 排版异常：页头右移、卡片无边界、纸张为默认 Letter）
    print "@page{size:A4;margin:12mm;}"
    print "@media print{body{background:#fff;padding:0;margin:0;}}"
    print "@media print{.toc,.top{display:none !important;}}"
    # 复位屏幕态的布局补偿：侧边栏让位与窄屏缩放都不该进纸面
    print "@media print{.layout{display:block !important;max-width:none;zoom:1 !important;} .main,.container{width:auto;max-width:none;} .pagehead{padding-left:0 !important;margin-bottom:10px;}}"
    # 卡片在白纸上要有可见边界（原来 #dde3ea 几乎看不见），且不跨页断开
    print "@media print{.card{box-shadow:none;border:1px solid #a0aec0;border-radius:0;background:#fff;margin:10px 0;padding:10px 14px;break-inside:avoid;page-break-inside:avoid;} .card h2{border-left:4px solid #1e3a5f;}}"
    # 表头深色底必须强制输出（否则浏览器"省墨"打成白底黑字）
    print "@media print{th{background:#1e3a5f !important;color:#fff !important;-webkit-print-color-adjust:exact;print-color-adjust:exact;border:1px solid #1e3a5f;} td{border-bottom:1px solid #cbd5e0;} table{border-collapse:collapse;width:100%;}}"
    # 附录长表允许跨页，但每行不拆开
    print "@media print{tr{break-inside:avoid;page-break-inside:avoid;} blockquote{border-left:3px solid #ed8936;-webkit-print-color-adjust:exact;print-color-adjust:exact;}}"
    # v1.53.31 补：A4 纵向纸宽 ≈794px < 900px 断点，窄屏的「表格转块级横向滚动」会漏进打印
    #   → 表格收缩不占满、列不换行。打印里必须复位成正常 table 布局
    print "@media print{table{display:table !important;overflow:visible !important;white-space:normal !important;width:100% !important;min-width:0 !important;} thead{display:table-header-group;} tbody{display:table-row-group;}}"
    print "@media print{.tw{overflow:visible !important;}}"
    print "@media print{.toc{position:static !important;}}"
    print "@media print{.top{right:12px;bottom:12px;}}"
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
    if (in_table) { print "</tbody></table></div>"; in_table = 0 }
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
    # v1.53.27：锚点 id 挂在 section 上（原挂 h2），配合 scroll-margin-top 让跳转后
    #   卡片顶部与侧边栏目录顶部同高
    print "<section class='card' id='sec-" nsec "'><h2>" sec "</h2>"
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
        print "<div class='tw" (n >= 6 ? " wide" : "") "'><table><thead><tr>"
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
        if (cls != "") print "<td class='" cls "'>" cell_br(inline_md(esc_html(c))) "</td>"
        else print "<td>" cell_br(inline_md(esc_html(c))) "</td>"
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
    if (in_table) { print "</tbody></table></div>"; in_table = 0 }
}

function trim_cell(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}

# HTML 转义（先 & 后 < > "，防二次转义）；cell_class 在转义前调用（用原始文本判色）
# v1.54.28：受控换行——MD 源里写 <br> 时，还原成真正的换行标签（其余标签仍转义）。
#   用途：表格单元格里「结论」与「解释/建议」分两行，避免一行长文把表格拉宽、也更好读。
function cell_br(s) {
    gsub(/&lt;br[ \t]*\/?&gt;/, "<br>", s)
    return s
}

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
function toc_short(s,   r) {
    r = ""
    if (s == "硬件概览（配置单，自动生成自检测数据）") r = "硬件概览"
    else if (s == "PCIe 链路明细（附录）") r = "链路明细"
    else if (s == "PCIe 拓扑与链路")      r = "链路"
    else if (s == "NVSwitch 域（Fabric）") r = "交换域"
    else if (s == "板载与外部接口")        r = "板载"
    else if (s == "电源 PSU")             r = "电源"
    else if (s == "RAID 控制器")           r = "RAID"
    else if (s == "主机总线适配器明细（HBA）") r = "HBA 明细"
    else if (s == "验收项")               r = "验收项目"
    else if (s == "验收项目") r = "验收项目"
    else if (s == "结论")                 r = "验收结论"
    if (r != "") return r
    # 建议4：侧栏按 4 字设计，未映射的长标题会折行 —— 打一行 stderr 提示补映射。
    #   判据用字节数 >12（中文 4 字 = 12 字节），gawk/mawk 下都成立，避开 length() 的字符/字节差异。
    #   必须在「未命中分支」里判断：若挂在函数末尾 return 前，attr_esc() 这类对每个属性值
    #   都调用的地方也会触发，把已映射的标题也报成"无短名映射"（实测踩过）。
    if (length(s) > 12 && !(s in _toc_warned)) {
        _toc_warned[s] = 1
        printf "md2html: [WARN] 侧栏标签无短名映射（会折行）：%s —— 请在 toc_short() 补一行\n", s > "/dev/stderr"
    }
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
    # v1.53.32：侧栏高度 JS 必须感知断点 —— 窄屏（≤1024）目录是顶部横向条，高度交给 CSS；
    #   原实现无条件用 innerHeight 设高，笔记本半屏下会把横条撑到 ~746px，把正文整块压到屏幕外
    print "</div></main><a class='top' href='#'>↑ 顶部</a></div><script>(function(){function f(){var t=document.querySelector('.toc');if(!t)return;if(window.matchMedia('(max-width:1024px)').matches){t.style.height='';return;}var r=t.getBoundingClientRect();var h=r.top<=17?(innerHeight-32):(innerHeight-r.top-16);t.style.height=Math.max(200,Math.round(h))+'px';}window.addEventListener('scroll',f,{passive:true});window.addEventListener('resize',f);if(document.readyState!=='loading'){f();}else{document.addEventListener('DOMContentLoaded',f);}})()</script></body></html>"
}
