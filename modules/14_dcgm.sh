#!/bin/bash
# =============================================================================
# 模块: 14_dcgm.sh — DCGM (Data Center GPU Manager) 诊断
# 输出目录: <OUTPUT_DIR>/dcgm/
# 说明：需要安装 datacenter-gpu-manager，无则静默跳过
# =============================================================================

MODULE_NAME="DCGM"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_dcgm() {
    local output_dir="$1"
    local dir="${output_dir}/dcgm"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    if ! check_cmd dcgmi; then
        echo -e "${YELLOW}[SKIP] dcgmi not found (install datacenter-gpu-manager)${NC}"
        module_end "$MODULE_NAME"
        return 0
    fi

    # DCGM hostengine 自动启动：discovery/stats/config 依赖 hostengine 服务，
    # 未启动时全部报 "unable to establish a connection"（diag 会自动拉起，不受影响）。
    # 验收/交付场景 root 跑，默认自动启动（DCGM_AUTO_START=1 可关）。
    DCGM_AUTO_START=${DCGM_AUTO_START:-1}
    DCGM_NOT_STARTED=0
    if [ "$DCGM_AUTO_START" -eq 1 ]; then
        if ! dcgmi discovery -l >/dev/null 2>&1; then
            # 尝试 systemd 服务，失败再试 nv-hostengine 直接启动
            if check_cmd systemctl && systemctl start nvidia-dcgm 2>/dev/null; then
                sleep 1
            elif check_cmd nv-hostengine; then
                nv-hostengine -s >/dev/null 2>&1 || true
                sleep 1
            fi
            # 启动后仍未通 → 记录提示（root 下一般能起，失败多为未安装 hostengine 包）
            dcgmi discovery -l >/dev/null 2>&1 || DCGM_NOT_STARTED=1
        fi
    fi

    # nvidia-persistenced 临时开关（v1.44.2，用户方案）：DCGM 诊断依赖 persistence mode 稳定性——
    # 原状态已开启则不动；原状态关闭则临时开启（nvidia-smi -pm 1），DCGM 采集后恢复原状（只读无害，不留状态变更）
    # v1.44.3 加固：逐卡记录原状态（混插平台可能部分卡已开启，全局 -pm 0 会误关）+ trap 兜底（采集被 kill 时防 -pm 1 残留）
    PERSIST_TOUCHED=0
    PERSIST_ORIG=()
    __dcgm_restore_persist() {
        [ "${PERSIST_TOUCHED:-0}" -eq 1 ] || return 0
        local _i=0 _s
        for _s in "${PERSIST_ORIG[@]}"; do
            [ "$_s" = "Disabled" ] && nvidia-smi -i "$_i" -pm 0 >/dev/null 2>&1
            _i=$((_i+1))
        done
        PERSIST_TOUCHED=0
        echo "[INFO] 已恢复 nvidia-persistenced 原状态（逐卡还原）"
    }
    if check_cmd nvidia-smi; then
        while IFS= read -r _pmline; do
            [ -n "$_pmline" ] && PERSIST_ORIG+=("$_pmline")
        done < <(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | grep -viE "N/A|unknown")
        _pm_off=0
        for _s in "${PERSIST_ORIG[@]}"; do [ "$_s" = "Disabled" ] && _pm_off=1; done
        if [ "$_pm_off" -eq 1 ]; then
            if nvidia-smi -pm 1 >/dev/null 2>&1; then
                PERSIST_TOUCHED=1
                echo "[INFO] nvidia-persistenced 临时开启（DCGM 采集后恢复原状）"
                # 兜底：脚本被 kill/Ctrl-C 时 EXIT 触发恢复；函数正常路径恢复后 TOUCHED=0，trap 触发为空操作
                trap '__dcgm_restore_persist' EXIT
            else
                echo -e "${YELLOW}[WARN] nvidia-smi -pm 1 失败（无权限或平台不支持），DCGM 在无 persistence 下运行${NC}" >&2
            fi
            sleep 1
        fi
    fi

    # 1~5. DCGM 诊断信息（并行采集；串行模式自动降级）
    run_and_log_parallel 5 \
        "dcgmi discovery -l 2>&1" "${dir}/dcgmi_discovery.log" \
        "dcgmi stats -v 2>&1" "${dir}/dcgmi_stats.log" \
        "dcgmi config --list 2>&1" "${dir}/dcgmi_config.log" \
        "dcgmi diag -r 1 2>&1" "${dir}/dcgmi_diag_level1.log" \
        "dcgmi --version 2>&1" "${dir}/dcgmi_version.log"

    # 恢复 nvidia-persistenced 原状态（逐卡还原；恢复后 trap 为空操作）
    __dcgm_restore_persist
    trap - EXIT

write_manifest "${dir}/manifest.txt" \
        "dcgmi_discovery" "dcgmi_discovery.log" \
        "dcgmi_stats" "dcgmi_stats.log" \
        "dcgmi_config" "dcgmi_config.log" \
        "dcgmi_diag_level1" "dcgmi_diag_level1.log" \
        "dcgmi_version" "dcgmi_version.log"

    # DCGM hostengine 未启动提示（discovery/stats 降级，仅 diag 可用）
    if [ "$DCGM_NOT_STARTED" -eq 1 ]; then
        echo "⚠️ DCGM hostengine 未启动（sudo systemctl start nvidia-dcgm 可启用）：discovery/stats 未采集，diag 结果正常" > "${dir}/dcgm_notice.log"
        write_manifest --append "${dir}/manifest.txt" "dcgm_notice" "dcgm_notice.log"
    fi

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_dcgm "$1"
fi
