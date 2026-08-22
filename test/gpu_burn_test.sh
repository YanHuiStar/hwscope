#!/bin/bash
# =============================================================================
# gpu_burn_test.sh — GPU 长时满载压测（gpu-burn，官方 wilicc/gpu-burn）
# test/gpu_burn_test.sh
# 用法: bash test/gpu_burn_test.sh [时长秒]      # 默认 1800（30 分钟）
#       bash test/gpu_burn_test.sh 3600          # 指定时长（如 1 小时）
#       bash test/gpu_burn_test.sh -h            # 帮助
# 说明: gpu-burn 官方参数 `gpu-burn [OPTIONS] [TIME]`——时长是位置参数，
#       -tc = 使用 Tensor cores（张量核心）；本脚本默认 `gpu_burn -tc <时长>`
#       （v1.39.0 新增独立脚本；聚合入口 test/test_all.sh 第 8 项）
# 依赖: gpu_burn（/opt/gpu-burn/gpu_burn 或 PATH）；nvidia-smi
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # 项目根（test/ 的上级）
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

# ─── gpu_burn 定位（常见路径 → PATH） ───
GB=""
for c in /opt/gpu-burn/gpu_burn /usr/local/bin/gpu_burn /usr/bin/gpu_burn; do
    [ -x "$c" ] && GB="$c" && break
done
[ -z "$GB" ] && GB=$(command -v gpu_burn 2>/dev/null)
if [ -z "$GB" ]; then
    echo -e "${RED}[ERROR] 未找到 gpu_burn（/opt/gpu-burn/gpu_burn 或 PATH）${NC}"
    echo "  安装: git clone https://github.com/wilicc/gpu-burn && cd gpu-burn && make"
    exit 1
fi

# ─── 时长（位置参数；无则交互；非法回退 1800） ───
BURN_TIME="${1:-}"
if [ -z "$BURN_TIME" ]; then
    read -p "压测时长(秒, 默认 1800=30 分钟): " -r BURN_TIME
fi
[[ "$BURN_TIME" =~ ^[0-9]+$ ]] || BURN_TIME=1800

# ─── 初始化日志（含服务器信息头） ───
test_init "gpu_burn"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true

LOGFILE="${REPORT_DIR}/gpu_burn_detail.log"
start_ts=$(date +%s)
# cd 到 gpu_burn 所在目录执行（compare.ptx 与二进制同目录，防找不到 compare kernel）；
# -tc = Tensor cores（gpu-burn 官方参数）
GB_DIR=$(dirname "$GB")
GB_BIN=$(basename "$GB")
run_and_log "cd '${GB_DIR}' && ./${GB_BIN} -tc ${BURN_TIME} 2>&1" "$LOGFILE"
rc=$?
test_record "gpu_burn" "$LOGFILE" "$start_ts" "$rc"

test_finish "gpu_burn"
