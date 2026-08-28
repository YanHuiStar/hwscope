#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：天数智芯（ix-smi，天垓 BI 生态）
# modules/gpu/adapter_iluvatar.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_iluvatar <gpu_dir> [prefix]
# v1.47.0：ix-smi 全量落盘 + lspci 层统一 CSV；输出解析标注【待真机校准】
# =============================================================================

run_gpu_iluvatar() {
    gpu_run_tool_adapter "$1" "${2:-}" "ix-smi" "Iluvatar|CoreX|天垓" "天数智芯天垓" \
        "ix-smi"                   "gpu_iluvatar_full.log" \
        "ix-smi -L"                "gpu_iluvatar_list.log"
}
