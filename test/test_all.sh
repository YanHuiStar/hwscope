#!/bin/bash
# HwScope — 硬件测试聚合入口
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo -e "\033[1;36m  HwScope 硬件测试\033[0m"
echo ""
echo "  1) CPU  测试   — cpu_test.sh"
echo "  2) 内存 测试   — memory_test.sh"
echo "  3) 硬盘 测试   — disk_test.sh"
echo "  4) 网络 测试   — network_test.sh"
echo ""
read -p "选择 (1-4, 逗号分隔): " -r c
[ -z "$c" ] && exit 0
IFS=',' read -ra S <<< "$c"
for s in "${S[@]}"; do
    s=$(echo "$s" | tr -d ' ')
    case "$s" in
        1) bash "${SCRIPT_DIR}/cpu_test.sh" ;;
        2) echo "[待开发] memory_test.sh" ;;
        3) echo "[待开发] disk_test.sh" ;;
        4) echo "[待开发] network_test.sh" ;;
    esac
done
