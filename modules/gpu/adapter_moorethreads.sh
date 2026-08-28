#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器：摩尔线程（mthreads-gmi，MUSA 生态）
# modules/gpu/adapter_moorethreads.sh — 由 modules/04_gpu.sh source 装配
# 契约: run_gpu_moorethreads <gpu_dir> [prefix]
# v1.47.0：mthreads-gmi 全量落盘 + lspci 层统一 CSV；输出解析标注【待真机校准】
# =============================================================================

run_gpu_moorethreads() {
    gpu_run_tool_adapter "$1" "${2:-}" "mthreads-gmi" "Moore Threads|MTT" "摩尔线程 MTT" \
        "mthreads-gmi -L"          "gpu_moorethreads_list.log" \
        "mthreads-gmi -q"          "gpu_moorethreads_query.log" \
        "mthreads-gmi"             "gpu_moorethreads_full.log"
}
