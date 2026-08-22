#!/bin/bash
# =============================================================================
# gpu_burn_test.sh — GPU 长时满载压测（gpu-burn，官方 wilicc/gpu-burn）
# test/gpu_burn_test.sh
# 用法: bash test/gpu_burn_test.sh [时长秒]      # 默认 1800（30 分钟）
#       bash test/gpu_burn_test.sh 3600          # 指定时长（如 1 小时）
#       bash test/gpu_burn_test.sh -h            # 帮助
# 说明: 薄封装——实际执行复用 gpu_test.sh 的 gpu_burn 分支（含 -tc Tensor cores、
#       compare.ptx 目录定位、server_info 日志头）；本脚本仅提供"默认 1800 秒长压测"入口。
#       gpu-burn 官方参数 `gpu-burn [OPTIONS] [TIME]`：时长是位置参数、-tc = Tensor cores。
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # 项目根（test/ 的上级）

case "${1:-}" in
    -h|--help|-help)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac

# 时长（位置参数；非法或缺失回退 1800）
BURN_TIME="${1:-}"
[[ "$BURN_TIME" =~ ^[0-9]+$ ]] || BURN_TIME=1800

exec bash "${SCRIPT_DIR}/test/gpu_test.sh" gpu_burn "${BURN_TIME}"
