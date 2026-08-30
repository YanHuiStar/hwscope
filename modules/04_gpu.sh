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
# v1.48.9 修复：用独立变量 MODULE_DIR——原 v1.47.0 直接赋 SCRIPT_DIR，被 hwscope.sh source 时
# BASH_SOURCE[0]=完整路径(/opt/.../modules/04_gpu.sh)，dirname 污染全局 SCRIPT_DIR=modules/，
# 导致后续模块拼接出 modules/modules/05_xxx.sh 全部报"模块脚本不存在"（01-03 用 $0 无害，05+ 全挂）
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
source "${MODULE_DIR}/../lib/common.sh" 2>/dev/null || true
# v1.48.17：并行子进程模式（hwscope.sh 用独立 bash 执行模块，不继承主脚本函数）——
# detect_gpu_vendors 在 lib/platform.sh，须显式 source（WSL 无 lspci 时 nvidia-smi 兜底依赖它）
source "${MODULE_DIR}/../lib/platform.sh" 2>/dev/null || true

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
    # v1.48.12 修复：适配器加载路径原用 SCRIPT_DIR（v1.48.9 改 MODULE_DIR 后为空）→ source 静默失败 → run_gpu_* 未定义
    [ -f "${MODULE_DIR}/gpu/lib.sh" ] && source "${MODULE_DIR}/gpu/lib.sh"
    for _ad in nvidia amd ascend intel cambricon biren moorethreads metax iluvatar generic; do
        [ -f "${MODULE_DIR}/gpu/adapter_${_ad}.sh" ] && source "${MODULE_DIR}/gpu/adapter_${_ad}.sh"
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
