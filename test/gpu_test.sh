#!/bin/bash
# =============================================================================
# HwScope — GPU 测试（自动发现系统测试程序）
# test/gpu_test.sh
# 用法:
#   bash test/gpu_test.sh                     # 自动发现 + 菜单选择
#   bash test/gpu_test.sh gpu_burn            # 直接指定工具（跳过菜单）
#   bash test/gpu_test.sh gpu_burn 1800       # 直接指定 + 时长（gpu_burn -tc 1800 秒）
#   bash test/gpu_test.sh bandwidthTest       # 直接跑带宽测试（逐卡 + P2P）
# 功能: 自动扫描系统已安装的 GPU 测试程序，菜单选择或直接指定执行
#   支持: cuda bandwidthTest(P2P) / gpu_burn(-tc 张量核心) / nvbandwidth / all_reduce_perf / partnerdiag
# 说明: 只调用系统已存在的测试程序，不自动安装
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

# ─── 参数：直接指定工具模式（可带工具参数；无参数 = 菜单模式） ───
TOOL_ARG="${1:-}"     # 工具名或编号（bandwidthTest/gpu_burn/... 或 0/1/...）
TOOL_EXTRA="${2:-}"   # gpu_burn 时长（秒）；其他工具暂不支持直接参数

if ! check_cmd nvidia-smi; then
    echo -e "${RED}[ERROR] nvidia-smi 未安装（无 NVIDIA 驱动）${NC}"
    exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
echo -e "${CYAN}[INFO] 检测到 ${GPU_COUNT} 张 GPU${NC}"

# ─── 自动发现系统测试程序 ───
# 格式: name|路径|描述|参数模板
declare -a FOUND=()

# 常见搜索路径（避免全盘扫描）
SEARCH_DIRS=(
    "/opt" "/usr/local" "${HOME}" "/usr/bin" "/usr/lib/cuda"
    "${SCRIPT_DIR}/nccl-tests/build"
)

# 候选程序: 名称 | 描述 | 候选路径
declare -a CANDIDATES=(
    "bandwidthTest|CUDA P2P/内存带宽测试 (cuda-samples)|bandwidthTest"
    "gpu_burn|GPU 满载压测 (gpu-burn, -tc 张量核心)|gpu_burn"
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

# ─── 执行单个工具（菜单与直接指定共用；$1=fname $2=fpath $3=额外参数如 gpu_burn 时长） ───
run_tool() {
    local fname="$1" fpath="$2" extra="${3:-}"
    echo "" | tee -a "$REPORT_LOG"
    echo -e "${CYAN}━━━ ${fname} (${fpath}) ━━━${NC}" | tee -a "$REPORT_LOG"
    local start_ts
    start_ts=$(date +%s)
    local LOGFILE="${REPORT_DIR}/${fname}_detail.log"
    # run_and_log 退出码暂存（末尾 test_record 用；bandwidthTest 分支已自行记录）
    # 注意：不能直接取 case 后的 $?——"[ fname = bandwidthTest ] ||" 会覆盖为 [ 的退出码（恒 1），
    # 导致非 bandwidthTest 分支全部误报"异常 (exit=1)"（v1.38.5 实测修复）
    local last_rc=0

    case "$fname" in
        bandwidthTest)
            # CUDA 带宽测试: 逐卡 quick + P2P；每卡独立 test_record
            # （报告压测段呈矩阵：测试项×GPU×结果，对标 DGX FLD 逐组件结果表——v1.36.0）
            for ((gi=0; gi<GPU_COUNT; gi++)); do
                run_and_log "${fpath} --device=${gi} --mode=quick 2>&1" "${REPORT_DIR}/bandwidthTest_gpu${gi}.log"
                test_record "bandwidthTest_gpu${gi}" "${REPORT_DIR}/bandwidthTest_gpu${gi}.log" "$start_ts" "$?"
            done
            if [ "$GPU_COUNT" -ge 2 ]; then
                run_and_log "${fpath} --device=0 --device=1 --mode=peertopeer 2>&1" "${REPORT_DIR}/bandwidthTest_p2p.log"
                test_record "bandwidthTest_p2p" "${REPORT_DIR}/bandwidthTest_p2p.log" "$start_ts" "$?"
            fi
            ;;
        gpu_burn)
            # 时长：直接参数优先（gpu_test.sh gpu_burn 1800）→ 交互 → 默认 60
            local btime="$extra"
            if [ -z "$btime" ]; then
                read -p "  压测时长(秒, 默认 60; 建议长压测如 1800): " -r btime
            fi
            [[ "$btime" =~ ^[0-9]+$ ]] || btime=60
            # cd 到 gpu_burn 所在目录执行：compare.ptx 与二进制同目录（v1.38.5 修复）；
            # -tc = Tensor cores（gpu-burn 官方参数，v1.39.3 完善）
            local gb_dir
            gb_dir=$(dirname "$fpath")
            run_and_log "cd '${gb_dir}' && ./gpu_burn -tc ${btime} 2>&1" "$LOGFILE"
            last_rc=$?
            ;;
        nvbandwidth)
            run_and_log "${fpath} 2>&1" "$LOGFILE"
            last_rc=$?
            ;;
        all_reduce_perf)
            read -p "  消息大小 -b/-e (默认 1G/4G): " -r msgb
            [ -z "$msgb" ] && msgb="1G"
            read -p "  GPU 数 -g (默认全部 ${GPU_COUNT}): " -r gpn
            [ -z "$gpn" ] && gpn="$GPU_COUNT"
            run_and_log "${fpath} -b ${msgb} -e 4G -f 2 -g ${gpn} -n 20 -w 5 2>&1" "$LOGFILE"
            last_rc=$?
            ;;
        partnerdiag)
            read -p "  参数 (默认 --field --level1 --run_on_error --no_bmc): " -r pdiag_args
            [ -z "$pdiag_args" ] && pdiag_args="--field --level1 --run_on_error --no_bmc"
            run_and_log "sudo ${fpath} ${pdiag_args} 2>&1" "$LOGFILE"
            last_rc=$?
            ;;
        *)
            run_and_log "${fpath} 2>&1" "$LOGFILE"
            last_rc=$?
            ;;
    esac
    # 已单独记录的（bandwidthTest 分支）跳过通用记录，避免重复
    [ "$fname" = "bandwidthTest" ] || test_record "$fname" "$LOGFILE" "$start_ts" "$last_rc"
}

# 按名称或编号解析到 FOUND 项（输出 "name|path|desc"，未找到输出空）
resolve_tool() {
    local arg="$1" i
    for i in "${!FOUND[@]}"; do
        IFS='|' read -r fname fpath fdesc <<< "${FOUND[$i]}"
        if [ "$arg" = "$fname" ] || [ "$arg" = "$i" ]; then
            echo "${fname}|${fpath}|${fdesc}"
            return 0
        fi
    done
    echo ""
}

# ─── 直接指定工具模式（bash test/gpu_test.sh gpu_burn [时长]） ───
if [ -n "$TOOL_ARG" ]; then
    SEL="$(resolve_tool "$TOOL_ARG")"
    if [ -z "$SEL" ]; then
        echo -e "${RED}[ERROR] 未找到工具: ${TOOL_ARG}${NC}"
        echo "  可用: $(for i in "${!FOUND[@]}"; do IFS='|' read -r fn fp fd <<< "${FOUND[$i]}"; printf '%s(%s) ', "$fn" "$i"; done)"
        exit 1
    fi
    IFS='|' read -r fname fpath fdesc <<< "$SEL"
    test_init "gpu"
    bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true
    run_tool "$fname" "$fpath" "$TOOL_EXTRA"
    test_finish "gpu"
    exit 0
fi

# ─── 菜单选择模式 ───
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
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true

IFS=',' read -ra SELECTED <<< "$choices"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    SEL="$(resolve_tool "$sel")"
    [ -z "$SEL" ] && continue
    IFS='|' read -r fname fpath fdesc <<< "$SEL"
    run_tool "$fname" "$fpath" ""
done

test_finish "gpu"
