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
    # MST 自动启动配置（默认 1=自动 start；验收/交付场景 root 跑，mst start 读真 SN）
    MST_AUTO_START=${MST_AUTO_START:-1}
    # MST 不可用标记（自动 start 失败/被禁用时置 1，报告标注 GUID 兜底）
    MST_NOT_STARTED=0
    # mstflint 查询失败计数（多 Mellanox 卡时可能有部分失败）
    MSTFLINT_FAILED_COUNT=0

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
            done < <(printf '%s\n' "$mlx_devs")
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
        done < <(printf '%s\n' "$eth_devs")
        [ "${#eth_jobs[@]}" -gt 0 ] && run_and_log_parallel 8 "${eth_jobs[@]}"
    fi

    # ─── IP / MAC 地址（并行） ───
    run_and_log_parallel 3 \
        "ip addr" "${dir}/ip_addr.log" \
        "ip link show" "${dir}/ip_link.log" \
        "ip route show" "${dir}/ip_route.log"
    local ip_ret=$?
    [ "$ip_ret" -ne 0 ] && echo -e "${YELLOW}[WARN] 网络 IP/MAC 采集部分失败${NC}" >&2 

    # ─── 网卡一览清单（dev|bdf|mac|sn|pn|fw|speed|width|psid|cap_speed|cap_width）───
    {
        echo "# nic inventory: dev|bdf|mac|serial|part_number|firmware|speed|width|psid|cap_speed|cap_width"
        for ndev in $(ls /sys/class/net/ 2>/dev/null); do
            [ "$ndev" = "lo" ] && continue
            # PCIe 网卡 + USB 网卡都收录：USB 网卡 BDF 是 usb 路径形式（如 2-9.4:1.0），
            # 报告端据此分类（PCIe 进主表，USB 单独标注）；虚拟网卡（无 /devices/pci 前缀）排除
            local ndev_path=$(readlink -f "/sys/class/net/${ndev}/device" 2>/dev/null)
            [[ "$ndev_path" != *"/devices/pci"* ]] && continue
            local nbdf=$(grep "PCI_SLOT_NAME" "/sys/class/net/${ndev}/device/uevent" 2>/dev/null | cut -d'=' -f2 | sed 's/^0000://')
            [ -z "$nbdf" ] && nbdf=$(basename "$ndev_path" | sed 's/^0000://')
            local nmac=$(cat "/sys/class/net/${ndev}/address" 2>/dev/null)
            # IB 长地址取后 6 字节
            if [ "${#nmac}" -gt 17 ]; then
                nmac=$(echo "$nmac" | awk -F: '{for(i=13;i<=NF;i++) printf "%s%s", $i, (i<NF?":":"")}')
            fi
            local nsn=$(cat "/sys/class/net/${ndev}/device/serial" 2>/dev/null)
            # Mellanox sysfs serial 常为占位值（如 1951526575073，多卡相同）——识别后置空，等 mstflint 读真 SN
            if [ -n "$nsn" ] && echo "$nsn" | grep -qE "^1951526575073$|^[0]+$"; then
                nsn=""
            fi
            [ -z "$nsn" ] && nsn=$(lspci -vv -s "$nbdf" 2>/dev/null | grep -i "Serial Number" | head -1 | awk '{print $NF}')
            [ -z "$nsn" ] && nsn="N/A"
            local npn=$(lspci -vv -s "$nbdf" 2>/dev/null | grep -i "Part Number" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
            [ -z "$npn" ] && npn=$(lspci -s "$nbdf" 2>/dev/null | cut -d' ' -f4-)
            # Mellanox 卡：sysfs serial 常为占位值（多卡相同），用 mstflint q 读 VPD 真 SN + PSID
            local mstdev=""
            local nis_mlx=0
            [[ "$npn" == *"Mellanox"* || "$npn" == *"ConnectX"* || "$npn" == *"MLX"* ]] && nis_mlx=1
            local npsid="N/A"
            local mstflint_failed=0
            if [ "$nis_mlx" -eq 1 ] && check_cmd mstflint; then
                # MST 未启动且配置允许 → 自动 mst start（root 下直接执行；非 root 会失败但无害）
                if [ "${MST_AUTO_START:-1}" -eq 1 ] && ! ls /dev/mst/* >/dev/null 2>&1 && check_cmd mst; then
                    mst start >/dev/null 2>&1 || true
                    sleep 1
                fi
                mstdev=$(mst status 2>/dev/null | grep -i "$nbdf" | awk '{print $1}' | head -1)
                [ -z "$mstdev" ] && mstdev=$(ls /dev/mst/* 2>/dev/null | grep -i "${nbdf//:}" | head -1)
                if [ -n "$mstdev" ]; then
                    # 声明与赋值分离：local mq_out=$(...) 会吞掉命令退出码（local 本身恒返回 0）
                    local mq_out
                    mq_out=$(mstflint -d "$mstdev" q 2>/dev/null)
                    if [ $? -ne 0 ]; then
                        mstflint_failed=1
                        MSTFLINT_FAILED_COUNT=$((MSTFLINT_FAILED_COUNT + 1))
                        echo -e "${YELLOW}[WARN] mstflint 查询失败: $nbdf${NC}" >&2
                    else
                        local mq_sn=$(echo "$mq_out" | grep -iE "^Serial Number|^Board Serial" | head -1 | awk '{print $NF}')
                        [ -n "$mq_sn" ] && nsn="$mq_sn"
                        local mq_psid=$(echo "$mq_out" | grep "PSID" | awk '{print $NF}')
                        [ -n "$mq_psid" ] && npsid="$mq_psid"
                    fi
                else
                    # MST 仍不可用（非 root 或 mst start 失败）→ 记录提示供报告标注
                    MST_NOT_STARTED=1
                    mstflint_failed=1
                fi
                # mstflint 读不到真 SN 时保持 sysfs/lspci 值（可能为 GUID 兜底），不覆盖
            fi
            # PSID 回退：mstflint q 无 PSID 时，从 mlxfwmanager.log 按 BDF 匹配（如 Inventec 平台）
            if [ "$npsid" = "N/A" ] && [ -f "${dir}/mlxfwmanager.log" ]; then
                local fw_psid=$(awk -v bdf="$nbdf" '
                    /PCI Device Name:/ { dev=$NF; sub(/^0000:/, "", dev) }
                    dev==bdf && /PSID:/ { sub(/.*PSID:[[:space:]]*/, ""); print; exit }
                ' "${dir}/mlxfwmanager.log" 2>/dev/null)
                # 新版 mlxfwmanager 无 PSID 字段但有 Part Number（精确型号，如 MCX75310AAS-NEA）
                if [ -z "$fw_psid" ]; then
                    fw_psid=$(awk -v bdf="$nbdf" '
                        /PCI Device Name:/ { dev=$NF; sub(/^0000:/, "", dev) }
                        dev==bdf && /Part Number:/ { sub(/.*Part Number:[[:space:]]*/, ""); print; exit }
                    ' "${dir}/mlxfwmanager.log" 2>/dev/null)
                    [ -n "$fw_psid" ] && fw_psid="PN:${fw_psid}"
                fi
                [ -n "$fw_psid" ] && npsid="$fw_psid"
            fi
            local nfw="N/A"
            if check_cmd ethtool; then
                # 固件是多段字符串（如 "9.00 0x8000d9a8 1.3256.0" / "0x00012b2c, 1.3429.0"），
                # 取冒号后全部（awk 只取第一段会丢 NVM 版本且带逗号）
                nfw=$(ethtool -i "$ndev" 2>/dev/null | grep "firmware-version" | cut -d: -f2- | xargs)
            fi
            local nspd="N/A" nwd="N/A" ncap_spd="N/A" ncap_wd="N/A"
            if check_cmd lspci; then
                local lnksta=$(lspci -vv -s "$nbdf" 2>/dev/null | grep "LnkSta:" | head -1)
                nspd=$(echo "$lnksta" | grep -oE "[0-9]+GT/s" | head -1)
                nwd=$(echo "$lnksta" | grep -oE "x[0-9]+" | head -1)
                # LnkCap（能力上限）— 标注检测值 vs 规格，客户可见当前协商与卡能力差异
                local lnkcap=$(lspci -vv -s "$nbdf" 2>/dev/null | grep "LnkCap:" | head -1)
                ncap_spd=$(echo "$lnkcap" | grep -oE "[0-9]+GT/s" | head -1)
                ncap_wd=$(echo "$lnkcap" | grep -oE "x[0-9]+" | head -1)
            fi
            [ -z "$nspd" ] && nspd="N/A"; [ -z "$nwd" ] && nwd="N/A"
            [ -z "$ncap_spd" ] && ncap_spd="N/A"; [ -z "$ncap_wd" ] && ncap_wd="N/A"
            [ -z "$nfw" ] && nfw="N/A"
            echo "${ndev}|${nbdf}|${nmac:-N/A}|${nsn}|${npn:-N/A}|${nfw}|${nspd}|${nwd}|${npsid}|${ncap_spd}|${ncap_wd}"
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

    # MST 未启动提示（MST_AUTO_START=1 时已自动 mst start 读真 SN；此提示仅在其被禁用/失败时出现，SN 为 GUID 兜底）
    if [ "$MST_NOT_STARTED" -eq 1 ]; then
        echo "⚠️ MST 服务未启动（sudo mst start 可启用）：Mellanox 卡 SN/PSID 未读到，报告以 GUID 兜底" > "${dir}/mst_notice.log"
        write_manifest --append "${dir}/manifest.txt" "mst_notice" "mst_notice.log"
    fi
    # mstflint 部分失败提示
    if [ "$MSTFLINT_FAILED_COUNT" -gt 0 ]; then
        echo "⚠️ $MSTFLINT_FAILED_COUNT 张 Mellanox 卡的 mstflint 查询失败（SN/PSID 可能不准确），请检查日志" > "${dir}/mstflint_failed.log"
        write_manifest --append "${dir}/manifest.txt" "mstflint_failed" "mstflint_failed.log"
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
