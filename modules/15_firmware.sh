#!/bin/bash
# =============================================================================
# 模块: 15_firmware.sh — 固件合规模块
# 输出目录: <OUTPUT_DIR>/firmware/
# 功能: 采集固件清单并判定合规——厂商无关：BIOS（SMBIOS Type 0）/ BMC / GPU VBIOS
#       （NVIDIA nvidia-smi 或 AMD rocm-smi）/ CPU 微码 / 网卡（mlxfwmanager 或 ethtool）/
#       存储盘 / NVSwitch（仅 NVIDIA），对照 conf/fw_required.txt 逐项判 合规/落后/较新/未知。
#       报告端只在「已录基线」时显示该段（无基线整段隐藏，v1.53.43）。
# 说明: 无基线条目 → 判"未知"（仅记录当前版本，不产生 WARN —— 基线未录入是配置
#       问题而非硬件问题）；基线由人工按厂商验收手册维护（模板见 conf/fw_required.txt）。
# =============================================================================

MODULE_NAME="Firmware"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

# ─── 版本比较：$1=当前 $2=基线 → 输出 -1(落后) 0(相等) 1(较新) 2(无法比较) ───
# 规则：逐段比较（. - 空格 / 分隔），段内纯数字按数值、纯十六进制按 hex、混合按字典序
fw_ver_cmp() {
    local cur="$1" base="$2"
    [ -z "$cur" ] || [ -z "$base" ] && { echo 2; return; }
    [ "$cur" = "$base" ] && { echo 0; return; }
    local -a ca=() ba=() _tmp=()
    while IFS=' .-/' read -r -a _tmp; do ca=("${_tmp[@]}"); done < <(printf '%s\n' "$cur")
    while IFS=' .-/' read -r -a _tmp; do ba=("${_tmp[@]}"); done < <(printf '%s\n' "$base")
    local i=0 n m max x y dx dy
    n=${#ca[@]}; m=${#ba[@]}; max=$(( n > m ? n : m ))
    for ((i=0; i<max; i++)); do
        x="${ca[$i]:-}"; y="${ba[$i]:-}"
        [ -z "$x" ] && [ -z "$y" ] && continue
        if [ -z "$x" ]; then echo -1; return; fi    # 段数少 = 版本旧（1.2 < 1.2.1）
        if [ -z "$y" ]; then echo 1; return; fi
        if [[ "$x" =~ ^[0-9]+$ ]] && [[ "$y" =~ ^[0-9]+$ ]]; then
            # 超长数字段（>18 位）避免 bash 64 位整数回绕误判相等，走字典序
            if [ "${#x}" -gt 18 ] || [ "${#y}" -gt 18 ]; then
                if [ "$x" \< "$y" ]; then echo -1; return; fi
                if [ "$x" \> "$y" ]; then echo 1; return; fi
            else
                if [ "$x" -lt "$y" ] 2>/dev/null; then echo -1; return; fi
                if [ "$x" -gt "$y" ] 2>/dev/null; then echo 1; return; fi
            fi
        elif [[ "$x" =~ ^[0-9A-Fa-f]{1,8}$ ]] && [[ "$y" =~ ^[0-9A-Fa-f]{1,8}$ ]]; then
            # 固件版本常含十六进制段（如 VBIOS 92.00.1D.00.11）
            dx=$((16#$x)); dy=$((16#$y))
            if [ "$dx" -lt "$dy" ]; then echo -1; return; fi
            if [ "$dx" -gt "$dy" ]; then echo 1; return; fi
        else
            if [ "$x" \< "$y" ]; then echo -1; return; fi
            if [ "$x" \> "$y" ]; then echo 1; return; fi
        fi
    done
    echo 0
}

# ─── 基线查找：$1=组件 $2=型号 → 输出 推荐版本|备注（无匹配输出空） ───
# 匹配规则：型号模式为空 = 该组件全部设备；否则 grep -E 匹配当前型号
fw_base_find() {
    local comp="$1" model="$2" line pat rec note
    [ -f "$FW_REQUIRED" ] || { echo ""; return; }
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        IFS='|' read -r bc bp br bn < <(printf '%s\n' "$line")
        [ "$(echo "${bc:-}" | tr '[:lower:]' '[:upper:]')" != "$comp" ] && continue
        pat="${bp:-}"
        if [ -z "$pat" ] || { [ -n "$model" ] && echo "$model" | grep -qE "$pat" 2>/dev/null; }; then
            echo "${br:-}|${bn:-}"
            return
        fi
    done < "$FW_REQUIRED"
    echo ""
}

run_firmware() {
    local output_dir="$1"
    local dir="${output_dir}/firmware"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    FW_REQUIRED="${SCRIPT_DIR}/../conf/fw_required.txt"
    [ -f "$FW_REQUIRED" ] || FW_REQUIRED=""

    # ─── 采集固件版本（并行；工具缺失自动跳过，不中断） ───
    # v1.48.69：移除 `nvidia-smi nvswitch --version`——nvidia-smi 无 nvswitch 子命令（580.105.08 实测
    # "ERROR: Option nvswitch is not valid for this command"，exit=2 → 误报 WARN），NVSwitch 版本统一由
    # `nvswitch --version`（独立 CLI，有则采）提供，与 05_nvswitch.sh 的口径一致（v1.48.61 立）。
    # v1.49.20：`ipmitool mc info` 原来没有超时——BMC 无响应时该条会一直挂到 300s 模块级超时，
    #   连带把本模块其余固件采集（GPU VBIOS / 网卡固件 / NVSwitch 版本）一起拖没。
    #   统一走 IPMI 快速级超时（mc info 属快命令，见 lib/common.sh 分级说明）。
    local fw_ipmi_fast="timeout ${IPMI_TIMEOUT_FAST:-30}"; check_cmd timeout || fw_ipmi_fast=""
    # v1.51.3：NVSwitch 版本来源由 `nvswitch --version` 改为 `nvswitch-audit --help`
    #   —— 前者这个命令**不存在**（见 05_nvswitch.sh 说明），恒为 cmd not found；
    #   后者真实存在（属 nvidia-fabricmanager 包），版本在第 2 行
    #   （"NVIDIA NVSwitch audit tool version 570.86.15"）。
    #   ⚠️ 不要加 `| head -1`：其 --help **首行是空行**，head -1 只取到空行、
    #      下方解析链（grep -v '^#' | grep -iE Version）整体落空，固件表 NVSWITCH 行消失（实测踩坑）。
    # v1.53.34：vbios 查询走 nvidia-smi，非 NVIDIA 平台（AMD/昇腾）上必然失败。
    #   不用「|| echo」兜底——那会把 NVIDIA 平台上的真失败也吞掉；改为提前判能力，
    #   无 N 卡时直接用一条记录性命令（exit 0、内容写明 SKIP），nv 平台行为完全不变。
    local _vbios_cmd="nvidia-smi --query-gpu=index,name,vbios_version --format=csv,noheader 2>&1"
    # v1.53.39：NVSwitch 同样按平台能力门禁。注意 `nvswitch-audit --help` 输出的是**工具自身版本**
    #   （如 615.71.09，属 nvidia-fabricmanager 包），不是本机 NVSwitch 固件——实测 AMD 整机
    #   （无 NVSwitch）也被记成「NVSwitch 615.71.09」并进固件清单/合规表，属误报。
    local _nvsw_cmd="nvswitch-audit --help 2>&1"
    if ! has_nvidia_gpu; then
        _nvsw_cmd="echo '# SKIP: 本机无 NVIDIA GPU（无 NVSwitch 可读）'"
    fi
    if ! has_nvidia_gpu; then
        _vbios_cmd="echo '# SKIP: 本机无 NVIDIA GPU（AMD/昇腾等平台无 nvidia VBIOS）'"
    fi
    run_and_log_parallel 4 \
        "${_vbios_cmd}" "${dir}/gpu_vbios.csv" \
        "${fw_ipmi_fast} bash -c \"ipmitool mc info 2>&1\"" "${dir}/bmc_mc.log" \
        "mlxfwmanager --query 2>&1" "${dir}/nic_fwmanager.log" \
        "${_nvsw_cmd}" "${dir}/nvswitch_version.log"

    # 网卡固件兜底（无 mlxfwmanager 时）：ethtool -i 逐口读 firmware-version
    if ! check_cmd mlxfwmanager; then
        local _dev _name
        for _dev in /sys/class/net/*; do
            [ -d "$_dev" ] || continue
            _name=$(basename "$_dev")
            case "$_name" in lo|docker*|veth*|br-*) continue ;; esac
            [ -f "${_dev}/device" ] || continue
            run_and_log "ethtool -i $_name 2>&1" "${dir}/nic_ethtool_${_name}.log"
        done
    fi

    # v1.53.38：模块上下文里没有 OUT 变量（父进程导出的是 OUTPUT_BASE/OUTPUT_DIR），
    #   本文件内统一用 _root 反推采集根目录——用 ${OUT} 会变成「/motherboard/…」而整段落空。
    local _root="${dir%/firmware}"

    # ─── 汇总原始版本清单（fw_versions.log，供人工核阅） ───
    # v1.53.38：清单改为**厂商无关**。此前只收 nvidia-smi / mlxfwmanager / nvswitch 三路，
    #   在 AMD 整机上三路全空（实测 8×MI300X），固件清单只剩空标题、验收判「无固件数据」。
    #   现补：① BIOS（dmidecode Type 0）② AMD GPU VBIOS + 微码（rocm-smi JSON）
    #        ③ 存储盘固件（smartctl/nvme 日志）④ 保留原 NVIDIA/NIC/NVSwitch 各段。
    #   ⚠️ 另修一处致命回归：v1.53.34 那次改动把上面 run_and_log_parallel 的续行符写成 `\\`，
    #      4 条命令因此根本没执行（实测 hwscope.log 报 `... ipmitool mc info 2>&1: command not found`，
    #      firmware/ 只剩 2 个文件）——续行符已改正。
    {
        echo "# HwScope 固件版本清单 $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "## BIOS（dmidecode Type 0）"
        grep -iE "Vendor:|Version:|Release Date:" "${_root}/motherboard/dmidecode_bios.log" 2>/dev/null \
            | sed 's/^[[:space:]]*/  /' | head -6
        echo ""
        echo "## BMC（ipmitool mc info）"
        grep -iE "Firmware Revision|Manufacturer Name|Product Name" "${dir}/bmc_mc.log" 2>/dev/null \
            | sed 's/^[[:space:]]*/  /'
        echo ""
        if has_nvidia_gpu; then
            echo "## GPU VBIOS（NVIDIA）"
            grep -v "^#" "${dir}/gpu_vbios.csv" 2>/dev/null | grep -v "^$" | sed 's/^/  /'
        fi
        echo ""
        echo "## GPU VBIOS（AMD / rocm-smi --showallinfo）"
        grep -oE '"VBIOS version":[[:space:]]*"[^"]*"' "${_root}/gpu/gpu_amd_full.log" 2>/dev/null \
            | cut -d'"' -f4 | sort -u | sed 's/^/  VBIOS: /'
        echo ""
        echo "## GPU 微码固件（AMD / rocm-smi --showfwinfo，取 card0）"
        grep -oE '"(SMC|SOS|TA RAS|TA XGMI|VCN|MEC|MEC2|RLC|SDMA|SDMA2) firmware version":[[:space:]]*"[^"]*"' \
            "${_root}/gpu/gpu_amd_fw.log" 2>/dev/null | head -10 | sed 's/^/  /'
        echo ""
        echo "## NIC（mlxfwmanager）"
        grep -E "Device Type:|Firmware Version:|PCI Device Name:" "${dir}/nic_fwmanager.log" 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "## NIC（network/nic_inventory.csv——07_network 已采，厂商无关）"
        local _nf
        if [ -f "${_root}/network/nic_inventory.csv" ]; then
            # 列序: dev|bdf|mac|serial|part_number|firmware|speed|width|psid|cap_speed|cap_width
            grep -v "^#" "${_root}/network/nic_inventory.csv" 2>/dev/null | grep -v "^$" \
                | awk -F'|' '{ m=$5; gsub(/^[ \t]+|[ \t]+$/,"",m); f=$6; gsub(/^[ \t]+|[ \t]+$/,"",f); b=$2; gsub(/^[ \t]+|[ \t]+$/,"",b);
                              if (b !~ /^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$/) next;   # USB 网卡不进固件表
                              if (f!="" && f!="N/A") print "  " (m==""||m=="N/A" ? $1 : m) " → FW " f }' \
                | sort -u | head -20
        fi
        echo ""
        echo "## NIC（ethtool 兜底）"
        local _f _n
        for _f in "${dir}"/nic_ethtool_*.log; do
            [ -f "$_f" ] || continue
            _n=$(basename "$_f" | sed 's/nic_ethtool_//; s/\.log//')
            echo "  $_n: $(grep -m1 'firmware-version' "$_f" 2>/dev/null | cut -d: -f2- | xargs)"
        done
        echo ""
        echo "## 存储盘固件（smartctl / nvme；不含 USB 盘）"
        _usb_list=$(grep -vE "^#|^$" "${_root}/storage/block_devices_all.log" 2>/dev/null \
            | awk '{u=0; for(i=2;i<=NF;i++) if($i=="usb") u=1; if(u) print $1}' | tr '\n' ' ')
        for _sf in "${_root}/storage"/smart_*.log "${_root}/storage"/nvme_*_health.log; do
            [ -f "$_sf" ] || continue
            _sd=$(basename "$_sf" | sed 's/^smart_//; s/_health\.log$//; s/\.log$//')
            case " ${_usb_list} " in *" ${_sd} "*) continue ;; esac
            _sv=$(grep -m1 -E "^Firmware Version|^Firmware Revision" "$_sf" 2>/dev/null | cut -d: -f2- | xargs)
            [ -n "$_sv" ] && echo "  ${_sd}: ${_sv}"
        done | sort -u | head -12
        echo ""
        if has_nvidia_gpu; then
            echo "## NVSwitch（nvidia-fabricmanager 包；此处为工具版本，非 NVSwitch 固件）"
            grep -v "^#" "${dir}/nvswitch_version.log" 2>/dev/null | grep --line-buffered -iE "Version|Firmware" | sed 's/^/  /'
        fi
    } > "${dir}/fw_versions.log"

    # ─── 合规判定 ───
    local csv="${dir}/fw_compliance.csv"
    {
        echo "# HwScope 固件合规判定 $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# component|device|current|baseline|status|note"
        echo "# status: 合规/落后/较新/未知（无基线）/无法比较"
        echo "# 基线文件: conf/fw_required.txt（未配置则全部判未知）"
        [ -z "$FW_REQUIRED" ] && echo "# ⚠️ conf/fw_required.txt 不存在——当前仅记录版本，不做合规判定"
    } > "$csv"

    local comp dev cur base note st rc
    local st_comply=0 st_behind=0 st_newer=0 st_unknown=0

    fw_emit() {
        local c="$1" d="$2" v="$3"
        local bb nn
        bb=$(fw_base_find "$c" "$d")
        IFS='|' read -r base note < <(printf '%s\n' "$bb")
        [ -z "$base" ] && { st_unknown=$((st_unknown+1)); echo "${c}|${d}|${v}|—|未知|无基线（conf/fw_required.txt 未录入）" >> "$csv"; return; }
        rc=$(fw_ver_cmp "$v" "$base")
        case "$rc" in
            -1) st_behind=$((st_behind+1)); echo "${c}|${d}|${v}|${base}|落后|${note:-当前低于推荐}" >> "$csv" ;;
            0)  st_comply=$((st_comply+1)); echo "${c}|${d}|${v}|${base}|合规|${note:-}" >> "$csv" ;;
            1)  st_newer=$((st_newer+1));   echo "${c}|${d}|${v}|${base}|较新|${note:-当前高于推荐（无需降级）}" >> "$csv" ;;
            *)  st_unknown=$((st_unknown+1)); echo "${c}|${d}|${v}|${base}|无法比较|版本格式非标准，需人工核对" >> "$csv" ;;
        esac
    }

    # GPU VBIOS（每卡一行：idx,name,vbios）
    if [ -s "${dir}/gpu_vbios.csv" ] && ! grep -q "NVIDIA-SMI has failed\|No devices were found" "${dir}/gpu_vbios.csv" 2>/dev/null; then
        while IFS=',' read -r gidx gname gvb; do
            [ -z "$gidx" ] && continue
            gname=$(echo "$gname" | sed 's/^ *//;s/ *$//')
            gvb=$(echo "$gvb" | sed 's/^ *//;s/ *$//')
            [ -z "$gvb" ] && continue
            fw_emit "GPU_VBIOS" "GPU${gidx} (${gname})" "$gvb"
        done < <(grep -v "^#" "${dir}/gpu_vbios.csv" 2>/dev/null | grep -v "^$")
    fi

    # BMC（本地优先；远程/HGX BMC 在 12_bmc 采集，此处只判本地）
    if [ -f "${dir}/bmc_mc.log" ]; then
        cur=$(grep -m1 "Firmware Revision" "${dir}/bmc_mc.log" 2>/dev/null | cut -d: -f2- | xargs)
        [ -n "$cur" ] && fw_emit "BMC" "本地BMC" "$cur"
    fi

    # NIC（mlxfwmanager 块解析优先，ethtool 兜底）
    local nic_hit=0
    if [ -s "${dir}/nic_fwmanager.log" ]; then
        # v1.53.39：mlxfwmanager 的真实输出是**表格式**——
        #     Device #1: / Device Type: ConnectX7 / Part Number: ... / PCI Device Name: 0000:03:00.0
        #     Versions:   Current   Available
        #        FW       28.43.2566   N/A
        #   旧解析只认 `Firmware Version:` 行，永远匹配不到（实测这台 10 张网卡一行都没进固件清单）。
        #   现按「Device # 分块 + FW 行取值」解析；设备名优先部件号，其次 BDF。
        local ntype="" nfwv="" nbdf="" npn2="" line
        local _nic_seen=" "
        _fw_nic_flush() {
            [ -z "$nfwv" ] && return 0
            local _lbl="${npn2:-${ntype:-NIC}}"
            # v1.53.39：同型号同版本只记一次（这台 8 张 CX7 部件号/固件完全相同，
            #   按卡逐行会把固件表撑成 9 行冗余）；部件号缺失时才退化为按 BDF 区分
            if [ -n "$npn2" ]; then
                case "$_nic_seen" in *" ${npn2}|${nfwv} "*) return 0 ;; esac
                _nic_seen="${_nic_seen}${npn2}|${nfwv} "
            else
                [ -n "$nbdf" ] && _lbl="${_lbl}（${nbdf}）"
            fi
            fw_emit "NIC" "$_lbl" "$nfwv"
            nic_hit=1
        }
        while IFS= read -r line; do
            case "$line" in
                "Device #"*) _fw_nic_flush; ntype=""; nfwv=""; nbdf=""; npn2="" ;;
                *"Device Type:"*)      ntype=$(printf '%s' "${line#*Device Type:}" | xargs) ;;
                *"Part Number:"*)      npn2=$(printf '%s' "${line#*Part Number:}" | xargs) ;;
                *"PCI Device Name:"*)  nbdf=$(printf '%s' "${line#*PCI Device Name:}" | xargs) ;;
                *"  FW "*)             nfwv=$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="FW"){print $(i+1); exit}}') ;;
            esac
        done < <(grep -v "^#" "${dir}/nic_fwmanager.log" 2>/dev/null)
        _fw_nic_flush
    fi
    if [ "$nic_hit" -eq 0 ]; then
        for _f in "${dir}"/nic_ethtool_*.log; do
            [ -f "$_f" ] || continue
            _n=$(basename "$_f" | sed 's/nic_ethtool_//; s/\.log//')
            cur=$(grep -m1 'firmware-version' "$_f" 2>/dev/null | cut -d: -f2- | xargs)
            [ -n "$cur" ] && { fw_emit "NIC" "$_n" "$cur"; nic_hit=1; }
        done
    fi

    # NIC 固件（来自 nic_inventory.csv，厂商无关；同型号同版本只判一次）
    if [ -f "${_root}/network/nic_inventory.csv" ]; then
        while IFS='|' read -r _nd _nb _nm _ns _npn _nfw _rest; do
            case "$_nd" in ""|"#"*) continue ;; esac
            _npn=$(printf '%s' "$_npn" | xargs); _nfw=$(printf '%s' "$_nfw" | xargs)
            [ -z "$_nfw" ] || [ "$_nfw" = "N/A" ] && continue
            # USB 网卡（接口路径形如 4-1.4:1.0）不是 PCIe 设备，其「固件」是 USB 驱动版本，不进交付固件表
            printf '%s' "$_nb" | grep -qE '^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$' || continue
            # 型号缺失（USB 网卡 part_number 为 N/A）时回退到接口名，避免出现「NIC|N/A」这种行
            _ndev_lbl="$_npn"
            case "$_ndev_lbl" in ""|"N/A") _ndev_lbl="$_nd" ;; esac
            fw_emit "NIC" "$_ndev_lbl" "$_nfw"
        done < <(grep -v "^#" "${_root}/network/nic_inventory.csv" 2>/dev/null | awk -F'|' '!seen[$5"|"$6]++')
    fi

    # v1.53.38：补齐非 NVIDIA 平台的固件判定项（此前 AMD 机 fw_compliance.csv 只有表头，
    #   验收只能判「无固件数据」）。无基线时 fw_emit 会写「未知」，属如实记录而非漏采。
    cur=$(grep -iE "^[[:space:]]*Version:" "${_root}/motherboard/dmidecode_bios.log" 2>/dev/null \
          | head -1 | cut -d: -f2- | xargs)
    [ -n "$cur" ] && fw_emit "BIOS" "主板 BIOS" "$cur"

    if [ -f "${_root}/gpu/gpu_amd_full.log" ]; then
        for cur in $(grep -oE '"VBIOS version":[[:space:]]*"[^"]*"' "${_root}/gpu/gpu_amd_full.log" 2>/dev/null \
                     | cut -d'"' -f4 | sort -u); do
            fw_emit "GPU_VBIOS" "AMD GPU（rocm-smi）" "$cur"
        done
    fi

    # v1.53.39：排除 **USB 盘**（实测 sde 是 PHILIPS USB 闪存，属现场 U 盘，不是交付关注的数据盘）
    _usb_disks=$(grep -vE "^#|^$" "${_root}/storage/block_devices_all.log" 2>/dev/null \
        | awk '{u=0; for(i=2;i<=NF;i++) if($i=="usb") u=1; if(u) print $1}' | tr '\n' ' ')
    for _sf in "${_root}/storage"/smart_*.log "${_root}/storage"/nvme_*_health.log; do
        [ -f "$_sf" ] || continue
        _sdev=$(basename "$_sf" | sed 's/^smart_//; s/_health\.log$//; s/\.log$//')
        case " ${_usb_disks} " in *" ${_sdev} "*) continue ;; esac
        cur=$(grep -m1 -E "^Firmware Version|^Firmware Revision" "$_sf" 2>/dev/null | cut -d: -f2- | xargs)
        [ -n "$cur" ] && fw_emit "STORAGE" "$_sdev" "$cur"
    done

    # NVSwitch 版本（v1.51.3 起来源为 `nvswitch-audit --help`——注意**不加 `| head -1`**：
    # 其 --help 首行是**空行**，加了会让下方解析链整体落空、固件表该行消失，v1.51.3 实测踩坑。
    # 输出形如 "NVIDIA NVSwitch audit tool version 570.86.15"——该工具属 nvidia-fabricmanager 包，
    # 版本号与驱动配套。原来源 `nvswitch --version` 的命令**不存在**，恒为空；
    # v1.48.69 已移除 nvidia-smi nvswitch --version 兜底——该子命令同样不存在，实测 exit=2）
    # 注意：必须先 grep -v '^#' 过滤日志头（"# Command  : ..." 含
    # "--version"/"2>&1"，直接匹配会误取头部导致版本号错乱，v1.29.0 冒烟实测踩坑）
    # 优先精确匹配 Firmware 行（防取到 "Library version" 库版本误判落后）
    cur=$(grep -v "^#" "${dir}/nvswitch_version.log" 2>/dev/null | grep -m1 -iE "Firmware" | grep -oE "[0-9][0-9A-Za-z.]*" | head -1)
    [ -z "$cur" ] && cur=$(grep -v "^#" "${dir}/nvswitch_version.log" 2>/dev/null | grep -m1 -iE "Version" | grep -vi "Library" | grep -oE "[0-9][0-9A-Za-z.]*" | head -1)
    # v1.53.39：NVSwitch 行只在有 NVIDIA GPU 时记录；且注明该值是**工具版本**（nvswitch-audit），
    #   不是 NVSwitch 固件——AMD 机上原本会凭空出现一行「NVSwitch 615.71.09」。
    if has_nvidia_gpu; then
        [ -n "$cur" ] && fw_emit "NVSWITCH" "nvswitch-audit（工具版本）" "$cur"
    fi

    # ─── 判定汇总（追加到 csv 尾部；供报告段直接引用） ───
    {
        echo ""
        echo "summary: 合规 ${st_comply} / 落后 ${st_behind} / 较新 ${st_newer} / 未知或无法比较 ${st_unknown}"
    } >> "$csv"

    write_manifest "${dir}/manifest.txt" \
        "fw_versions" "fw_versions.log" \
        "fw_compliance" "fw_compliance.csv" \
        "gpu_vbios" "gpu_vbios.csv"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_firmware "$1"
fi
