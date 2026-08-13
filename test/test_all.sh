#!/bin/bash
# HwScope — 硬件测试聚合入口
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo -e "\033[1;36m  HwScope 硬件测试\033[0m"
echo ""
echo "  1) CPU  测试   — cpu_test.sh"
echo "  2) 内存 测试   — memory_test.sh"
echo "  3) 硬盘 测试   — disk_test.sh"
echo "  4) 网络 测试   — network_test.sh"
echo "  5) NCCL 通信   — nccl_test.sh"
echo "  6) GPU 测试    — gpu_test.sh"
echo "  7) IB 打流     — ib_test.sh"
echo ""
read -p "选择 (1-7, 逗号分隔): " -r c
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
    esac
done
