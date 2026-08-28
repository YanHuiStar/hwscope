#!/bin/sh
# HwScope CRLF Fix — run this first if copied from Windows
# v1.47.1: 递归覆盖 report/**、modules/gpu/**、tools/agent/**、docs/**、tools/win/*.ps1（原 glob 不递归子目录，会漏修）
# 修复：.sh/.conf/.md/.awk/.txt/.ps1 统一转 LF（ps1 只剥 \r，UTF-8 BOM 保留，PowerShell 兼容 LF）
# 排除：*.bat（cmd 需 CRLF，AGENTS.md v1.43.2 教训）、.git/、output/、logs/
find . -type f \( -name '*.sh' -o -name '*.conf' -o -name '*.md' -o -name '*.awk' -o -name '*.txt' -o -name '*.ps1' \) \
    -not -path './.git/*' -not -path './output/*' -not -path './logs/*' \
    -exec sed -i 's/\r$//' {} +
echo "Done. Run: sudo bash hwscope.sh"
