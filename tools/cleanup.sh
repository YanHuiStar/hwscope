#!/bin/bash
# =============================================================================
# cleanup.sh — 清理 HwScope 采集输出（output/ 与 logs/）
# 用法: bash cleanup.sh          # 交互确认（输入 yes 才执行）
#       bash cleanup.sh --force  # 跳过确认（谨慎使用）
# 安全: 默认显示将删除的目录/大小/文件数，必须输入 yes 才删除；输出目录为采集产物
#       （.gitignore 已排除），不影响项目源码
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

TARGETS=("${SCRIPT_DIR}/output" "${SCRIPT_DIR}/logs")
EXIST=()
for t in "${TARGETS[@]}"; do
    [ -d "$t" ] && EXIST+=("$t")
done

if [ "${#EXIST[@]}" -eq 0 ]; then
    echo -e "\033[0;33m[INFO] output/ 与 logs/ 均不存在，无需清理\033[0m"
    exit 0
fi

echo -e "\033[0;36m════ 将清理以下目录 ════\033[0m"
for t in "${EXIST[@]}"; do
    SIZE=$(du -sh "$t" 2>/dev/null | cut -f1)
    FILES=$(find "$t" -type f 2>/dev/null | wc -l)
    echo "  ${t}  (${SIZE}, ${FILES} 个文件)"
done

if [ "$FORCE" -ne 1 ]; then
    echo ""
    read -rp "输入 yes 确认删除（其他输入取消）: " ANS
    if [ "$ANS" != "yes" ] && [ "$ANS" != "YES" ]; then
        echo -e "\033[0;33m已取消\033[0m"
        exit 1
    fi
fi

rm -rf "${EXIST[@]}"
echo -e "\033[0;32m[OK] 已清理 ${#EXIST[@]} 个目录\033[0m"
