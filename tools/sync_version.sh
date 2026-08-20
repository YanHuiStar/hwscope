#!/bin/bash
# =============================================================================
# sync_version.sh — 从 hwscope.sh 读取版本号，同步到 hwscope.sh 注释 + README.md
# 用法: bash tools/sync_version.sh
# 原理: hwscope.sh 的 HWSCOPE_VERSION 是唯一权威来源，
#       本脚本读取后自动同步到：
#       ① hwscope.sh 头部注释行 (# Version : X.Y.Z)
#       ② README.md 的 Version 徽章
# =============================================================================

set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ─── 帮助 ───
case "${1:-}" in
    -h|--help)
        sed -n '2,/^[^#]/p' "$0" | sed 's/^# \?//' | sed '/^$/d'
        echo ""
        exit 0 ;;
esac

# ─── 从 hwscope.sh 读取版本号（只读）───
HWSCOPE="${SCRIPT_DIR}/hwscope.sh"
if [ ! -f "$HWSCOPE" ]; then
    echo "[ERROR] 找不到 hwscope.sh: ${HWSCOPE}" >&2; exit 1
fi

VER=$(grep '^HWSCOPE_VERSION=' "$HWSCOPE" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)   # || true：pipefail 下无匹配静默退出会吞掉下方友好报错（v1.33.3）
VER_NUM="${VER#v}"

if [ -z "$VER" ] || [ "$VER" = "$VER_NUM" ]; then
    echo "[ERROR] 无法从 hwscope.sh 读取 HWSCOPE_VERSION（格式：HWSCOPE_VERSION=\"vX.Y.Z\"）" >&2
    exit 1
fi

echo "[INFO] 版本: ${VER}"

# ─── 同步 hwscope.sh 头部注释行 ───
# 替换 # Version : X.Y.Z 中的版本号
if sed "s/^# Version : [0-9][0-9.]*/# Version : ${VER_NUM}/" "$HWSCOPE" > "${HWSCOPE}.tmp"; then
    mv "${HWSCOPE}.tmp" "$HWSCOPE"
    echo "[OK] hwscope.sh 注释 → ${VER_NUM}"
else
    echo "[ERROR] hwscope.sh 注释同步失败" >&2
    rm -f "${HWSCOPE}.tmp" 2>/dev/null || true
    exit 1
fi

# ─── 同步 README.md（Version 徽章）───
README="${SCRIPT_DIR}/README.md"
if [ ! -f "$README" ]; then
    echo "[WARN] README.md 不存在，跳过"; exit 0
fi

# 备份（防万一可回滚）
cp "$README" "${README}.bak"

# 替换 Version 徽章（精确匹配 **Version:** 后跟数字，兼容 v 前缀——README 写 v1.34.14 格式）
if sed "s/\*\*Version:\*\* v\?[0-9][0-9.]*/\*\*Version:\*\* ${VER_NUM}/" "$README" > "${README}.tmp"; then
    mv "${README}.tmp" "$README"
    rm -f "${README}.bak" 2>/dev/null || true
    echo "[OK] README.md → ${VER_NUM}"
else
    echo "[ERROR] sed 替换失败，已回滚" >&2
    mv "${README}.bak" "$README" 2>/dev/null || true
    rm -f "${README}.tmp" 2>/dev/null || true
    exit 1
fi

# ─── 验证一致性 ───
echo ""
echo "=== 版本一致性检查 ==="
echo "hwscope.sh 变量 : ${VER}"
HEAD_VER=$(grep -m1 "^# Version" "$HWSCOPE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)   # || true：pipefail 兼容（v1.33.3）
echo "hwscope.sh 注释 : ${HEAD_VER}"
grep -m1 "Version" "$README" | sed 's/^/README.md      : /'

# 确认三处版本号一致
if [ "$HEAD_VER" != "$VER_NUM" ]; then
    echo "[ERROR] hwscope.sh 注释不一致: 期望 ${VER_NUM}, 实际 ${HEAD_VER}" >&2
    exit 1
fi

# 改用 sed 提取（grep -oP 依赖 GNU grep 的 -P/\K，busybox/macOS 不可用——v1.33.3；v\? 兼容 README 的 v 前缀）
README_VER=$(sed -n 's/.*\*\*Version:\*\* v\?\([0-9][0-9.]*\).*/\1/p' "$README" | head -1)
if [ "$README_VER" != "$VER_NUM" ]; then
    echo "[ERROR] README 版本不一致: 期望 ${VER_NUM}, 实际 ${README_VER}" >&2
    exit 1
fi

echo ""
echo "[DONE] 版本同步完成（三处一致：hwscope.sh 注释 + 变量 + README 徽章）"
