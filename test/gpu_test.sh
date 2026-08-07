#!/bin/bash
# =============================================================================
# HwScope — GPU 测试（自动发现系统测试程序）
# test/gpu_test.sh
# 用法: bash test/gpu_test.sh
# 功能: 自动扫描系统已安装的 GPU 测试程序，列出可选，执行所选
#   支持: cuda bandwidthTest(P2P) / gpu_burn / nvbandwidth / partnerdiag 等
# 说明: 只调用系统已存在的测试程序，不自动安装
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

if ! check_cmd nvidia-smi; then
    echo -e "${RED}[ERROR] nvidia-smi 未安装（无 NVIDIA 驱动）${NC}"
    exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
echo -e "${CYAN}[INFO] 检测到 ${GPU_COUNT} 张 GPU${NC}"

# ─── 自动发现系统测试程序 ───
# 格式: name|路径|描述|参数模板
declare -a FOUND=()
declare -a TOOLS_LIST=()

# 常见搜索路径（避免全盘扫描）
SEARCH_DIRS=(
    "/opt" "/usr/local" "${HOME}" "/usr/bin" "/usr/lib/cuda"
    "${SCRIPT_DIR}/nccl-tests/build"
)

# 候选程序: 名称 | 描述 | 候选路径
declare -a CANDIDATES=(
    "bandwidthTest|CUDA P2P/内存带宽测试 (cuda-samples)|bandwidthTest"
    "gpu_burn|GPU 满载压测 (gpu-burn)|gpu_burn"
    "nvbandwidth|NVIDIA NVLink 带宽微基准|nvbandwidth"
    "all_reduce_perf|NCCL AllReduce 集合通信|all_reduce_perf"
    "partnerdiag|NVIDIA Field Diag (现场诊断)|partnerdiag"
)

find_gpu_test() {
    local name="$1" desc="$2" bin="$3"
    local found_path=""
    # 1. PATH 直接查
    found_path=$(command -v "$bin" 2>/dev/null)
    # 2. 常见目录 find（限深）
    if [ -z "$found_path" ]; then
        found_path=$(find "${SEARCH_DIRS[@]}" -maxdepth 4 -name "$bin" -type f -executable 2>/dev/null | head -1)
    fi
    if [ -n "$found_path" ]; then
        FOUND+=("$name|$found_path|$desc")
        TOOLS_LIST+=("$name:$found_path:$desc")
    fi
}

echo -e "${CYAN}扫描系统 GPU 测试程序...${NC}"
for cand in "${CANDIDATES[@]}"; do
    IFS='|' read -r cname cdesc cbin <<< "$cand"
    find_gpu_test "$cname" "$cdesc" "$cbin"
done

if [ ${#FOUND[@]} -eq 0 ]; then
    echo -e "${YELLOW}[WARN] 未找到任何已安装的 GPU 测试程序${NC}"
    echo ""
    echo "  可手动安装:"
    echo "    ├─ cuda-samples : 编译 bandwidthTest (见 CUDA 文档)"
    echo "    ├─ gpu-burn     : git clone https://github.com/wilicc/gpu-burn && make"
    echo "    ├─ nvbandwidth  : git clone https://github.com/NVIDIA/nvbandwidth && make"
    echo "    ├─ nccl-tests   : git clone https://github.com/NVIDIA/nccl-tests && make"
    echo "    └─ partnerdiag  : NVIDIA FLD 包 (现场诊断)"
    exit 1
fi

# ─── 菜单选择 ───
echo ""
echo -e "${CYAN}已发现测试程序:${NC}"
for i in "${!FOUND[@]}"; do
    IFS='|' read -r fname fpath fdesc <<< "${FOUND[$i]}"
    echo -e "  ${GREEN}[${i}]${NC} ${fname} — ${fdesc}"
    echo -e "      路径: ${fpath}"
done
echo ""
read -p "选择 (编号, 多个用逗号; Enter 跳过): " -r choices
[ -z "$choices" ] && echo "跳过" && exit 0

test_init "gpu"

IFS=',' read -ra SELECTED <<< "$choices"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for i in "${!FOUND[@]}"; do
        [ "$sel" != "$i" ] && continue
        IFS='|' read -r fname fpath fdesc <<< "${FOUND[$i]}"
        echo "" | tee -a "$REPORT_LOG"
        echo -e "${CYAN}━━━ ${fname} (${fpath}) ━━━${NC}" | tee -a "$REPORT_LOG"
        start_ts=$(date +%s)
        LOGFILE="${REPORT_DIR}/${fname}_detail.log"

        case "$fname" in
            bandwidthTest)
                # CUDA 带宽测试: 逐卡 + P2P；--mode=sharing 测两卡互传
                run_and_log "${fpath} --device=0 --mode=quick 2>&1" "$LOGFILE"
                if [ "$GPU_COUNT" -ge 2 ]; then
                    run_and_log "${fpath} --device=0 --device=1 --mode=peertopeer 2>&1" "${REPORT_DIR}/bandwidthTest_p2p.log"
                fi
                ;;
            gpu_burn)
                read -p "  压测时长(秒, 默认 60): " -r btime
                [ -z "$btime" ] && btime=60
                run_and_log "${fpath} ${btime} 2>&1" "$LOGFILE"
                ;;
            nvbandwidth)
                run_and_log "${fpath} 2>&1" "$LOGFILE"
                ;;
            all_reduce_perf)
                read -p "  消息大小 -b/-e (默认 1G/4G): " -r msgb
                [ -z "$msgb" ] && msgb="1G"
                read -p "  GPU 数 -g (默认全部 ${GPU_COUNT}): " -r gpn
                [ -z "$gpn" ] && gpn="$GPU_COUNT"
                run_and_log "${fpath} -b ${msgb} -e 4G -f 2 -g ${gpn} -n 20 -w 5 2>&1" "$LOGFILE"
                ;;
            partnerdiag)
                read -p "  参数 (默认 --field --level1 --run_on_error --no_bmc): " -r pdiag_args
                [ -z "$pdiag_args" ] && pdiag_args="--field --level1 --run_on_error --no_bmc"
                run_and_log "sudo ${fpath} ${pdiag_args} 2>&1" "$LOGFILE"
                ;;
            *)
                run_and_log "${fpath} 2>&1" "$LOGFILE"
                ;;
        esac
        test_record "$fname" "$LOGFILE" "$start_ts" "$?"
    done
done

test_finish "gpu"
