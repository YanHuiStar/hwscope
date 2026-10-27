#!/bin/bash
# =============================================================================
# HwScope - 网卡归类统计（计算网卡 / DPU / 网卡&端口，按「张」与「口」双口径）
#   v1.54.32：从 gen_acceptance.sh 抽出——原来这段统计只服务验收清单「硬件概览」，
#   报告「网络」段想显示「计算网卡 张/口」时只能重复实现一遍，同一台机会得出
#   「9 张」与「0 张」两个答案（实测 B300：概览 9 张，网络段按 topo 标记算出 0）。
#   现在一处计算、三端共用（验收概览 / 报告网络段 / JSON 如需）。
#   依赖：60_nic_fan_temp.sh 的 NIC_DETAILS、GPU_TOPO_AVAIL（source 顺序即保证）
# =============================================================================
ACC_NIC_IB="N/A"; ACC_NIC_IB_COUNT=0; ACC_NIC_IB_PORT=0; ACC_NIC_ETH="N/A"; ACC_NIC_ETH_COUNT=0; ACC_NIC_ETH_PORT=0
ACC_NIC_DPU="N/A"; ACC_NIC_DPU_COUNT=0; ACC_NIC_DPU_PORT=0
# v1.49.15：按「卡」记录口数分布——配置单要能看出"每张卡几口"（用户要求）。
#   口数取 nport 的分母（形如 1/2 → 2 口）；分布串如 "1口×8" / "2口×1+4口×1"。
declare -A _ib_dist _eth_dist _dpu_dist _ib_model_ports _eth_model_ports
_card_ports() { printf '%s' "${1:-1/1}" | awk -F/ '{p=$2+0; print (p>0)?p:1}'; }
_dist_add() {   # $1=分布串引用名 $2=口数  → 递增计数（用全局数组避免 nameref 兼容问题）
    local _n=$2
    case "$1" in
        ib)  _ib_dist[$_n]=$(( ${_ib_dist[$_n]:-0} + 1 )) ;;
        dpu) _dpu_dist[$_n]=$(( ${_dpu_dist[$_n]:-0} + 1 )) ;;
        *)   _eth_dist[$_n]=$(( ${_eth_dist[$_n]:-0} + 1 )) ;;
    esac
}
_port_name() {   # v1.49.17：口数用行业叫法（Intel/NVIDIA 官方 Single/Dual/Quad-Port）
    case "$1" in
        1) printf '单口' ;; 2) printf '双口' ;; 3) printf '三口' ;;
        4) printf '四口' ;; 8) printf '八口' ;; *) printf '%s 口' "$1" ;;
    esac
}
_dist_str() {   # $1=ib|dpu|eth → "1口×8" / "2口×1+4口×1"（口数升序）
    local _k _out=""
    case "$1" in
        ib)  for _k in $(printf '%s\n' "${!_ib_dist[@]}" | sort -n); do _out="${_out}${_out:+ + }$(_port_name "$_k")×${_ib_dist[$_k]}"; done ;;
        dpu) for _k in $(printf '%s\n' "${!_dpu_dist[@]}" | sort -n); do _out="${_out}${_out:+ + }$(_port_name "$_k")×${_dpu_dist[$_k]}"; done ;;
        *)   for _k in $(printf '%s\n' "${!_eth_dist[@]}" | sort -n); do _out="${_out}${_out:+ + }$(_port_name "$_k")×${_eth_dist[$_k]}"; done ;;
    esac
    printf '%s' "$_out"
}
# 注：型号的口数后缀由 sections/60_nic_fan_temp.sh 统一拼接（一处生效三端），
#   此处直接用 $_nm，勿再加一次（曾导致「（2 口）（2 口）」重复）。
# v1.49.8：数量单位由「口」改「张」——nport 列形如 `1/2`（该卡第 1 口 / 共 2 口），
#   只数「第 1 口」的行，每行 = 1 张物理卡。旧实现每端口 +1，导致「双口卡 ×2 + 板载 ×1」
#   被写成「5 口」，与配置单的「张」对不上（实测 DGX A100：5 口实为 3 张卡）。
#   nport 为空（老采集/无该字段）时按单口卡处理，保持向后兼容。
#   另累计 *口数* 供硬件概览显示「N 张（M 口）」。
_nic_is_card_head() { case "${1:-1/1}" in 1/*|"") return 0 ;; *) return 1 ;; esac; }
if [ -n "$NIC_DETAILS" ]; then
    while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip nport nlink nloc; do
        [ -z "$nnic" ] && continue
        # v1.48.85：归类判据改为「物理直连」而非「接口名」——
        #   ① DPU（BlueField 系列）优先判定：它可能同时 GPU 直连（实测 BlueField-3 挂在 GPU 下游），
        #      先判 DPU 才不会在两个桶里各统计一次
        #   ② 标记为 GPU直连（nvidia-smi topo PIX = 与 GPU 同 PCIe switch）→ 计算网卡
        #   ③ 其余 → 网卡&端口
        # 旧实现按接口名 ^ib 归类（= 当前跑 IB 模式），判的是**可配置的模式**而非物理直连：
        #   实测 B200-sample-c 上 18 口真 GPU 直连网卡全跑 ETH 模式而被划入「以太」，
        #   唯一跑 IB 的 CX-7（PCIe 仅 x2、物理位置 M2_1、不在 GPU 域）反被当成计算网卡。
        #   v1.43.10 当时按 ConnectX|MCX 前缀归类失效，改为接口名是"打补丁"；本次从物理属性重新定义。
        # v1.49.15：型号清理必须**保护口数后缀**——原 `s/ for 10GBASE-T.*//` 贪婪，
        #   会把 60 段拼上的「（2 口）」一起吃成 `X710`（实测 X710 双口卡在概览里丢了口数）。
        #   做法：先摘出后缀 → 再清理冗长前缀/rev → 最后拼回。
        # v1.49.17 修复：后缀保护原先只认「（N 口）」数字形式，改用**通用**的
        #   参数展开——口数叫法改成「双口/四口」后原正则失配，_nm_suf 会取到整个型号串，
        #   而 _nm_raw 也没剥掉后缀 → 最终拼接成「A（双口）A（双口）」（实测到的重复）。
        #   参数展开不依赖具体文案，今后改叫法也不会再踩。
        _nm_raw="${npn:-N/A}"
        _nm_suf=""
        case "$_nm_raw" in
            *（*口）) _nm_suf="（${_nm_raw##*（}"
                      _nm_raw="${_nm_raw%（*}"        # 删掉「（双口）」这类后缀（%）* 匹配最后一个「（」起） ;;
        esac
        _nm=$(echo "$_nm_raw" | sed 's/Intel Corporation Ethernet Controller //; s/ for 10GBASE-T.*//; s/ (rev [0-9]*)//')
        _nm="${_nm}${_nm_suf}"
        if echo "${npn:-}" | grep -qiE "BlueField"; then
            ACC_NIC_DPU_PORT=$((ACC_NIC_DPU_PORT+1))
            if _nic_is_card_head "$nport"; then
                ACC_NIC_DPU_COUNT=$((ACC_NIC_DPU_COUNT+1))
                _cp=$(_card_ports "$nport"); _dist_add dpu "$_cp"
                [ "$ACC_NIC_DPU" = "N/A" ] && ACC_NIC_DPU="$_nm"
            fi
        elif [ "${ngd:-}" = "GPU直连" ] && echo "${npn:-}" | grep -qE "ConnectX-[678]|BlueField"; then
            # v1.48.86：GPU直连 之外再加「卡型」过滤——PXB 级距离会把同 PCIe 域的
            #   非计算卡一并纳入（实测 A100 机上 MCX556A-ECAT（CX-5）也是 PXB），
            #   只认高速计算卡（ConnectX-6/7/8、BlueField）才算计算网卡。
            ACC_NIC_IB_PORT=$((ACC_NIC_IB_PORT+1))
            if _nic_is_card_head "$nport"; then
                ACC_NIC_IB_COUNT=$((ACC_NIC_IB_COUNT+1))
                _cp=$(_card_ports "$nport"); _dist_add ib "$_cp"
                [ "$ACC_NIC_IB" = "N/A" ] && ACC_NIC_IB="$_nm"
            fi
        elif [ "${GPU_TOPO_AVAIL:-0}" != "1" ] && echo "$nnic" | grep -qE "^ib"; then
            # v1.48.86 回退分支：**无 topo 数据时**按接口名判（IB 模式口 = 计算网卡，同旧实现）。
            #   必须保留这条——AMD/昇腾平台没有 nvidia-smi topo，GPU_DIRECT_NIC 恒为空，
            #   若不回退会把这类平台的计算网卡整批丢进「网卡&端口」：
            #   实测 AMD MI300X（AMD-sample-a）8 口 CX-7 400G 计算网卡因此全部消失。
            #   与「GPU直连」判据的分工是：有 topo → 用物理直连（准确）；无 topo → 用协议口兜底（可用）。
            ACC_NIC_IB_PORT=$((ACC_NIC_IB_PORT+1))
            if _nic_is_card_head "$nport"; then
                ACC_NIC_IB_COUNT=$((ACC_NIC_IB_COUNT+1))
                _cp=$(_card_ports "$nport"); _dist_add ib "$_cp"
                [ "$ACC_NIC_IB" = "N/A" ] && ACC_NIC_IB="$_nm"
            fi
        else
            ACC_NIC_ETH_PORT=$((ACC_NIC_ETH_PORT+1))
            if _nic_is_card_head "$nport"; then
                ACC_NIC_ETH_COUNT=$((ACC_NIC_ETH_COUNT+1))
                _cp=$(_card_ports "$nport"); _dist_add eth "$_cp"
                _mm="$_nm"
                # v1.49.17：去重按**基础型号**（去掉口数后缀）比对——原整串比对在型号
                #   带上「（双口）」这类后缀后失效，同一型号被拼接两次（实测 "A A + B B"）。
                _mbase="${_nm%%（*}"
                if [ "$ACC_NIC_ETH" = "N/A" ]; then
                    ACC_NIC_ETH="$_mm"
                elif ! printf '%s' "$ACC_NIC_ETH" | grep -qF "$_mbase"; then
                    ACC_NIC_ETH="${ACC_NIC_ETH} + ${_mm}"
                fi
            fi
        fi
    done < <(printf '%s\n' "$NIC_DETAILS")
fi
