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

    # ─── InfiniBand + Mellanox / NVIDIA NIC 工具（并行） ───
    local ib_jobs=()
    check_cmd ibstat       && ib_jobs+=("ibstat" "${dir}/ibstat.log")
    check_cmd ibstatus     && ib_jobs+=("ibstatus" "${dir}/ibstatus.log")
    check_cmd ibv_devinfo  && ib_jobs+=("ibv_devinfo" "${dir}/ibv_devinfo.log")
    check_cmd ibdev2netdev && ib_jobs+=("ibdev2netdev" "${dir}/ibdev2netdev.log")
    check_cmd mlxfwmanager && ib_jobs+=("mlxfwmanager" "${dir}/mlxfwmanager.log")
    if check_cmd mlxconfig; then
        ib_jobs+=("mlxconfig query" "${dir}/mlxconfig.log")
        # 每口 LINK_TYPE 模式（IB/ETH/VPI，现场判断网络模式的关键）
        # 动态枚举全部 mlx5 设备（禁止 head 截断：B300 高密度节点 12+ 个）
        local mlx_cfg_devs=$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5)
        for cfg_dev in $mlx_cfg_devs; do
            ib_jobs+=("mlxconfig query -d ${cfg_dev} 2>/dev/null | grep -E 'LINK_TYPE_P[12]'" "${dir}/mlxconfig_${cfg_dev}_linktype.log")
        done
    fi
    [ "${#ib_jobs[@]}" -gt 0 ] && run_and_log_parallel 8 "${ib_jobs[@]}" 

    # ─── mlxlink：遍历所有 mlx5 设备（并行） ───
    if check_cmd mlxlink; then
        local mlx_jobs=()
        local mlx_devs=$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5)
        if [ -z "$mlx_devs" ]; then
            # 回退：动态探测设备号（B300 平台最多 12+ 个 mlx5 设备，避免硬编码漏采）
            local dev_num=0
            while [ "$dev_num" -lt 24 ]; do
                if [ -e "/sys/class/net/mlx5_${dev_num}" ] || ls /sys/class/infiniband/ 2>/dev/null | grep -q "mlx5_${dev_num}"; then
                    mlx_jobs+=("mlxlink -d mlx5_${dev_num}" "${dir}/mlxlink_${dev_num}.log")
                    [ "${NO_MODULE:-0}" -eq 0 ] && mlx_jobs+=("mlxlink -d mlx5_${dev_num} -m" "${dir}/mlxlink_${dev_num}_module.log")
                fi
                ((dev_num++))
            done
        else
            while IFS= read -r dev; do
                mlx_jobs+=("mlxlink -d $dev" "${dir}/mlxlink_${dev}.log")
                [ "${NO_MODULE:-0}" -eq 0 ] && mlx_jobs+=("mlxlink -d $dev -m" "${dir}/mlxlink_${dev}_module.log")
            done <<< "$mlx_devs"
        fi
        [ "${#mlx_jobs[@]}" -gt 0 ] && run_and_log_parallel 8 "${mlx_jobs[@]}"
    fi

    # ─── 以太网口（并行） ───
    if check_cmd ethtool; then
        local eth_jobs=()
        local eth_devs=$(ip -o link show | grep -v 'lo' | awk -F': ' '{print $2}' | sed 's/@.*//')
        while IFS= read -r dev; do
            [ -z "$dev" ] && continue
            # 跳过虚拟/IB 接口
            [[ "$dev" == *ib* ]] && continue
            [[ "$dev" == *bond* ]] && continue
            [[ "$dev" == *docker* ]] && continue
            [[ "$dev" == *veth* ]] && continue
            local safe_name=$(echo "$dev" | tr '/' '_')
            eth_jobs+=("ethtool '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}.log")
            eth_jobs+=("ethtool -i '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}_driver.log")
            eth_jobs+=("ethtool -m '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}_module.log")
        done <<< "$eth_devs"
        [ "${#eth_jobs[@]}" -gt 0 ] && run_and_log_parallel 8 "${eth_jobs[@]}"
    fi

    # ─── IP / MAC 地址（并行） ───
    run_and_log_parallel 3 \
        "ip addr" "${dir}/ip_addr.log" \
        "ip link show" "${dir}/ip_link.log" \
        "ip route show" "${dir}/ip_route.log" 

    # ─── 网卡一览清单（dev|bdf|mac|sn|pn|fw|speed|width）───
    {
        echo "# nic inventory: dev|bdf|mac|serial|part_number|firmware|speed|width"
        for ndev in $(ls /sys/class/net/ 2>/dev/null); do
            [ "$ndev" = "lo" ] && continue
            # 仅 PCIe 网卡
            local ndev_path=$(readlink -f "/sys/class/net/${ndev}/device" 2>/dev/null)
            [[ "$ndev_path" != *pci* ]] && continue
            local nbdf=$(grep "PCI_SLOT_NAME" "/sys/class/net/${ndev}/device/uevent" 2>/dev/null | cut -d'=' -f2 | sed 's/^0000://')
            [ -z "$nbdf" ] && nbdf=$(basename "$ndev_path" | sed 's/^0000://')
            local nmac=$(cat "/sys/class/net/${ndev}/address" 2>/dev/null)
            # IB 长地址取后 6 字节
            if [ "${#nmac}" -gt 17 ]; then
                nmac=$(echo "$nmac" | awk -F: '{for(i=13;i<=NF;i++) printf "%s%s", $i, (i<NF?":":"")}')
            fi
            local nsn=$(cat "/sys/class/net/${ndev}/device/serial" 2>/dev/null)
            [ -z "$nsn" ] && nsn=$(lspci -vv -s "$nbdf" 2>/dev/null | grep -i "Serial Number" | head -1 | awk '{print $NF}')
            [ -z "$nsn" ] && nsn="N/A"
            local npn=$(lspci -vv -s "$nbdf" 2>/dev/null | grep -i "Part Number" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
            [ -z "$npn" ] && npn=$(lspci -s "$nbdf" 2>/dev/null | cut -d' ' -f4-)
            # Mellanox 卡：sysfs serial 常为占位值（多卡相同），用 mstflint q 读 VPD 真 SN + PSID
            local mstdev=""
            local nis_mlx=0
            [[ "$npn" == *"Mellanox"* || "$npn" == *"ConnectX"* || "$npn" == *"MLX"* ]] && nis_mlx=1
            local npsid="N/A"
            if [ "$nis_mlx" -eq 1 ] && check_cmd mstflint; then
                mstdev=$(mst status 2>/dev/null | grep -i "$nbdf" | awk '{print $1}' | head -1)
                [ -z "$mstdev" ] && mstdev=$(ls /dev/mst/* 2>/dev/null | grep -i "${nbdf//:}" | head -1)
                if [ -n "$mstdev" ]; then
                    local mq_out=$(mstflint -d "$mstdev" q 2>/dev/null)
                    local mq_sn=$(echo "$mq_out" | grep -iE "^Serial Number|^Board Serial" | head -1 | awk '{print $NF}')
                    [ -n "$mq_sn" ] && nsn="$mq_sn"
                    local mq_psid=$(echo "$mq_out" | grep "PSID" | awk '{print $NF}')
                    [ -n "$mq_psid" ] && npsid="$mq_psid"
                fi
            fi
            local nfw="N/A"
            if check_cmd ethtool; then
                nfw=$(ethtool -i "$ndev" 2>/dev/null | grep "firmware-version" | awk '{print $2}')
            fi
            local nspd="N/A" nwd="N/A"
            if check_cmd lspci; then
                local lnksta=$(lspci -vv -s "$nbdf" 2>/dev/null | grep "LnkSta:" | head -1)
                nspd=$(echo "$lnksta" | grep -oE "[0-9]+GT/s" | head -1)
                nwd=$(echo "$lnksta" | grep -oE "x[0-9]+" | head -1)
            fi
            [ -z "$nspd" ] && nspd="N/A"; [ -z "$nwd" ] && nwd="N/A"
            echo "${ndev}|${nbdf}|${nmac:-N/A}|${nsn}|${npn:-N/A}|${nfw}|${nspd}|${nwd}|${npsid}"
        done
    } > "${dir}/nic_inventory.csv" 2>/dev/null || true

    # ─── 网络拓扑 ───
    if check_cmd lstopo; then
        run_and_log "lstopo --no-io --output-format txt" "${dir}/lstopo_network.txt"
    fi

# NOTE: mlxconfig_*_linktype.log, mlxlink_N.log, mlxlink_N_module.log,
    #       ethtool_*.log, ethtool_*_driver.log, ethtool_*_module.log are generated per device
    write_manifest "${dir}/manifest.txt" \
        "ibstat" "ibstat.log" \
        "ibstatus" "ibstatus.log" \
        "ibv_devinfo" "ibv_devinfo.log" \
        "ibdev2netdev" "ibdev2netdev.log" \
        "mlxfwmanager" "mlxfwmanager.log" \
        "mlxconfig" "mlxconfig.log" \
        "ip_addr" "ip_addr.log" \
        "ip_link" "ip_link.log" \
        "ip_route" "ip_route.log" \
        "nic_inventory" "nic_inventory.csv" \
        "lstopo_network" "lstopo_network.txt"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_network "$1"
fi
