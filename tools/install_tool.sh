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
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}[ERROR] 需要 root 运行: sudo bash $0${NC}"; exit 1; }   # 安装需写系统（v1.33.3）
if check_cmd apt-get; then PKG_MGR="apt-get"; OS="debian"
elif check_cmd dnf; then PKG_MGR="dnf"; OS="rhel"
elif check_cmd yum; then PKG_MGR="yum"; OS="rhel"
else echo -e "${RED}[ERROR] 不支持的包管理器${NC}"; exit 1; fi

echo -e "${CYAN}[INFO] 包管理器: ${PKG_MGR}${NC}"
if [ "$OS" = "rhel" ]; then
    echo -e "${YELLOW}[提示] RHEL/Rocky/Alma 的 stress-ng/sysbench/fio/iperf3 依赖 EPEL 源，装不上请先: sudo dnf install -y epel-release${NC}"
fi

# ─── 包名映射：Ubuntu apt vs Rocky yum ───
if [ "$OS" = "debian" ]; then
    LM_SENSORS_PKG="lm-sensors"
else
    LM_SENSORS_PKG="lm_sensors"
fi

# ─── 安装功能表 ───
# 7-9 为实验功能（auto 模式）：自动安装代码默认注释态，需人工在真机环境验证后取消注释启用
OPS=(
    "1:基础采集工具:dmidecode pciutils ipmitool smartmontools ${LM_SENSORS_PKG}:${PKG_MGR}"
    "2:压测工具:stress-ng sysbench fio iperf3 mtr:${PKG_MGR}"
    "3:IB 诊断工具:infiniband-diags perftest rdma-core:${PKG_MGR}"
    "4:DCGM 诊断:NVIDIA DCGM:manual"
    "5:MFT 固件工具:Mellanox Firmware Tools:manual"
    "6:推理引擎:Triton / TensorRT-LLM:manual"
    "7:DCGM 自动安装(实验):NVIDIA DCGM:auto"
    "8:MFT 自动安装(实验):Mellanox MFT:auto"
    "9:厂商 RAID 工具(实验):storcli/sas3ircu:auto"
)

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  环境安装工具${NC}"
echo -e "${CYAN}========================================${NC}"
for op in "${OPS[@]}"; do
    IFS=':' read -r num name pkgs how <<< "$op"
    echo -e "  ${GREEN}[${num}]${NC} ${name}  ${YELLOW}(${how})${NC}"
done
echo ""
read -p "选择安装项 (1-9, 逗号分隔): " -r choices
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
                # 管道退出码是 tail 的——检查真实安装结果（v1.33.3）
                if [ "${PIPESTATUS[0]:-1}" -ne 0 ]; then
                    echo -e "${RED}[ERROR] ${PKG_MGR} 安装失败（${OS} 下部分包依赖 EPEL/额外源）${NC}"
                fi
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
            auto)
                # ─── 实验功能（默认注释态）───
                # 选择 7-9 仅打印状态提示；自动安装代码块默认注释，需人工在真机环境
                # 验证下载源/步骤可用后，删除下方对应块的行首 # 即可启用。
                case "$num" in
                    7)
                        echo "  [实验] DCGM 自动安装 — 默认未启用（代码注释态）"
                        echo "  启用: 编辑本文件，删除下方 7) 自动安装块的行首 # 后重跑"
                        echo ""
                        # ─── [实验] DCGM 自动安装（真机验证后取消注释启用）───
                        # echo "  [1/3] 配置 NVIDIA 官方仓库..."
                        # if [ "$OS" = "debian" ]; then
                        #     UBUNTU_CODENAME=$(. /etc/os-release && echo $VERSION_CODENAME)
                        #     curl -fsSL -o /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${VERSION_ID/./}${UBUNTU_CODENAME}/x86_64/cuda-keyring_1.1-1_all.deb
                        #     dpkg -i /tmp/cuda-keyring.deb && apt-get update -qq
                        #     apt-get install -y datacenter-gpu-manager
                        # else
                        #     dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
                        #     dnf install -y datacenter-gpu-manager
                        # fi
                        # echo "  [2/3] 启用 hostengine 自启..."
                        # systemctl enable --now nvidia-dcgm 2>/dev/null || true
                        # echo "  [3/3] 验证: dcgmi discovery -l"
                        ;;
                    8)
                        echo "  [实验] MFT 自动安装 — 默认未启用（代码注释态）"
                        echo "  启用: 编辑本文件，删除下方 8) 自动安装块的行首 # 后重跑"
                        echo "  注意: MFT 下载需 NVIDIA 账号登录，请先手动下载 mft-*.tgz 放到 /tmp/"
                        echo ""
                        # ─── [实验] MFT 自动安装（真机验证后取消注释启用）───
                        # if [ -f /tmp/mft-*.tgz ]; then
                        #     cd /tmp && tar xzf mft-*.tgz && cd mft-* && ./install.sh
                        #     mst status && echo "  MFT 安装成功"
                        # else
                        #     echo "  未找到 /tmp/mft-*.tgz，请先到官网下载（需 NVIDIA 账号）:"
                        #     echo "  https://network.nvidia.com/products/adapter-software/firmware-tools/"
                        # fi
                        ;;
                    9)
                        echo "  [实验] 厂商 RAID 工具自动安装 — 默认未启用（代码注释态）"
                        echo "  启用: 编辑本文件，删除下方 9) 自动安装块的行首 # 后重跑"
                        echo "  注意: storcli/sas3ircu 需从 Broadcom 官网下载（无需登录），放到 /tmp/ 后自动部署"
                        echo ""
                        # ─── [实验] 厂商 RAID 工具自动部署（真机验证后取消注释启用）───
                        # # storcli64: 用户提前下载 storcli_linux_*.zip 到 /tmp
                        # if ls /tmp/storcli_linux_*.zip >/dev/null 2>&1; then
                        #     cd /tmp && unzip -o storcli_linux_*.zip -d storcli_tmp >/dev/null 2>&1
                        #     find /tmp/storcli_tmp -name storcli64 -exec cp {} /usr/local/bin/ \; 2>/dev/null
                        #     chmod +x /usr/local/bin/storcli64 && storcli64 -v | head -1
                        #     rm -rf /tmp/storcli_tmp
                        # fi
                        # # sas3ircu / sas2ircu: 用户提前下载对应 zip 到 /tmp
                        # for z in /tmp/sas3ircu*.zip /tmp/sas2ircu*.zip; do
                        #     [ -f "$z" ] || continue
                        #     unzip -o "$z" -d /tmp/sas_tmp >/dev/null 2>&1
                        #     find /tmp/sas_tmp -type f \( -name sas3ircu -o -name sas2ircu \) -exec cp {} /usr/local/bin/ \; 2>/dev/null
                        #     rm -rf /tmp/sas_tmp
                        # done
                        # echo "  部署完成，验证: storcli64 /c0 show 或 sas3ircu list"
                        ;;
                esac
                ;;
        esac
        echo ""
    done
done

echo -e "${GREEN}安装流程结束${NC}"
echo -e "${YELLOW}提示: 安装后重新运行 hwscope.sh 可采集到新增工具的信息${NC}"
