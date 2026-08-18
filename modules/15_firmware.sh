#!/bin/bash
# =============================================================================
# 模块: 15_firmware.sh — 固件合规模块
# 输出目录: <OUTPUT_DIR>/firmware/
# 功能: 采集 GPU VBIOS / BMC FW / NIC FW / NVSwitch FW 版本，
#       对照 conf/fw_required.txt（厂商推荐基线）逐项判定 合规/落后/较新/未知。
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
    run_and_log_parallel 4 \
        "nvidia-smi --query-gpu=index,name,vbios_version --format=csv,noheader 2>&1" "${dir}/gpu_vbios.csv" \
        "ipmitool mc info 2>&1" "${dir}/bmc_mc.log" \
        "mlxfwmanager --query 2>&1" "${dir}/nic_fwmanager.log" \
        "nvswitch --version 2>&1" "${dir}/nvswitch_version.log" \
        "nvidia-smi nvswitch --version 2>&1" "${dir}/nvswitch_smi_version.log"

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

    # ─── 汇总原始版本清单（fw_versions.log，供人工核阅） ───
    {
        echo "# HwScope 固件版本清单 $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "## GPU VBIOS"
        grep -v "^#" "${dir}/gpu_vbios.csv" 2>/dev/null | grep -v "^$" | sed 's/^/  /'
        echo ""
        echo "## BMC"
        grep -iE "Firmware Revision" "${dir}/bmc_mc.log" 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "## NIC (mlxfwmanager)"
        grep -E "Device Type:|Firmware Version:|PCI Device Name:" "${dir}/nic_fwmanager.log" 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "## NIC (ethtool 兜底)"
        local _f _n
        for _f in "${dir}"/nic_ethtool_*.log; do
            [ -f "$_f" ] || continue
            _n=$(basename "$_f" | sed 's/nic_ethtool_//; s/\.log//')
            echo "  $_n: $(grep -m1 'firmware-version' "$_f" 2>/dev/null | cut -d: -f2- | xargs)"
        done
        echo ""
        echo "## NVSwitch"
        grep -v "^#" "${dir}/nvswitch_version.log" 2>/dev/null | grep -iE "Version|Firmware" | sed 's/^/  /'
        grep -v "^#" "${dir}/nvswitch_smi_version.log" 2>/dev/null | grep -iE "Version|Firmware" | sed 's/^/  /'
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
        local ntype="" nfwv="" nbdf="" line
        while IFS= read -r line; do
            case "$line" in
                "Device #"*) [ -n "$ntype" ] && [ -n "$nfwv" ] && { fw_emit "NIC" "${nbdf:+${nbdf} }${ntype}" "$nfwv"; nic_hit=1; }
                             ntype=""; nfwv=""; nbdf="" ;;
                *"Device Type:"*)      ntype=$(echo "$line" | cut -d: -f2- | xargs) ;;
                *"Firmware Version:"*) nfwv=$(echo "$line" | cut -d: -f2- | xargs) ;;
                *"PCI Device Name:"*)  nbdf=$(echo "$line" | cut -d: -f2- | xargs) ;;
            esac
        done < <(grep -v "^#" "${dir}/nic_fwmanager.log" 2>/dev/null)
        [ -n "$ntype" ] && [ -n "$nfwv" ] && { fw_emit "NIC" "${nbdf:+${nbdf} }${ntype}" "$nfwv"; nic_hit=1; }
    fi
    if [ "$nic_hit" -eq 0 ]; then
        for _f in "${dir}"/nic_ethtool_*.log; do
            [ -f "$_f" ] || continue
            _n=$(basename "$_f" | sed 's/nic_ethtool_//; s/\.log//')
            cur=$(grep -m1 'firmware-version' "$_f" 2>/dev/null | cut -d: -f2- | xargs)
            [ -n "$cur" ] && { fw_emit "NIC" "$_n" "$cur"; nic_hit=1; }
        done
    fi

    # NVSwitch（nvswitch --version 优先，nvidia-smi nvswitch --version 兜底）
    # 注意：必须先 grep -v '^#' 过滤日志头（"# Command  : nvswitch --version 2>&1" 含
    # "--version"/"2>&1"，直接匹配会误取头部导致版本号错乱，v1.29.0 冒烟实测踩坑）
    # 优先精确匹配 Firmware 行（防取到 "Library version" 库版本误判落后）
    cur=$(grep -v "^#" "${dir}/nvswitch_version.log" 2>/dev/null | grep -m1 -iE "Firmware" | grep -oE "[0-9][0-9A-Za-z.]*" | head -1)
    [ -z "$cur" ] && cur=$(grep -v "^#" "${dir}/nvswitch_version.log" 2>/dev/null | grep -m1 -iE "Version" | grep -vi "Library" | grep -oE "[0-9][0-9A-Za-z.]*" | head -1)
    [ -z "$cur" ] && cur=$(grep -v "^#" "${dir}/nvswitch_smi_version.log" 2>/dev/null | grep -m1 -iE "Firmware|Version" | grep -oE "[0-9][0-9A-Za-z.]*" | head -1)
    [ -n "$cur" ] && fw_emit "NVSWITCH" "NVSwitch" "$cur"

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
