#!/bin/bash
# shellcheck disable=SC2010  # /sys/class 内核接口名无空格且字母数字，ls|grep 过滤安全（glob 反而复杂）
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
    # v1.49.2：mstflint 失败详情（原先 `2>/dev/null` 把失败原因丢掉，真机上无法诊断——
    #   CX8/新平台实测 8 张卡全失败但只留了个计数，不知道是版本不认、权限还是设备节点问题）
    MSTFLINT_FAILED_DETAIL=""

    # ─── InfiniBand + Mellanox / NVIDIA NIC 工具（并行） ───
    local ib_jobs=()
    check_cmd ibstat       && ib_jobs+=("ibstat" "${dir}/ibstat.log")
    check_cmd ibstatus     && ib_jobs+=("ibstatus" "${dir}/ibstatus.log")
    check_cmd ibv_devinfo  && ib_jobs+=("ibv_devinfo" "${dir}/ibv_devinfo.log")
    check_cmd ibdev2netdev && ib_jobs+=("ibdev2netdev" "${dir}/ibdev2netdev.log")
    # v1.48.53：ibdev2netdev -v（verbose 含 PCI BDF）——mlx5_X ↔ 接口名 ↔ BDF 三方对齐，
    # 供物理槽位标注（mlxlink/mlxconfig 按 mlx5_X、槽位表按 BDF）与 PSID 解析交叉校验
    check_cmd ibdev2netdev && ib_jobs+=("ibdev2netdev -v" "${dir}/ibdev2netdev_v.log")

    # IB 链路性能计数器（v1.48.90）——IB 卡验收的金标准指标。
    # 为什么必需：ibstat/ibstatus 只给链路状态与速率，**看不见误码**。链路「ACTIVE 400Gb」也可能是
    #   在坏线缆上反复纠错达成的，只有 perfquery 的 SymbolError/PortRcvErrors/PortXmitDiscards/
    #   LinkDowned 才能真正反映链路质量（这些计数增长 = 线缆/光模块/交换机端口问题）。
    # -x 取扩展计数集。**perfquery 必须用 -C 指定 CA**：不带 -C 时它用 (null):0 打 UMAD 端口，
    #   必然失败（v1.51.1 实机实测：`perfquery -x` → "can't open UMAD port ((null):0)" exit=255）。
    #   逐 CA 采并只采**链路已起**的口：Base lid 为 **0 或 65535** 都表示子网管理器(SM)未分配 LID
    #   （链路未起），此时没有端口计数器可读，采了只会得到 classportinfo 超时/UMAD 打不开。
    #   （v1.51.1 实测 DGX A100：8 张 CX6 全 Down，Base lid=0 → 修好参数也读不到，
    #   属平台当前状态而非采集缺陷；注意 LID 不是只有 65535 一种"未分配"表现。）
    #   全部未起时只在日志末尾留一行注释说明，报告端据此判「未取到」而非「全部为 0」。
    check_cmd perfquery && check_cmd ibstat && ib_jobs+=("_pq_seen=0; for ca in \$(ibstat -l 2>/dev/null); do lid=\$(ibstat \$ca 2>/dev/null | grep -m1 'Base lid' | grep -oE '[0-9]+\$'); case \"\${lid:-}\" in \"\"|0|65535) continue;; esac; echo \"=== \$ca (LID \$lid) ===\"; perfquery -C \$ca -P 1 -x 2>&1; _pq_seen=1; done; [ \"\${_pq_seen:-0}\" = 0 ] && echo '# --- 无端口计数器（所有 IB 口 Base lid 为 0/65535，子网管理器未分配 → 链路未起）---'; true" "${dir}/perfquery.log")
    # v1.48.53：devlink 固件信息（内核标准接口）——取 fw.psid（PSID）；MST/mstflint 在新平台
    # （CX8/NV access）不可用时 devlink 仍可用，作为 PSID 主来源（回退链 devlink → mstflint → mlxfwmanager）
    check_cmd devlink && ib_jobs+=("devlink dev info" "${dir}/devlink_dev_info.log")
    check_cmd mlxfwmanager && ib_jobs+=("mlxfwmanager" "${dir}/mlxfwmanager.log")
    [ "${#ib_jobs[@]}" -gt 0 ] && run_and_log_parallel 8 "${ib_jobs[@]}"

    # ─── mlxconfig：独立低并发（Mellanox 工具共享 MST 设备，混在 IB 8 路里会互相抢占）───
    # v1.48.69：原实现把每设备的两次 mlxconfig 调用（全量 + grep LINK_TYPE）都塞进 ib_jobs 的 8 路并行。
    # 22.84 实测 12 设备混跑：mlx5_0 耗时 83s（正常数秒），mlx5_5/6 报
    # "-E- Error when trying to check if NV access registers are supported"（exit=3 → 误报 WARN）。
    # 改进：① 每设备只调一次工具（LINK_TYPE 由本地 grep 从全量日志提取，零额外工具调用）
    #       ② 独立 2 路并行（MST 争用大幅降低，且不再与 ibstat/devlink 抢设备）
    if check_cmd mlxconfig; then
        # v1.48.60 命令修正：子命令必须排在 -d 之后（`mlxconfig -d <dev> q`）；原 `mlxconfig query -d <dev>`
        # 实测报 "-E- Failed to identify the device" 且无有效输出；全局 `mlxconfig query`（无 -d）靠 MST
        # 枚举同样无效（8 次 identify 失败、耗时近百秒）。
        local mlx_cfg_devs
        mlx_cfg_devs=$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5)
        local mlxcfg_jobs=()
        for cfg_dev in $mlx_cfg_devs; do
            mlxcfg_jobs+=("mlxconfig -d ${cfg_dev} q" "${dir}/mlxconfig_${cfg_dev}.log")
        done
        [ "${#mlxcfg_jobs[@]}" -gt 0 ] && run_and_log_parallel 2 "${mlxcfg_jobs[@]}"
        # LINK_TYPE 提取：从刚采的全量日志本地提取（输出内容与原来的 `... q | grep` 完全一致）
        for cfg_dev in $mlx_cfg_devs; do
            grep -E 'LINK_TYPE_P[12]' "${dir}/mlxconfig_${cfg_dev}.log" 2>/dev/null \
                > "${dir}/mlxconfig_${cfg_dev}_linktype.log" || true
        done
    fi

    # ─── mlxlink：遍历所有 mlx5 设备（并行） ───
    if check_cmd mlxlink; then
        local mlx_jobs=()
        local mlx_devs
        mlx_devs=$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5)
        if [ -z "$mlx_devs" ]; then
            # 回退：动态探测设备号（B300 平台最多 12+ 个 mlx5 设备，避免硬编码漏采）
            local dev_num=0
            while [ "$dev_num" -lt 24 ]; do
                if [ -e "/sys/class/net/mlx5_${dev_num}" ] || ls /sys/class/infiniband/ 2>/dev/null | grep -q "mlx5_${dev_num}"; then
                    mlx_jobs+=("mlxlink -d mlx5_${dev_num}" "${dir}/mlxlink_${dev_num}.log")
                    [ "${NO_MODULE:-0}" -eq 0 ] && mlx_jobs+=("mlxlink -d mlx5_${dev_num} -m" "${dir}/mlxlink_${dev_num}_module.log")
                    # v1.48.58：物理计数器 + BER（Symbol/Raw Physical BER、Link Down Counter）——链路质量第一手数据，
                    # 不依赖模块读取（不用 -m），避免与 NO_MODULE 开关冲突
                    mlx_jobs+=("mlxlink -d mlx5_${dev_num} -c" "${dir}/mlxlink_${dev_num}_counters.log")
                fi
                ((dev_num++))
            done
        else
            while IFS= read -r dev; do
                mlx_jobs+=("mlxlink -d $dev" "${dir}/mlxlink_${dev}.log")
                [ "${NO_MODULE:-0}" -eq 0 ] && mlx_jobs+=("mlxlink -d $dev -m" "${dir}/mlxlink_${dev}_module.log")
                # v1.48.58：物理计数器 + BER（见上）
                mlx_jobs+=("mlxlink -d $dev -c" "${dir}/mlxlink_${dev}_counters.log")
            done < <(printf '%s\n' "$mlx_devs")
        fi
        [ "${#mlx_jobs[@]}" -gt 0 ] && run_and_log_parallel 8 "${mlx_jobs[@]}"
    fi

    # ─── 以太网口（并行） ───
    if check_cmd ethtool; then
        local eth_jobs=()
        local eth_devs
        eth_devs=$(ip -o link show | grep -v 'lo' | awk -F': ' '{print $2}' | sed 's/@.*//')
        while IFS= read -r dev; do
            [ -z "$dev" ] && continue
            # 跳过虚拟/IB 接口
            [[ "$dev" == *ib* ]] && continue
            [[ "$dev" == *bond* ]] && continue
            [[ "$dev" == *docker* ]] && continue
            [[ "$dev" == *veth* ]] && continue
            local safe_name
            safe_name=$(echo "$dev" | tr '/' '_')
            eth_jobs+=("ethtool '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}.log")
            eth_jobs+=("ethtool -i '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}_driver.log")
            # v1.48.84：Mellanox（mlx5_core）跳过 ethtool -m——光模块信息前面已由 mlxlink -m 采集；
            #   且该命令在部分固件上触发内核报错刷屏（mlx5_cmd_out_err / QUERY_MCIA_REG status 0x3 /
            #   mlx5_query_module_eeprom_by_page failed:0xffffffff），既污染 console 又污染 dmesg，
            #   而 2>/dev/null 挡不住内核 printk。非 mlx5 网卡（只有 ethtool 能读光模块）照旧保留。
            local nic_drv=""
            [ -e "/sys/class/net/$dev/device/driver" ] && nic_drv=$(basename "$(readlink -f "/sys/class/net/$dev/device/driver" 2>/dev/null)" 2>/dev/null)
            if [ "$nic_drv" != "mlx5_core" ]; then
                eth_jobs+=("ethtool -m '$dev' 2>/dev/null" "${dir}/ethtool_${safe_name}_module.log")
            fi
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
    local nic_pcie_jobs=()
    {
        # v1.48.56：同卡 PSID 共享表（BDF 去功能号 → PSID）——多口卡 MST 只注册 function 0，
        # 其余口 mstflint 取不到；同卡 PSID 本相同，可安全继承
        declare -A nic_psid_by_card
        echo "# nic inventory: dev|bdf|mac|serial|part_number|firmware|speed|width|psid|cap_speed|cap_width"
        for ndev_path in /sys/class/net/*/; do
            [ -e "$ndev_path" ] || continue   # 无匹配时 glob 原样返回，跳过
            ndev=$(basename "$ndev_path")
            [ "$ndev" = "lo" ] && continue
            # PCIe 网卡 + USB 网卡都收录：USB 网卡 BDF 是 usb 路径形式（如 2-9.4:1.0），
            # 报告端据此分类（PCIe 进主表，USB 单独标注）；虚拟网卡（无 /devices/pci 前缀）排除
            ndev_path=$(readlink -f "/sys/class/net/${ndev}/device" 2>/dev/null)
            [[ "$ndev_path" != *"/devices/pci"* ]] && continue
            local nbdf
            nbdf=$(grep "PCI_SLOT_NAME" "/sys/class/net/${ndev}/device/uevent" 2>/dev/null | cut -d'=' -f2 | sed 's/^0000://')
            [ -z "$nbdf" ] && nbdf=$(basename "$ndev_path" | sed 's/^0000://')
            # 每网卡 lspci -vv 全量（v1.41.0 全量原则，循环后统一并行落盘）
            nic_pcie_jobs+=("lspci -vv -s ${nbdf} 2>&1" "nic_${ndev}_pcie.log")
            local nmac
            nmac=$(cat "/sys/class/net/${ndev}/address" 2>/dev/null)
            # IB 长地址取后 6 字节
            if [ "${#nmac}" -gt 17 ]; then
                nmac=$(echo "$nmac" | awk -F: '{for(i=13;i<=NF;i++) printf "%s%s", $i, (i<NF?":":"")}')
            fi
            local nsn
            nsn=$(cat "/sys/class/net/${ndev}/device/serial" 2>/dev/null)
            # Mellanox sysfs serial 常为占位值（如 1951526575073，多卡相同）——识别后置空，等 mstflint 读真 SN
            if [ -n "$nsn" ] && echo "$nsn" | grep -qE "^1951526575073$|^[0]+$"; then
                nsn=""
            fi
            [ -z "$nsn" ] && nsn=$(lspci -vv -s "$nbdf" 2>/dev/null | grep --line-buffered -i "Serial Number" | head -1 | awk '{print $NF}')
            [ -z "$nsn" ] && nsn="N/A"
            local npn
            npn=$(lspci -vv -s "$nbdf" 2>/dev/null | grep --line-buffered -i "Part Number" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
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
                mstdev=$(mst status 2>/dev/null | grep --line-buffered -i "$nbdf" | awk '{print $1}' | head -1)
                [ -z "$mstdev" ] && mstdev=$(ls /dev/mst/* 2>/dev/null | grep --line-buffered -i "${nbdf//:}" | head -1)
                if [ -n "$mstdev" ]; then
                    # 声明与赋值分离：local mq_out=$(...) 会吞掉命令退出码（local 本身恒返回 0）
                    local mq_out
                    # v1.49.2：stderr 不再丢弃——失败原因记入 mstflint_failed.log 供真机诊断
                    local mq_err
                    mq_err=$(mktemp)
                    mq_out=$(mstflint -d "$mstdev" q 2>"$mq_err")
                    local mq_rc=$?
                    if [ "$mq_rc" -ne 0 ]; then
                        mstflint_failed=1
                        MSTFLINT_FAILED_COUNT=$((MSTFLINT_FAILED_COUNT + 1))
                        MSTFLINT_FAILED_DETAIL="${MSTFLINT_FAILED_DETAIL}--- BDF ${nbdf} · dev ${mstdev} · rc=${mq_rc} ---"$'\n'
                        [ -s "$mq_err" ] && MSTFLINT_FAILED_DETAIL="${MSTFLINT_FAILED_DETAIL}$(head -5 "$mq_err")"$'\n'
                        # 兜底①：mlxlink -d <ibdev> -v（部分新平台 mstflint 不认，mlxlink 能读到卡 SN）
                        #   注意 mlxlink -d 收的是 mlx5_X 设备名或 BDF，不是 /dev/mst/* 路径
                        if check_cmd mlxlink; then
                            local nibdev mv_out
                            nibdev=$(ls "/sys/class/net/${ndev}/device/infiniband/" 2>/dev/null | head -1)
                            mv_out=$(mlxlink -d "${nibdev:-$nbdf}" -v 2>/dev/null | grep --line-buffered -iE "^[[:space:]]*(Serial Number|Base MAC)" | head -2)
                            if [ -n "$mv_out" ]; then
                                MSTFLINT_FAILED_DETAIL="${MSTFLINT_FAILED_DETAIL}    mlxlink -v 兜底: ${mv_out}"$'\n'
                                local mv_sn
                                mv_sn=$(printf '%s\n' "$mv_out" | grep -i "Serial Number" | head -1 | awk -F: '{print $NF}' | tr -d ' \t')
                                [ -n "$mv_sn" ] && [ "$mv_sn" != "N/A" ] && nsn="$mv_sn"
                            fi
                        fi
                        echo -e "${YELLOW}[WARN] mstflint 查询失败: $nbdf (rc=$mq_rc)${NC}" >&2
                    else
                        local mq_sn
                        mq_sn=$(echo "$mq_out" | grep --line-buffered -iE "^Serial Number|^Board Serial" | head -1 | awk '{print $NF}')
                        [ -n "$mq_sn" ] && nsn="$mq_sn"
                        local mq_psid
                        mq_psid=$(echo "$mq_out" | grep "PSID" | awk '{print $NF}')
                        [ -n "$mq_psid" ] && npsid="$mq_psid"
                    fi
                    rm -f "$mq_err"
                else
                    # MST 仍不可用（非 root 或 mst start 失败）→ 记录提示供报告标注
                    MST_NOT_STARTED=1
                    mstflint_failed=1
                fi
                # mstflint 读不到真 SN 时保持 sysfs/lspci 值（可能为 GUID 兜底），不覆盖
            fi
            # PSID 回退：mstflint q 无 PSID 时，从 mlxfwmanager.log 按 BDF 匹配（如 Inventec 平台）
            if [ "$npsid" = "N/A" ] && [ -f "${dir}/mlxfwmanager.log" ]; then
                local fw_psid
                fw_psid=$(awk -v bdf="$nbdf" '
                    /PCI Device Name:/ { dev=$NF; sub(/^0000:/, "", dev) }
                    dev==bdf && /PSID:/ { sub(/.*PSID:[[:space:]]*/, ""); print; exit }
                ' "${dir}/mlxfwmanager.log" 2>/dev/null)
                # 新版 mlxfwmanager 无 PSID 字段但有 Part Number（精确型号，如 MCX75310AAS-NEA）
                if [ -z "$fw_psid" ]; then
                    fw_psid=$(awk -v bdf="$nbdf" '
                        /PCI Device Name:/ { dev=$NF; sub(/^0000:/, "", dev) }
                        dev==bdf && /Part Number:/ { sub(/.*Part Number:[[:space:]]*/, ""); print; exit }
                    ' "${dir}/mlxfwmanager.log" 2>/dev/null)
                    # v1.48.56：Part Number 为占位符（"--"/"-"）时不采用——原逻辑只判非空，
                    # 会把空值变成 "PN:--" 污染 PSID 列（实测 B300 样本出现）
                    case "$fw_psid" in
                        ""|"--"|"-"|"N/A") fw_psid="" ;;
                        *) fw_psid="PN:${fw_psid}" ;;
                    esac
                fi
                case "$fw_psid" in
                    ""|"--"|"-"|"N/A") ;;
                    *) npsid="$fw_psid" ;;
                esac
            fi
            local nfw="N/A" _ndrv=""
            if check_cmd ethtool; then
                # v1.48.88：一次 ethtool -i 同时取固件串与驱动名
                local _ei
                _ei=$(ethtool -i "$ndev" 2>/dev/null)
                # 固件是多段字符串（如 "9.00 0x8000d9a8 1.3256.0" / "0x00012b2c, 1.3429.0"），
                # 取冒号后全部（awk 只取第一段会丢 NVM 版本且带逗号）
                nfw=$(printf '%s' "$_ei" | grep "firmware-version" | cut -d: -f2- | xargs)
                _ndrv=$(printf '%s' "$_ei" | awk -F': ' '/^driver:/{print $2; exit}')
            fi
            # v1.48.56：ethtool PSID（权威来源）——Mellanox ethtool -i 的 firmware-version 形如
            # "40.46.5500 (NVD0000000072)"，括号内即 PSID。零额外命令（nfw 已取）、每卡每口都有，
            # 且由内核按 netdev 提供——不像 mstflint 经 MST 设备（实测多口卡/新平台下残缺，
            # 甚至 MST 设备↔BDF 误配读到他卡 PSID：CX7 卡读出 CX8 的 NVD0000000072）
            # v1.48.88：判据由「接口名 ib*/mlx*/ConnectX*」改为「驱动名 mlx5_core/mlx4_core」——
            #   以太模式（ens*）的 Mellanox 口名字里没有 ib/mlx 字样，旧条件把它们整批漏掉，
            #   只能靠后续 mstflint 兜（兜到就有、兜不到就 N/A，同型号两张卡结果还不一致：
            #   实测 MCX755106AS-HEAT 的 ens3f0np0 明明 ethtool -i 带 (MT_0000000834) 却写成 N/A，
            #   而 ens10f0np0 是绕 mstflint 兜到的 MT_0000000884）。驱动名与协议模式无关，更可靠。
            local _eth_psid=""
            case "$_ndrv" in
                mlx5_core|mlx4_core)
                    case "$nfw" in
                        *"("*")"*)
                            _eth_psid=$(printf '%s' "$nfw" | sed -n 's/.*(\([^)]*\)).*/\1/p')
                            case "$_eth_psid" in ""|"--"|"-"|"N/A") _eth_psid="" ;; esac ;;
                    esac ;;
            esac
            [ -n "$_eth_psid" ] && npsid="$_eth_psid"
            # v1.48.56：同卡共享——同卡（同 BDF 去功能号）任一口已有 PSID 时继承（多口卡补齐）
            _card_key="${nbdf%%.*}"
            if [ -n "${nic_psid_by_card[$_card_key]:-}" ] && { [ "$npsid" = "N/A" ] || [ -z "$npsid" ]; }; then
                npsid="${nic_psid_by_card[$_card_key]}"
            fi
            if [ -n "$npsid" ] && [ "$npsid" != "N/A" ] && [ "$npsid" != "PN:"* ]; then
                nic_psid_by_card[$_card_key]="$npsid"
            fi
            local nspd="N/A" nwd="N/A" ncap_spd="N/A" ncap_wd="N/A"
            if check_cmd lspci; then
                local lnksta
                lnksta=$(lspci -vv -s "$nbdf" 2>/dev/null | grep "LnkSta:" | head -1)
                nspd=$(echo "$lnksta" | grep -oE "[0-9]+GT/s" | head -1)
                nwd=$(echo "$lnksta" | grep -oE "x[0-9]+" | head -1)
                # LnkCap（能力上限）— 标注检测值 vs 规格，客户可见当前协商与卡能力差异
                local lnkcap
                lnkcap=$(lspci -vv -s "$nbdf" 2>/dev/null | grep "LnkCap:" | head -1)
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

    # ─── 每网卡 lspci -vv 全量落盘（v1.41.0 全量原则：nic_inventory.csv 只含提取字段，
    #      网卡 PCIe 链路/能力全量日志模块自包含，不依赖 06_pcie）───
    if [ "${#nic_pcie_jobs[@]}" -gt 0 ]; then
        run_and_log_parallel 8 "${nic_pcie_jobs[@]}"
    fi

# NOTE: mlxconfig_N.log, mlxconfig_*_linktype.log, mlxlink_N.log, mlxlink_N_module.log, mlxlink_N_counters.log,
    #       ethtool_*.log, ethtool_*_driver.log, ethtool_*_module.log, nic_*_pcie.log
    #       are generated per device
    write_manifest "${dir}/manifest.txt" \
        "ibstat" "ibstat.log" \
        "ibstatus" "ibstatus.log" \
        "ibv_devinfo" "ibv_devinfo.log" \
        "ibdev2netdev" "ibdev2netdev.log" \
        "ibdev2netdev_v" "ibdev2netdev_v.log" \
        "perfquery" "perfquery.log" \
        "devlink_dev_info" "devlink_dev_info.log" \
        "mlxfwmanager" "mlxfwmanager.log" \
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
        {
            echo "⚠️ $MSTFLINT_FAILED_COUNT 张 Mellanox 卡的 mstflint 查询失败（SN/PSID 可能不准确），请检查日志"
            echo ""
            echo "失败详情（v1.49.2 起记录 stderr 与兜底尝试）："
            printf '%s' "${MSTFLINT_FAILED_DETAIL:-（无详情）}"
        } > "${dir}/mstflint_failed.log"
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
