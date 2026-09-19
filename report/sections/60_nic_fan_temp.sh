#!/bin/bash
# =============================================================================
# HwScope - 变量解析：网卡明细(mt_model/GPU直连/PSID) + 风扇 + 温度
# report/sections/60_nic_fan_temp.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# 网卡明细（nic_inventory.csv: dev|bdf|mac|sn|pn|fw|speed|width|psid）
# IB 控制器型号识别：ibstat CA type + ibdev2netdev 映射（mlx5_N ↔ ibp*），附加到 PN 列
# v1.45.15：同循环收集 CA State（端口 Link 状态——完整明细补"Link 状态"列）
declare -A CA_MODEL NETDEV_CA CA_STATE NETDEV_STATE
NIC_MLX=0
GPU_TOPO_AVAIL=0
if [ -f "${ibstat}" ]; then
    cur_ca=""
    while IFS= read -r il; do
        case "$il" in
            *"CA '"*) cur_ca=$(echo "$il" | sed "s/.*'\(.*\)'.*/\1/") ;;
            *"CA type:"*) [ -n "$cur_ca" ] && CA_MODEL[$cur_ca]=$(echo "$il" | awk '{print $NF}') ;;
            *"State:"*)
                # v1.45.17：多口 CA 聚合——ibstat 按口输出 State（CA 级无 State），双口卡两端口状态
                # 可能不同；原实现后者覆盖前者。集合式聚合（逗号分隔去重），显示如 "Up" 或 "Up,Down"
                [ -n "$cur_ca" ] || continue
                _st=$(echo "$il" | awk '{print $NF}')
                _prev="${CA_STATE[$cur_ca]:-}"
                case ",${_prev}," in
                    *",${_st},"*) : ;;                              # 已含该状态
                    ",,") CA_STATE[$cur_ca]="$_st" ;;
                    *)  CA_STATE[$cur_ca]="${_prev},${_st}" ;;
                esac ;;
        esac
    done < <(grep -v "^#" "${ibstat}")
fi
if [ -f "${ibdev2netdev}" ]; then
    while IFS= read -r nl; do
        ca=$(echo "$nl" | awk '{print $1}'); dev=$(echo "$nl" | awk '{print $5}')
        [ -n "$ca" ] && [ -n "$dev" ] && NETDEV_CA[$dev]=$ca
    done < <(grep -v "^#" "${ibdev2netdev}")
fi
mt_model() {
    case "$1" in
        MT4131) echo "ConnectX-8" ;;
        # MT4129=ConnectX-7 (MCX75xxx, NDR 400G)；MT2910/MT4125 同代不同封装
        MT4129|MT2910|MT4125) echo "ConnectX-7" ;;
        # v1.48.85：BlueField DPU（MT43244 = lspci 型号名；MT41692 = ibstat CA type 的 SoC 编号）
        MT43244|MT41692) echo "BlueField-3" ;;
        MT4124) echo "ConnectX-6 Lx" ;;
        MT4123) echo "ConnectX-6 Dx" ;;
        MT4121|MT4122) echo "ConnectX-6" ;;
        MT2892|MT2893) echo "ConnectX-5" ;;
        MT2884|MT2883) echo "ConnectX-4" ;;
        *) echo "Mellanox" ;;
    esac
}
NIC_DETAILS=""
USB_NICS=""
# GPU 直连标注：解析 topo 矩阵（gpu_topo_nic.log 优先；旧版 -n 语法错误时回退 gpu_topo.log，
# v1.26.27+ 的 topo -m 已自带 NIC 列）
# PIX = 同一 PCIe switch（GPU 直连），NODE = 同 NUMA，SYS = 跨节点
# NIC0..NICn 按 BDF 升序对应 nic_inventory 中的 PCIe 网卡
declare -A GPU_DIRECT_NIC
GPU_TOPO_FILE=""
for _tf in "${GPU_DIR}/gpu_topo_nic.log" "${GPU_DIR}/gpu_topo.log"; do
    [ -f "$_tf" ] || continue
    # 内容有效性：含 NIC 列且无 "-n" 语法报错
    if grep -v "^#" "$_tf" 2>/dev/null | grep -qE "NIC[0-9]+" && ! grep -q "Option \"-n\"" "$_tf" 2>/dev/null; then
        GPU_TOPO_FILE="$_tf"
        break
    fi
done
if [ -n "$GPU_TOPO_FILE" ]; then
    _nic_cols=()
    _nic_idx=()
    _hdr=$(grep -v "^#" "$GPU_TOPO_FILE" | grep -E "NIC[0-9]" | head -1)
    # 同时记录列名与列号（动态计算，兼容 4/8 GPU 等不同卡数导致的列偏移）
    if [ -n "$_hdr" ]; then
        # tab 偏移修正：表头以 tab/空格开头时 $1 为空，列号比数据行小 1（数据行 $1=GPU0 占位）
        # 判定：表头首字符为空白（\t 或空格）→ 所有列号 +1
        _tabfix=0
        case "$_hdr" in
            [[:space:]]*) _tabfix=1 ;;
        esac
        while IFS= read -r _pair; do
            _nic_cols+=("${_pair%%:*}")
            _nic_idx+=("$(( ${_pair##*:} + _tabfix ))")
        done < <(echo "$_hdr" | awk '{for(i=1;i<=NF;i++) if($i~/^NIC[0-9]+$/) printf "%s:%d\n", $i, i}')
    fi
    if [ "${#_nic_cols[@]}" -gt 0 ]; then
        # 每列 NIC：统计 GPU 行中 PIX/PXB 出现情况（任一 GPU 近距即标记）
        # v1.48.86：判据由 PIX 放宽到 PIX|PXB。NVIDIA 拓扑距离分级里，PIX（同一 PCIe switch）
        #   与 PXB（跨多个 switch 但同处一个 PCIe 域、不经 CPU）**都属"本地"连接**，
        #   是 GPUDirect RDMA 的可用形态；PHB/NODE/SYS 才经 CPU。仅认 PIX 会漏判老 HGX 平台：
        #   实测 A100 HGX（A100-sample-a）4 口 CX-6 计算网卡全为 PXB（经 PLX switch 上连），
        #   无一条 PIX → 整列被隐藏、计算网卡行消失。
        declare -A _nic_pix
        while IFS= read -r _row; do
            [ -z "$_row" ] && continue
            echo "$_row" | grep -qE "^GPU[0-9]+" || continue
            _idx=0
            for _col in "${_nic_cols[@]}"; do
                _val=$(echo "$_row" | awk -v c="${_nic_idx[$_idx]}" '{print $c}')
                case "$_val" in PIX|PXB) _nic_pix[$_col]=1 ;; esac
                _idx=$((_idx+1))
            done
        done < <(grep -v "^#" "$GPU_TOPO_FILE")
        # ─── v1.48.85：优先用 topo 自带的 "NIC<n>: mlx5_<m>" 权威映射 ───
        # 原实现假设「topo NIC 列序 = 网卡 BDF 升序」（见下方降级分支），但 topo 只列出
        # 具备 RDMA 能力的口（实测 18 列 vs 网卡 26 口），列数与口数不等时按序硬对**必然错位**
        # ——表现为管理口（X710/10GBASE-T）被误标 GPU直连、而部分 MCX 反而漏标。
        # topo 文件自带对照表（"NIC0: mlx5_0" …），据此把 NIC<n> 换成 mlx5 设备名，
        # 再用 ibdev2netdev 建立的 NETDEV_CA 反查得到 netdev，映射唯一且不依赖排序假设。
        declare -A _ca2dev
        for _dv in "${!NETDEV_CA[@]}"; do
            [ -n "${NETDEV_CA[$_dv]:-}" ] && _ca2dev["${NETDEV_CA[$_dv]}"]="$_dv"
        done
        _mapped=0
        while IFS= read -r _line; do
            _n=$(printf '%s' "$_line" | sed -n 's/^\(NIC[0-9]\+\):.*/\1/p')
            _m=$(printf '%s' "$_line" | sed -n 's/^NIC[0-9]\+: *\([A-Za-z0-9_.-]\+\).*/\1/p')
            if [ -z "$_n" ] || [ -z "$_m" ]; then continue; fi
            if [ "${_nic_pix[$_n]:-0}" -ne 1 ]; then continue; fi
            _nd="${_ca2dev[$_m]:-}"
            if [ -n "$_nd" ]; then
                GPU_DIRECT_NIC["$_nd"]="1"
                _mapped=$((_mapped+1))
            fi
        done < <(grep -oE "^ *NIC[0-9]+: *[A-Za-z0-9_.-]+" "$GPU_TOPO_FILE" 2>/dev/null | sed 's/^ *//')
        # 降级：topo 无对照表（老版本）时，退回「topo NIC 列按 BDF 升序」旧逻辑
        if [ "$_mapped" -eq 0 ]; then
            _pci_nics=()
            while IFS='|' read -r _d _bdf _rest; do
                [ -z "$_d" ] || [ "$_d" = "#" ] && continue
                echo "$_bdf" | grep -qE "^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$" && _pci_nics+=("$_d|$_bdf")
            done < <(grep -v "^#" "${nic_inventory}" 2>/dev/null)
            # 按 BDF 排序（老版 topo 的 NIC 列序 = BDF 升序）
            _pci_nics=($(printf '%s\n' "${_pci_nics[@]}" | sort -t'|' -k2))
            _nn=0
            for _col in "${_nic_cols[@]}"; do
                _entry="${_pci_nics[$_nn]:-}"
                [ -n "$_entry" ] && [ "${_nic_pix[$_col]:-0}" -eq 1 ] && GPU_DIRECT_NIC[${_entry%%|*}]="1"
                _nn=$((_nn+1))
            done
        fi
    fi
fi
if [ -f "${nic_inventory}" ]; then
    # ─── v1.48.53：物理槽位映射（dmidecode Type 9 槽位表 + PCIe 上游桥链上溯）───
    # 数据链：网卡 BDF → 沿 pcie_full 桥链（primary/secondary）逐级上溯 → 命中槽位 Bus Address → 槽位名
    # （B300 HGX 的 IB 卡多挂在 SXM*_GPU* 槽位下 = GPU 直连域的物理含义；标准卡命中 SLOTn/LAN 等）
    declare -A SLOT_BY_BUS PCIE_UPSTREAM
    NIC_SLOT_AVAIL=0
    _slots_file="${MB_DIR:-${OUT}/motherboard}/dmidecode_slot.log"
    if [ ! -f "$_slots_file" ]; then
        load_manifest "${MB_DIR:-${OUT}/motherboard}" dmidecode_slot "dmidecode_slot.log" 2>/dev/null
        _slots_file="${dmidecode_slot:-$_slots_file}"
    fi
    if [ -f "$_slots_file" ]; then
        # v1.49.6：多个槽位可能共享同一 Bus Address（实测 DGX A100：NIC3 与 U.2_NVMe2 同为 bus 51、
        #   NIC7 与 U.2_NVMe6 同为 bus bf、U.2_NVMe0/3/4/7 四个全是 ff:00.0、M.2_0/1 与 OCulink 都是 20）。
        #   原实现 `SLOT_BY_BUS[$bus]=$name` 是一对多压成一对一、**后写覆盖先写**，导致网卡的「物理位置」
        #   被显示成硬盘槽名（实测该机 ibp84s0 → U.2_NVMe2）。改为按优先级取优：
        #   真扩展槽（PCI Express 且名字不像存储）= 3 > 中立（Proprietary 等）= 2 > 存储槽 = 1。
        #   判据用 SMBIOS 客观的 Type 字段 + Designation 名，不靠单一名猜测。
        declare -A _slot_pri
        while IFS='|' read -r _sd _st _sa; do
            [ -z "$_sd" ] && continue
            _sbus=$(printf '%s' "$_sa" | sed 's/^[0-9a-fA-F]*://; s/:.*//')
            [ -z "$_sbus" ] && continue
            _pri=3
            # ① Type 明确是存储槽类型
            case "$_st" in
                *SFF-8639*|*M.2*|*SATA*|*SAS*) _pri=1 ;;
            esac
            # ② Designation 名字像存储槽（覆盖 OCulink 这种 Type 写作 "x8 PCI Express x8" 的）
            case "$_sd" in
                *U.2*|*NVMe*|*M.2*|*OCulink*) _pri=1 ;;
            esac
            # ③ 既非 PCI Express 也非存储 → 中立（不给满优先级）
            case "$_st" in
                *"PCI Express"*) : ;;
                *) [ "$_pri" -eq 3 ] && _pri=2 ;;
            esac
            if [ "${_slot_pri[$_sbus]:-0}" -le "$_pri" ]; then
                SLOT_BY_BUS[$_sbus]="$_sd"
                _slot_pri[$_sbus]=$_pri
            fi
        done < <(awk '
            /^System Slot Information/ {d=""; t=""; inslot=1; next}
            inslot && /Designation:/ {sub(/.*: /,""); d=$0}
            inslot && /^[ \t]*Type:/ {sub(/.*: /,""); t=$0}
            inslot && /Bus Address:/ {sub(/.*: /,""); printf "%s|%s|%s\n", d, t, $0; inslot=0}
        ' "$_slots_file" 2>/dev/null)
        [ "${#SLOT_BY_BUS[@]}" -gt 0 ] && NIC_SLOT_AVAIL=1
    fi
    if [ "$NIC_SLOT_AVAIL" -eq 1 ] && [ -f "${pcie_full:-}" ]; then
        while IFS='|' read -r _s _p; do
            [ -n "$_s" ] && PCIE_UPSTREAM[$_s]="$_p"
        done < <(awk '
            /^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]\.[0-9a-fA-F] / {next}
            /Bus: primary=/ {
                match($0, /primary=[0-9a-fA-F]+/); p=substr($0, RSTART+8, RLENGTH-8)
                match($0, /secondary=[0-9a-fA-F]+/); s=substr($0, RSTART+10, RLENGTH-10)
                if (s != "" && p != "") printf "%s|%s\n", s, p
            }
        ' "${pcie_full}" 2>/dev/null | sort -u)
    fi
    # BDF → 槽位名（逐级上溯，最多 8 级防环）
    nic_slot_name() {
        local _bdf="$1" _bus _depth=0
        _bus=$(printf '%s' "$_bdf" | sed 's/:.*//')
        while [ -n "$_bus" ] && [ "$_depth" -lt 8 ]; do
            if [ -n "${SLOT_BY_BUS[$_bus]:-}" ]; then
                printf '%s' "${SLOT_BY_BUS[$_bus]}"
                return
            fi
            _bus="${PCIE_UPSTREAM[$_bus]:-}"
            _depth=$((_depth + 1))
        done
    }
    # 物理口聚合（v1.44.0）：同卡多口共享总线号（11:00.0/11:00.1 = 同一物理卡两个功能），
    # 按 BDF 前缀（去功能号）统计每卡接口数——比 SN 聚合可靠（非 Mellanox 卡 SN 不保证同卡唯一）
    declare -A NIC_PORT_TOTAL
    while IFS='|' read -r _d _b _rest; do
        [ -z "$_d" ] || [ "$_d" = "N/A" ] || [ "$_d" = "#" ] && continue
        echo "$_b" | grep -qE "^[0-9a-fA-F]{2,4}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$" || continue
        _bd="${_b%%.*}"
        NIC_PORT_TOTAL[$_bd]=$(( ${NIC_PORT_TOTAL[$_bd]:-0} + 1 ))
    done < <(grep -v "^#" "${nic_inventory}" 2>/dev/null)
    declare -A NIC_PORT_IDX
    GPU_DIRECT_COUNT=0
# ─── v1.49.4：BMC FRU 网卡 SN 兜底 ───
# BMC 的 FRU 表按槽位登记板卡（PCIE_NIC0/NIC1...），提供 Board/Product Serial——这是**带外**读取，
#  不依赖 OS 驱动或 MST，是 CX8（sysfs 给占位值 + mstflint 不认）这类平台的最后一路 SN 来源。
# 保守规则：仅当某 PN 在 FRU 中**恰好 1 条**时才采用（多条无法确定对应哪张卡，宁可留白不配错）。
declare -A FRU_NIC_SN_BY_PN
declare -A FRU_NIC_PN_CNT
load_manifest "${BMC_DIR}" ipmi_fru_all "ipmi_fru_all.log"
if [ -f "${ipmi_fru_all}" ]; then
    while IFS="|" read -r _fpn _fsn; do
        [ -z "$_fpn" ] || [ -z "$_fsn" ] && continue
        FRU_NIC_PN_CNT["$_fpn"]=$(( ${FRU_NIC_PN_CNT["$_fpn"]:-0} + 1 ))
        FRU_NIC_SN_BY_PN["$_fpn"]="$_fsn"
    done < <(grep -v "^#" "${ipmi_fru_all}" 2>/dev/null | awk '
        /^FRU Device Description/ {
            if (nic == 1 && pn != "" && sn != "") print pn "|" sn
            nic = (index($0, "NIC") > 0) ? 1 : 0
            pn = ""; sn = ""
            next
        }
        nic != 1 { next }
        /Part Number/ { if (pn == "") { split($0, a, /:[ \t]*/); pn = a[2]; gsub(/[ \t]+$/, "", pn) } }
        /Serial/      { if (sn == "") { split($0, a, /:[ \t]*/); sn = a[2]; gsub(/[ \t]+$/, "", sn) } }
        END { if (nic == 1 && pn != "" && sn != "") print pn "|" sn }
    ')
fi

    while IFS='|' read -r nnic nnbdf nmac nsn npn nfw nspd nwd npsid ncapspd ncapwd; do
        [ -z "$nnic" ] || [ "$nnic" = "N/A" ] && continue
        [ "$nnic" = "#" ] && continue
        # 分类：非 PCIe BDF（如 USB 路径 2-9.4:1.0）→ USB 网卡，单独列表显示（不混入 PCIe 主表）
        nusb=0
        if [ -n "$nnbdf" ] && ! echo "$nnbdf" | grep -qE "^[0-9a-fA-F]{2,4}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$"; then
            nusb=1
            USB_NICS="${USB_NICS}${nnic}|${nmac}|${npn}|${nfw}"$'\n'
            continue
        fi
        # v1.48.53：devlink 回查（内核标准接口——MST/mstflint 在新平台不可用时仍可取 PSID；
        # devlink dev info 输出 pci/0000:XX:YY.Z 段内 versions.fixed.fw.psid）
        if [ "$npsid" = "N/A" ] && [ -f "${devlink_dev_info:-}" ]; then
            dvl_psid=$(awk -v bdf="${nnbdf%% (USB)*}" '
                /^pci\/0000:/ { dev=$0; sub(/^pci\/0000:/, "", dev); sub(/:$/, "", dev) }
                dev==bdf && /fw\.psid:/ { sub(/.*fw\.psid:[[:space:]]*/, ""); print; exit }
            ' "${devlink_dev_info}" 2>/dev/null)
            [ -n "$dvl_psid" ] && npsid="$dvl_psid"
        fi
        # ─── v1.48.88：PSID 权威来源 = ethtool -i 固件串括号值，**有值就覆盖**（不只是 N/A 时兜底） ───
        #   内核按 netdev 提供、每卡每口都有，且与端口跑 IB 还是 ETH 无关，不会错配。
        #   为什么要覆盖而非兜底：实测 mlxfwmanager 查询失败时（"-E- Failed to query 0000:b6:00.0
        #   device, error : FwInit has failed!"）会把**他卡的 PSID** 配过来——b6:00.0（ens10f0np0，
        #   MCX755106AS，真值 MT_0000000834）被写成 MT_0000000884，而后者实际属于 ens1f0np0（BlueField-3）。
        #   这正是 AGENTS 记过的「MST 设备↔BDF 误配读到他卡 PSID」。
        #   另：旧采集数据的 nic_inventory 里以太模式（ens*）的 Mellanox 口 PSID 恒为 N/A
        #   （旧判据用接口名 ib*/mlx*，把 ens* 漏了），也借此一并修正。
        if [ -f "${NET_DIR}/ethtool_${nnic}_driver.log" ]; then
            _ei_log="${NET_DIR}/ethtool_${nnic}_driver.log"
            _ei_drv=$(awk -F': ' '/^driver:/{print $2; exit}' "$_ei_log" 2>/dev/null | tr -d '\r')
            case "$_ei_drv" in
                mlx5_core|mlx4_core)
                    _ei_fw=$(grep -m1 "firmware-version" "$_ei_log" 2>/dev/null | cut -d: -f2- | xargs)
                    _ei_psid=$(printf '%s' "$_ei_fw" | sed -n 's/.*(\([^)]*\)).*/\1/p')
                    case "$_ei_psid" in
                        ""|"--"|"-"|"N/A") ;;
                        *) npsid="$_ei_psid" ;;
                    esac ;;
            esac
        fi
        # PSID 回查：nic_inventory 中 PSID=N/A 时，从 mlxfwmanager.log 按 BDF 补 PSID/Part Number
        # （采集端 mstflint 失败或 mlxfwmanager 无 PSID 字段时；报告端日志已就绪，无竞态）
        # 顺序: Device # → Device Type → Part Number → Description → PSID → PCI Device Name → ...
        # 字段散落在 Device Name 前后——遇下一设备头结算上一设备
        if [ "$npsid" = "N/A" ] && [ -f "${NET_DIR}/mlxfwmanager.log" ]; then
            # PSID 回查：按行扫描，PSID/PN 归属到其后的 PCI Device Name 匹配设备
            # 顺序: Device # → Device Type → Part Number → Description → PSID → PCI Device Name → Base GUID
            rpsid=$(awk -v bdf="${nnbdf%% (USB)*}" '
                /Part Number:/ { pn=$0; sub(/.*Part Number:[[:space:]]*/, "", pn) }
                /PSID:/        { psid=$0; sub(/.*PSID:[[:space:]]*/, "", psid) }
                /PCI Device Name:/ { dev=$NF; sub(/^0000:/, "", dev) }
                dev==bdf && /Base GUID:/ {
                    if (psid != "" && psid != "N/A") { print psid; exit }
                    if (pn != "" && pn != "--") { print "PN:" pn; exit }
                    exit
                }
            ' "${NET_DIR}/mlxfwmanager.log" 2>/dev/null | head -1)
            # 取第一行匹配，防多行污染
            rpsid=$(echo "$rpsid" | tr -d '\n\r')
            [ -n "$rpsid" ] && npsid="$rpsid"
        fi
        # ─── v1.48.85：型号提取与 DPU 判定对所有接口生效 ───
        # 原来整块（型号/DPU/芯片）都锁在 ibp*/ibs* 分支内，导致 ens* 形态的 BlueField DPU
        # （实测 900-9D3B6-00CV-AA0 → ens1f0np0）永远取不到型号，从未被判为 DPU；
        # 且 lspci 正则要求方括号（\[BlueField[^]]*\]），而 lspci 里 BlueField 是裸文本
        # （"MT43244 BlueField-3 integrated ConnectX-7"）→ 双重失配。两处一并修正。
        mt=""
        if [ -f "${lspci_all}" ]; then
            mt=$(grep -E "^${nnbdf%% (USB)*} " "${lspci_all}" 2>/dev/null | grep -oE 'ConnectX-[0-9]+( Lx| Dx)?|BlueField[- ][0-9A-Za-z]*' | head -1)
        fi
        # 兜底：lspci 无型号时用 CA type 映射（MT4129→ConnectX-7 等）
        # v1.48.88：同样必须先判映射存在——Intel/USB 口 lspci 取不到 ConnectX/BlueField 型号、
        #   NETDEV_CA 也无映射，空下标会让 bash 报 "bad array subscript" 并中断报告生成。
        if [ -z "$mt" ]; then
            _mt_ca="${NETDEV_CA[$nnic]:-}"
            if [ -n "$_mt_ca" ]; then
                mt="${CA_MODEL[$_mt_ca]:-}"
            fi
            [ -n "$mt" ] && mt=$(mt_model "$mt")
        fi
        [ -n "$mt" ] && npn="${npn} [${mt}]"
        # BlueField 系列 = DPU（Data Processing Unit，内置 Arm 处理器），标注区分普通网卡
        if echo "$mt" | grep -qiE "BlueField"; then
            npn="${npn} [DPU]"
        fi
        # ─── v1.48.88：芯片编号（MT 编号）对所有接口提取，不再限 ibp*/ibs* ───
        # CA_MODEL 来自 ibstat，而 ibstat 会列出**所有 RDMA 设备**，与端口当前跑 IB 还是 ETH 无关：
        #   实测 MCX755106AS-HEAT 的以太口 ens3f0np0 → mlx5_0 → CA type = MT4129（信息一直都在）。
        # 原实现把它锁在 ibp*/ibs* 分支内，导致**所有以太模式 Mellanox 卡的「芯片」列恒为 —**。
        # 注意：必须先判 NETDEV_CA 映射存在再用作下标——Intel/USB 等非 Mellanox 口没有映射，
        #   直接写 ${CA_MODEL[${NETDEV_CA[$nnic]:-}]} 会产生空下标 → bash 报 "bad array subscript"。
        nchip=""
        _nchip_ca="${NETDEV_CA[$nnic]:-}"
        if [ -n "$_nchip_ca" ]; then
            nchip="${CA_MODEL[$_nchip_ca]:-}"
        fi
        # v1.49.4：BMC FRU 兜底——必须放在 IB/非 IB 分支**之前**，所有接口都要过。
        #   实测教训：初版写在 ibp*/ibs* 分支内，而 CX8 的以太口名是 enp112s0np0，根本进不到那段。
        if [ -z "$nsn" ] || [ "$nsn" = "N/A" ] || [[ "$nsn" == 195* ]]; then
            _fpn_key="${npn%% *}"
            if [ -n "$_fpn_key" ] && [ "${FRU_NIC_PN_CNT[$_fpn_key]:-0}" = "1" ]; then
                nsn="${FRU_NIC_SN_BY_PN[$_fpn_key]}"
            fi
        fi
        # IB 设备（ibp*/ibs*）的专属补充：Mellanox 标志 + SN 为占位时的 Node GUID 兜底
        if [[ "$nnic" == ibp* || "$nnic" == ibs* ]]; then
            NIC_MLX=1
            # SN 为占位值/空时，用 ibstat Node GUID 兜底（每卡唯一，可区分多卡）
            if [ -z "$nsn" ] || [ "$nsn" = "N/A" ] || [ "$nsn" = "1951526575073" ]; then
                ng_ca="${NETDEV_CA[$nnic]:-}"
                ng_guid=""
                [ -n "$ng_ca" ] && ng_guid=$(awk "/CA '$ng_ca'/{found=1; next} found && /Node GUID/{print \$3; exit}" "${ibstat}" 2>/dev/null)
                [ -n "$ng_guid" ] && nsn="GUID:${ng_guid}"
                [ -z "$nsn" ] && nsn="N/A"
            fi
        else
            # 非 IB 卡（Intel/Broadcom 等）：sysfs serial 常是 MAC 变形（如 aa-bb-cc-dd-ee-ff-00-11）
            # 特征：含 ff-ff 或与 MAC 高度相似（- 分隔 16 进制），识别后标记为 MAC 派生
            if [ -n "$nsn" ] && echo "$nsn" | grep -qE "^([0-9a-f]{2}-){5,}[0-9a-f]{2}$"; then
                nsn="${nsn} (MAC)"
            fi
        fi
        # GPU 直连标记（topo PIX 判定）——无有效 topo 数据（旧采集/采集失败）时整列隐藏，避免误会：
        #   "GPU直连" = PIX 直连；"—" = 有 topo 数据但非直连
        # v1.44.0：GPU_DIRECT_COUNT 统计——平台无任何直连网卡时（非 H200/B200 类 1:1 直连形态）
        # 整列全 "—"，渲染层据此隐藏该列（动态列隐藏惯例，JSON 保留全字段）
        gd_mark=""
        if [ -n "$GPU_TOPO_FILE" ]; then
            GPU_TOPO_AVAIL=1
            if [ "${GPU_DIRECT_NIC[$nnic]:-0}" = "1" ]; then
                gd_mark="GPU直连"
                GPU_DIRECT_COUNT=$((GPU_DIRECT_COUNT + 1))
            else
                gd_mark="—"
            fi
        fi
        # PCIe 能力（LnkCap）与当前（LnkSta）合并显示：当前一致时只显当前，不一致标注能力
        npcie_cap=""
        if [ -n "$ncapspd" ] && [ "$ncapspd" != "N/A" ]; then
            if [ "$nspd" = "$ncapspd" ] && [ "$nwd" = "$ncapwd" ]; then
                npcie_cap="${nspd}/${nwd}"
            else
                npcie_cap="${nspd}/${nwd} (能力 ${ncapspd}/${ncapwd})"
            fi
        else
            npcie_cap="${nspd}/${nwd}"
        fi
        # PCIe 无数据（N/A/N/A）→ 统一 "—"
        case "${npcie_cap:-}" in ""|N/A|N/A/N/A|/|na|NA) npcie_cap="—" ;; esac
        # 固件回退：旧采集 csv 固件被 awk 截断成第一段（如 "0x00012b2c," 带逗号 / "9.00" 丢 NVM 版本）
        # → 从 ethtool_<dev>_driver.log 取完整固件字符串（新采集已修复，此处兼容旧数据）
        if echo "$nfw" | grep -qE ",$|^[0-9]+\.[0-9]+$"; then
            _nfw_full=$(grep -m1 "firmware-version" "${NET_DIR}/ethtool_${nnic}_driver.log" 2>/dev/null | cut -d: -f2- | xargs)
            [ -n "$_nfw_full" ] && nfw="$_nfw_full"
        fi
        # 无数据统一占位 "—"（N/A/空 → —；仅 GPU直连 保留三态语义）
        case "${nsn:-}" in ""|N/A|na|NA) nsn="—" ;; esac
        case "${npn:-}" in ""|N/A|na|NA) npn="—" ;; esac
        case "${nfw:-}" in ""|N/A|na|NA) nfw="—" ;; esac
        case "${npsid:-}" in ""|N/A|na|NA) npsid="—" ;; esac
        case "${nchip:-}" in ""|N/A|na|NA) nchip="—" ;; esac
        [ -z "$nmac" ] && nmac="—"
        [ -z "$npcie_cap" ] && npcie_cap="—"
        # v1.45.15：端口 Link 状态——IB 口从 ibstat State（经 NETDEV_CA 映射），以太口从 ethtool Link detected
        # v1.48.39：统一语义——IB Active/以太 yes → Up，IB Down/以太 no → Down（中间态 Init/Armed 保留原文如实）
        nlink="—"
        if [ -n "${NETDEV_CA[$nnic]:-}" ]; then
            nlink="${CA_STATE[${NETDEV_CA[$nnic]}]:-—}"
        fi
        if [ "$nlink" = "—" ]; then
            _ld=$(grep -m1 "Link detected" "${NET_DIR}/ethtool_${nnic}.log" 2>/dev/null | cut -d: -f2- | xargs)
            [ -n "$_ld" ] && nlink="$_ld"
        fi
        case "$nlink" in
            Active|yes|up|Up|YES|Yes) nlink="Up" ;;
            no|NO|No|down|Down)       nlink="Down" ;;
            # v1.48.42：多口 CA 聚合值（v1.45.17 CA_STATE 集合式，如 "Active,Down"）逐词归一
            *,*)
                _norm=""
                IFS=',' read -ra _nl_parts <<< "$nlink"
                for _np in "${_nl_parts[@]}"; do
                    case "$_np" in
                        Active|yes|up|Up)   _np="Up" ;;
                        no|NO|No|down|Down) _np="Down" ;;
                    esac
                    _norm="${_norm}${_norm:+,}${_np}"
                done
                nlink="$_norm" ;;
        esac
        # 物理口序号：同卡第 N 口/共 M 口（USB/非 PCIe 接口已在上方排除；明细行序 = BDF 升序，同卡相邻）
        nport="—"
        _bd_pre="${nnbdf%%.*}"
        if [ -n "${NIC_PORT_TOTAL[$_bd_pre]:-}" ]; then
            NIC_PORT_IDX[$_bd_pre]=$(( ${NIC_PORT_IDX[$_bd_pre]:-0} + 1 ))
            nport="${NIC_PORT_IDX[$_bd_pre]}/${NIC_PORT_TOTAL[$_bd_pre]}"
        fi
        # v1.49.15：型号列标注口数（用户要求"一看就知道是几口网卡"）。
        #   口数 = 同 BDF 前缀的接口行数（NIC_PORT_TOTAL，v1.44.0 物理口聚合，实测可靠：
        #   B300 的 CX8 在 ibstat 里 Number of ports:1 = 单口；CX6 Dx 的 4e:00.0/.1 = 双口）。
        #   仅对**多口卡**加后缀——单口是常态，标出来只是噪音，且「端口」列已写 1/1。
        _npt="${NIC_PORT_TOTAL[${nnbdf%%.*}]:-0}"
        if [ "${_npt:-0}" -gt 1 ] 2>/dev/null; then
        # v1.49.17：口数用**行业叫法**（Intel/NVIDIA 官方为 Single/Dual/Quad-Port，
        #   中文习惯"单口/双口/四口"——不说"两口"）；非 1/2/3/4/8 用「N 口」。
        case "$_npt" in
            1) _ptxt="单口" ;;
            2) _ptxt="双口" ;;
            3) _ptxt="三口" ;;
            4) _ptxt="四口" ;;
            8) _ptxt="八口" ;;
            *) _ptxt="${_npt} 口" ;;
        esac
            npn="${npn}（${_ptxt}）"
        fi
        # 物理位置（v1.48.53）：槽位表上溯（GPU 直连卡命中 SXM*_GPU* 槽位；标准卡命中 SLOTn/LAN）
        nloc=""
        [ "$NIC_SLOT_AVAIL" -eq 1 ] && nloc="$(nic_slot_name "${nnbdf%%.*}")"
        [ -z "$nloc" ] && nloc="—"
        NIC_DETAILS="${NIC_DETAILS}${nnic}|${nnbdf}|${nmac}|${nsn}|${npn}|${nfw}|${npcie_cap}|${npsid}|${gd_mark}|${nchip}|${nport}|${nlink}|${nloc}"$'\n'
    done < <(grep -v "^#" "${nic_inventory}" 2>/dev/null)
fi
# 网卡明细回退：nic_inventory.csv 空但 ibstat 有 CA（旧采集 v1.x 未生成 csv）→ 从 ibstat 构建简化明细
# 字段：ca|ca_type|node_guid|state（ibstat 只有 CA 级信息，无接口/BDF/固件——标注回退来源）
NIC_FALLBACK_DETAILS=""
if [ -z "$NIC_DETAILS" ] && [ -f "${ibstat}" ]; then
    _ca_count=$(grep -c "^CA '" "${ibstat}" 2>/dev/null)
    if [ "$_ca_count" -gt 0 ]; then
        NIC_FALLBACK_DETAILS=$(awk '
            /^CA /{ca=$2; gsub(/'"'"'/,"",ca)}
            /CA type/{type=$NF}
            /Node GUID/{guid=$NF}
            /State: /{state=$NF; printf "%s|%s|%s|%s\n", ca, type, guid, state}
        ' "${ibstat}" 2>/dev/null)
    fi
fi

# ─── PSID 缺失提示：有 Mellanox 卡但 PSID 全空时说明（采集时 MST 未启动/旧数据） ───
PSID_NOTICE=""
if [ "$NIC_MLX" -eq 1 ]; then
    _mlx_no_psid=0
    _mlx_total=0
    while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip nport; do
        [ -z "$nnic" ] && continue
        # 只统计 Mellanox 卡（型号含 ConnectX/BlueField/MLX，或芯片列 MT 编号 MT3xxx/MT4xxx）
        if ! echo "$npn" | grep -qiE "ConnectX|BlueField|MLX" && ! echo "$nchip" | grep -qE "^MT[0-9]{4}"; then
            continue
        fi
        _mlx_total=$((_mlx_total + 1))
        case "$npsid" in ""|N/A|—) _mlx_no_psid=$((_mlx_no_psid + 1)) ;; esac
    done <<< "$NIC_DETAILS"
    if [ "$_mlx_total" -gt 0 ] && [ "$_mlx_no_psid" -eq "$_mlx_total" ]; then
        PSID_NOTICE="⚠️ 有 ${_mlx_total} 张 Mellanox 卡未读到 PSID（采集时 MST 未启动或旧数据）；重新采集可获取"
    fi
fi

# ─── 风扇（IPMI 传感器，| 分隔格式） ───
FAN_DIR="${OUT}/fan"
load_manifest "${FAN_DIR}" ipmi_fan_sensors "ipmi_fan_sensors.log"
load_manifest "${FAN_DIR}" sensors_all "sensors_all.log"
# v1.48.98：兜底改用 bmc/ipmi_sensors.log——**同一台机的同一份数据，别再显示 N/A**。
#   实测 B300（B300-sample-a，22.224）：采集日志里
#     bmc/ipmi_sensors.log   = `ipmitool sensor list 2>&1`            → 100 行（含 15 行 FAN、18 行 PSU）
#     fan/ipmi_fan_sensors.log = `ipmitool sensor list | grep -iE 'FAN|RPM…'` → **0 行**
#   两者都是同一个 ipmitool 命令，差别只在**后者的输出接了管道 grep**：
#   grep 在管道里是**块缓冲**，30s 超时被 kill 时缓冲区未 flush → 整份输出丢失。
#   而前者直接重定向到文件（行缓冲/无缓冲），超时前已落盘的 100 行得以保留。
#   后果：报告「风扇 数量 N/A（未取到数据）」，而同一份日志里风扇转速标标准准。
#   修复分两处：① 采集端（modules/11_fan.sh）加 `grep --line-buffered`，从源头杜绝缓冲丢数据；
#            ② 本处兜底：ipmi_fan_sensors 为空时改用 bmc/ipmi_sensors.log（同为 sensor list 全量，
#               字段格式一致，下游 awk 自带 /fan[0-9]/ 过滤，不会把其他传感器算进来）。
#   注意仅「空/无有效行」时才兜底：有数据仍以专用文件为准（避免行为变化）。
_fan_have=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | grep -cE "[^[:space:]]")
if [ "${_fan_have:-0}" -eq 0 ]; then
    _fan_fb="${BMC_DIR}/ipmi_sensors.log"
    if [ -f "${_fan_fb}" ] && [ "$(grep -v '^#' "${_fan_fb}" 2>/dev/null | grep -icE 'fan|rpm')" -gt 0 ]; then
        ipmi_fan_sensors="${_fan_fb}"
        FAN_SRC_FALLBACK=1
    fi
fi
# 风扇匹配：兼容 Fan10_Speed_F / FAN1_Speed / Fan2 等大小写变体；只统计转速传感器（$3=RPM），
# 跳过 Present/discrete 等离散值（如 PSU1 Slow FAN1 是 discrete 状态位 0x1，非真实转速）
FAN_COUNT=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{c++} END{print c+0}')
# v1.48.88：区分「采集失败」与「平台真无风扇传感器」——此前两者都渲染成「数量 0」，会让客户以为机器没风扇。
#   判据：日志有实际数据行 = 采集成功（此时 0 才是真无传感器）；日志空/仅注释 = 命令超时或不可读（BMC 慢）。
#   实测 Giga B200（B200-sample-c）：ipmitool sensor list 10s 超时 → 日志空 → 报告写「数量 0」，
#   而该机实为 8×B200 整机，风扇必然存在。
FAN_DATA_OK=0
if [ -f "${ipmi_fan_sensors}" ] && [ -s "${ipmi_fan_sensors}" ]; then
    _fan_lines=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | grep -cE "[^[:space:]]")
    [ "${_fan_lines:-0}" -gt 0 ] && FAN_DATA_OK=1
fi
FAN_MIN=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{gsub(/ /,"",$2); if($2 ~ /^[0-9]+(\.[0-9]+)?$/) sub(/\.?0+$/,"",$2); if($2 ~ /^[0-9]+$/) print $2}' | sort -n | head -1)
FAN_MAX=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{gsub(/ /,"",$2); if($2 ~ /^[0-9]+(\.[0-9]+)?$/) sub(/\.?0+$/,"",$2); if($2 ~ /^[0-9]+$/) print $2}' | sort -n | tail -1)
FAN_SPEED=""
[ -n "$FAN_MIN" ] && FAN_SPEED="${FAN_MIN}-${FAN_MAX} RPM"

# 风扇每风扇明细
FAN_DETAILS=""
if [ -f "${ipmi_fan_sensors}" ]; then
    FAN_DETAILS=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{
        name=$1; gsub(/^ +| +$/,"",name)
        val=$2; gsub(/^ +| +$/,"",val)
        # 转速去尾零（9300.000 → 9300）
        if(val ~ /^[0-9]+\.[0-9]+$/) {sub(/\.?0+$/,"",val)}
        status=$4; gsub(/^ +| +$/,"",status)
        print name"|"val"|"status
    }')
fi

# ─── v1.48.88：IPMI 取不到时的 OS 侧风扇兜底（lm-sensors → hwmon sysfs） ───
# 服务器风扇多走 BMC（SMBus/PMBus），OS 看不到；但部分平台会把转速暴露给内核驱动
# （nct6775/it87/ast 等），此时采集端已落盘的 sensors_fan.log / hwmon_*/fan_values.log 有数据。
# 原实现完全没读这条路，**明明采到了也显示 N/A**，还会让「风扇」章节误报采集失败。
# 仅在 IPMI 无数据时兜底（IPMI 权威：带状态；风扇冗余自 v1.49.0 移除，见下）。
FAN_SOURCE="IPMI"
if [ "${FAN_DATA_OK:-0}" -ne 1 ]; then
    _os_details=""; _os_src=""

    # ① lm-sensors：sensors 输出形如 "fan1:        4200 RPM  (min = 0 RPM)"
    if [ -f "${FAN_DIR}/sensors_fan.log" ]; then
        _os_details=$(grep -vE "^#|^[[:space:]]*$" "${FAN_DIR}/sensors_fan.log" 2>/dev/null \
            | grep -iE "rpm" | sed 's/^[[:space:]]*//' \
            | awk '{name=$1; sub(/:$/,"",name); val=""; for(i=1;i<=NF;i++){ if($i ~ /^[0-9]+(\.[0-9]+)?$/) {val=$i; break} } if(val!="") print name"|"val"|OS(lm-sensors)"}' \
            | head -40)
        [ -n "$_os_details" ] && _os_src="lm-sensors"
    fi

    # ② hwmon sysfs：hwmon_*/fan_values.log 形如 "fan1_input: 4200"
    if [ -z "$_os_src" ]; then
        _hw_files=$(find "${FAN_DIR}" -maxdepth 2 -name "fan_values.log" 2>/dev/null | head -5)
        if [ -n "$_hw_files" ]; then
            _os_details=$(cat $_hw_files 2>/dev/null | grep -iE "fan[0-9]+_input" \
                | awk -F': *' '{n=$1; gsub(/[^0-9]/,"",n); print "fan"n"|"$2"|OS(hwmon)"}' | head -40)
            [ -n "$_os_details" ] && _os_src="hwmon"
        fi
    fi

    if [ -n "$_os_details" ]; then
        FAN_DETAILS="$_os_details"
        FAN_COUNT=$(printf '%s\n' "$_os_details" | grep -c '|')
        _os_min=$(printf '%s\n' "$_os_details" | awk -F'|' '$2 ~ /^[0-9]+$/ {print $2}' | sort -n | head -1)
        _os_max=$(printf '%s\n' "$_os_details" | awk -F'|' '$2 ~ /^[0-9]+$/ {print $2}' | sort -n | tail -1)
        [ -n "$_os_min" ] && FAN_SPEED="${_os_min}-${_os_max} RPM"
        FAN_DATA_OK=1
        FAN_SOURCE="OS 侧（${_os_src}）"
    fi

    # ③ dmidecode Type 27（Cooling Device）——最后一档：只有 Type/Status，无转速
    #   SMBIOS 的 Cooling Device 表给出平台声明的散热器件（Type: Fan，Status: OK）。
    #   信息量少于前两路（无 RPM），但能证明「平台确实有风扇且状态正常」——
    #   对「风扇数量 0」这种误导性结论，有它就足以纠正为「平台有 N 个风扇（来自 SMBIOS，无转速）」。
    if [ "${FAN_DATA_OK:-0}" -ne 1 ]; then
        _dmi_full=$(find "${FAN_DIR}/.." -maxdepth 2 -name "dmidecode_full.log" 2>/dev/null | head -1)
        if [ -n "$_dmi_full" ]; then
            _dmi_fans=$(awk '
                /^Cooling Device$/ { incool=1; ctype=""; cstat=""; next }
                incool && /^\tType:/ { t=$2; ctype=$2 }
                incool && /^\tStatus:/ { cstat=$2 }
                incool && /^\tType:/ && ctype ~ /^Fan/ { }
                /^$/ { if (incool && ctype ~ /^Fan/) { print "SMBIOS冷却装置|" cstat "|SMBIOS(Type27)"; } incool=0 }
                END { if (incool && ctype ~ /^Fan/) { print "SMBIOS冷却装置|" cstat "|SMBIOS(Type27)" } }
            ' "$_dmi_full" 2>/dev/null)
            _dmi_n=$(printf '%s\n' "$_dmi_fans" | grep -c '|')
            if [ "${_dmi_n:-0}" -gt 0 ]; then
                FAN_DETAILS="$_dmi_fans"
                FAN_COUNT="$_dmi_n"
                FAN_DATA_OK=1
                FAN_SOURCE="SMBIOS（dmidecode Type 27，无转速）"
            fi
        fi
    fi
fi

# ─── 风扇冗余（已移除，v1.49.0） ───
# 原解析 Fan Redundancy / FAN Cable / Fan PG 三态（v1.36.0）。删除理由见 gen_acceptance.sh 第 14 项注释：
#   22 台样本无一提供有效冗余信息（6 台是 `FAN_Redundancy | 0x00 | ok`——0x00 在 IPMI discrete 语义里是
#   「无该状态/未定义」，不是「有冗余」；且原 `*ok*` 分支会把它误判成「冗余满足」；另 16 台为空文件）。
#   BMC 普遍不提供风扇冗余接口，保留只会产生噪声与误判。
# FAN_SENSOR_PRESENT 亦随之移除（原本仅服务风扇冗余的「平台固有 N/A」判定）。

# 温度概况（ipmi_sensors_temp.log：进风/出风/CPU/内存/电源 关键温度聚合 min-max）
TEMP_SUMMARY=""
load_manifest "${BMC_DIR}" ipmi_sensors_temp "ipmi_sensors_temp.log"
if [ -f "${ipmi_sensors_temp}" ]; then
    _temp_agg() {   # $1=匹配模式, $2=标签
        # v1.49.8：先 trim `$1` 再匹配——IPMI 传感器的 Name 列是**左对齐补空格**的
        #   （实测 `TEMP_CPU0        |`），带 `$` 锚的模式（如 ^temp_cpu[0-9]+$）永不命中。
        grep -v "^#" "${ipmi_sensors_temp}" 2>/dev/null | awk -F'|' -v pat="$1" '{ k=$1; sub(/^[ \t]+/,"",k); sub(/[ \t]+$/,"",k); k=tolower(k); if (k ~ pat) { v=$2; gsub(/ /,"",v); if(v ~ /^[0-9]+(\.[0-9]+)?$/) { if(v+0>0) print v } } }' | sort -n | awk -v lbl="$2" 'NR==1{mn=$1} {mx=$1} END{if(mn!=""){sub(/\.0+$/,"",mn); sub(/\.0+$/,"",mx); printf "%s %s-%s°C  ", lbl, mn, mx}}'
    }
    # v1.49.8：加 DGX 平台的 `TEMP_CPU<N>` / `TEMP_GB_GPU<N>` 命名（实测 DGX A100：
    #   TEMP_CPU0 46C / TEMP_GB_GPU0~7 27~35C）。原模式 `^cpu[0-9]+[ _]temp` 要求
    #   "cpu 开头"，而 DGX 是 "temp_cpu0"，故整机温度被判「无温度传感器数据」——
    #   实际有数据（错的是解析，不是硬件）。注意 _temp_agg 已 tolower。
    TEMP_SUMMARY="$( _temp_agg 'inlet.*temp|tr[0-9]+.*temp' '进风'; _temp_agg 'outlet.*temp' '出风'; _temp_agg '^cpu[0-9]+[ _]temp|^temp_cpu[0-9]+$' 'CPU'; _temp_agg 'dimm.*temp' '内存'; _temp_agg 'psu[0-9]+[ _]temp' '电源'; _temp_agg 'pch.*temp' 'PCH'; _temp_agg '^temp_gb_gpu[0-9]+$' 'GPU' )"
    TEMP_SUMMARY=$(echo "$TEMP_SUMMARY" | sed 's/  *$//')
fi
# OS 侧温度兜底（v1.45.16）：无 BMC 温度（ipmi_sensors_temp 无/失败/平台无 BMC）时，
# 从 lm-sensors（sensors_all.log）聚合 CPU 封装温度——标注"OS 侧"，验收不因此误判
# v1.45.17：聚合全部 Package id 取 min-max（双路 CPU 此前只显示第一颗）
TEMP_SUMMARY_OS=""
if [ -z "$TEMP_SUMMARY" ] && [ -f "${sensors_all}" ]; then
    _os_cpu=$(grep "Package id" "${sensors_all}" 2>/dev/null | grep -oE '[0-9.]+°C' | awk '
        {gsub(/°C/,""); if(NR==1||$1+0<min)min=$1+0; if($1+0>max)max=$1+0}
        END{if(NR==1) printf "%.0f°C", min; else if(NR>1) printf "%.0f-%.0f°C", min, max}')
    if [ -n "$_os_cpu" ]; then
        TEMP_SUMMARY_OS="CPU ${_os_cpu}（OS 侧 lm-sensors）"
    else
        _os_cpu2=$(grep -m1 "Core 0:" "${sensors_all}" 2>/dev/null | grep -oE '[0-9.]+°C' | head -1)
        [ -n "$_os_cpu2" ] && TEMP_SUMMARY_OS="CPU ${_os_cpu2}（OS 侧 lm-sensors）"
    fi
fi
