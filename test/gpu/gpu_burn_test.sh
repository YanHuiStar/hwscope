#!/bin/bash
# =============================================================================
# gpu_burn_test.sh — GPU 长时满载压测（gpu-burn，官方 wilicc/gpu-burn）
# test/gpu/gpu_burn_test.sh
# 用法: bash test/gpu/gpu_burn_test.sh [时长秒]      # 默认 1800（30 分钟）
#       bash test/gpu/gpu_burn_test.sh 3600          # 指定时长（如 1 小时）
#       bash test/gpu/gpu_burn_test.sh -h            # 帮助
# 说明: gpu-burn 官方参数 `gpu-burn [OPTIONS] [TIME]`：时长位置参数、-tc = Tensor cores
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true

BURN_TIME="${1:-}"
[[ "$BURN_TIME" =~ ^[0-9]+$ ]] || BURN_TIME=1800

# 查找 gpu_burn 程序（PATH + 常见路径）
GB_BIN=$(command -v gpu_burn 2>/dev/null)
[ -z "$GB_BIN" ] && GB_BIN=$(find /usr /opt /root /home -maxdepth 4 -name "gpu_burn" -type f -executable 2>/dev/null | head -1)
if [ -z "$GB_BIN" ]; then
    echo -e "${RED}[ERROR] gpu_burn 未找到（git clone https://github.com/wilicc/gpu-burn && make）${NC}"
    exit 1
fi

test_init "gpu_burn"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
start_ts=$(date +%s)
LOGFILE="${REPORT_DIR}/gpu_burn_detail.log"
echo "" | tee -a "$REPORT_LOG"
echo -e "${CYAN}━━━ GPU 满载压测 (gpu_burn -tc, ${BURN_TIME}s) ━━━${NC}" | tee -a "$REPORT_LOG"
# cd 到 gpu_burn 所在目录：compare.ptx 与二进制同目录（v1.38.5 修复）
gb_dir=$(dirname "$GB_BIN")
run_and_log "cd '${gb_dir}' && ./gpu_burn -tc ${BURN_TIME} 2>&1" "$LOGFILE"
test_record "gpu_burn" "$LOGFILE" "$start_ts" "$?"
test_finish "gpu_burn"
