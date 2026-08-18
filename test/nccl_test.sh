#!/bin/bash
# =============================================================================
# HwScope — NCCL 集群通信测试
# test/nccl_test.sh
# 用法: bash test/nccl_test.sh
# 功能: all_reduce_perf / all_gather_perf / all_to_all_perf 带宽验证
# 依赖: nccl-tests (编译产物 all_reduce_perf 等)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

# ─── 查找 nccl-tests 编译产物（限常见路径，避免全盘扫描） ───
BIN_DIR=""
PERF_BIN=""
for cand in \
    "${SCRIPT_DIR}/nccl-tests/build" \
    "/opt/nccl-tests/build" \
    "/usr/local/nccl-tests/build" \
    "${HOME}/nccl-tests/build" \
    "$(find /usr /opt /root ${HOME} -maxdepth 4 -name "all_reduce_perf" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null)"; do
    if [ -n "$cand" ] && [ -x "${cand}/all_reduce_perf" ]; then
        BIN_DIR="$cand"
        PERF_BIN="${cand}/all_reduce_perf"
        break
    fi
done

if [ -z "$PERF_BIN" ]; then
    echo -e "${RED}[ERROR] 未找到 nccl-tests 编译产物 (all_reduce_perf)${NC}"
    echo ""
    echo "  手动安装部署步骤:"
    echo "  ─────────────────────────────────────────────"
    echo "  1. 确认 NCCL 已安装:  ldconfig -p | grep nccl"
    echo "     (未安装: 见 NVIDIA 官方 NCCL 文档或容器镜像)"
    echo ""
    echo "  2. 获取源码并编译:"
    echo "     git clone https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests"
    echo "     cd /opt/nccl-tests"
    echo "     make NCCL_HOME=/usr/local/nccl2"
    echo "     # NCCL 在标准路径时直接 make 即可"
    echo ""
    echo "  3. 验证编译产物:"
    echo "     ls /opt/nccl-tests/build/all_reduce_perf"
    echo ""
    echo "  4. 重新运行本脚本"
    echo "  ─────────────────────────────────────────────"
    exit 1
fi

echo -e "${GREEN}[OK] 找到 nccl-tests: ${BIN_DIR}${NC}"

# ─── GPU 数量 ───
GPU_N=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
[ "$GPU_N" -lt 1 ] && echo -e "${RED}[ERROR] 未检测到 GPU${NC}" && exit 1
echo -e "${CYAN}[INFO] 检测到 ${GPU_N} 张 GPU${NC}"

# ─── 测试菜单 ───
TESTS=(
    "1:all_reduce_perf:AllReduce (梯度同步，最常用)"
    "2:all_gather_perf:AllGather (前向激活聚合)"
    "3:all_to_all_perf:AllToAll (MoE 专家路由)"
    "4:reduce_scatter_perf:ReduceScatter (反向梯度)"
    "5:broadcast_perf:Broadcast (参数广播)"
)

echo ""
echo -e "${CYAN}可选测试:${NC}"
for t in "${TESTS[@]}"; do
    IFS=':' read -r num name desc <<< "$t"
    echo -e "  ${GREEN}[${num}]${NC} ${name} — ${desc}"
done
echo ""
read -p "选择 (1-5, 逗号分隔; Enter 跳过): " -r choices
[ -z "$choices" ] && echo "跳过" && exit 0

# ─── 消息大小 / 轮次 ───
read -p "起始大小 -b (默认 1G): " -r MSG_B
[ -z "$MSG_B" ] && MSG_B="1G"
read -p "终止大小 -e (默认 4G): " -r MSG_E
[ -z "$MSG_E" ] && MSG_E="4G"
read -p "迭代轮数 -n (默认 20): " -r ITERS
[ -z "$ITERS" ] && ITERS="20"

test_init "nccl"

IFS=',' read -ra SELECTED <<< "$choices"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for t in "${TESTS[@]}"; do
        IFS=':' read -r num name desc <<< "$t"
        [ "$sel" != "$num" ] && continue
        echo "" | tee -a "$REPORT_LOG"
        echo -e "${CYAN}━━━ ${name} 测试 (${GPU_N} GPU) ━━━${NC}" | tee -a "$REPORT_LOG"
        start_ts=$(date +%s)
        LOGFILE="${REPORT_DIR}/${name}_detail.log"
        run_and_log "${BIN_DIR}/${name} -b ${MSG_B} -e ${MSG_E} -f 2 -g ${GPU_N} -n ${ITERS} -w 5 2>&1" "$LOGFILE"
        test_record "$name" "$LOGFILE" "$start_ts" "$?"
    done
done

test_finish "nccl"
