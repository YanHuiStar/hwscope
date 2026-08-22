#!/bin/bash
# HwScope — 硬件测试聚合入口
# 用法: bash test/test_all.sh    # 交互式菜单选择压测项（1-7）
#       bash test/test_all.sh -h # 显示本帮助
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
    -h|--help)
        sed -n '2,/^[^#]/p' "$0" | sed 's/^# \?//' | sed '/^$/d'
        echo ""
        echo "  1) CPU  测试   — cpu_test.sh"
        echo "  2) 内存 测试   — memory_test.sh"
        echo "  3) 硬盘 测试   — disk_test.sh"
        echo "  4) 网络 测试   — network_test.sh"
        echo "  5) NCCL 通信   — nccl_test.sh"
        echo "  6) GPU 测试    — gpu_test.sh"
        echo "  7) IB 打流     — ib_test.sh"
        echo "  8) GPU Burn    — gpu_burn_test.sh（-tc 张量核心长压测）"
        exit 0 ;;
esac
echo -e "\033[1;36m  HwScope 硬件测试\033[0m"
echo ""
echo "  1) CPU  测试   — cpu_test.sh"
echo "  2) 内存 测试   — memory_test.sh"
echo "  3) 硬盘 测试   — disk_test.sh"
echo "  4) 网络 测试   — network_test.sh"
echo "  5) NCCL 通信   — nccl_test.sh"
echo "  6) GPU 测试    — gpu_test.sh"
echo "  7) IB 打流     — ib_test.sh"
echo "  8) GPU Burn    — gpu_burn_test.sh（-tc 张量核心长压测）"
echo ""
read -p "选择 (1-8, 逗号分隔): " -r c
[ -z "$c" ] && exit 0
IFS=',' read -ra S <<< "$c"
for s in "${S[@]}"; do
    s=$(echo "$s" | tr -d ' ')
    case "$s" in
        1) bash "${SCRIPT_DIR}/cpu_test.sh" ;;
        2) bash "${SCRIPT_DIR}/memory_test.sh" ;;
        3) bash "${SCRIPT_DIR}/disk_test.sh" ;;
        4) bash "${SCRIPT_DIR}/network_test.sh" ;;
        5) bash "${SCRIPT_DIR}/nccl_test.sh" ;;
        6) bash "${SCRIPT_DIR}/gpu_test.sh" ;;
        7) bash "${SCRIPT_DIR}/ib_test.sh" ;;
        8) bash "${SCRIPT_DIR}/gpu_burn_test.sh" ;;
    esac
done
