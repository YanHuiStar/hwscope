#!/bin/bash
# =============================================================================
# HwScope — 硬件测试聚合入口（test_all.sh）
# test/test_all.sh
# 用法: bash test/test_all.sh           # 分类菜单选择
#       bash test/test_all.sh --all     # 全部单脚本顺序执行
# 说明: 纯聚合编排——测试实现全在 test/<组件>/ 单脚本中，本文件不含任何测试逻辑；
#       单脚本可独立执行（如 bash test/cpu/cpu_stress_ng.sh 60）
# 日志: 各单脚本落盘 logs/test/<时间戳>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── 工具表（分类:显示名:脚本相对路径） ───
TOOLS=(
    "CPU:stress-ng 满载压测:cpu/cpu_stress_ng.sh"
    "CPU:sysbench CPU 基准:cpu/cpu_sysbench.sh"
    "CPU:mprime 散热验证:cpu/cpu_mprime.sh"
    "内存:stress-ng vm 压力:memory/mem_stress_ng.sh"
    "内存:memtester 位翻转:memory/mem_memtester.sh"
    "内存:sysbench 内存带宽:memory/mem_sysbench.sh"
    "磁盘:fio IOPS/延迟:disk/disk_fio.sh"
    "磁盘:hdparm 缓存读:disk/disk_hdparm.sh"
    "磁盘:dd 顺序读:disk/disk_dd.sh"
    "网络:iperf3 吞吐:network/net_iperf3.sh"
    "网络:mtr 路径质量:network/net_mtr.sh"
    "IB:perftest 打流配对:ib/ib_perftest.sh"
    "GPU:bandwidthTest 带宽:gpu/gpu_bandwidth.sh"
    "GPU:gpu-burn 长压测:gpu/gpu_burn_test.sh"
    "GPU:nvbandwidth 带宽基准:gpu/gpu_nvbandwidth.sh"
    "GPU:partnerdiag 出厂诊断:gpu/gpu_partnerdiag.sh"
    "NCCL:集合通信带宽:nccl/nccl_test.sh"
)

# ─── 帮助 ───
case "${1:-}" in
    -h|--help)
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac

# ─── --all：全部顺序执行（v1.45.3 会话共享目录：建一个 <SN>-<时间戳> 目录，所有子测试累积，
#            避免 17 个测试产生 17 个碎片目录；结束后可用 test/report.sh <会话目录> 出全量报告） ───
if [ "${1:-}" = "--all" ]; then
    source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true
    SESSION_DIR="$(test_new_dir)"
    export HW_TEST_SESSION_DIR="$SESSION_DIR"
    echo "测试目录: ${SESSION_DIR}（本机全部测试日志累积于此，文件名带时间戳区分）"
    echo ""
    echo "全部测试顺序执行..."
    for entry in "${TOOLS[@]}"; do
        IFS=':' read -r cat name path <<< "$entry"
        echo ""
        echo "════ ${cat} — ${name} ════"
        bash "${SCRIPT_DIR}/${path}" "${2:-}" 2>&1 || echo "[WARN] ${name} 执行异常 (exit=$?)"
    done
    echo ""
    echo "全部测试完成"
    echo "报告生成: bash test/report.sh ${SESSION_DIR}"
    exit 0
fi

# ─── 菜单选择 ───
echo "========================================"
echo "  HwScope 硬件测试（test_all 聚合入口）"
echo "========================================"
echo ""
prev_cat=""
idx=0
for entry in "${TOOLS[@]}"; do
    IFS=':' read -r cat name path <<< "$entry"
    if [ "$cat" != "$prev_cat" ]; then
        echo ""
        echo "── ${cat} ──"
        prev_cat="$cat"
    fi
    echo "  [${idx}] ${name}  (test/${path})"
    ((idx++))
done
echo ""
echo "  [${idx}] 全部测试（顺序执行）"
echo ""
read -rp "> 输入编号（多个逗号: 0,1），Enter 取消: " -r choices
[ -z "$choices" ] && echo "已取消" && exit 0

IFS=',' read -ra sels <<< "$choices"
# v1.45.4：菜单选中多个测试 → 同一会话目录（避免碎片；单独选 1 个 = 该会话内独立目录同语义）
source "${SCRIPT_DIR}/test/lib/test_common.sh" 2>/dev/null || true
SESSION_DIR="$(test_new_dir)"
export HW_TEST_SESSION_DIR="$SESSION_DIR"
echo "测试目录: ${SESSION_DIR}（本次所选测试日志累积于此）"
echo ""
for sel in "${sels[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    if [ "$sel" = "$idx" ]; then
        bash "$0" --all
        exit 0
    fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "$idx" ]; then
        IFS=':' read -r cat name path <<< "${TOOLS[$sel]}"
        echo ""
        echo "════ ${cat} — ${name} ════"
        bash "${SCRIPT_DIR}/${path}" 2>&1 || echo "[WARN] ${name} 执行异常 (exit=$?)"
    else
        echo "[WARN] 无效选择: $sel"
    fi
done
echo ""
echo "完成"
