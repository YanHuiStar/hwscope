#!/bin/bash
# =============================================================================
# HwScope — 网络测试
# test/network_test.sh
# 用法: bash test/network_test.sh
# 功能: iperf3 TCP/UDP 吞吐 / ib_write_bw IB 带宽 / mtr 路径质量
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/test/test_common.sh" 2>/dev/null || true

# ─── 网卡/IB 设备列表 ───
echo -e "${CYAN}可用网络设备:${NC}"
ip -o link show 2>/dev/null | grep -v 'lo:' | awk -F': ' '{print "  " $2}' | head -10
ls /sys/class/infiniband/ 2>/dev/null | sed 's/^/  IB: /' | head -5
echo ""

# ─── iperf3 需要远端 ───
echo -e "${YELLOW}提示: iperf3 测试需要服务端，直接输入服务端 IP（如 192.168.1.100）${NC}"
read -p "iperf3 服务端地址 (Enter 跳过): " -r iperf_host

TOOLS=(
    "iperf3:iperf3:TCP/UDP 吞吐测试"
    "ib_write_bw:ib_write_bw:InfiniBand 写带宽"
    "mtr:mtr:网络路径丢包/延迟"
)

test_menu TOOLS || exit 0
test_init "network"
bash "${SCRIPT_DIR}/test/test_server_info.sh" --append "$REPORT_LOG" --out "$REPORT_DIR" 2>/dev/null || true

IFS=',' read -ra SELECTED <<< "$TEST_CHOICES"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for entry in "${TEST_AVAILABLE[@]}"; do
        IFS='|' read -r idx name desc cmd <<< "$entry"
        [ "$sel" != "$idx" ] && continue
        echo "" | tee -a "$REPORT_LOG"
        echo -e "${CYAN}━━━ ${name} 测试 ━━━${NC}" | tee -a "$REPORT_LOG"
        start_ts=$(date +%s)
        LOGFILE="${REPORT_DIR}/${name// /_}_detail.log"

        case "$name" in
            iperf3)
                if [ -n "$iperf_host" ]; then
                    run_and_log "iperf3 -c ${iperf_host} -t 10 -P 4 2>&1" "$LOGFILE"
                else
                    echo "[SKIP] 未提供服务端地址" | tee -a "$LOGFILE"
                fi
                ;;
            ib_write_bw)
                # 提示改用 ib_test.sh（perftest 无对端地址即 server 模式，这里直跑会挂起等客户端——v1.33.3）
                echo "[SKIP] IB 打流请用 bash test/ib_test.sh（自动配对 + 双端地址）" | tee -a "$LOGFILE"
                ;;
            mtr)
                run_and_log "mtr -rw -c 10 8.8.8.8 2>&1" "$LOGFILE"
                ;;
        esac
        test_record "$name" "$LOGFILE" "$start_ts" "$?"
    done
done

test_finish "network"
