#!/bin/bash
# =============================================================================
# HwScope — 兼容 wrapper
# 主入口已迁移至 report/report.sh（v1.35.0 refactor，行为不变）
# 旧路径 `bash tools/report.sh ...` 继续可用；新路径为 `bash report/report.sh ...`
# =============================================================================
exec bash "$(cd "$(dirname "$0")/.." && pwd)/report/report.sh" "$@"
