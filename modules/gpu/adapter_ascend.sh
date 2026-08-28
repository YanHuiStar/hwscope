#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：华为昇腾（npu-smi，Atlas 生态）
# modules/gpu/adapter_ascend.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_ascend <gpu_dir> [prefix]
# v1.47.0：识别（v1.46.7）+ 采集接入。npu-smi 全量落盘（info/board/topo HCCS/health/每卡 detail/mem）；
#   统一 CSV 取 lspci 层（名称/BDF/PCIe 链路可判，显存/温度等 N/A）——
#   npu-smi 输出格式解析标注【待真机校准】，真机样本到位后仅改本文件解析，全量日志已在归档中
# =============================================================================

run_gpu_ascend() {
    local dir="$1" prefix="${2:-}"
    if ! check_cmd npu-smi; then
        gpu_fallback_pci "$dir" "$prefix" "npu-smi" "Huawei|HiSilicon"
        return 1
    fi

    echo -e "${CYAN}[INFO] 检测到昇腾 GPU（npu-smi），走 Atlas 采集路径${NC}"

    # 全量落盘（并行；npu-smi 各子命令均为只读查询）
    local asc_jobs=(
        "npu-smi info"                     "${dir}/gpu_ascend_info.log"
        "npu-smi info -t board"            "${dir}/gpu_ascend_board.log"
        "npu-smi info -t topo"             "${dir}/gpu_ascend_hccs_topo.log"
        "npu-smi info -t health"           "${dir}/gpu_ascend_health.log"
        "npu-smi info -t common"           "${dir}/gpu_ascend_common.log"
        "npu-smi info -t proc-mem"         "${dir}/gpu_ascend_procmem.log"
    )
    run_and_log_parallel 4 "${asc_jobs[@]}"

    # 每卡明细（按 lspci 加速卡数；npu-smi 卡 id 与 BDF 顺序一致时一一对应）
    local _cnt=${GPU_PCI_PRESENT:-0}
    local _ai=0
    while [ "$_ai" -lt "$_cnt" ]; do
        run_and_log "npu-smi info -t common -i $_ai"     "${dir}/gpu_ascend_${_ai}_detail.log"
        run_and_log "npu-smi info -t proc-mem -i $_ai"   "${dir}/gpu_ascend_${_ai}_mem.log"
        run_and_log "npu-smi info -t health -i $_ai"     "${dir}/gpu_ascend_${_ai}_health.log"
        _ai=$((_ai + 1))
    done

    # 统一 CSV：lspci 层保底（PCIe 链路可判；显存/温度待真机校准解析 npu-smi）
    gpu_csv_from_lspci "$dir" "$prefix" "Huawei|HiSilicon"
    local inv_csv="gpu_inventory.csv"
    [ -n "$prefix" ] && inv_csv="gpu_inventory_${prefix}.csv"

    gpu_adapter_manifest "$dir" \
        "gpu_ascend_info" "gpu_ascend_info.log" \
        "gpu_ascend_board" "gpu_ascend_board.log" \
        "gpu_ascend_hccs_topo" "gpu_ascend_hccs_topo.log" \
        "gpu_ascend_health" "gpu_ascend_health.log" \
        "gpu_ascend_procmem" "gpu_ascend_procmem.log" \
        "gpu_inventory" "${inv_csv}"
}
