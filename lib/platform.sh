#!/bin/bash
# =============================================================================
# HwScope 平台检测函数库
# lib/platform.sh
# 功能：机器标识、平台架构检测、GPU 计数、IPMI 预热
# =============================================================================

# ─── 机器标识（SN/UUID，fallback 时间戳）───
detect_machine_id() {
    local mid=""
    if check_cmd dmidecode; then
        mid=$(dmidecode -t system 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        [ -z "$mid" ] && mid=$(dmidecode -t baseboard 2>/dev/null | grep -i 'Serial Number' | grep -v 'Not Specified' | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        [ -z "$mid" ] && mid=$(dmidecode -t system 2>/dev/null | grep -i 'UUID' | head -1 | awk -F': ' '{print $2}' | tr -d ' -')
    fi
    # 占位 SN 过滤（OEM 默认值）+ 路径安全清洗（仅字母数字与 -_，防流入目录名/tar 包名/sed）
    [ -z "$mid" ] || echo "$mid" | grep -qiE "To Be Filled|O\.E\.M\.|Default string|System Serial|Not Specified|Unknown|None" && mid=""
    mid=$(echo "$mid" | tr -cd 'A-Za-z0-9_-')
    [ -z "$mid" ] && mid=$(date '+%Y%m%d%H%M%S')
    echo "$mid"
}

# ─── 平台架构检测（x86_64_SXM / x86_64_PCIe / x86_64_head / x86_64_none / aarch64_SXM ...）───
# 设置全局变量：GPU_COUNT, PLATFORM
# head（HGX 机头）：PCIe Gen5 Fabric Switch（PEX89xxx/PEX97xxx/Switchtec）+ 非 SXM + 无 GPU。
#   机头无本地 GPU，经 Switch 接 HGX 模组；裸机采集稳定判 head。模组接入后 GPU 透传可见 → 按事实判 PCIe
#   （报告含模组 GPU 数据）；SXM 一体化主机（B300 等主板也带 PEX89）因有 GPU 不受 head 判定影响。
detect_platform() {
    local hw_arch
    hw_arch=$(uname -m 2>/dev/null || echo "unknown")
    PLATFORM="${hw_arch}"
    GPU_COUNT=0

    if check_cmd nvidia-smi; then
        # 注意：pipefail 下 nvidia-smi 非零退出时 `| wc -l || echo 0` 会双输出（wc 的计数 + echo 的 0），
        # 产生 "2\n0" 多行值 → 后续 -gt 比较报 integer expression expected、PLATFORM 误判 none（v1.26.53 真机踩坑）
        # wc 空输入必输出 0（exit 0），无需 || 兜底；再清洗为纯数字防御多行
        GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
        GPU_COUNT=$(echo "$GPU_COUNT" | head -1 | tr -dc '0-9')
        [ -z "$GPU_COUNT" ] && GPU_COUNT=0
        # SXM 四重检测：nvswitch CLI → lspci NVSwitch → nv-fabricmanager 进程(需 NVLink 交叉验证) → nvidia-smi topo
        local _sxm=0
        if check_cmd nvswitch && nvswitch -q 2>/dev/null | grep -qi "Switch Name"; then
            _sxm=1
        elif check_cmd lspci && lspci 2>/dev/null | grep -qi "NVSwitch\|SXM.*Bridge"; then
            _sxm=1
        elif pgrep -f nv-fabricmanager >/dev/null 2>&1; then
            # 进程检测有误判风险：交叉验证 NVLink 是否存在（SXM 机器必有 NVLink）
            if nvidia-smi nvlink --status 2>/dev/null | grep -qi "GPU\|active\|link"; then
                _sxm=1
            fi
        fi
        # HGX 机头检测：PCIe Gen5 Fabric Switch（Broadcom PEX89xxx / PLX PEX97xxx / Microchip Switchtec）+ 无 GPU
        # 注意必须叠加"无 GPU"条件：SXM 一体化主机（如华硕 HGX B300）主板也带 PEX89xxx Switch，
        # 若 SXM 检测失效且有 GPU，仍按 PCIe 事实判定，避免整机漂移为 head
        local _head=0
        if [ "$GPU_COUNT" -eq 0 ] && check_cmd lspci && lspci 2>/dev/null | grep -qiE "PEX89|PEX97|Switchtec"; then
            _head=1
        fi
        if [ "$_sxm" -eq 1 ]; then
            PLATFORM="${hw_arch}_SXM"
        elif [ "$_head" -eq 1 ]; then
            PLATFORM="${hw_arch}_head"
        elif [ "$GPU_COUNT" -gt 0 ]; then
            PLATFORM="${hw_arch}_PCIe"
        else
            PLATFORM="${hw_arch}_none"
        fi
    else
        # 无 nvidia-smi：检测 AMD/昇腾等独立 GPU（v1.46.6 多平台——NVIDIA 走 nvidia-smi，
        # 其他厂商走 lspci 3D controller/Processing accelerators 判定，避免 AMD/昇腾机器被误判为 none/head）
        detect_gpu_vendors
        if [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
            # 有独立 GPU（AMD/Ascend/Intel 等）→ PCIe 形态（NVIDIA SXM 才走 _sxm 分支）
            # v1.48.0：AMD OAM 模组（device ID 判定的 MI250X/MI300X/MI325X）→ x86_64_OAM
            if [ "${GPU_OAM:-0}" -eq 1 ] 2>/dev/null; then
                PLATFORM="${hw_arch}_OAM"
            else
                PLATFORM="${hw_arch}_PCIe"
            fi
        elif check_cmd lspci && lspci 2>/dev/null | grep -qiE "PEX89|PEX97|Switchtec"; then
            PLATFORM="${hw_arch}_head"
        else
            PLATFORM="${hw_arch}_none"
        fi
    fi
}

# ─── IPMI 预热（虚空跑一次 mc info，触发驱动加载，避免首次命令失败）───
ipmi_preheat() {
    if [ "${IPMI_PREHEAT:-1}" -ne 1 ] 2>/dev/null || ! check_cmd ipmitool; then
        return 0
    fi
    ipmitool mc info >/dev/null 2>&1
}


# ─── GPU 厂商检测（v1.46.2，单一实现——采集端 04_gpu / 报告端 20_gpu 共用）───
# 设置全局变量：GPU_PCI_PRESENT（3D controller/Processing accelerators 加速卡数）、GPU_PCI_VENDORS（厂商分组 "AMD:8 NVIDIA:2"）、
#   GPU_PCI_VENDOR（首个厂商，单厂商场景直接可用）、GPU_PLATFORM（nvidia/amd/ascend/intel/mixed/other/none）、
#   GPU_OAM（AMD Instinct OAM 模组标记，v1.48.0：device ID 属 OAM 型号 → 1）
# 参数 $1（可选）：lspci 日志文件路径——报告端只读日志传此参；采集端实时检测不传（内部调 lspci）
# 厂商判定：昇腾（Huawei/HiSilicon）→ NVIDIA → AMD → Intel → 其他；VGA compatible 集显不算独立 GPU
# v1.46.7 类目扩展：华为昇腾卡 lspci 类目为 "Processing accelerators"（非 3D controller），须一并匹配
# v1.48.0 OAM 识别：AMD 卡 device ID（lspci -nn [1002:xxxx]）属 OAM 模组型号（MI250X/MI300X/MI325X）→ GPU_OAM=1；
#   ID 表【待真机校准】——真机样本核对后再增补 MI355X 等新号
detect_gpu_vendors() {
    local _src="${1:-}"
    local _lspci_out=""
    if [ -n "$_src" ] && [ -f "$_src" ]; then
        _lspci_out=$(cat "$_src")
    elif check_cmd lspci; then
        _lspci_out=$(lspci 2>/dev/null)
    fi
    GPU_PCI_PRESENT=0
    GPU_PCI_VENDOR=""
    GPU_PCI_VENDORS=""
    GPU_PLATFORM="none"
    GPU_OAM=0
    [ -z "$_lspci_out" ] && {
        # v1.48.17：WSL 等无 lspci 平台兜底——nvidia-smi 有卡则判 NVIDIA（仅采集端无 _src 时；
        # 报告端传日志 _src 有文件不会到这，保持只读）
        if [ -z "$_src" ] && check_cmd nvidia-smi && nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | grep -q .; then
            GPU_PCI_PRESENT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
            GPU_PCI_PRESENT=$(echo "$GPU_PCI_PRESENT" | head -1 | tr -dc '0-9')
            [ -z "$GPU_PCI_PRESENT" ] && GPU_PCI_PRESENT=0
            GPU_PCI_VENDOR="NVIDIA"
            GPU_PCI_VENDORS="NVIDIA:${GPU_PCI_PRESENT}"
            GPU_PLATFORM="nvidia"
        fi
        return 0
    }
    # GPU 类目: NVIDIA/AMD/Intel 独立显卡为 "3D controller"; 华为昇腾等加速卡为 "Processing accelerators"
    # v1.48.15：sed 提取容忍类目码后缀 [1200]（lspci -vvv 输出 `Processing accelerators [1200]:`，
    # 实时 lspci 简版无后缀——此前仅简版匹配，报告端读 -vvv 日志厂商提取失败 → 误判 other）
    GPU_PCI_PRESENT=$(printf '%s\n' "$_lspci_out" | grep -cE "3D controller|Processing accelerators")
    [ -z "$GPU_PCI_PRESENT" ] && GPU_PCI_PRESENT=0
    if [ "$GPU_PCI_PRESENT" -gt 0 ] 2>/dev/null; then
        GPU_PCI_VENDORS=$(printf '%s\n' "$_lspci_out" | grep -E "3D controller|Processing accelerators" | sed -n 's/.*\(3D controller\|Processing accelerators\)[^:]*: //p' | while IFS= read -r _gl; do
            case "$_gl" in
                *NVIDIA*) echo "NVIDIA" ;;
                *"Advanced Micro Devices"*|*AMD*|*ATI*) echo "AMD" ;;
                *Huawei*|*HiSilicon*) echo "Ascend" ;;
                *Intel*) echo "Intel" ;;
                *) echo "Other" ;;
            esac
        done | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}' | sed 's/ $//')
        GPU_PCI_VENDOR=$(echo "$GPU_PCI_VENDORS" | awk -F'[: ]' '{print $1}')
        _gv_count=$(echo "$GPU_PCI_VENDORS" | grep -oE ":" | wc -l)
        if [ "$_gv_count" -gt 1 ]; then
            GPU_PLATFORM="mixed"
        else
            case "$GPU_PCI_VENDOR" in
                NVIDIA) GPU_PLATFORM="nvidia" ;;
                AMD) GPU_PLATFORM="amd" ;;
                Ascend) GPU_PLATFORM="ascend" ;;
                Intel) GPU_PLATFORM="intel" ;;
                *) GPU_PLATFORM="other" ;;
            esac
        fi
        # ─── AMD OAM 模组判定（v1.48.0）───
        # v1.48.1 只读修复：实时补查 lspci -nn 仅限采集端（未传 _src）；报告端（传日志）无 ID 时
        # GPU_OAM 安全降级为 0（不实时执行命令——报告只读原则；v1.48.1 起采集端 lspci_all.log 已含 -nn ID）
        if [ "$GPU_PLATFORM" = "amd" ]; then
            local _nn_out="$_lspci_out"
            if ! printf '%s\n' "$_nn_out" | grep -qE "\[1002:[0-9a-fA-F]{4}\]"; then
                if [ -z "$_src" ]; then
                    check_cmd lspci && _nn_out=$(lspci -nn 2>/dev/null)
                else
                    _nn_out=""    # 报告端旧采集（无 device ID）：OAM 判不出，跳过
                fi
            fi
            if [ -n "$_nn_out" ]; then
                local _aid _oam=1 _n=0
                for _aid in $(printf '%s\n' "$_nn_out" | grep -E "3D controller|Processing accelerators" \
                        | grep -iE "Advanced Micro Devices|AMD|ATI" | grep -oE "1002:[0-9a-fA-F]{4}" | cut -d: -f2 | sort -u); do
                    _n=$((_n + 1))
                    case "$_aid" in
                        7408|74a1|74c2) ;;   # MI250X/MI300X/MI325X OAM 模组（ID 待真机校准）
                        *) _oam=0 ;;
                    esac
                done
                [ "$_n" -gt 0 ] && [ "$_oam" -eq 1 ] && GPU_OAM=1
            fi
        fi
    fi
}

# ─── 设备形态分类（v1.46.2）───
# 设置全局变量：MACHINE_CLASS（laptop/aio/desktop/workstation-consumer/workstation-server/
#   server-traditional/server-nvidia-gpu/server-amd-gpu/server-gpu-other/server-gpu-head/server-gb300/unknown）
# 信号优先级：BMC 存在 > dmidecode Chassis Type > CPU ECC > GPU 类型/厂商 > GPU 数量 > PCIe Fabric Switch（机头）
# 参数 $1（可选）：输出目录——报告端传此参（只读日志：motherboard/dmidecode_chassis.log 等 + BMC_PRESENT）；
#   采集端不传（实时 dmidecode/ipmitool 探测）
classify_machine() {
    local _dir="${1:-}"
    MACHINE_CLASS="unknown"
    local _chassis="" _ecc=0 _bmc=0
    if [ -n "$_dir" ]; then
        # 报告端：只读日志 + 已判定变量（零新采集）
        if [ -f "$_dir/motherboard/dmidecode_chassis.log" ]; then
            _chassis=$(grep -i "Type:" "$_dir/motherboard/dmidecode_chassis.log" | head -1 | sed 's/.*Type: *//I')
        fi
        if [ -f "$_dir/memory/dmidecode_memory_full.log" ] && grep -qiE "Error Correction.*(Multi-bit|Single-bit|Parity)" "$_dir/memory/dmidecode_memory_full.log"; then
            _ecc=1
        fi
        _bmc=${BMC_PRESENT:-0}
    else
        # 采集端：实时探测
        if check_cmd dmidecode; then
            _chassis=$(dmidecode -t chassis 2>/dev/null | grep -i "Type:" | head -1 | sed 's/.*Type: *//I')
        fi
        if check_cmd dmidecode && dmidecode -t memory 2>/dev/null | grep -qiE "Error Correction.*(Multi-bit|Single-bit|Parity)"; then
            _ecc=1
        fi
        if check_cmd ipmitool && ipmitool mc info 2>/dev/null | grep -qi "Manufacturer"; then
            _bmc=1
        fi
    fi
    # GPU 类型信号
    local _gpu_cnt=0
    [ -n "${GPU_PCI_PRESENT:-}" ] && _gpu_cnt=$GPU_PCI_PRESENT
    local _gpu_plat="${GPU_PLATFORM:-none}"
    # v1.48.26：PCIe Gen5 Fabric Switch（PEX89xxx/PEX97xxx/Switchtec）——8-GPU HGX 底座的机头特征
    # 无 GPU 但有 Fabric = HGX 机头（GPU 模组未装/待装/另采），非传统服务器（真机 AMAX ESC N8-E11V 误判教训）
    local _fabric=0
    if [ -n "$_dir" ]; then
        [ -f "$_dir/pcie/lspci_all.log" ] && grep -qiE "PEX89|PEX97|Switchtec" "$_dir/pcie/lspci_all.log" && _fabric=1
    elif check_cmd lspci; then
        lspci 2>/dev/null | grep -qiE "PEX89|PEX97|Switchtec" && _fabric=1
    fi

    case "$_chassis" in
        *Portable*|*Notebook*|*Laptop*|*"Sub Notebook"*|*Tablet*)
            MACHINE_CLASS="laptop" ;;
        *"All in One"*|*"All-in-One"*)
            MACHINE_CLASS="aio" ;;
        *Rack*|*Blade*|*"Main Server"*|*"Multi-system"*)
            # 机架/刀片 → 服务器（按 GPU 类型细分；v1.48.26 无 GPU 但有 Fabric Switch = HGX 机头）
            if [ "$_gpu_cnt" -gt 0 ] 2>/dev/null; then
                case "$_gpu_plat" in
                    nvidia) MACHINE_CLASS="server-nvidia-gpu" ;;
                    amd)    MACHINE_CLASS="server-amd-gpu" ;;
                    *)      MACHINE_CLASS="server-gpu-other" ;;
                esac
            elif [ "$_fabric" -eq 1 ]; then
                MACHINE_CLASS="server-gpu-head"
            else
                MACHINE_CLASS="server-traditional"
            fi ;;
        *Tower*|*Mini*Tower*|*"Mini Tower"*|*Desktop*|*"Low Profile"*|*"Space-saving"*|*"Mini PC"*)
            # 塔式/台式：BMC+GPU → 服务器版工作站；ECC+GPU → 工作站；仅 ECC → 服务器版工作站；其余台式
            if [ "$_bmc" -eq 1 ] && [ "$_gpu_cnt" -gt 0 ] 2>/dev/null; then
                MACHINE_CLASS="workstation-server"
            elif [ "$_ecc" -eq 1 ] && [ "$_gpu_cnt" -gt 0 ] 2>/dev/null; then
                MACHINE_CLASS="workstation-consumer"
            elif [ "$_ecc" -eq 1 ]; then
                MACHINE_CLASS="workstation-server"
            else
                MACHINE_CLASS="desktop"
            fi ;;
        *)
            # Chassis 未知：BMC+GPU → GPU 服务器；仅 BMC → Fabric 判定（机头）否则传统；GPU+ECC → 工作站；其余按 GPU 兜底
            if [ "$_bmc" -eq 1 ] && [ "$_gpu_cnt" -gt 0 ] 2>/dev/null; then
                case "$_gpu_plat" in
                    nvidia) MACHINE_CLASS="server-nvidia-gpu" ;;
                    amd)    MACHINE_CLASS="server-amd-gpu" ;;
                    *)      MACHINE_CLASS="server-gpu-other" ;;
                esac
            elif [ "$_bmc" -eq 1 ]; then
                [ "$_fabric" -eq 1 ] && MACHINE_CLASS="server-gpu-head" || MACHINE_CLASS="server-traditional"
            elif [ "$_ecc" -eq 1 ]; then
                MACHINE_CLASS="workstation-server"
            elif [ "$_gpu_cnt" -gt 0 ] 2>/dev/null; then
                MACHINE_CLASS="workstation-consumer"
            else
                MACHINE_CLASS="desktop"
            fi ;;
    esac
    # GB300 机架级（v1.46.2 特征占位：GB300 NVL72 液冷——GPU 温度极低 + 无风扇传感器 + 大量 NVLink）
    # v1.46.3 只读修复：报告端（_dir 模式）从 gpu 日志判断，不再调 nvidia-smi（报告只读原则）
    if [ "$MACHINE_CLASS" = "server-nvidia-gpu" ]; then
        _gb300=0
        if [ -n "$_dir" ]; then
            grep -qiE "GB300|GB200" "$_dir/gpu/gpu_full.log" 2>/dev/null && _gb300=1
        elif command -v nvidia-smi >/dev/null 2>&1; then
            nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | grep -qi "GB300\|GB200" && _gb300=1
        fi
        [ "$_gb300" -eq 1 ] && MACHINE_CLASS="server-gb300"
    fi
    # 中文标签（gen 渲染用；随 MACHINE_CLASS 同步计算，勿放 sections——那时 MACHINE_CLASS 未就绪）
    case "$MACHINE_CLASS" in
        laptop) MACHINE_CLASS_LABEL="笔记本" ;;
        aio) MACHINE_CLASS_LABEL="一体机" ;;
        desktop) MACHINE_CLASS_LABEL="台式机" ;;
        workstation-consumer) MACHINE_CLASS_LABEL="工作站（消费版）" ;;
        workstation-server) MACHINE_CLASS_LABEL="工作站（服务器版）" ;;
        server-traditional) MACHINE_CLASS_LABEL="传统服务器" ;;
        server-nvidia-gpu) MACHINE_CLASS_LABEL="NVIDIA GPU 服务器" ;;
        server-amd-gpu) MACHINE_CLASS_LABEL="AMD GPU 服务器" ;;
        server-gpu-other) MACHINE_CLASS_LABEL="其他 GPU 服务器" ;;
        server-gpu-head) MACHINE_CLASS_LABEL="HGX 机头（PCIe Fabric 底座，GPU 模组另采）" ;;
        server-gb300) MACHINE_CLASS_LABEL="GB300 机架服务器" ;;
        *) MACHINE_CLASS_LABEL="" ;;
    esac
}
