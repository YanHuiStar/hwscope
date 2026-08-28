#!/bin/bash
# =============================================================================
# 模块: 04_gpu.sh — GPU 信息采集（v1.47.0 适配器框架）
# 输出目录: <OUTPUT_DIR>/gpu/
# 统一检测接口：detect_gpu_vendors 识别 → 按 GPU_PLATFORM 分发到 modules/gpu/adapter_<vendor>.sh
#   NVIDIA=adapter_nvidia（金标准） / AMD=adapter_amd（ROCm） / 昇腾=adapter_ascend（npu-smi）
#   Intel=adapter_intel（xpu-smi） / 国产=adapter_cambricon|biren|moorethreads|metax|iluvatar
#   未知/无工具=adapter_generic（lspci -vvv 兜底，不丢数据）
# 每个适配器输出统一 gpu_inventory.csv（列与 nvidia-smi 18 列一致）→ 报告零改动跨厂商消费
# =============================================================================

MODULE_NAME="GPU"
# v1.47.0: 用 BASH_SOURCE[0]（source 时 $0 是主脚本，dirname 会解析错；独立执行时二者一致）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_gpu() {
    local output_dir="$1"
    local dir="${output_dir}/gpu"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # ─── GPU 平台检测（v1.46.2 起调 detect_gpu_vendors 单一实现）───
    #   识别类目：NVIDIA/AMD/Intel 独立卡 = lspci "3D controller"，华为昇腾卡 = "Processing accelerators"（v1.46.7）
    if command -v detect_gpu_vendors >/dev/null 2>&1; then
        detect_gpu_vendors
    else
        # 兜底（函数缺失时）
        GPU_PCI_PRESENT=$(lspci 2>/dev/null | grep -cE "3D controller|Processing accelerators")
        GPU_PCI_VENDOR=""; GPU_PCI_VENDORS=""; GPU_PLATFORM="none"
    fi

    # ─── 装载 GPU 适配器（v1.47.0）───
    local _ad
    [ -f "${SCRIPT_DIR}/gpu/lib.sh" ] && source "${SCRIPT_DIR}/gpu/lib.sh"
    for _ad in nvidia amd ascend intel cambricon biren moorethreads metax iluvatar generic; do
        [ -f "${SCRIPT_DIR}/gpu/adapter_${_ad}.sh" ] && source "${SCRIPT_DIR}/gpu/adapter_${_ad}.sh"
    done

    # ─── 无 GPU → SKIP（不落 inventory，报告按"无 GPU"N/A 处理）───
    if [ "${GPU_PCI_PRESENT:-0}" -le 0 ] 2>/dev/null; then
        echo -e "${YELLOW}[SKIP] 无 GPU（无 3D controller/加速卡设备），跳过 GPU 模块${NC}"
        module_end "$MODULE_NAME"
        return 0
    fi

    # ─── 按平台分发（mixed = 多厂商逐 adapter + 合并统一 CSV）───
    case "$GPU_PLATFORM" in
        nvidia)       run_gpu_nvidia "$dir" ;;
        amd)          run_gpu_amd "$dir" ;;
        ascend)       run_gpu_ascend "$dir" ;;
        intel)        run_gpu_intel "$dir" ;;
        cambricon)    run_gpu_cambricon "$dir" ;;
        biren)        run_gpu_biren "$dir" ;;
        moorethreads) run_gpu_moorethreads "$dir" ;;
        metax)        run_gpu_metax "$dir" ;;
        iluvatar)     run_gpu_iluvatar "$dir" ;;
        mixed)
            local _mk _mv
            for _mk in $(echo "$GPU_PCI_VENDORS" | tr ' ' '\n' | sed 's/:.*//'); do
                [ -z "$_mk" ] && continue
                _mv=$(gpu_vendor_to_platform "$_mk")
                case "$_mv" in
                    nvidia) run_gpu_nvidia "$dir" nvidia ;;
                    amd)    run_gpu_amd "$dir" amd ;;
                    ascend) run_gpu_ascend "$dir" ascend ;;
                    intel)  run_gpu_intel "$dir" intel ;;
                    *)      run_gpu_generic "$dir" "$(echo "$_mk" | tr 'A-Z' 'a-z')" ;;
                esac
            done
            # 合并各厂商统一 CSV → gpu_inventory.csv（manifest tail -1 生效）
            gpu_merge_inventory "$dir"
            write_manifest --append "${dir}/manifest.txt" "gpu_inventory" "gpu_inventory.csv"
            ;;
        *)  # other/未知厂商 → lspci 兜底（不丢数据）
            run_gpu_generic "$dir" ;;
    esac

    module_end "$MODULE_NAME"
}

# 允许单独执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_gpu "$1"
fi
