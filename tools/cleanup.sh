#!/bin/bash
# =============================================================================
# cleanup.sh — 清理 HwScope 采集输出（output/ 与 logs/）
# 用法: bash cleanup.sh          # 交互确认（输入 yes 才执行）
#       bash cleanup.sh --force  # 跳过确认（谨慎使用）
#       bash cleanup.sh -h       # 显示帮助
# 安全: 默认显示将删除的目录/大小/文件数，必须输入 yes 才删除；输出目录为采集产物
#       （.gitignore 已排除），不影响项目源码
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "用法: $0 [-h|--help] [--force]"
    echo "功能: 清理采集产物目录 output/ 与 logs/（.gitignore 已排除，不碰项目源码）"
    echo "选项:"
    echo "  --force       跳过交互确认，直接删除（谨慎使用）"
    echo "  -h, --help    显示本帮助"
    echo ""
    echo "示例:"
    echo "  bash $0            # 先列出目录/大小/文件数，输入 yes 才删除"
    echo "  bash $0 --force    # 无确认直接清理"
    echo ""
}

# v1.50.5：补 help 分支 + 未知参数明确报错（此前仅识别 --force，其他参数被静默忽略后
#   直接进入清理流程；破坏性工具遇 `-h`/打错 flag 不报错即干活的隐患）
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)    FORCE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo -e "\033[0;31m[ERROR] 未知参数: $1\033[0m"; usage; exit 1 ;;
    esac
done

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
