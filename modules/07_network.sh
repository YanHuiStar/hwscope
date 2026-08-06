#!/bin/bash
# =============================================================================
# 模块: 07_network.sh — 网络/IB/光模块信息采集
# 输出目录: <OUTPUT_DIR>/network/
# =============================================================================

MODULE_NAME="Network"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_network() {
    local output_dir="$1"
    local dir="${output_dir}/network"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # ─── InfiniBand ───
    if check_cmd ibstat; then
        run_and_log "ibstat" "${dir}/ibstat.log"
    else
        echo -e "${YELLOW}[SKIP] ibstat not found${NC}"
    fi

    if check_cmd ibstatus; then
        run_and_log "ibstatus" "${dir}/ibstatus.log"
    fi

    if check_cmd ibv_devinfo; then
        run_and_log "ibv_devinfo" "${dir}/ibv_devinfo.log"
    fi

    if check_cmd ibdev2netdev; then
        run_and_log "ibdev2netdev" "${dir}/ibdev2netdev.log"
    fi

    # ─── Mellanox / NVIDIA NIC 工具 ───
    if check_cmd mlxfwmanager; then
        run_and_log "mlxfwmanager" "${dir}/mlxfwmanager.log"
    else
        echo -e "${YELLOW}[SKIP] mlxfwmanager not found${NC}"
    fi

    if check_cmd mlxconfig; then
        run_and_log "mlxconfig query" "${dir}/mlxconfig.log"
        # 每口 LINK_TYPE 模式（IB/ETH/VPI，现场判断网络模式的关键）
        local mlx_cfg_devs=$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5 | head -12)
        for cfg_dev in $mlx_cfg_devs; do
            run_and_log "mlxconfig query -d ${cfg_dev} 2>/dev/null | grep -E 'LINK_TYPE_P[12]'" \
                "${dir}/mlxconfig_${cfg_dev}_linktype.log"
        done
    fi

    # ─── mlxlink：遍历所有 mlx5 设备 ───
    if check_cmd mlxlink; then
        local mlx_devs=$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5)
        if [ -z "$mlx_devs" ]; then
            # 回退：动态探测设备号（B300 平台最多 12+ 个 mlx5 设备，避免硬编码漏采）
            local dev_num=0
            while [ "$dev_num" -lt 24 ]; do
                if [ -e "/sys/class/net/mlx5_${dev_num}" ] || ls /sys/class/infiniband/ 2>/dev/null | grep -q "mlx5_${dev_num}"; then
                    run_and_log "mlxlink -d mlx5_${dev_num}" "${dir}/mlxlink_${dev_num}.log"
                    [ "${NO_MODULE:-0}" -eq 0 ] && run_and_log "mlxlink -d mlx5_${dev_num} -m" "${dir}/mlxlink_${dev_num}_module.log"
                fi
                ((dev_num++))
            done
        else
            local count=0
            while IFS= read -r dev; do
                run_and_log "mlxlink -d $dev" "${dir}/mlxlink_${dev}.log"
                [ "${NO_MODULE:-0}" -eq 0 ] && run_and_log "mlxlink -d $dev -m" "${dir}/mlxlink_${dev}_module.log"
                ((count++))
            done <<< "$mlx_devs"
        fi
    fi

    # ─── 以太网口 ───
    if check_cmd ethtool; then
        local eth_devs=$(ip -o link show | grep -v 'lo' | awk -F': ' '{print $2}' | sed 's/@.*//')
        while IFS= read -r dev; do
            [ -z "$dev" ] && continue
            # 跳过虚拟/IB 接口
            [[ "$dev" == *ib* ]] && continue
            [[ "$dev" == *bond* ]] && continue
            [[ "$dev" == *docker* ]] && continue
            [[ "$dev" == *veth* ]] && continue
            local safe_name=$(echo "$dev" | tr '/' '_')
            run_and_log "ethtool '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}.log"
            run_and_log "ethtool -i '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}_driver.log"
            run_and_log "ethtool -m '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}_module.log"
        done <<< "$eth_devs"
    fi

    # ─── IP / MAC 地址 ───
    run_and_log "ip addr" "${dir}/ip_addr.log"
    run_and_log "ip link show" "${dir}/ip_link.log"
    run_and_log "ip route show" "${dir}/ip_route.log"

    # ─── 网络拓扑 ───
    if check_cmd lstopo; then
        run_and_log "lstopo --no-io --output-format txt" "${dir}/lstopo_network.txt"
    fi

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_network "$1"
fi
