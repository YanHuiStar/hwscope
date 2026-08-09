#!/bin/bash
# =============================================================================
# sync_version.sh — 从 hwscope.sh 读取版本号，同步到 README.md / AGENTS.md
# 用法: bash tools/sync_version.sh
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 从 hwscope.sh 读取版本号（唯一权威来源）
VER=$(grep '^HWSCOPE_VERSION=' "${SCRIPT_DIR}/hwscope.sh" | head -1 | sed 's/.*"\(.*\)"/\1/')
VER_NUM="${VER#v}"  # 去掉 v 前缀

if [ -z "$VER" ] || [ "$VER" = "$VER_NUM" ]; then
    echo "[ERROR] 无法从 hwscope.sh 读取 HWSCOPE_VERSION" >&2
    exit 1
fi

echo "[INFO] 版本: ${VER}"

# 同步 README.md（Version 徽章）
README="${SCRIPT_DIR}/README.md"
if [ -f "$README" ]; then
    sed -i "s/\*\*Version:\*\* [0-9][0-9.]*/\*\*Version:\*\* ${VER_NUM}/" "$README"
    echo "[OK] README.md → ${VER_NUM}"
fi

# 同步 AGENTS.md（如有版本引用则更新，没有则跳过）
AGENTS="${SCRIPT_DIR}/AGENTS.md"
if [ -f "$AGENTS" ] && grep -q "Version.*${VER_NUM%.*}" "$AGENTS" 2>/dev/null; then
    echo "[OK] AGENTS.md 无需更新（无版本引用）"
fi

# 验证三处一致
echo ""
echo "=== 版本一致性检查 ==="
echo "hwscope.sh HWSCOPE_VERSION : ${VER}"
grep -m1 "Version" "$README" | sed 's/^/README.md : /'
echo ""
echo "[DONE] 版本同步完成"
