#!/bin/bash
# =============================================================================
# 模块: 02_nvswitch.sh — NVSwitch 信息采集
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

    # 1. NVSwitch 全局信息（小写 -q，大写 -Q 不存在）
    if check_cmd nvswitch; then
        run_and_log "nvswitch -q" "${dir}/nvswitch_all.log"

        # 2. 每个 NVSwitch 单独（通常 4 颗）
        for i in 0 1 2 3; do
            run_and_log "nvswitch -q -i $i" "${dir}/nvswitch_${i}.log"
        done

        # 3. NVSwitch 版本
        run_and_log "nvswitch --version 2>&1" "${dir}/nvswitch_version.log"
    else
        echo -e "${YELLOW}[SKIP] nvswitch command not found${NC}"
    fi

    # 4. Fabric Manager 状态（nvidia-fabricmanager 是守护进程，不是 CLI 查询工具）
    if check_cmd nvidia-fabricmanager; then
        run_and_log "nvidia-fabricmanager --version 2>&1" "${dir}/fabricmanager_version.log"
    fi
    if check_cmd systemctl; then
        run_and_log "systemctl status nvidia-fabricmanager 2>&1 | head -40" "${dir}/fabricmanager_service.log"
    fi

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_nvswitch "$1"
fi
