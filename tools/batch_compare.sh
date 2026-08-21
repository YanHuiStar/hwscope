#!/bin/bash
# =============================================================================
# HwScope — 兼容 wrapper
# 主入口已迁移至 report/tools/batch_compare.sh（v1.35.0 refactor，行为不变）
# 旧路径 `bash tools/batch_compare.sh ...` 继续可用
# =============================================================================
exec bash "$(cd "$(dirname "$0")/.." && pwd)/report/tools/batch_compare.sh" "$@"
