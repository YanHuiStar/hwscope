#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：沐曦（mx-smi，曦云 C 系列生态）
# modules/gpu/adapter_metax.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_metax <gpu_dir> [prefix]
# v1.47.0：mx-smi 全量落盘 + lspci 层统一 CSV；输出解析标注【待真机校准】
# =============================================================================

run_gpu_metax() {
    gpu_run_tool_adapter "$1" "${2:-}" "mx-smi" "MetaX|曦云|C500" "沐曦曦云" \
        "mx-smi"                   "gpu_metax_full.log" \
        "mx-smi -q"                "gpu_metax_query.log"
}
