#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：寒武纪（cnmon，MLU 生态）
# modules/gpu/adapter_cambricon.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_cambricon <gpu_dir> [prefix]
# v1.47.0：cnmon 全量落盘 + lspci 层统一 CSV；cnmon 输出解析标注【待真机校准】
# =============================================================================

run_gpu_cambricon() {
    gpu_run_tool_adapter "$1" "${2:-}" "cnmon" "Cambricon|MLU" "寒武纪 MLU" \
        "cnmon info"             "gpu_cambricon_info.log" \
        "cnmon"                  "gpu_cambricon_full.log" \
        "cnmon -c 1"             "gpu_cambricon_poll.log"
}
