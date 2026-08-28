#!/bin/bash
# =============================================================================
# HwScope - GPU 适配器公共库（v1.47.0，统一检测接口）
# modules/gpu/lib.sh — 由 modules/04_gpu.sh source 装配；各 adapter 复用
# =============================================================================
# 统一 CSV 契约（v1.47.0）：
#   gpu_inventory.csv 列与 nvidia-smi --query-gpu=... --format=csv 完全一致（18 列）——
#   报告端 20_gpu.sh 零改动消费：数量/型号/序列号/BDF/UUID/显存/功耗/温度/利用率/时钟/ECC/PCIe 链路
#   任意厂商适配器输出同一 schema → 显存魔改检测（verify_gpu_mem）/ PCIe 降级检测 / 验收 GPU PCIe 项 自动可用
# 适配器契约：run_gpu_<vendor> <gpu_dir> [prefix]
#   输出：统一 gpu_inventory.csv（prefix 存在时 gpu_inventory_<prefix>.csv，mixed 模式合并用）
#         + 厂商扩展日志/JSON（全量落盘，v1.41.1 原则）
#   工具缺失：调 gpu_fallback_pci 落 PCI 提示 + lspci 层 CSV，返回 1（不中断模块）
# =============================================================================

# ─── 统一 CSV 表头（与 nvidia-smi --format=csv 输出一致）───
GPU_CSV_HEADER="index,name,serial,pci.bus_id,gpu_uuid,memory.total [MiB],memory.used [MiB],power.limit [W],power.draw [W],temperature.gpu,utilization.gpu [%],clocks.current.graphics [MHz],clocks.current.memory [MHz],ecc.mode.current,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max"

# 输出统一 CSV 表头
gpu_csv_header() {
    echo "$GPU_CSV_HEADER"
}

# 输出统一 CSV 单行（缺省 N/A）：
# gpu_csv_row <idx> <name> <serial> <bdf> <uuid> <mem_total> <mem_used> <pwr_limit> <pwr_draw> <temp> <util> <clk_g> <clk_m> <ecc> <gen_cur> <width_cur> <gen_max> <width_max>
# 显存须带 " MiB" 后缀（报告 MiB→GiB 换算）；功耗/温度/利用率/时钟/PCIe 传纯数字
# 字段内逗号会被替换为空格（报告按逗号切列，型号如 "Huawei Technologies Co., Ltd." 含逗号会错位）
gpu_csv_row() {
    local i v line="" 
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
        v="${!i:-N/A}"
        v="${v//, / }"   # "Co., Ltd." → "Co. Ltd."（避免双空格）
        v="${v//,/ }"
        line="${line}${line:+,}${v}"
    done
    echo "$line"
}

# ─── lspci 加速卡行解析 ───
# 输出 "bdf|名称|设备ID"（3D controller / Processing accelerators 类目）
# 参数 $1（可选）：lspci -nn 输出文本；缺省实时执行 lspci -nn
gpu_lspci_accel_rows() {
    local _out="${1:-}"
    if [ -z "$_out" ]; then
        check_cmd lspci || return 0
        _out=$(lspci -nn 2>/dev/null)
    fi
    printf '%s\n' "$_out" | grep -E "3D controller|Processing accelerators" | while IFS= read -r _l; do
        [ -z "$_l" ] && continue
        local _bdf _name _did
        _bdf=$(echo "$_l" | awk '{print $1}')
        # "01:00.0 3D controller [0302]: NVIDIA Corporation GA100 [10de:20b2]"
        _name=$(echo "$_l" | sed 's/^[^ ]* [^[]*\[[0-9a-f]*\]: //; s/ \[[0-9a-f:]*\]$//')
        _did=$(echo "$_l" | grep -oE "\[[0-9a-f]{4}:[0-9a-f]{4}\]$" | tr -d '[]')
        echo "${_bdf}|${_name}|${_did}"
    done
}

# 按厂商名过滤加速卡行（单厂商适配器/混合模式用）：gpu_lspci_accel_rows_filter <grep 模式>
# 大小写敏感（lspci 厂商名为规范大小写；-i 会让 "ATI" 误匹配 "Corporati-on" 等子串）
gpu_lspci_accel_rows_filter() {
    local _pat="$1"
    local _row
    while IFS='|' read -r _bdf _name _did; do
        [ -z "$_bdf" ] && continue
        if [ -z "$_pat" ] || echo "$_name" | grep -qE "$_pat"; then
            echo "${_bdf}|${_name}|${_did}"
        fi
    done < <(gpu_lspci_accel_rows)
}

# ─── lspci -vvv PCIe 链路解析 ───
# 输出 "gen_cur|width_cur|gen_max|width_max"（N/A 缺省；LnkSta 实测 vs LnkCap 额定）
gpu_lspci_pcie() {
    local bdf="$1"
    local vv cap sta gc gw sc sw g1 w1 g2 w2
    vv=$(lspci -vvv -s "$bdf" 2>/dev/null)
    [ -z "$vv" ] && { echo "N/A|N/A|N/A|N/A"; return 0; }
    cap=$(echo "$vv" | grep -m1 "LnkCap:")
    sta=$(echo "$vv" | grep -m1 "LnkSta:")
    gc=$(echo "$cap" | grep -oE "[0-9.]+GT/s" | head -1)
    gw=$(echo "$cap" | grep -oE "x[0-9]+" | head -1 | tr -d 'x')
    sc=$(echo "$sta" | grep -oE "[0-9.]+GT/s" | head -1)
    sw=$(echo "$sta" | grep -oE "x[0-9]+" | head -1 | tr -d 'x')
    g1="N/A"; g2="N/A"; w1="N/A"; w2="N/A"
    case "$gc" in 2.5GT/s) g2=1;; 5GT/s) g2=2;; 8GT/s) g2=3;; 16GT/s) g2=4;; 32GT/s) g2=5;; 64GT/s) g2=6;; esac
    case "$sc" in 2.5GT/s) g1=1;; 5GT/s) g1=2;; 8GT/s) g1=3;; 16GT/s) g1=4;; 32GT/s) g1=5;; 64GT/s) g1=6;; esac
    [ -n "$gw" ] && w2="$gw"; [ -n "$sw" ] && w1="$sw"
    echo "${g1}|${w1}|${g2}|${w2}"
}

# ─── 从 lspci 生成统一 CSV（PCI 层保底：名称/BDF/PCIe 链路，其余 N/A）───
# gpu_csv_from_lspci <dir> [prefix] [厂商过滤模式]
# 厂商过滤模式示例："Huawei|HiSilicon" / "Advanced Micro Devices|AMD|ATI"；空=全部加速卡
gpu_csv_from_lspci() {
    local dir="$1" prefix="${2:-}" pat="${3:-}"
    local csv
    if [ -n "$prefix" ]; then csv="${dir}/gpu_inventory_${prefix}.csv"; else csv="${dir}/gpu_inventory.csv"; fi
    gpu_csv_header > "$csv"
    local _i=0 _row _bdf _name _did _p _gc _wc _gm _wm
    while IFS='|' read -r _bdf _name _did; do
        [ -z "$_bdf" ] && continue
        _p=$(gpu_lspci_pcie "$_bdf")
        IFS='|' read -r _gc _wc _gm _wm <<< "$_p"
        if [ -n "$prefix" ]; then
            gpu_csv_row "${prefix}_${_i}" "$_name" "N/A" "$_bdf" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "$_gc" "$_wc" "$_gm" "$_wm" >> "$csv"
        else
            gpu_csv_row "$_i" "$_name" "N/A" "$_bdf" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "$_gc" "$_wc" "$_gm" "$_wm" >> "$csv"
        fi
        _i=$((_i + 1))
    done < <(gpu_lspci_accel_rows_filter "$pat")
}

# ─── 工具缺失兜底：PCI 提示 + lspci 层统一 CSV（报告"驱动未装"展示，不误报无 GPU）───
# gpu_fallback_pci <dir> [prefix] <工具名> [厂商过滤模式]
gpu_fallback_pci() {
    local dir="$1" prefix="${2:-}" tool="$3" pat="${4:-}"
    {
        echo "# GPU PCI detected but no vendor tool (${tool})"
        echo "# Vendor line: $(lspci 2>/dev/null | grep -m1 -E '3D controller|Processing accelerators')"
    } > "${dir}/gpu_pci_only.log"
    gpu_csv_from_lspci "$dir" "$prefix" "$pat"
    echo -e "${YELLOW}[WARN] 检测到 ${GPU_PCI_PRESENT:-0} 个 GPU（${GPU_PCI_VENDORS:-${GPU_PCI_VENDOR:-未知}}）但 ${tool} 未安装——仅 lspci 层采集（PCIe 链路可判，显存/温度等 N/A）${NC}"
    return 1
}

# ─── mixed 模式：合并 gpu_inventory_<vendor>.csv → gpu_inventory.csv ───
# 各适配器写 gpu_inventory_<prefix>.csv（行内 index 带 prefix，与 per-card 日志名对应）
# 剥离 run_and_log 包装注释（# 开头）与各文件表头（每文件尾 -n +2 去自身表头，保留合并表头）
gpu_merge_inventory() {
    local dir="$1" csv="${dir}/gpu_inventory.csv"
    gpu_csv_header > "$csv"
    local f
    for f in "${dir}"/gpu_inventory_*.csv; do
        [ -f "$f" ] || continue
        grep -v "^#" "$f" | tail -n +2 >> "$csv"
    done
}

# ─── 厂商显示名 → 平台 id（detect_gpu_vendors 的 GPU_PCI_VENDORS 名 → GPU_PLATFORM 值）───
gpu_vendor_to_platform() {
    case "$1" in
        NVIDIA) echo "nvidia" ;;
        AMD|ATI|"Advanced Micro Devices") echo "amd" ;;
        Ascend|Huawei|HiSilicon) echo "ascend" ;;
        Intel) echo "intel" ;;
        *) echo "other" ;;
    esac
}

# 单适配器完成：--append 写 manifest（键不冲突；mixed 合并后 04_gpu.sh 再追加 gpu_inventory）
gpu_adapter_manifest() {
    local dir="$1"; shift
    write_manifest --append "${dir}/manifest.txt" "$@"
}

# ─── 通用工具型适配器（Intel/国产等：工具存在 → 全量命令组落盘 + lspci 层 CSV；缺失 → 兜底）───
# gpu_run_tool_adapter <dir> <prefix> <工具名> <厂商过滤模式> <显示名> <key:文件>...
# 后续 (cmd, logfile) 对为采集命令组；logfile 为相对 gpu/ 的文件名
gpu_run_tool_adapter() {
    local dir="$1" prefix="$2" tool="$3" pat="$4" label="$5"; shift 5
    if ! check_cmd "$tool"; then
        gpu_fallback_pci "$dir" "$prefix" "$tool" "$pat"
        return 1
    fi
    echo -e "${CYAN}[INFO] 检测到 ${label}（${tool}），走厂商采集路径${NC}"
    local jobs=()
    while [ $# -ge 2 ]; do
        jobs+=("$1" "${dir}/$2"); shift 2
    done
    run_and_log_parallel 4 "${jobs[@]}"
    gpu_csv_from_lspci "$dir" "$prefix" "$pat"
    local inv_csv="gpu_inventory.csv"
    [ -n "$prefix" ] && inv_csv="gpu_inventory_${prefix}.csv"
    write_manifest --append "${dir}/manifest.txt" "gpu_inventory" "${inv_csv}"
}
