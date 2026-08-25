#!/bin/bash
# =============================================================================
# HwScope — AI 推理引擎环境安装
# tools/install_ai.sh
# 用法: bash tools/install_ai.sh
# 功能: vLLM / SGLang / TensorRT-LLM / Ollama / llama.cpp 一键安装
# 参考: 推理引擎部署对比（五引擎）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  AI 推理引擎环境安装${NC}"
echo -e "${CYAN}========================================${NC}"

# ─── 环境预检 ───
echo ""
echo -e "${BLUE}[预检]${NC}"
if check_cmd nvidia-smi; then
    DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 | awk '{printf "%.0f GB", $1/1024}')
    echo -e "  ${GREEN}✓${NC} GPU: ${GPU_NAME} (${VRAM})  驱动: ${DRIVER}"
else
    echo -e "  ${RED}✗${NC} 未检测到 nvidia-smi — GPU 驱动未安装"
    echo "    安装驱动: https://www.nvidia.com/driver"
fi

check_cmd uv && echo -e "  ${GREEN}✓${NC} uv 已安装" || echo -e "  ${YELLOW}✗${NC} uv 未安装 (推荐安装: curl -LsSf https://astral.sh/uv/install.sh | sh)"
check_cmd docker && echo -e "  ${GREEN}✓${NC} docker 已安装" || echo -e "  ${YELLOW}✗${NC} docker 未安装 (容器部署需要)"

# ─── 引擎菜单 ───
ENGINES=(
    "1:vLLM:高性能推理引擎 (OpenAI 兼容 API)"
    "2:SGLang:结构化生成 + 高吞吐"
    "3:TensorRT-LLM:NVIDIA 官方 (NGC 容器)"
    "4:Ollama:极简部署 (GGUF)"
    "5:llama.cpp:边缘/CPU 部署 (GGUF)"
    "6:全部安装"
)

echo ""
echo -e "${CYAN}可选引擎:${NC}"
for e in "${ENGINES[@]}"; do
    IFS=':' read -r num name desc <<< "$e"
    echo -e "  ${GREEN}[${num}]${NC} ${name} — ${desc}"
done
echo ""
read -p "选择 (1-6, 逗号分隔): " -r choices
[ -z "$choices" ] && echo "跳过" && exit 0

# ─── 安装目录 ───
read -p "uv 环境根目录 (默认 /opt/Projects): " -r ENV_ROOT
[ -z "$ENV_ROOT" ] && ENV_ROOT="/opt/Projects"
mkdir -p "$ENV_ROOT" 2>/dev/null || { echo -e "${RED}[ERROR] 无法创建 ${ENV_ROOT}（需要 sudo）${NC}"; exit 1; }

install_vllm() {
    local env="${ENV_ROOT}/uv-vllm-env"
    echo -e "${CYAN}━━━ 安装 vLLM → ${env} ━━━${NC}"
    uv venv --python 3.12 --seed "$env" 2>/dev/null || uv venv --python 3.12 "$env"
    source "${env}/bin/activate"
    uv pip install vllm --torch-backend=auto || { echo -e "${RED}[ERROR] vLLM 安装失败${NC}"; return 1; }
    echo -e "${GREEN}完成! 使用:${NC}"
    echo "  source ${env}/bin/activate"
    echo "  uv run vllm serve /data/models/ModelScope/Qwen/Qwen3-8B-AWQ --served-model-name qwen3-8b-awq --quantization awq --dtype auto --max-model-len 8192 --gpu-memory-utilization 0.85 --host 0.0.0.0 --port 8000 --trust-remote-code"
}

install_sglang() {
    local env="${ENV_ROOT}/uv-sglang-env"
    echo -e "${CYAN}━━━ 安装 SGLang → ${env} ━━━${NC}"
    uv venv --python 3.12 --seed "$env" 2>/dev/null || uv venv --python 3.12 "$env"
    source "${env}/bin/activate"
    uv pip install sglang
    echo -e "${GREEN}完成! 使用:${NC}"
    echo "  source ${env}/bin/activate"
    echo "  uv run sglang serve /data/models/ModelScope/Qwen/Qwen3-8B-AWQ --host 0.0.0.0 --port 30000 --trust-remote-code --mem-fraction-static 0.85"
}

install_trtllm() {
    echo -e "${CYAN}━━━ 安装 TensorRT-LLM (NGC 容器) ━━━${NC}"
    if ! check_cmd docker; then
        echo -e "${RED}需要 Docker: apt install docker.io && systemctl start docker${NC}"
        return 1
    fi
    docker pull nvcr.io/nvidia/tensorrt-llm/release:latest || { echo -e "${RED}[ERROR] docker pull 失败（检查 docker 运行/登录 nvcr.io）${NC}"; return 1; }
    echo -e "${GREEN}完成! 使用:${NC}"
    echo "  docker run --gpus all -p 8000:8000 -v /data/models:/data/models -it nvcr.io/nvidia/tensorrt-llm/release:latest"
    echo "  # 容器内: trtllm-serve serve /data/models/... --host 0.0.0.0 --port 8000"
}

install_ollama() {
    echo -e "${CYAN}━━━ 安装 Ollama ━━━${NC}"
    if check_cmd ollama; then
        echo -e "${GREEN}已安装: $(ollama --version 2>/dev/null)${NC}"
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi
    echo -e "${GREEN}完成! 使用:${NC}"
    echo "  ollama pull qwen3:8b && ollama run qwen3:8b"
    echo "  # API: curl http://localhost:11434/api/generate -d '{\"model\":\"qwen3:8b\",\"prompt\":\"Hi\"}'"
}

install_llamacpp() {
    local dir="${ENV_ROOT}/llama.cpp"
    echo -e "${CYAN}━━━ 安装 llama.cpp → ${dir} ━━━${NC}"
    if [ -d "$dir" ]; then
        echo -e "${GREEN}已存在，执行 git pull${NC}"
        cd "$dir" && git pull
    else
        # clone 失败兜底：否则 cd 失败后在当前目录跑 cmake 污染仓库（v1.43.11）
        git clone https://github.com/ggml-org/llama.cpp.git "$dir" || { echo -e "${RED}git clone 失败，跳过 llama.cpp 安装${NC}"; return 1; }
        cd "$dir" || { echo -e "${RED}无法进入 ${dir}，跳过 llama.cpp 安装${NC}"; return 1; }
    fi
    cmake -B build -DGGML_CUDA=ON 2>/dev/null && cmake --build build --config Release -j"$(nproc)"
    echo -e "${GREEN}完成! 使用:${NC}"
    echo "  ${dir}/build/bin/llama-server -m /data/models/qwen3-8b-q4_k_m.gguf --host 0.0.0.0 --port 8080 -ngl 999 --ctx-size 8192"
}

IFS=',' read -ra SELECTED <<< "$choices"
# 写操作确认（curl|sh / uv pip install / git clone+cmake / docker pull 均为系统级安装，与 install_tool 的 y/N 模式对齐——v1.33.3）
echo -e "${YELLOW}以下操作将安装/构建软件到系统（${ENV_ROOT} 及系统环境）：${NC}"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    case "$sel" in
        1) echo "  - vLLM (uv venv + uv pip install vllm)" ;;
        2) echo "  - SGLang (uv venv + uv pip install sglang)" ;;
        3) echo "  - TensorRT-LLM (docker pull nvcr.io)" ;;
        4) echo "  - Ollama (curl | sh + ollama pull)" ;;
        5) echo "  - llama.cpp (git clone + cmake 构建)" ;;
    esac
done
read -rp "确认执行安装? (y/N) " confirm
[[ ! "$confirm" =~ ^[Yy] ]] && { echo -e "${YELLOW}已取消${NC}"; exit 0; }

for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    case "$sel" in
        1) install_vllm ;;
        2) install_sglang ;;
        3) install_trtllm ;;
        4) install_ollama ;;
        5) install_llamacpp ;;
        6) install_vllm; install_sglang; install_trtllm; install_ollama; install_llamacpp ;;
        *) echo -e "${YELLOW}[SKIP] 未知选项 ${sel}${NC}" ;;
    esac
done

echo ""
echo -e "${GREEN}安装流程结束${NC}"
echo -e "${YELLOW}提示: 模型统一放在 /data/models/ModelScope/ 下（ModelScope 下载）${NC}"
