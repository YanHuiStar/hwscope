#!/bin/bash
# =============================================================================
# sync_version.sh — 从 hwscope.sh 读取版本号，同步到 README.md
# 用法: bash tools/sync_version.sh
# 原理: hwscope.sh 的 HWSCOPE_VERSION 是唯一权威来源，
#       本脚本读取后自动更新 README.md 的 Version 徽章。
#       不修改 hwscope.sh 本身（只读）。
# =============================================================================

set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ─── 从 hwscope.sh 读取版本号（只读）───
HWSCOPE="${SCRIPT_DIR}/hwscope.sh"
if [ ! -f "$HWSCOPE" ]; then
    echo "[ERROR] 找不到 hwscope.sh: ${HWSCOPE}" >&2; exit 1
fi

VER=$(grep '^HWSCOPE_VERSION=' "$HWSCOPE" | head -1 | sed 's/.*"\(.*\)"/\1/')
VER_NUM="${VER#v}"

if [ -z "$VER" ] || [ "$VER" = "$VER_NUM" ]; then
    echo "[ERROR] 无法从 hwscope.sh 读取 HWSCOPE_VERSION（格式：HWSCOPE_VERSION=\"vX.Y.Z\"）" >&2
    exit 1
fi

echo "[INFO] 版本: ${VER}"

# ─── 同步 README.md（Version 徽章）───
README="${SCRIPT_DIR}/README.md"
if [ ! -f "$README" ]; then
    echo "[WARN] README.md 不存在，跳过"; exit 0
fi

# 备份（防万一可回滚）
cp "$README" "${README}.bak"

# 替换 Version 徽章（精确匹配 **Version:** 后跟数字）
if sed "s/\*\*Version:\*\* [0-9][0-9.]*/\*\*Version:\*\* ${VER_NUM}/" "$README" > "${README}.tmp"; then
    mv "${README}.tmp" "$README"
    rm -f "${README}.bak"
    echo "[OK] README.md → ${VER_NUM}"
else
    echo "[ERROR] sed 替换失败，已回滚" >&2
    mv "${README}.bak" "$README"
    rm -f "${README}.tmp"
    exit 1
fi

# ─── 验证一致性 ───
echo ""
echo "=== 版本一致性检查 ==="
echo "hwscope.sh : ${VER}"
grep -m1 "Version" "$README" | sed 's/^/README.md : /'

# 确认 README 版本号已更新
README_VER=$(grep -oP '\*\*Version:\*\* \K[0-9][0-9.]*' "$README" | head -1)
if [ "$README_VER" != "$VER_NUM" ]; then
    echo "[ERROR] README 版本不一致: 期望 ${VER_NUM}, 实际 ${README_VER}" >&2
    exit 1
fi

echo ""
echo "[DONE] 版本同步完成（三处一致：hwscope.sh 注释 + 变量 + README 徽章）"
