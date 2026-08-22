#!/bin/bash
# =============================================================================
# HwScope - 变量解析：网卡明细(mt_model/GPU直连/PSID) + 风扇 + 温度
# report/sections/60_nic_fan_temp.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# 网卡明细（nic_inventory.csv: dev|bdf|mac|sn|pn|fw|speed|width|psid）
# IB 控制器型号识别：ibstat CA type + ibdev2netdev 映射（mlx5_N ↔ ibp*），附加到 PN 列
declare -A CA_MODEL NETDEV_CA
NIC_MLX=0
GPU_TOPO_AVAIL=0
if [ -f "${ibstat}" ]; then
    cur_ca=""
    while IFS= read -r il; do
        case "$il" in
            *"CA '"*) cur_ca=$(echo "$il" | sed "s/.*'\(.*\)'.*/\1/") ;;
            *"CA type:"*) [ -n "$cur_ca" ] && CA_MODEL[$cur_ca]=$(echo "$il" | awk '{print $NF}') ;;
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
        # 每列 NIC：统计 GPU 行中 PIX 出现次数（任一 GPU 直连即标记）
        declare -A _nic_pix
        while IFS= read -r _row; do
            [ -z "$_row" ] && continue
            echo "$_row" | grep -qE "^GPU[0-9]+" || continue
            _idx=0
            for _col in "${_nic_cols[@]}"; do
                _val=$(echo "$_row" | awk -v c="${_nic_idx[$_idx]}" '{print $c}')
                [ "$_val" = "PIX" ] && _nic_pix[$_col]=1
                _idx=$((_idx+1))
            done
        done < <(grep -v "^#" "$GPU_TOPO_FILE")
        # 映射：topo NIC 列按 BDF 升序 = nic_inventory 中 PCIe 网卡按 BDF 升序
        _pci_nics=()
        while IFS='|' read -r _d _bdf _rest; do
            [ -z "$_d" ] || [ "$_d" = "#" ] && continue
            echo "$_bdf" | grep -qE "^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$" && _pci_nics+=("$_d|$_bdf")
        done < <(grep -v "^#" "${nic_inventory}" 2>/dev/null)
        # 按 BDF 排序（topo NIC 列序 = BDF 升序）
        _pci_nics=($(printf '%s\n' "${_pci_nics[@]}" | sort -t'|' -k2))
        _nn=0
        for _col in "${_nic_cols[@]}"; do
            _entry="${_pci_nics[$_nn]:-}"
            [ -n "$_entry" ] && [ "${_nic_pix[$_col]:-0}" -eq 1 ] && GPU_DIRECT_NIC[${_entry%%|*}]="1"
            _nn=$((_nn+1))
        done
    fi
fi
if [ -f "${nic_inventory}" ]; then
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
        # IB 设备（ibp*/ibs*）附加控制器型号
        if [[ "$nnic" == ibp* || "$nnic" == ibs* ]]; then
            NIC_MLX=1
            # 型号附加：优先 lspci 直读（PCI ID 权威，认识所有 Mellanox 卡，无需维护映射表）
            mt=""
            if [ -f "${lspci_all}" ]; then
                mt=$(grep -E "^${nnbdf%% (USB)*} " "${lspci_all}" 2>/dev/null | grep -oE '\[ConnectX-[0-9]+( Lx| Dx)?\]|\[BlueField[^]]*\]' | head -1 | tr -d '[]')
            fi
            # 兜底：lspci 无型号时用 CA type 映射（MT4129→ConnectX-7 等）
            if [ -z "$mt" ]; then
                mt="${CA_MODEL[${NETDEV_CA[$nnic]:-}]:-}"
                [ -n "$mt" ] && mt=$(mt_model "$mt")
            fi
            [ -n "$mt" ] && npn="${npn} [${mt}]"
            # BlueField 系列 = DPU（Data Processing Unit，内置 Arm 处理器），标注区分普通网卡
            if echo "$mt" | grep -qiE "BlueField"; then
                npn="${npn} [DPU]"
            fi
            # 芯片编号（MT 编号：MT4129 等，工程/固件视角核对用）
            nchip=""
            if [[ "$nnic" == ibp* || "$nnic" == ibs* ]]; then
                nchip="${CA_MODEL[${NETDEV_CA[$nnic]:-}]:-}"
            fi
            # SN 为占位值/空时，用 ibstat Node GUID 兜底（每卡唯一，可区分多卡）
            if [ -z "$nsn" ] || [ "$nsn" = "N/A" ] || [ "$nsn" = "1951526575073" ]; then
                ng_ca="${NETDEV_CA[$nnic]:-}"
                ng_guid=""
                [ -n "$ng_ca" ] && ng_guid=$(awk "/CA '$ng_ca'/{found=1; next} found && /Node GUID/{print \$3; exit}" "${ibstat}" 2>/dev/null)
                [ -n "$ng_guid" ] && nsn="GUID:${ng_guid}"
                [ -z "$nsn" ] && nsn="N/A"
            fi
        else
            # 非 IB 卡（Intel/Broadcom 等）：sysfs serial 常是 MAC 变形（如 f5-96-29-ff-ff-9f-ad-a0）
            # 特征：含 ff-ff 或与 MAC 高度相似（- 分隔 16 进制），识别后标记为 MAC 派生
            if [ -n "$nsn" ] && echo "$nsn" | grep -qE "^([0-9a-f]{2}-){5,}[0-9a-f]{2}$"; then
                nsn="${nsn} (MAC)"
            fi
        fi
        # GPU 直连标记（topo PIX 判定）——无有效 topo 数据（旧采集/采集失败）时整列隐藏，避免误会：
        #   "GPU直连" = PIX 直连；"—" = 有 topo 数据但非直连
        gd_mark=""
        if [ -n "$GPU_TOPO_FILE" ]; then
            GPU_TOPO_AVAIL=1
            if [ "${GPU_DIRECT_NIC[$nnic]:-0}" = "1" ]; then
                gd_mark="GPU直连"
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
        NIC_DETAILS="${NIC_DETAILS}${nnic}|${nnbdf}|${nmac}|${nsn}|${npn}|${nfw}|${npcie_cap}|${npsid}|${gd_mark}|${nchip}"$'\n'
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
    while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip; do
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
# 风扇匹配：兼容 Fan10_Speed_F / FAN1_Speed / Fan2 等大小写变体；只统计转速传感器（$3=RPM），
# 跳过 Present/discrete 等离散值（如 PSU1 Slow FAN1 是 discrete 状态位 0x1，非真实转速）
FAN_COUNT=$(grep -v "^#" "${ipmi_fan_sensors}" 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan[0-9]/ && tolower($3) ~ /rpm/ && tolower($1) !~ /present/ && tolower($1) !~ /total/{c++} END{print c+0}')
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

# ─── 风扇冗余三态（Fan Redundancy / FAN Cable / Fan PG；Dell/标准服务器 IPMI，v1.36.0） ───
# FAN_REDUNDANT: 冗余满足 / ⚠️ 冗余失效 / N/A（供报告与验收"风扇冗余"判定）
# FAN_EXTRA: 三态摘要展示（如 "Fan Redundancy:ok FAN Cable:ok 12V Fan PG:ok"）
FAN_REDUNDANT="N/A"; FAN_EXTRA=""
load_manifest "${FAN_DIR}" ipmi_fan_redundancy "ipmi_fan_redundancy.log"
if [ -f "${ipmi_fan_redundancy}" ]; then
    FAN_EXTRA=$(grep -v "^#" "${ipmi_fan_redundancy}" 2>/dev/null | grep -iE "Redundancy|Cable|PG" | head -6 \
        | awk -F'|' '{n=$1; v=$3; gsub(/^ +| +$/,"",n); gsub(/^ +| +$/,"",v); if(n!=""&&v!="") printf "%s:%s ", n, v}' | sed 's/ $//')
    _fan_red=$(grep -v "^#" "${ipmi_fan_redundancy}" 2>/dev/null | grep -iE "Fan.*Redundancy" | head -1)
    if [ -n "$_fan_red" ]; then
        case "$_fan_red" in
            *"| 0x01"*|*"| 0x1"*|*ok*|*OK*) FAN_REDUNDANT="冗余满足" ;;
            *) FAN_REDUNDANT="⚠️ 冗余失效" ;;
        esac
    fi
fi

# 温度概况（ipmi_sensors_temp.log：进风/出风/CPU/内存/电源 关键温度聚合 min-max）
TEMP_SUMMARY=""
load_manifest "${BMC_DIR}" ipmi_sensors_temp "ipmi_sensors_temp.log"
if [ -f "${ipmi_sensors_temp}" ]; then
    _temp_agg() {   # $1=匹配模式, $2=标签
        grep -v "^#" "${ipmi_sensors_temp}" 2>/dev/null | awk -F'|' -v pat="$1" 'tolower($1) ~ pat {
            v=$2; gsub(/ /,"",v); if(v ~ /^[0-9]+(\.[0-9]+)?$/) { if(v+0>0) print v }
        }' | sort -n | awk -v lbl="$2" 'NR==1{mn=$1} {mx=$1} END{if(mn!=""){sub(/\.0+$/,"",mn); sub(/\.0+$/,"",mx); printf "%s %s-%s°C  ", lbl, mn, mx}}'
    }
    TEMP_SUMMARY="$( _temp_agg 'inlet.*temp|tr[0-9]+.*temp' '进风'; _temp_agg 'outlet.*temp' '出风'; _temp_agg '^cpu[0-9]+[ _]temp' 'CPU'; _temp_agg 'dimm.*temp' '内存'; _temp_agg 'psu[0-9]+[ _]temp' '电源'; _temp_agg 'pch.*temp' 'PCH' )"
    TEMP_SUMMARY=$(echo "$TEMP_SUMMARY" | sed 's/  *$//')
fi
