#!/bin/bash
# =============================================================================
# HwScope — IB 数据面打流测试（perftest）
# test/ib_test.sh
# 用法: sudo bash test/ib_test.sh
# 功能: 自动发现 IB 设备，逐对用 ib_write_bw / ib_read_bw 打流验证数据面
#   支持: 自动配对（serial 相同）/ 手动指定 / 单口回环
# 日志: logs/test/<时间戳>/
# 注意: 需要 perftest 包（ib_write_bw/ib_read_bw）；IB 模式需 SM（NVSwitch 自带）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

if ! check_cmd ib_write_bw; then
    echo -e "${RED}[ERROR] perftest 未安装 (ib_write_bw)${NC}"
    echo "        安装: apt install perftest"
    exit 1
fi
if ! check_cmd nvidia-smi && ! ls /sys/class/infiniband/ 2>/dev/null | grep -q mlx5; then
    echo -e "${RED}[ERROR] 未发现 IB 设备 (mlx5)${NC}"
    exit 1
fi

# ─── 发现 IB 设备（排除 Down 口） ───
IB_DEVS=$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5)
if [ -z "$IB_DEVS" ]; then
    echo -e "${YELLOW}[WARN] 未发现 mlx5 IB 设备${NC}"
    exit 1
fi
echo -e "${CYAN}[INFO] 发现 IB 设备: ${IB_DEVS//$'\n'/ }${NC}"

# ─── 自动配对：serial 相同 = 物理相连（借鉴 cable_map / NVIDIA 引擎逻辑） ───
echo -e "${CYAN}自动配对 (serial 相同 = 同一根线)...${NC}"
declare -A PAIRS
PAIRED_DEVS=""
if check_cmd mlxlink; then
    for dev in $IB_DEVS; do
        serial=$(sudo mlxlink -d "$dev" -p 1 2>/dev/null | grep -iE "Serial Number" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        [ -z "$serial" ] || [ "$serial" = "N/A" ] && continue
        if [ -n "${PAIRS[$serial]}" ]; then
            echo -e "  ${GREEN}${PAIRS[$serial]} ↔ ${dev}${NC} (serial ${serial})"
            PAIRED_DEVS="${PAIRED_DEVS} ${PAIRS[$serial]} ${dev}"
        else
            PAIRS[$serial]="$dev"
        fi
    done
fi

# ─── 手动配对输入（serial 无法自动配对时） ───
SINGLE_DEVS=""
for dev in $IB_DEVS; do
    echo "$PAIRED_DEVS" | grep -qw "$dev" || SINGLE_DEVS="${SINGLE_DEVS} $dev"
done
if [ -n "$SINGLE_DEVS" ]; then
    echo ""
    echo -e "${YELLOW}未自动配对设备:${SINGLE_DEVS}${NC}"
    echo "  可手动配对: 输入形如 'mlx5_0:mlx5_1' (空格分隔多对)，Enter 跳过"
    read -p "  手动配对: " -r manual
    if [ -n "$manual" ]; then
        for pair in $manual; do
            a="${pair%%:*}"; b="${pair##*:}"
            [ -n "$a" ] && [ -n "$b" ] && PAIRED_DEVS="${PAIRED_DEVS} $a $b"
        done
    fi
fi

if [ -z "$PAIRED_DEVS" ]; then
    echo -e "${YELLOW}[WARN] 无配对设备，无法打流（需两根线互联或回环头）${NC}"
    exit 1
fi

# ─── 测试选择 ───
echo ""
echo "  测试项:"
echo "    [1] ib_write_bw (写带宽)"
echo "    [2] ib_read_bw  (读带宽)"
echo "    [3] 全部"
read -p "选择 (1-3, 默认 3): " -r tsel
[ -z "$tsel" ] && tsel=3

test_init "ib"
start_ts=$(date +%s)

# 逐对打流（PAIRED_DEVS 是成对的：srv cli srv cli...）
TEST_INDEX=0
read -ra PD <<< "$PAIRED_DEVS"
for ((i=0; i<${#PD[@]}; i+=2)); do
    srv="${PD[$i]}"; cli="${PD[$((i+1))]}"
    [ -z "$srv" ] || [ -z "$cli" ] && continue
    TEST_INDEX=$((TEST_INDEX + 1))
    echo "" | tee -a "$REPORT_LOG"
    echo -e "${CYAN}━━━ 对 ${TEST_INDEX}: ${srv} (S) <-> ${cli} (C) ━━━${NC}" | tee -a "$REPORT_LOG"

    case "$tsel" in
        1|3)
            LOGFILE="${REPORT_DIR}/ib_write_bw_${srv}_${cli}.log"
            # server 后台起，等 2 秒，client 连
            timeout 20 ib_write_bw -d "$srv" -F -s 4194304 > /dev/null 2>&1 &
            SRV_PID=$!
            sleep 2
            run_and_log "ib_write_bw -d '$cli' -F -s 4194304 --report_gbits 2>&1" "$LOGFILE"
            rc=$?
            kill $SRV_PID 2>/dev/null
            test_record "ib_write_bw_${srv}_${cli}" "$LOGFILE" "$start_ts" "$rc"
            ;;
        2|3)
            LOGFILE="${REPORT_DIR}/ib_read_bw_${srv}_${cli}.log"
            timeout 20 ib_read_bw -d "$srv" -F -s 4194304 > /dev/null 2>&1 &
            SRV_PID=$!
            sleep 2
            run_and_log "ib_read_bw -d '$cli' -F -s 4194304 --report_gbits 2>&1" "$LOGFILE"
            rc=$?
            kill $SRV_PID 2>/dev/null
            test_record "ib_read_bw_${srv}_${cli}" "$LOGFILE" "$start_ts" "$rc"
            ;;
    esac
done

test_finish "ib"
