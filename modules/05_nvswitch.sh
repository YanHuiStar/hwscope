#!/bin/bash
# =============================================================================
# 模块: 05_nvswitch.sh — NVSwitch 信息采集
# 输出目录: <OUTPUT_DIR>/nvswitch/
# =============================================================================

MODULE_NAME="NVSwitch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_nvswitch() {
    local output_dir="$1"
    local dir="${output_dir}/nvswitch"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # 1~3. NVSwitch 全局信息 + 每颗单独 + 版本（条件执行）
    if check_cmd nvswitch; then
        run_and_log "nvswitch -q" "${dir}/nvswitch_all.log"

        # 每个 NVSwitch 单独采集：动态枚举（逐个 index 探测直至失败，
        # 适配不同型号数量差异：HGX 4颗/B300 6颗/GB300 更多，禁止硬编码）
        # 双保险：exit code 非零 或 输出含 Invalid/not found → 结束枚举
        local ns_idx=0
        while [ "$ns_idx" -lt 32 ]; do
            local ns_out
            ns_out=$(nvswitch -q -i "$ns_idx" 2>&1)
            # 终止判定：退出码非零 或 明确不存在（去掉过宽 'failed'，防降级 switch 的正常输出含 failed 字样提前截断枚举）
            if [ $? -ne 0 ] || echo "$ns_out" | grep -qiE "invalid|not found"; then
                break
            fi
            run_and_log "nvswitch -q -i ${ns_idx}" "${dir}/nvswitch_${ns_idx}.log"
            ((ns_idx++))
        done
        [ "$ns_idx" -eq 0 ] && echo -e "${YELLOW}[WARN] nvswitch -q -i 0 失败，无法枚举 NVSwitch${NC}"

        # NVSwitch 版本
        run_and_log "nvswitch --version 2>&1" "${dir}/nvswitch_version.log"
    else
        echo -e "${YELLOW}[SKIP] nvswitch command not found${NC}"
        # ─── 无独立 nvswitch CLI 时的 fallback（v1.48.61 命令修正）───
        # 原实现四条命令全部无效（驱动 580.105.08 上逐条实测）：
        #   ① `nvidia-smi nvswitch --status`    → ERROR: Option nvswitch is not recognized
        #      （nvidia-smi 并无 nvswitch 子命令；原注释"驱动 525+ 内置"系误判）
        #   ② `nvidia-smi nvswitch --info`      → 同上，同样失败
        #   ③ `nvidia-smi nvlink --error_count` → Option "--error_count" is not recognized（正确选项为 -e）
        #   ④ `dcgmi nvswitch -l`               → ERROR: Invalid subsystem（DCGM 4.4.0 无 nvswitch 子系统）
        # → 三项采集长期为空，而报告端为 ① 的输出格式写了解析（永久空转）。
        # 改用实测有效、且共同刻画 NVSwitch 域健康的三个数据源：
        #   nvidia-smi -q        → Fabric 段（State / Status / CliqueId / ClusterUUID）
        #   nvidia-smi nvlink -R → 各链路对端设备（NVSwitch 连通性；FM 未运行时为 FFFFFFFF）
        #   nvidia-smi nvlink -e → 逐链路错误计数与流量（v1.48.61 修正原选项名）
        if check_cmd nvidia-smi; then
            run_and_log "nvidia-smi -q 2>&1" "${dir}/nvswitch_fabric_q.log"
            run_and_log "nvidia-smi nvlink -R 2>&1" "${dir}/nvlink_remote_info.log"
            run_and_log "nvidia-smi nvlink -e 2>&1" "${dir}/nvlink_error_count.log"
        fi
    fi

    # 4~5. Fabric Manager 相关（独立于 nvswitch 命令，条件执行）
    if check_cmd nv-fabricmanager || check_cmd nvidia-fabricmanager; then
        run_and_log "nv-fabricmanager --version 2>&1 || nvidia-fabricmanager --version 2>&1" "${dir}/fabricmanager_version.log"
    fi
    if check_cmd systemctl; then
        run_and_log "systemctl status nvidia-fabricmanager 2>&1 | head -40" "${dir}/fabricmanager_service.log"
    fi

# NOTE: nvswitch_N.log are generated per NVSwitch (N=0,1,...)
#       nvswitch_fabric_q.log / nvlink_remote_info.log / nvlink_error_count.log
#       为无独立 nvswitch CLI 平台（B300/GB300 等）的 fallback（v1.48.61 起）
    write_manifest "${dir}/manifest.txt" \
        "nvswitch_all" "nvswitch_all.log" \
        "nvswitch_version" "nvswitch_version.log" \
        "fabricmanager_version" "fabricmanager_version.log" \
        "fabricmanager_service" "fabricmanager_service.log" \
        "nvswitch_fabric_q" "nvswitch_fabric_q.log" \
        "nvlink_remote_info" "nvlink_remote_info.log" \
        "nvlink_error_count" "nvlink_error_count.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_nvswitch "$1"
fi
