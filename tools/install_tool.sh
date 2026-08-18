#!/bin/bash
# =============================================================================
# HwScope — 环境安装工具
# tools/install_tool.sh
# 用法: sudo bash tools/install_tool.sh
# 功能: 安装 DCGM / MFT / 压测工具 / 推理引擎
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"

# ─── 检测包管理器 ───
if check_cmd apt-get; then PKG_MGR="apt-get"; OS="debian"
elif check_cmd dnf; then PKG_MGR="dnf"; OS="rhel"
elif check_cmd yum; then PKG_MGR="yum"; OS="rhel"
else echo -e "${RED}[ERROR] 不支持的包管理器${NC}"; exit 1; fi

echo -e "${CYAN}[INFO] 包管理器: ${PKG_MGR}${NC}"

# ─── 包名映射：Ubuntu apt vs Rocky yum ───
if [ "$OS" = "debian" ]; then
    LM_SENSORS_PKG="lm-sensors"
else
    LM_SENSORS_PKG="lm_sensors"
fi

# ─── 安装功能表 ───
OPS=(
    "1:基础采集工具:dmidecode pciutils ipmitool smartmontools ${LM_SENSORS_PKG}:${PKG_MGR}"
    "2:压测工具:stress-ng sysbench fio iperf3 mtr:${PKG_MGR}"
    "3:IB 诊断工具:infiniband-diags perftest rdma-core:${PKG_MGR}"
    "4:DCGM 诊断:NVIDIA DCGM:manual"
    "5:MFT 固件工具:Mellanox Firmware Tools:manual"
    "6:推理引擎:Triton / TensorRT-LLM:manual"
)

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  环境安装工具${NC}"
echo -e "${CYAN}========================================${NC}"
for op in "${OPS[@]}"; do
    IFS=':' read -r num name pkgs how <<< "$op"
    echo -e "  ${GREEN}[${num}]${NC} ${name}  ${YELLOW}(${how})${NC}"
done
echo ""
read -p "选择安装项 (1-6, 逗号分隔): " -r choices
[ -z "$choices" ] && echo "跳过" && exit 0

IFS=',' read -ra SELECTED <<< "$choices"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for op in "${OPS[@]}"; do
        IFS=':' read -r num name pkgs how <<< "$op"
        [ "$sel" != "$num" ] && continue
        echo -e "${CYAN}━━━ 安装: ${name} ━━━${NC}"

        case "$how" in
            "${PKG_MGR}")
                echo -e "${YELLOW}  执行: ${PKG_MGR} install -y ${pkgs}${NC}"
                read -p "  确认安装? (y/N) " -r confirm
                [[ ! "$confirm" =~ ^[Yy] ]] && echo "  跳过" && continue
                ${PKG_MGR} install -y $pkgs 2>&1 | tail -5
                ;;
            manual)
                case "$num" in
                    4)
                        echo "  DCGM 安装:"
                        echo "    Ubuntu: sudo apt install -y datacenter-gpu-manager"
                        echo "    RHEL  : sudo yum install -y datacenter-gpu-manager"
                        echo "    需要先配置 NVIDIA 官方源，详见:"
                        echo "    https://developer.nvidia.com/dcgm"
                        ;;
                    5)
                        echo "  MFT 安装:"
                        echo "    下载: https://network.nvidia.com/products/adapter-software/firmware-tools/"
                        echo "    tar xzf mft-*.tgz && cd mft-* && sudo ./install.sh"
                        ;;
                    6)
                        echo "  推理引擎:"
                        echo "    Triton:     https://github.com/triton-inference-server/server"
                        echo "    TensorRT-LLM: https://github.com/NVIDIA/TensorRT-LLM"
                        echo "    建议容器化部署 (NGC): nvcr.io/nvidia/tritonserver"
                        ;;
                esac
                ;;
        esac
        echo ""
    done
done

echo -e "${GREEN}安装流程结束${NC}"
echo -e "${YELLOW}提示: 安装后重新运行 hwscope.sh 可采集到新增工具的信息${NC}"
