#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：壁仞（bmt-smi，BR100 生态）
# modules/gpu/adapter_biren.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_biren <gpu_dir> [prefix]
# v1.47.0：bmt-smi 全量落盘 + lspci 层统一 CSV；bmt-smi 输出解析标注【待真机校准】
# =============================================================================

run_gpu_biren() {
    gpu_run_tool_adapter "$1" "${2:-}" "bmt-smi" "Biren|BR[0-9]" "壁仞 BR100" \
        "bmt-smi"                  "gpu_biren_full.log" \
        "bmt-smi info -l"          "gpu_biren_list.log"
}
