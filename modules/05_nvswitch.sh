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

    # 1~3. NVSwitch 视图（v1.51.3 换数据源）
    #
    # 【为什么换】原主路径是 `nvswitch`（独立 CLI）—— 但 **NVIDIA 根本没有这个名字的命令**：
    #   目标机实测 `command -v nvswitch` 找不到、`find /` 找不到、apt 也无对应包，
    #   于是 check_cmd 恒假，整段主路径**从未执行过一次**（每次都走 else 的 fallback）。
    #
    # 【换用什么】`nvswitch-audit` —— 真实存在，属 `nvidia-fabricmanager-*` 包，
    #   输出 NVSwitch 层面的 **GPU 可达性矩阵**（每对 GPU 之间实际编程了多少条 NVLink；
    #   `-1` = 无路径、`0` = 非 GPU 槽位、`X` = 自身）。这是「整机 NVSwitch 组网是否完整」
    #   的直接证据，比 nvidia-smi 侧的链路状态更接近 switch 视角。三份各有用途：
    #     默认输出  人读的矩阵（行列对齐）
    #     -c        CSV，报告端按字段解析
    #     -v        带 `Switch Arch = N` 与 devId/phyid/switchId 表（NVSwitch 颗数一目了然）
    if check_cmd nvswitch-audit; then
        run_and_log "nvswitch-audit" "${dir}/nvswitch_audit.log"
        run_and_log "nvswitch-audit -c" "${dir}/nvswitch_audit_csv.log"
        run_and_log "nvswitch-audit -v" "${dir}/nvswitch_audit_verbose.log"
    else
        echo -e "${YELLOW}[SKIP] nvswitch-audit not found（属 nvidia-fabricmanager 包）${NC}"
    fi

    # NVSwitch 域健康的 nvidia-smi 侧数据（无条件采；与上一段互补，非重复）
    #   nvidia-smi -q        → Fabric 段（State / Status / CliqueId / ClusterUUID）
    #   nvidia-smi nvlink -R → 各链路对端设备（NVSwitch 连通性；FM 未运行时为 FFFFFFFF）
    #   nvidia-smi nvlink -e → 逐链路错误计数与流量（选项名是 -e，不是 --error_count）
    if check_cmd nvidia-smi; then
        run_and_log "nvidia-smi -q 2>&1" "${dir}/nvswitch_fabric_q.log"
        run_and_log "nvidia-smi nvlink -R 2>&1" "${dir}/nvlink_remote_info.log"
        run_and_log "nvidia-smi nvlink -e 2>&1" "${dir}/nvlink_error_count.log"
    fi

    # 4~5. Fabric Manager 相关（独立于 NVSwitch 工具，条件执行）
    if check_cmd nv-fabricmanager || check_cmd nvidia-fabricmanager; then
        run_and_log "nv-fabricmanager --version 2>&1 || nvidia-fabricmanager --version 2>&1" "${dir}/fabricmanager_version.log"
    fi
    if check_cmd systemctl; then
        run_and_log "systemctl status nvidia-fabricmanager 2>&1 | head -40" "${dir}/fabricmanager_service.log"
    fi

# NOTE: nvswitch_audit*.log 为 NVSwitch 可达性矩阵（v1.51.3 起，替代不存在的 nvswitch CLI）
#       nvswitch_fabric_q.log / nvlink_remote_info.log / nvlink_error_count.log
#       为 nvidia-smi 侧的 NVSwitch 域健康数据（v1.48.61 起）
    write_manifest "${dir}/manifest.txt" \
        "nvswitch_audit" "nvswitch_audit.log" \
        "nvswitch_audit_csv" "nvswitch_audit_csv.log" \
        "nvswitch_audit_verbose" "nvswitch_audit_verbose.log" \
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
