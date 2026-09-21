#!/bin/bash
# =============================================================================
# HwScope - Markdown 报告生成器 gen_md
# report/gen/gen_md.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
gen_md() {
    local f="${OUT}/hwscope_report.md"
    # 内存插槽明细 Markdown 表
    local dimms_md=""
    if [ -n "$MEM_DIMMS" ]; then
        # 位宽列动态隐藏（v1.45.13）：部件号能推断出 x4/x8 才显示该列（整列全空隐藏，动态列惯例）
        local d_width_any=0
        printf '%s\n' "$MEM_DIMMS" | grep -qE '\|x[0-9]+$' && d_width_any=1
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur drank dwidth; do
            [ -z "$dslot" ] && continue
            # v1.50.3：空槽内部标记 -> 展示文案（统计端已排除该标记，仅渲染时转换）
            [ "$dsize" = "EMPTY_SLOT" ] && dsize="（未插）"
            dseq=$((dseq+1))
            if [ "$d_width_any" -eq 1 ]; then
                dimms_md="${dimms_md}| ${dseq} | ${dslot} | ${dsize} | ${dmfr} | ${dsn} | ${dpn} | ${dnom} | ${dcur} | ${drank:-N/A} | ${dwidth:-N/A} |"$'\n'
            else
                dimms_md="${dimms_md}| ${dseq} | ${dslot} | ${dsize} | ${dmfr} | ${dsn} | ${dpn} | ${dnom} | ${dcur} | ${drank:-N/A} |"$'\n'
            fi
        done < <(printf '%s\n' "$MEM_DIMMS")
    fi
    # GPU 每卡明细 Markdown 表
    local gpu_details_md=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存显示 默认(额定)/可用（如 288GB/268.6 GiB 可用），防止客户误读检测值为卡容量
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gused glimit gvb; do
            [ -z "$gidx" ] && continue
            # PCIe 合并：满速只显当前值，降速才标注能力（如 "5x8 (能力 5x16)"）
            gpcie_disp="$gpcie"
            if [ "$gpcie" != "N/A" ] && [ "$gmax" != "N/A" ] && [ -n "$gmax" ] && [ "$gpcie" != "$gmax" ]; then
                gpcie_disp="${gpcie} (能力 ${gmax})"
            fi
            # 显存 检测/额定（检测=采集可见值 GiB，额定=规格 GB，差异为 ECC/显存预留）
            gmem_disp="${gmem:-N/A}"
            if [ -n "$gmem_spec" ] && [ "$gmem" != "N/A" ] && [ -n "$gmem" ]; then
                gmem_disp="${gmem}/${gmem_spec}"
            fi
            # 功耗 检测/额定（检测=当前功耗，额定=规格最大功耗）
            gdraw_disp="${gdraw:-N/A}"
            if [ -n "$gdraw" ] && [ -n "$glimit" ] && [ "$gdraw" != "N/A" ] && [ "$glimit" != "N/A" ]; then
                _gl=$(echo "$glimit" | grep -oE "[0-9.]+" | head -1 | awk '{printf "%g", $1}')
                gdraw_disp="${gdraw}/${_gl}W"
            fi
            gpu_details_md="${gpu_details_md}| ${gidx} | ${gname} | ${gsn} | ${gmem_disp} | ${gdraw_disp} | ${gtemp} | ${gpcie_disp} | ${gvb:-N/A} |"$'\n'
        done < <(printf '%s\n' "$GPU_DETAILS")
    fi
    # 盘明细 Markdown 表
    local disk_details_md=""
    # 整列隐藏判定：寿命%/额定/健康 整列全为占位符（旧采集无 SMART 数据）时隐藏该列（有任一值即显示）
    local disk_has_spare=0 disk_has_spec=0 disk_has_health=0
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            [ -n "$dspare" ] && [ "$dspare" != "—" ] && [ "$dspare" != "N/A" ] && disk_has_spare=1
            [ -n "$dspec" ] && [ "$dspec" != "—" ] && [ "$dspec" != "N/A" ] && disk_has_spec=1
            [ -n "$dhealth" ] && [ "$dhealth" != "—" ] && [ "$dhealth" != "N/A" ] && disk_has_health=1
        done < <(printf '%s\n' "$DISK_DETAILS")
        local dn=0
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            dn=$((dn + 1))
            # 动态列拼接（整列无值列省略，保持表头/数据行列一致；额定列紧跟容量便于检测/规格对比）
            _spare_col=""; [ "$disk_has_spare" -eq 1 ] && _spare_col=" | ${dspare}"
            _spec_col="";  [ "$disk_has_spec" -eq 1 ] && _spec_col=" | ${dspec#额定}"   # MD 有列头"额定"，值去前缀防重复
            _health_col=""; [ "$disk_has_health" -eq 1 ] && _health_col=" | ${dhealth}"
            disk_details_md="${disk_details_md}| ${dn} | ${dname} | ${dtype} | ${dsize}${_spec_col} | ${dmodel} | ${dsn} | ${dfw} | ${dbdf} | ${dpo} | ${dpc}${_spare_col}${_health_col} |"$'\n'
        done < <(printf '%s\n' "$DISK_DETAILS")
    fi
    # 网卡明细 Markdown 表（v1.44.0：端口列 = 同卡第 N 口/共 M 口；GPU直连列仅平台存在直连网卡时显示——
    # 无 H200/B200 类 1:1 直连形态时整列全 "—"，按动态列隐藏惯例隐藏并附注）
    local nic_details_md=""
    if [ -n "$NIC_DETAILS" ]; then
        local nn=0
        local _gd_col=0
        [ "${GPU_TOPO_AVAIL:-0}" -eq 1 ] && [ "${GPU_DIRECT_COUNT:-0}" -gt 0 ] && _gd_col=1
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip nport nlink nloc; do
            [ -z "$nnic" ] && continue
            nn=$((nn + 1))
            if [ "$_gd_col" -eq 1 ]; then
                # v1.45.17 修复：去掉尾部重复的 nlink 列（表头 13 列对齐——Link 状态仅 GPU直连 前一列）
                # v1.48.53：尾部追加物理位置列（槽位表上溯——SXM*_GPU*/SLOTn/LAN）
                nic_details_md="${nic_details_md}| ${nn} | ${nnic} | ${nnbdf} | ${nport:-—} | ${nmac} | ${nsn} | ${npn} | ${nchip:-} | ${nfw} | ${npcie} | ${npsid} | ${nlink:-—} | ${ngd:-} | ${nloc:-—} |"$'\n'
            else
                nic_details_md="${nic_details_md}| ${nn} | ${nnic} | ${nnbdf} | ${nport:-—} | ${nmac} | ${nsn} | ${npn} | ${nchip:-} | ${nfw} | ${npcie} | ${npsid} | ${nlink:-—} | ${nloc:-—} |"$'\n'
            fi
        done < <(printf '%s\n' "$NIC_DETAILS")
    fi
    # v1.48.53：NIC 表尾注——必须在函数内计算：nic_details_md 是 local，函数外的大 heredoc
    # 读不到（v1.45.15/v1.48.39 的注直接引用它 → 从未显示）；结果存入非 local 的 NIC_TAILNOTES
    NIC_TAILNOTES=""
    if [ -n "$nic_details_md" ]; then
        if printf '%s\n' "$nic_details_md" | grep -q "能力 "; then
            NIC_TAILNOTES="${NIC_TAILNOTES}> 注：PCIe(协商) 标注 \`(能力 …)\` 表示卡能力高于当前协商——多为平台通路设计（扩展板卡/端口按 x8 配置、BIOS 端口拆分），非链路故障；如疑可对照板卡规格确认"$'\n'
        fi
        if printf '%s\n' "$nic_details_md" | grep -qE '\| (Down|—) \| [^|]*\|$'; then
            NIC_TAILNOTES="${NIC_TAILNOTES}> 注：Link 状态 = 端口物理链路——Up=已连接；Down=未插线缆或对端关闭（交付场景 IB 卡未接线属预期形态，非故障；插线后应转 Up）"$'\n'
        fi
        if printf '%s\n' "$nic_details_md" | grep -qE '\| (SXM[0-9]+_GPU[0-9]+|SLOT[0-9]+|LAN|M2_[0-9]+) \|$'; then
            NIC_TAILNOTES="${NIC_TAILNOTES}> 注：物理位置 = 主板 SMBIOS 槽位表（Type 9）+ PCIe 上游桥链上溯所得——\`SXM<n>_GPU<m>\` 表示该网卡位于第 n 组 SXM 的第 m 号 GPU 模块处（板级物理位置名，非 nvidia-smi 逻辑编号），即「GPU 直连」的物理落点；\`SLOTn\`/\`LAN\`/\`M2_x\` 为标准槽位名"$'\n'
        fi
    fi
    # NVSwitch Markdown 表
    local nvs_md=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_md="${nvs_md}| ${nidx} | ${nstat} | ${ntemp} | ${nports} |"$'\n'
        done < <(printf '%s\n' "$NVS_DETAILS")
    fi
    # CPU 每 Socket 明细 Markdown 表
    local cpu_details_md=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_md="${cpu_details_md}| ${csocket} | ${cmodel} | ${ccores} | ${cthreads} | ${cmaxspd} | ${ccurspd} | ${cstep} |"$'\n'
        done < <(printf '%s\n' "$CPU_DETAILS")
    fi
    # SEL 最近事件 Markdown 表
    local sel_details_md=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_md="${sel_details_md}| ${sid} | ${sdate} | ${stime} | ${stype} | ${sdesc} |"$'\n'
        done < <(printf '%s\n' "$SEL_DETAILS")
    fi
    # 风扇明细 Markdown 表
    local fan_details_md=""
    if [ -n "$FAN_DETAILS" ]; then
        local fn=0
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fn=$((fn + 1))
            fan_details_md="${fan_details_md}| ${fn} | ${fname} | ${frpm} | ${fstatus} |"$'\n'
        done < <(printf '%s\n' "$FAN_DETAILS")
    fi

    # ══════════════════════════════════════════════════════════════════════
    # v1.50.0 新增明细表（报告端聚合既有采集数据，零新采集；旧采集目录同样生效）
    #   ⚠️ 以下变量必须非 local：函数外的 heredoc 读不到 local 变量（v1.48.53 教训）
    # ══════════════════════════════════════════════════════════════════════

    # ── ① 网卡卡级明细（每张卡一行；按 BDF 去掉 function 后聚合端口级 NIC_DETAILS）
    #      口数 = 同 BDF 前缀的端口行数（物理口实测，非型号名推断）；叫法用行业术语
    NIC_CARD_MD=""
    if [ -n "$NIC_DETAILS" ]; then
        NIC_CARD_MD=$(printf '%s\n' "$NIC_DETAILS" | awk -F'|' '
            function ptxt(n) {
                if (n == 1) return "单口"
                if (n == 2) return "双口"
                if (n == 3) return "三口"
                if (n == 4) return "四口"
                if (n == 8) return "八口"
                return n " 口"
            }
            {
                bdf = $2
                sub(/\.[0-9]+$/, "", bdf)
                if (bdf == "") next
                if (!(bdf in seen)) {
                    seen[bdf] = 1
                    order[++n] = bdf
                    # 型号：去掉 60 段追加的「（双口）」类后缀——口数已有独立列，避免重复
                    m = $5
                    _i = index(m, "（")
                    if (_i > 0) m = substr(m, 1, _i - 1)
                    model[bdf] = m
                    chip[bdf] = $10
                    # 固件：去掉附带的 (PSID)——PSID 已有独立列
                    f = $6
                    _j = index(f, " (")
                    if (_j > 0) f = substr(f, 1, _j - 1)
                    fw[bdf] = f
                    psid[bdf] = $8; loc[bdf] = $13; bdf0[bdf] = $2
                }
                cnt[bdf]++
            }
            END {
                # BDF 升序（格式等宽 xx:xx.x，字符串比较即可；n 很小，冒泡足够）
                for (i = 1; i <= n; i++)
                    for (j = i + 1; j <= n; j++)
                        if (order[j] < order[i]) { t = order[i]; order[i] = order[j]; order[j] = t }
                for (i = 1; i <= n; i++) {
                    b = order[i]
                    c = chip[b]; if (c == "") c = "—"
                    l = loc[b];  if (l == "") l = "—"
                    f = fw[b];   if (f == "") f = "—"
                    p = psid[b]; if (p == "") p = "—"
                    printf "| %d | %s | %s | %s | %s | %s | %s | %s |\n", i, model[b], ptxt(cnt[b]), bdf0[b], c, f, p, l
                }
            }')
    fi

    # ── ② 功耗读数表（不同口径分行展示、不并排——AGENTS v1.48.97 立规）
    #      数据源均为既有文本变量（格式「标签: 值」），报告端拆分；旧采集目录同样生效
    PWR_TABLE_MD=""
    # 取「标签: 值」的值部分并去掉首尾空白（BMC 输出常带前导空格）
    _ptrim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
    if [ -n "$PSU_EXTRA" ]; then
        case "$PSU_EXTRA" in
            *": "*) _pl="${PSU_EXTRA%%: *}"; _pv="$(_ptrim "${PSU_EXTRA#*: }")" ;;
            *)      _pl="整机功耗";          _pv="$(_ptrim "$PSU_EXTRA")" ;;
        esac
        PWR_TABLE_MD="${PWR_TABLE_MD}| ${_pl} | ${_pv} | 各 PSU 输入功率合计 |"$'\n'
    fi
    if [ -n "$PSU_DCMI" ]; then
        _dv="$(_ptrim "${PSU_DCMI#*: }")"; [ "$_dv" = "$PSU_DCMI" ] && _dv="$(_ptrim "$PSU_DCMI")"
        case "$_dv" in
            *"｜"*)
                PWR_TABLE_MD="${PWR_TABLE_MD}| DCMI 平台功耗（瞬时） | $(_ptrim "${_dv%%｜*}") | dcmi power reading 瞬时值 |"$'\n'
                PWR_TABLE_MD="${PWR_TABLE_MD}| DCMI 窗口统计 | $(_ptrim "${_dv#*｜}") | BMC 采样窗口内 Min/Max/Avg |"$'\n'
                ;;
            *)
                PWR_TABLE_MD="${PWR_TABLE_MD}| DCMI 平台功耗 | ${_dv} | dcmi power reading |"$'\n'
                ;;
        esac
    fi
    if [ -n "$PSU_CPU_RAPL" ]; then
        case "$PSU_CPU_RAPL" in
            *": "*) _rl="${PSU_CPU_RAPL%%: *}"; _rv="$(_ptrim "${PSU_CPU_RAPL#*: }")" ;;
            *)      _rl="CPU 功耗（RAPL）";      _rv="$(_ptrim "$PSU_CPU_RAPL")" ;;
        esac
        PWR_TABLE_MD="${PWR_TABLE_MD}| ${_rl} | ${_rv} | CPU 内部 RAPL 计数器（不含 GPU）|"$'\n'
    fi

    # ── ③ IB 链路质量（逐 CA）/ 端口模式（逐端口）明细表
    #      数据源为 40/50 段既有汇总变量，从健康检查表的长串拆出为独立表（观感 + 可逐行读）
    IB_BER_TABLE_MD=""
    if [ -n "$IB_BER_SUMMARY" ]; then
        IB_BER_TABLE_MD=$(printf '%s\n' "$IB_BER_SUMMARY" | tr ' ' '\n' | awk -F':' '
            NF >= 2 && $1 != "" { printf "| %s | %s |\n", $1, $2 }')
    fi
    IB_PORTMODE_MD=""
    if [ -n "$LINKTYPE_SUMMARY" ]; then
        IB_PORTMODE_MD=$(printf '%s\n' "$LINKTYPE_SUMMARY" | tr ',' '\n' | awk '
            {
                c = index($0, ":")
                if (c == 0) next
                ca = substr($0, 1, c - 1)
                rest = substr($0, c + 1)
                nb = split(rest, pp, " ")
                for (i = 1; i <= nb; i++) {
                    e = index(pp[i], "=")
                    if (e == 0) continue
                    printf "| %s | %s | %s |\n", ca, substr(pp[i], 1, e - 1), substr(pp[i], e + 1)
                }
            }')
    fi
    # IB 链路质量摘要（健康检查行用，替代原来的整串 BER）
    IB_BER_BRIEF=""
    if [ -n "$IB_BER_SUMMARY" ]; then
        _bnb=$(printf '%s\n' "$IB_BER_SUMMARY" | tr ' ' '\n' | awk -F':' 'NF >= 2 { print $2 }' | sed '/^$/d')
        _bcnt=$(printf '%s\n' "$_bnb" | grep -c .)
        _bbest=$(printf '%s\n' "$_bnb" | sort -g | head -1)
        _bworst=$(printf '%s\n' "$_bnb" | sort -g | tail -1)
        IB_BER_BRIEF="${_bcnt} 个 CA 有读数 · 最优 ${_bbest} / 最差 ${_bworst}"
    fi

    # ── ④ 板载 / 外部接口表（VGA、USB、板载网口；BMC 管理口行在渲染时用 BMC_IP/BMC_MAC 补）
    #      数据源：10 段从 lspci_all/lsusb 解析所得（零新采集）
    BOARD_IFACE_MD=""
    if [ -n "$BOARD_IFACE" ]; then
        BOARD_IFACE_MD=$(printf '%s' "$BOARD_IFACE" | awk -F'|' 'NF >= 4 { printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }')
    fi
    BOARD_USB_MD=""
    if [ -n "$BOARD_USB_DEV" ]; then
        BOARD_USB_MD=$(printf '%s\n' "$BOARD_USB_DEV" | awk -F'|' 'NF >= 4 { printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }')
    fi

    cat > "$f" << EOF
# HwScope 硬件巡检报告

**采集版本:** ${VERSION:-unknown} · **报告生成器:** ${REPORT_VERSION:-unknown} · **主机:** ${HOSTNAME:-unknown} · **平台:** ${PLATFORM_LABEL:-unknown} · **时间:** ${TIMESTAMP:-unknown}

## 环境
| 项 | 值 |
|----|----|
| OS | ${OS_NAME:-N/A} |
| 内核 | ${KERNEL:-N/A} |
| 驱动 | ${GPU_DRIVER:-N/A} |$(if [ -n "${GPU_CUDA:-}" ] || [ "${GPU_PLATFORM:-}" = "nvidia" ] 2>/dev/null; then echo "
| CUDA | ${GPU_CUDA:-N/A} |"; fi)
| 设备形态 | ${MACHINE_CLASS_LABEL:-${MACHINE_CLASS:-N/A}} |$(if [ -n "${DCGM_COMPUTE_MODE:-}" ]; then echo "
| Compute Mode | ${DCGM_COMPUTE_MODE} |"; fi)$(if [ -n "${DCGM_ECC_MODE:-}" ]; then echo "
| ECC Mode | ${DCGM_ECC_MODE}${DCGM_CONFIG_NOTE} |"; fi)
| 采集耗时 | ${TIMING_TOTAL:-N/A} |

## 主板
| 项 | 值 |
|----|----|
| 制造商 | ${MB_MANUFACTURER:-N/A} |
| 型号 | ${MB_PRODUCT:-N/A} |
| SN | ${MB_SN:-N/A} |
| 主板 SN | ${MB_BOARD_SN:-N/A} |
| BIOS | ${BIOS_VERSION:-N/A} |
| 机箱 SN | ${CHASSIS_SN:-N/A} |
$(if [ -n "$FABRIC_SW" ] && [ "$GPU_COUNT" -eq 0 ]; then echo "| PCIe Fabric Switch | ${FABRIC_SW}（HGX 模组互联通道） |"; fi)
## PCIe 拓扑与链路
$(if [ -n "$PCIE_PEX_DETAILS" ] || [ -n "$PCIE_SLOW_LINKS" ] || [ "$PCIE_LINKS_TOTAL" -gt 0 ]; then
    if [ -n "$PCIE_PEX_DETAILS" ]; then
        echo "| Fabric Switch | ${PCIE_PEX_DETAILS} |"
        echo ""
    fi
    # v1.44.0 摘要 + 异常明细（v1.44.1）：满速链路不逐条列（全量明细见文末附录）
    if [ "$PCIE_LINKS_TOTAL" -gt 0 ] && [ -n "$PCIE_LINK_TABLE" ]; then
        _full=$((PCIE_LINKS_TOTAL - PCIE_SLOW_COUNT - PCIE_MGMT_COUNT - ${PCIE_BRIDGE_NEG_COUNT:-0}))
        echo "| 链路统计 | ${PCIE_LINKS_TOTAL} 条 · 满速 ${_full} · 降速/降宽 ${PCIE_SLOW_COUNT} · bridge 协商 ${PCIE_BRIDGE_NEG_COUNT:-0} · 管理芯片 ${PCIE_MGMT_COUNT} |"
        echo ""
        if [ "$PCIE_SLOW_COUNT" -gt 0 ] 2>/dev/null; then
            echo "### ⚠️ 降速/降宽链路"
            echo ""
            echo "| BDF | 设备 | LnkCap | LnkSta | 判定 |"
            echo "|-----|------|--------|--------|------|"
            printf '%s\n' "$PCIE_LINK_TABLE" | while IFS='|' read -r lbdf ldesc lcap lsta lverdict; do
                [ -z "$lbdf" ] && continue
                case "$lverdict" in *⚠️*) echo "| ${lbdf} | ${ldesc} | ${lcap} | ${lsta} | ${lverdict} |" ;; esac
            done
            echo ""
        fi
        if [ "$PCIE_MGMT_COUNT" -gt 0 ] 2>/dev/null; then
            echo "> 管理芯片（BMC VGA 桥等）${PCIE_MGMT_COUNT} 条固有低速为正常现象，不计链路异常"
            echo ""
        fi
        if [ "$PCIE_SLOW_COUNT" -eq 0 ] 2>/dev/null; then
            echo "> 全部非管理芯片链路满速（全量明细见文末附录）"
            echo ""
        fi
    elif [ -n "$PCIE_SLOW_LINKS" ]; then
        echo "### ⚠️ 降速/降宽链路（LnkSta < LnkCap）"
        echo ""
        printf '%s\n' "$PCIE_SLOW_LINKS" | while IFS= read -r line; do
            echo "- \`$line\`"
        done
        echo ""
    elif [ "$PCIE_LINKS_TOTAL" -gt 0 ]; then
        echo "| 链路状态 | ✅ 全部 ${PCIE_LINKS_TOTAL} 条链路满速（无降速/降宽） |"
    fi
else
    echo "| 链路数据 | N/A（旧采集无 pcie_full 全量日志，链路检测需重新采集） |"
fi)
## CPU
| 项 | 值 |
|----|----|
| 型号 | ${CPU_MODEL:-N/A} |
| 核心数 | ${CPU_CORES:-N/A}/颗 × ${CPU_SOCKETS:-N/A} 路 = ${CPU_TOTAL_CORES:-N/A} 总核 |
| 插槽数 | ${CPU_SOCKETS:-N/A} |
| Stepping | ${CPU_STEPPING:-N/A} |
| 频率 | ${CPU_MAX_SPEED:-N/A} MHz（当前 ${CPU_CUR_SPEED:-N/A} MHz） |
$(if [ -n "$CPU_DETAILS" ]; then
    cseq=0
    local c_has_sn=0
    # 检测是否有任何 CPU 有真实 SN（Not Specified 已置空）
    while IFS='|' read -r cs cm cc ct cmx ccur cstep csn; do
        [ -z "$cs" ] && continue
        [ -n "$csn" ] && c_has_sn=1
    done < <(printf '%s\n' "$CPU_DETAILS")
    echo "### 处理器明细（CPU）"
    if [ "$c_has_sn" -eq 1 ]; then
        echo "| # | Socket | 型号 | 核心 | 线程 | 最大频率 | 当前频率 | Stepping | SN |"
        echo "|---|--------|------|------|------|---------|---------|----------|----|"
        echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep csn; do
            cseq=$((cseq + 1))
            echo "| ${cseq} | ${cs} | ${cm} | ${cc} | ${ct} | ${cmx} | ${ccur} | ${cstep} | ${csn:-} |"
        done
    else
        echo "| # | Socket | 型号 | 核心 | 线程 | 最大频率 | 当前频率 | Stepping |"
        echo "|---|--------|------|------|-----------|------|---------|---------|"
        echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep csn; do
            cseq=$((cseq + 1))
            echo "| ${cseq} | ${cs} | ${cm} | ${cc} | ${ct} | ${cmx} | ${ccur} | ${cstep} |"
        done
    fi
fi)

## 内存
| 项 | 值 |
|----|----|
| 总量 | ${MEM_TOTAL_PHYS:-${MEM_TOTAL:-N/A}}/${MEM_TOTAL:-N/A} 可见 |
| 类型 | ${MEM_TYPE:-N/A} |
| 速率 | ${MEM_SPEED:-N/A} ${MEM_SPEED_NOTE:-} |
| 插槽 | ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} |

### 内存模块明细（DIMM）
$(if printf '%s\n' "$MEM_DIMMS" | grep -qE '\|x[0-9]+$' 2>/dev/null; then
    echo "| # | 插槽 | 容量 | 厂商 | SN | 部件号 | 额定速率 | 当前速率 | Rank | 位宽 |"
    echo "|----|------|------|------|----|--------|--------|--------|------|------|"
else
    echo "| # | 插槽 | 容量 | 厂商 | SN | 部件号 | 额定速率 | 当前速率 | Rank |"
    echo "|----|------|------|------|----|--------|--------|--------|------|"
fi)
$(printf '%s' "$dimms_md")

$(if [ "$GPU_COUNT" -gt 0 ] || [ "$HEAD_NODE" -eq 1 ] || [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
    echo "## GPU"
    if [ "$GPU_COUNT" -eq 0 ]; then
        if [ "$HEAD_NODE" -eq 1 ]; then
        echo "| 项 | 值 |"
        echo "|----|----|"
            echo "| 状态 | HGX 机头（无本地 GPU，HGX 模组经 PCIe Fabric 单独接入，需单独采集） |"
        elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
            echo "| 项 | 值 |"
            echo "|----|----|"
            echo "| 状态 | ⚠️ 检测到 ${GPU_PCI_PRESENT} 个 GPU（${GPU_PCI_VENDORS:-${GPU_PCI_VENDOR:-未知}}），但对应管理工具无数据（驱动未安装或异常） |"
        else
            echo "<!-- GPU: 无 GPU 平台，整段隐藏（v1.46.0） -->"
        fi
    else
        echo "| 项 | 值 |"
    echo "|----|----|"
    echo "| 数量 | ${GPU_COUNT:-0} |"
    echo "| 型号 | ${GPU_NAMES:-N/A} |"
    echo "| 显存总量 | ${GPU_MEM:-N/A}/${GPU_MEM_SPEC_TOTAL:-${GPU_MEM:-N/A}}（检测/额定${GPU_MEM_SPEC:+，${GPU_MEM_SPEC}}）${GPU_MEM_SPEC_NOTE:+ ${GPU_MEM_SPEC_NOTE}} |"
    if [ -n "${GPU_AMD_SUSPECT:-}" ]; then
        echo "| 显存异常 | ⚠️ ${GPU_AMD_SUSPECT%, }（疑似显存魔改或伪装，需核实） |"
    fi
    echo "| 额定功耗 | ${GPU_POWER:-N/A} |"
    echo "| 温度 | ${GPU_TEMP:-N/A} |"
    # v1.48.36: 厂商感知字段——NVIDIA 显示 ECC/退役行（nvidia-smi 字段），AMD 显示 RAS（ECC 对应物），其余平台隐藏（NVIDIA 专属概念）
    case "${GPU_PLATFORM:-}" in
        amd)
            echo "| RAS | ${GPU_RAS:-N/A} |"
            ;;
        nvidia)
            echo "| ECC | ${GPU_ECC:-N/A} |"
            echo "| 退役行 | ${GPU_REMAP:-N/A} |"
            ;;
    esac
    echo "| VBIOS | ${GPU_VBIOS:-N/A} |"
        if [ -n "${GPU_ASCEND_NOTE:-}" ]; then
            echo "| 昇腾 | ${GPU_ASCEND_NOTE} |"
        fi
        if [ -n "$NV_LINK_SUMMARY" ] && [ "$NV_LINK_SUMMARY" != "N/A" ]; then
            echo "| NVLink | ${NV_LINK_SUMMARY} |"
        fi
        if [ -n "${GPU_XGMI_SUMMARY:-}" ]; then
            echo "| xGMI | ${GPU_XGMI_SUMMARY} |"
        fi
        if [ -n "${GPU_XID:-}" ]; then
            echo "| XID 错误 | ⚠️ 检出 ${GPU_XID_COUNT} 类 GPU XID 错误（来源: ${GPU_XID_SRC}）——详见下方明细 |"
        fi
    fi
fi)
$(if [ -n "$gpu_details_md" ]; then
    echo ""
    echo "### 图形处理器明细（GPU）"
    # v1.44.0 SXM 适配：SXM 平台模组无 CPU 直连 PCIe 链路，nvidia-smi 链路协商值实为 NVLink 通道
    _gpu_link_col="PCIe(协商)"
    case "${PLATFORM_LABEL:-}" in *SXM*) _gpu_link_col="NVLink(协商)" ;; esac
    echo "| 卡 | 型号 | SN | 显存(检测/额定) | 功耗(检测/额定) | 温度 | ${_gpu_link_col} | VBIOS |"
    echo "|----|------|----|----|------|------|----------|-------|"
    printf '%s' "$gpu_details_md"
fi)
$(if [ -n "${GPU_XID:-}" ]; then
    echo ""
    echo "> ⚠️ **GPU XID 错误历史（来源: ${GPU_XID_SRC}）** —— XID 是 NVIDIA 官方故障码，"
    echo "> 常见含义：79=GPU 掉总线、48=ECC 双bit不可纠正、13/31=显存/指令异常、62=显存页退役、74=NVLink 错误。"
    echo "> 以下为检出记录（去重）："
    echo ""
    echo '```'
    printf '%s\n' "$GPU_XID"
    echo '```'
fi)

$(if [ -n "$nvs_md" ]; then
    echo ""
    echo "## NVSwitch"
    echo "| 编号 | 状态 | 温度 | 活动/总端口 |"
    echo "|------|------|------|-------------|"
    printf '%s' "$nvs_md"
fi)$(if [ -n "${NVSWITCH_FABRIC:-}" ]; then
    echo ""
    echo "## NVSwitch 域（Fabric）"
    echo "${NVSWITCH_FABRIC}"
fi)

$(if [ "${FW_COMPLIANCE_ACTIVE:-0}" -eq 1 ] 2>/dev/null; then
    echo ""
    echo "## 固件合规"
    echo "> 对照 conf/fw_required.txt（厂商推荐版本基线）逐项判定；无基线条目判未知（仅记录）"
    echo ""
    echo "| 组件 | 设备 | 当前版本 | 推荐版本 | 状态 | 说明 |"
    echo "|------|------|---------|---------|------|------|"
    echo "$FW_COMPLIANCE_DETAILS" | while IFS='|' read -r fc fd fcur fbase fst fnote; do
        [ -z "$fc" ] && continue
        case "$fst" in
            合规) fst_disp="✅ 合规" ;;
            落后) fst_disp="⚠️ 落后" ;;
            *)    fst_disp="$fst" ;;
        esac
        echo "| ${fc} | ${fd} | ${fcur} | ${fbase} | ${fst_disp} | ${fnote:-} |"
    done
    [ -n "$FW_SUMMARY" ] && echo ""
    [ -n "$FW_SUMMARY" ] && echo "> ${FW_SUMMARY}"
fi)

## 存储
| 项 | 值 |
|----|----|
| 盘数 | ${STORAGE_COUNT:-0} |
| 总容量 | ${STORAGE_TOTAL:-N/A} |
| 盘型号 | ${STORAGE_MODELS:-N/A} |
| 系统盘(已排除) | ${SYS_DISK:-N/A} |

$(if [ -n "$(printf '%s' "$disk_details_md" | tr -d ' \n')" ]; then
    # v1.49.17：无数据盘（HGX 模组等）时整块不输出——原实现标题/表头/分隔行无条件渲染，
    #   只把数据行留空，MD 会渲染成一张空表格（实测 B300 台 phys 盘数 0）。
    echo "### 存储盘明细"
    echo "| # | 设备 | 类型 | 容量$(if [ "$disk_has_spec" -eq 1 ]; then echo " | 额定"; fi) | 型号 | SN | 固件 | BDF | 通电(h) | 通电次数$(if [ "$disk_has_spare" -eq 1 ]; then echo " | 寿命%"; fi)$(if [ "$disk_has_health" -eq 1 ]; then echo " | 健康"; fi) |"
    echo "|---|------|------|------$(if [ "$disk_has_spec" -eq 1 ]; then echo "|------"; fi)|------|------|----|------|---------|----------$(if [ "$disk_has_spare" -eq 1 ]; then echo "|-------"; fi)$(if [ "$disk_has_health" -eq 1 ]; then echo "|------"; fi)|"
    printf '%s\n' "$disk_details_md"
fi)
$(if [ -n "$(printf '%s' "$DISK_DETAILS" | tr -d ' \n')" ] && { [ "$disk_has_spare" -eq 0 ] || [ "$disk_has_health" -eq 0 ]; }; then
    echo "> 注：$(if [ "$disk_has_spare" -eq 0 ]; then echo "寿命%"; fi)$(if [ "$disk_has_spare" -eq 0 ] && [ "$disk_has_health" -eq 0 ]; then echo "、"; fi)$(if [ "$disk_has_health" -eq 0 ]; then echo "健康"; fi) 列因旧采集无 SMART 数据而隐藏"
fi)

$(if [ -n "$RAID_VD_DETAILS" ]; then
    echo "### RAID 虚拟盘明细（VD）"
    echo "| # | 设备 | RAID 卡 | 容量 | SN(LUN) |"
    echo "|---|------|---------|------|---------|"
    rvd_seq=0
    echo "$RAID_VD_DETAILS" | while IFS='|' read -r rvdname rvdmodel rvdsize rvdsn; do
        [ -z "$rvdname" ] && continue
        rvd_seq=$((rvd_seq+1))
        echo "| ${rvd_seq} | ${rvdname} | ${rvdmodel} | ${rvdsize} | ${rvdsn:-N/A} |"
    done
fi)

$(if [ -n "$RAID_DETAILS" ]; then
    echo "## RAID 控制器"
    echo "| # | 控制器 | 型号 | SN | 固件 | 虚拟盘 |"
    echo "|---|--------|------|----|------|--------|"
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd rvd_list; do
        [ -z "$ridx" ] && continue
        rseq=$((rseq + 1))
        echo "| ${rseq} | ${ridx} | ${rmodel} | ${rsn} | ${rfw} | ${rvd} |"
        # 虚拟盘明细行（VD0:RAID1/1.817 TB/Optimal; 分隔）
        if [ -n "$rvd_list" ]; then
            echo "$rvd_list" | tr ';' '\n' | while IFS= read -r vdline; do
                [ -z "$vdline" ] && continue
                vdname="${vdline%%:*}"
                vdrest="${vdline#*:}"
                echo "|   | ${vdname} | ${vdrest} | | | |"
            done
        fi
    done
else
    if [ -n "$RAID_PCI_PRESENT" ]; then
        echo "## RAID 控制器"
        echo "> ⚠️ 检测到 RAID 控制器（$(echo "$RAID_PCI_PRESENT" | sed 's/.*: //' | xargs)），但 storcli64 未安装或采集失败——RAID 配置/虚拟盘/底层盘信息不可用，需现场安装 storcli64 后重采"
    elif [ -n "$MD_RAID_LIST" ]; then
        echo "## RAID 控制器"
        echo "> ℹ️ Linux 软件 RAID（mdadm）: ${MD_RAID_LIST}（系统级软 RAID，非硬件 RAID 卡）"
    elif [ "${RAID_VMD_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
        echo "## RAID 控制器"
        echo "> ℹ️ 检测到 Intel VMD NVMe RAID（虚拟 RAID，非独立卡，由系统管理）"
    fi
fi)

$(if [ -n "$HBA_DETAILS" ]; then
    echo "## 主机总线适配器明细（HBA）"
    echo "| # | 控制器 | 型号 | 固件 | SN | 状态 | SAS地址 | 端口 |"
    echo "|---|--------|------|------|----|------|---------|------|"
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat hsas hports; do
        [ -z "$hname" ] && continue
        hseq=$((hseq + 1))
        echo "| ${hseq} | ${hname} | ${htype} | ${hfw} | ${hsn} | ${hstat} | ${hsas} | ${hports} |"
    done
else
    if [ -n "$HBA_PCI_PRESENT" ]; then
        echo "## 主机总线适配器明细（HBA）"
        echo "> ⚠️ 检测到 SAS HBA（$(echo "$HBA_PCI_PRESENT" | sed 's/.*: //' | xargs)），但 sas3ircu/sas2ircu 未安装或采集失败——HBA 型号/固件/端口信息不可用"
    fi
fi)

## 网络
| 项 | 值 |
|----|----|
| IB 设备数 | ${IB_COUNT:-0} |
| IB 活动口 | ${IB_ACTIVE:-0}${IB_ACTIVE_SPEED:+ (${IB_ACTIVE_SPEED})} |
| IB Link 状态 | Active ${IB_ACTIVE:-0}${IB_INITIALIZING:+ / Initializing ${IB_INITIALIZING}} / Down ${IB_LINK_DOWN:-0}$([ "${IB_UNPLUGGED:-0}" -gt 0 ] 2>/dev/null && printf '（未插线缆 %s）' "$IB_UNPLUGGED") |
| IB 额定速率 | ${IB_NOMINAL:-N/A} |$(if [ -n "${IB_FW_INCONSISTENT}" ]; then printf '\n| IB 固件一致性 | ⚠️ 同型号卡固件版本不一致（仅供核对，非故障判定）：%s |' "${IB_FW_INCONSISTENT}"; fi)
| 以太网口 up | ${ETH_LINK_UP:-0} |
$(net_extra_md)

### 网络适配器明细（卡级）
$(if [ -n "$NIC_CARD_MD" ]; then
    echo "| # | 型号 | 口数 | BDF | 芯片 | 固件 | PSID | 物理位置 |"
    echo "|---|------|------|-----|------|------|------|-----------|"
    printf '%s' "$NIC_CARD_MD"
    echo ""
    echo "> 口数 = 该卡在系统中实际呈现的物理端口数（按同 BDF 前缀的端口行统计）；逐口链路状态见下表。GPU 直连标记在端口级表中"
    echo ""
fi)
### 网络适配器明细（NIC）
$(if [ "${GPU_TOPO_AVAIL:-0}" -eq 1 ] && [ "${GPU_DIRECT_COUNT:-0}" -eq 0 ]; then
    echo "> GPU直连 列已隐藏：本机无 GPU 直连网卡（网卡均不与 GPU 同 PCIe Switch；H200/B200 类 1:1 直连或 B300 板载网卡形态才会标记）"
    echo ""
    echo "| # | 接口 | BDF | 端口 | MAC | SN | 型号 | 芯片 | 固件 | PCIe(协商) | PSID | Link 状态 | 物理位置 |"
    echo "|---|------|-----|------|-----|----|------|------|-----------|------|------|------|-----------|"
elif [ "${GPU_TOPO_AVAIL:-0}" -eq 1 ]; then
    echo "| # | 接口 | BDF | 端口 | MAC | SN | 型号 | 芯片 | 固件 | PCIe(协商) | PSID | Link 状态 | GPU直连 | 物理位置 |"
    echo "|---|------|-----|------|-----|----|------|------|-----------|------|------|------|-----------|-----------|"
else
    echo "| # | 接口 | BDF | 端口 | MAC | SN | 型号 | 芯片 | 固件 | PCIe(协商) | PSID | Link 状态 | 物理位置 |"
    echo "|---|------|-----|------|-----|----|------|------|-----------|------|------|------|-----------|"
fi)
$(printf '%s' "$nic_details_md")
$(printf '%s' "$NIC_TAILNOTES")
$(if [ -z "$nic_details_md" ] && [ -n "$NIC_FALLBACK_DETAILS" ]; then
    echo "### 网络适配器明细（NIC，ibstat 回退，旧采集无 nic_inventory）"
    echo "| # | CA | 型号 | Node GUID | Link 状态 |"
    echo "|---|----|------|-----------|-----------|"
    nfb=0
    echo "$NIC_FALLBACK_DETAILS" | while IFS='|' read -r fca ftype fguid fstate; do
        [ -z "$fca" ] && continue
        nfb=$((nfb+1))
        echo "| ${nfb} | ${fca} | ${ftype} | ${fguid} | ${fstate} |"
    done
fi)

$(if [ -n "$IB_BER_TABLE_MD" ]; then
    echo "### IB 链路质量（每 CA）"
    echo "| CA | 物理 BER |"
    echo "|----|---------|"
    printf '%s' "$IB_BER_TABLE_MD"
    echo ""
    echo "> 取自 mlxlink 的 Raw Physical BER 原始计数器值，未设阈值判定（数值越小越好）；Link Down 累计 ${IB_LINK_DOWN_EVENTS:-0} 次为该机所有 CA 合计。以太模式端口无 IB BER 读数${IB_ETH_MODE_PORTS:+（本机 ${IB_ETH_MODE_PORTS}）}"
    echo ""
fi)

$(if [ -n "$IB_PORTMODE_MD" ]; then
    echo "### 端口模式（每端口）"
    echo "| CA | 端口 | 模式 |"
    echo "|----|------|------|"
    printf '%s' "$IB_PORTMODE_MD"
    echo ""
    echo "> 取自 \`mlxconfig\` 的 LINK_TYPE_P1/P2：ETH = 以太模式，IB = InfiniBand，「未配置」= 该口未启用（交付时按采购配置核对）"
    echo ""
fi)

$(if [ -n "$USB_NICS" ]; then
    echo "另发现 USB 外接网卡（非 PCIe，不参与网卡统计）:"
    echo ""
    echo "| 接口 | MAC | 型号 | 固件 |"
    echo "|------|-----|------|------|"
    while IFS='|' read -r unnic unmac unpn unfw; do
        [ -z "$unnic" ] && continue
        _upn="${unpn:-}"; case "$_upn" in N/A|n/a|NA|na|"") _upn="N/A（USB 网卡，无 PCI 芯片信息）";; esac
        echo "| ${unnic} | ${unmac} | ${_upn} | ${unfw:-—} |"
    done < <(printf '%s\n' "$USB_NICS")
fi)

## BMC
| 项 | 值 |
|----|----|
| 型号 | ${BMC_FRU:-N/A} |
| 固件 | ${BMC_FW:-N/A} |
$(rf_line=""
[ -n "${RF_FW_BIOS:-}" ] && rf_line="${rf_line}BIOS=${RF_FW_BIOS}, "
[ -n "${RF_FW_CPLD:-}" ] && rf_line="${rf_line}CPLD=${RF_FW_CPLD}, "
[ -n "${RF_FW_PSU:-}" ] && rf_line="${rf_line}PSU=${RF_FW_PSU}, "
[ -n "${RF_FW_OTHER:-}" ] && rf_line="${rf_line}${RF_FW_OTHER}"
if [ -n "$rf_line" ]; then echo "| Redfish 固件明细 | $(echo "$rf_line" | sed 's/, $//') |"; fi)
| IP | ${BMC_IP:-N/A} |
| MAC | ${BMC_MAC:-N/A} |
| SEL 事件 | $(if [ "${SEL_DATA_VALID:-0}" -eq 1 ] 2>/dev/null; then echo "${SEL_TOTAL:-0}（未解除 Critical ${SEL_CRIT_UNRESOLVED:-0}${SEL_CRIT_RECOVERED:+，已自愈 $SEL_CRIT_RECOVERED}）"; else echo "⚠️ 数据不可用"; fi) |
$(if [ "${SEL_DATA_VALID:-0}" -eq 0 ] 2>/dev/null; then
    echo "> ⚠️ SEL 数据不可用（ipmitool 采集失败或无权限），事件列表不完整"
elif [ -n "$SEL_DETAILS" ]; then
    echo "### SEL 告警事件"
    echo "| # | 日期 | 时间 | 类型 | 描述 |"
    echo "|---|------|------|-----------|------|"
    sel_seq=0
    echo "$SEL_DETAILS" | while IFS='|' read -r sid sdate stime stype sdesc; do
        sel_seq=$((sel_seq+1))
        echo "| ${sid} | ${sdate} | ${stime} | ${stype} | ${sdesc} |"
    done
else
    if [ "${SEL_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
        echo "> 告警事件: 无（另有 ${SEL_TOTAL} 条非告警历史事件，如开机传感器状态记录，无需处理）"
    else
        echo "> 告警事件: 无"
    fi
fi)

$(if [ -n "$BMC_CONSISTENCY" ]; then
    echo ""
    echo "### BMC 数据一致性校验（OS vs BMC）"
    echo "> OS 层采集 vs BMC 层交叉校验（只读既有日志，零新采集）；不一致 = 潜在刷 SN/换件/固件不匹配风险"
    echo ""
    echo "| 对比项 | OS 侧 | BMC 侧 | 结果 |"
    echo "|--------|-------|--------|------|"
    echo "$BMC_CONSISTENCY" | while IFS='|' read -r bitem bos bbmc bres; do
        [ -z "$bitem" ] && continue
        echo "| ${bitem} | ${bos} | ${bbmc} | ${bres} |"
    done
fi)

## 板载与外部接口
$(if [ -n "$BOARD_IFACE_MD" ] || [ -n "$BMC_IP" ]; then
    echo "| 类型 | 设备 | BDF | 说明 |"
    echo "|------|------|-----|------|"
    # ⚠️ 必须 printf '%s\n'：BOARD_IFACE_MD 由 $( ) 命令替换赋值，尾换行已被剥掉，
    #    用 %s 会让最后一行与下一行（BMC 管理口）黏成一行 → 表列数不一致
    printf '%s\n' "$BOARD_IFACE_MD"
    [ -n "$BMC_IP" ] && echo "| BMC 管理口 | 带外管理网口 | — | IP ${BMC_IP}${BMC_MAC:+ · MAC ${BMC_MAC}}（远程管理/KVM，不经操作系统）|"
    echo ""
    echo "> 仅列出 lspci/lsusb 可见的接口；机箱后面板的具体接口数量与形态（USB 口数、VGA 口位、串口）以厂商机箱规格为准"
    echo ""
fi)
$(if [ -n "$BOARD_USB_MD" ]; then
    echo "### USB 已接设备"
    echo "| 总线 | 设备 | VID:PID | 描述 |"
    echo "|------|------|---------|------|"
    printf '%s' "$BOARD_USB_MD"
    echo ""
fi)

## 风扇
| 项 | 值 |
|----|----|
| 数量 | $(if [ "${FAN_DATA_OK:-0}" -eq 1 ] 2>/dev/null; then echo "${FAN_COUNT:-0}"; else echo "N/A（未取到数据）"; fi) |
| 转速 | ${FAN_SPEED:-N/A（该平台风扇转速未经标准 IPMI 传感器暴露，详见下方说明）} |
| 温度 | ${TEMP_SUMMARY:-${TEMP_SUMMARY_OS:-N/A}} |$(if [ -n "$FAN_DETAILS" ]; then echo "
| 数据来源 | ${FAN_SOURCE:-IPMI} |"; fi)
$(if [ -n "$FAN_DETAILS" ]; then
    echo "### 散热风扇明细"
    echo "| # | 风扇 | 转速(RPM) | 状态 |"
    echo "|---|------|----------|------|"
    fan_seq=0
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        fan_seq=$((fan_seq+1))
        echo "| ${fan_seq} | ${fname} | ${fval} | ${fstatus} |"
    done
elif [ "${FAN_DATA_OK:-0}" -eq 0 ] 2>/dev/null; then
    echo "> ⚠️ 风扇数据**采集失败**（ipmitool 风扇传感器命令超时或不可读，非平台无风扇）——建议复核 BMC 响应速度，或手动执行 \`ipmitool sensor list | grep -i fan\` 确认"
elif [ "${FAN_COUNT:-0}" -eq 0 ] 2>/dev/null; then
    echo "> 已采集到传感器表但无风扇转速项（该平台风扇可能不经标准 IPMI 传感器暴露）"
fi)

## 电源 PSU
### 电源模块明细（PSU）
| # | 描述 | 型号 | 部件号 | 序列号 | 额定容量 | 当前功耗 |
|----|------|------|-----------|--------|-----------|--------|
$(if [ -n "$PSU_DETAILS" ]; then
    pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        pcap_d="${pcap:-}"; case "$pcap_d" in N/A|n/a|"") pcap_d="—" ;; esac
          ppwr_d="${ppower:-}"; case "$ppwr_d" in N/A|n/a|"") ppwr_d="—" ;; esac
          printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "$pcap_d" "$ppwr_d"
    done < <(printf '%s\n' "$PSU_DETAILS")
else
    # v1.49.18：无 FRU/型号明细 ≠ 平台没有电源——IPMI 状态传感器可见在位颗数时如实区分
    if [ "${PSU_SENSOR_SEEN:-0}" -gt 0 ] 2>/dev/null; then
        echo "| — | N/A（未取到单电源 FRU/型号明细；但 IPMI PS*_Status 可见 ${PSU_SENSOR_SEEN} 颗电源在位，供电状态见下方说明） | — | — | — | — | — |"
    else
        echo "| — | N/A（无 PSU 数据：无电源 FRU 且电源传感器为空，可能采集时 BMC 传感器不可读） | — | — | — | — | — |"
    fi
fi)
$(
    # PSU 尾注（电源冗余/平台说明）；功耗读数移至下方独立表（v1.50.0）
    if [ "$PSU_REDUNDANT" != "N/A" ] || [ -n "$PSU_PLATFORM_NOTE" ]; then
        echo ""
    fi
    [ "$PSU_REDUNDANT" != "N/A" ] && echo "**电源冗余: ${PSU_REDUNDANT}**"
    # v1.50.0：在位/槽位对比——场地供电受限时可能不满配，如实标注供验收人核对，不做硬判定
    if [ -n "$PSU_SLOT_TOTAL" ]; then
        _pn=${PSU_SENSOR_SEEN:-0}
        [ "$_pn" -eq 0 ] 2>/dev/null && _pn=${PSU_COUNT_DMI:-0}
        if [ "$_pn" -gt 0 ] 2>/dev/null; then
            if [ "$_pn" -lt "$PSU_SLOT_TOTAL" ] 2>/dev/null; then
                printf '**电源配置: %s / %s 个槽位在位**\n' "$_pn" "$PSU_SLOT_TOTAL"
                printf '> ⚠️ 该机型共 %s 个电源槽位、当前 %s 个在位。若因场地供电限制（机柜单路/双路供电等）降配运行，请确认仍满足当前负载的冗余要求（N+1 / N+N），并在验收单备注\n' "$PSU_SLOT_TOTAL" "$_pn"
            else
                printf '**电源配置: %s / %s 个槽位（全部在位）**\n' "$_pn" "$PSU_SLOT_TOTAL"
            fi
        fi
    fi
    [ -n "$PSU_PLATFORM_NOTE" ] && echo "> ⚠️ ${PSU_PLATFORM_NOTE}"
)
$(if [ -n "$PWR_TABLE_MD" ]; then
    echo ""
    echo "### 功耗读数"
    echo "| 来源 | 读数 | 口径 |"
    echo "|------|------|------|"
    printf '%s' "$PWR_TABLE_MD"
    echo ""
    echo "> 各读数口径与时间基准不同（PSU 输入合计 / BMC DCMI 瞬时与窗口统计 / CPU 内部计数器），仅作对照参考，不互相印证；逐颗 PSU 实时功率见上表"
fi)

$(if [ -n "$PWR_CUR" ] || [ -n "$PWR_ENERGY" ]; then
    echo ""
    echo "## 能耗台账"
    echo "| 项 | 值 |"
    echo "|----|----|"
    [ -n "$PWR_CUR" ] && echo "| 当前功耗 | ${PWR_CUR} |"
    [ -n "$PWR_MIN" ] && echo "| 采样最小 | ${PWR_MIN} |"
    [ -n "$PWR_MAX" ] && echo "| 采样最大 | ${PWR_MAX} |"
    [ -n "$PWR_AVG" ] && echo "| 采样平均 | ${PWR_AVG} |"
    [ -n "$PWR_ENERGY" ] && echo "| 累计能耗 | ${PWR_ENERGY}${PWR_ENERGY_SRC:+（${PWR_ENERGY_SRC}）} |"
    [ -n "$PWR_NOTE" ] && echo ""
    [ -n "$PWR_NOTE" ] && echo "> ${PWR_NOTE}"
fi)

## 健康检查
| 项 | 状态 |
|----|------|
$(
    if [ "$GPU_COUNT" -eq 0 ]; then
        if [ "$HEAD_NODE" -eq 1 ]; then
            echo "| GPU PCIe 链路 | N/A（HGX 机头无本地 GPU，模组单独采集） |"
        else
            echo "| GPU PCIe 链路 | N/A（无 GPU） |"
        fi
    else
        echo "| GPU PCIe 链路 | ${GPU_DEGRADED:-✓ 全部正常} |"
    fi
    if [ "${NVLINK_HEALTH:-N/A}" != "N/A" ]; then
        echo "| NVLink | ${NVLINK_HEALTH}${NVLINK_CRC:+ (存在CRC错误)} |"
    fi
    if [ -n "$DCGM_SUMMARY" ] && [ "$DCGM_SUMMARY" != "N/A" ]; then
        echo "| DCGM 诊断 | ${DCGM_SUMMARY} |"
    elif [ "$HEAD_NODE" -eq 1 ]; then
        echo "| DCGM 诊断 | N/A（HGX 机头无 GPU，模组单独采集） |"
    fi
    if [ -n "$DCGM_NOTICE" ]; then
        echo "| ⚠️ DCGM | ${DCGM_NOTICE} |"
    fi
    # ─── v1.48.90：新增健康项（XID / MCE / IB 误码 / NVMe 错误 / RAID 缓存电池）───
    # 集中放在健康检查段：这五类都是「曾经出过事」的直接证据，客户/供应商谈判时最先看这里。
    if [ -n "${GPU_XID:-}" ]; then
        echo "| ⚠️ GPU XID 错误 | 检出 ${GPU_XID_COUNT} 类（来源: ${GPU_XID_SRC}）——详见 GPU 段明细 |"
    fi
    if [ -n "${MCE_HITS:-}" ]; then
        echo "| ⚠️ CPU MCE | 检出 ${MCE_COUNT} 条机器检查异常（来源: ${MCE_SRC}） |"
    fi
    if [ -n "${IB_PERF_NONZERO:-}" ]; then
        echo "| ⚠️ IB 链路误码 | ${IB_PERF_NONZERO} |"
    else
        case "${IB_COUNT:-0}" in
            ''|0) ;;
            # v1.51.1：**文件存在 ≠ 取到数据**——perfquery 失败时日志里只有 ibwarn/超时行，
            #   旧实现据此断言「✓ 性能计数器全部为 0」是**假 PASS**（链路未起/参数错都落到这里）。
            #   先确认真有计数器行，再有条件地报「全部为 0」；否则如实报未取到。
            *)
                _pqf="${NET_DIR:-}/perfquery.log"
                if [ -f "$_pqf" ]; then
                    if grep -qE 'Counter' "$_pqf" 2>/dev/null; then
                        echo "| IB 链路误码 | ✓ 性能计数器全部为 0 |"
                    else
                        echo "| IB 链路误码 | N/A（未取到端口计数器——所有 IB 口 LID=65535，SM 未分配，链路未起） |"
                    fi
                fi
                ;;
        esac
    fi
    # v1.48.96：NVMe 错误按 status_field 分类呈现——
    #   介质类（Write Fault/Unrecovered Read/Data Protection…）与掉电类（Unsafe Shutdown）
    #   才报 ⚠️；纯命令类（Invalid Field/Opcode/Namespace，主机侧命令不兼容）作提示，
    #   因为它**不是盘故障**（实测 opcode=0、lba 全 F，无任何读写失败）。
    if [ "${NVME_ERR_MEDIA:-0}" -gt 0 ] 2>/dev/null; then
        echo "| ⚠️ NVMe 介质错误 | ${NVME_ERR_MEDIA_D}（介质/盘自身类错误，建议复查该盘） |"
    fi
    if [ "${NVME_ERR_SHUTDOWN:-0}" -gt 0 ] 2>/dev/null; then
        echo "| ⚠️ NVMe 非正常掉电 | ${NVME_ERR_SHUTDOWN_D}（Unsafe Shutdown，建议排查供电/拔盘历史） |"
    fi
    if [ "${NVME_ERR_CMD:-0}" -gt 0 ] 2>/dev/null; then
        echo "| NVMe 命令兼容性 | ${NVME_ERR_CMD_D} Invalid Field（主机侧命令参数不被固件支持，非介质故障） |"
    fi
    if [ -n "${RAID_BBU_SUMMARY:-}" ]; then
        if [ "${RAID_BBU_WARN:-0}" -eq 1 ] 2>/dev/null; then
            echo "| ⚠️ RAID 缓存电池 | ${RAID_BBU_SUMMARY}（异常——与写缓存策略同看） |"
        else
            echo "| RAID 缓存电池 | ${RAID_BBU_SUMMARY} |"
        fi
    fi
    if [ -n "${RAID_CACHE_POLICY:-}" ]; then
        echo "| RAID 写缓存策略 | ${RAID_CACHE_POLICY} |"
    fi
)
| SEL PCIe 错误 | ${SEL_PCIE_ERR:-0} 条 |
| 线缆配对 | ${CABLE_PAIRS:-N/A（未取到模块 EEPROM 序列号——IB 链路未起，或该口未插光模块）} |

$(if [ -n "$TEST_DETAILS" ]; then
    echo ""
    echo "## 压测归档"
    echo "> 压测目录: ${TEST_DIR_LABEL}（test/ 压测脚本落盘，report 只读解析，不重跑）"
    echo ""
    echo "| 测试项 | 结果 | 耗时 | 详情文件 |"
    echo "|--------|------|------|-----------|"
    echo "$TEST_DETAILS" | while IFS='|' read -r tname tstatus telapsed tfile; do
        [ -z "$tname" ] && continue
        case "$tstatus" in
            通过) tst_disp="✅ 通过" ;;
            异常*) tst_disp="❌ ${tstatus}" ;;
            工具缺失) tst_disp="— 工具缺失" ;;
            *) tst_disp="$tstatus" ;;
        esac
        echo "| ${tname} | ${tst_disp} | ${telapsed}s | ${tfile} |"
    done
fi)

$(if [ -n "$FLD_SUMMARY" ]; then
    echo ""
    echo "## FLD 诊断参考"
    echo "> 目录: ${FLD_DIR_LABEL} · ${FLD_SUMMARY}"
    _fld_res=""
    case "$FLD_RESULT" in
        PASS) _fld_res="✅ PASS" ;;
        FAIL) _fld_res="❌ FAIL" ;;
        *)    _fld_res="${FLD_RESULT:-N/A}" ;;
    esac
    echo "> **最终结果: ${_fld_res}**"
    echo ""
    echo "| 测试项 | 结果 | 组件数 |"
    echo "|--------|------|--------|"
    printf '%s\n' "$FLD_DETAILS" | awk -F'|' '{
        cnt[$1]++
        if ($3 ~ /^OK/) ok[$1]++
        else if ($4 ~ /skip/ || $3 ~ /skip/) sk[$1]++
        else { fail[$1]++; failc[$1] = failc[$1] ($2 != "" ? $2 : "-") "," }
    } END {
        for (v in cnt) {
            st = "✅ PASS"
            if (fail[v] > 0) st = "❌ FAIL (" failc[v] ")"
            else if (sk[v] > 0) st = "— 跳过 (" sk[v] ")"
            printf "%s|%s|%d\n", v, st, cnt[v]
        }
    }' | sort | while IFS='|' read -r fvid fst fcnt; do
        echo "| ${fvid} | ${fst} | ${fcnt} |"
    done
    # 非 OK 明细（FAIL/跳过 逐组件列出，PASS 行不展开）
    if printf '%s\n' "$FLD_DETAILS" | grep -vqE '\|OK'; then
        echo ""
        echo "### 非通过项明细"
        echo "| 测试项 | 组件 | 结果 | 说明 |"
        echo "|--------|------|------|-----------|"
        printf '%s\n' "$FLD_DETAILS" | while IFS='|' read -r fvid fcomp fres fnote; do
            [ -z "$fvid" ] && continue
            case "$fres" in
                OK*) continue ;;
                *skip*) fdisp="— 跳过" ;;
                *) fdisp="❌ ${fres}" ;;
            esac
            echo "| ${fvid} | ${fcomp} | ${fdisp} | ${fnote} |"
        done
    fi
fi)

$(if [ -n "$BASELINE_COMPARE" ]; then
    echo ""
    echo "## 基线对比"
    echo "> ${BASELINE_COMPARE_NOTE}"
    echo ""
    echo "| 项 | 状态 | 当前 | 基线 |"
    echo "|----|------|------|-----------|"
    echo "$BASELINE_COMPARE" | while IFS='|' read -r bitem bst bcur bbase; do
        [ -z "$bitem" ] && continue
        case "$bst" in
            变化|新增) bst_disp="⚠️ ${bst}" ;;
            移除) bst_disp="❌ ${bst}" ;;
            *) bst_disp="$bst" ;;
        esac
        echo "| ${bitem} | ${bst_disp} | ${bcur} | ${bbase} |"
    done
fi)

---
## PCIe 链路明细（附录）
$(if [ "$PCIE_LINKS_TOTAL" -gt 0 ] 2>/dev/null && [ -n "$PCIE_LINK_TABLE" ]; then
    echo "> 全量 ${PCIE_LINKS_TOTAL} 条链路逐条状态（交付核对扩展板卡通路/模组接口用；异常行见「PCIe 拓扑与链路」摘要）"
    echo ""
    echo "| BDF | 设备 | LnkCap | LnkSta | 判定 |"
    echo "|-----|------|--------|--------|------|"
    printf '%s\n' "$PCIE_LINK_TABLE" | while IFS='|' read -r lbdf ldesc lcap lsta lverdict; do
        [ -z "$lbdf" ] && continue
        echo "| ${lbdf} | ${ldesc} | ${lcap} | ${lsta} | ${lverdict} |"
    done
    echo ""
else
    echo "| 数据 | N/A（旧采集无 pcie_full 全量日志） |"
fi)

---
## 术语说明

| 术语 | 说明 |
|------|------|
$(glossary_md)
$(if [ -n "$NIC_MLX" ]; then
    echo ""
    echo "### 网卡型号对照表"
    echo ""
    echo "| MT 编号 | 型号 |"
    echo "|---------|------|"
    echo "| MT4131 | ConnectX-8 |"
    echo "| MT4129 / MT2910 / MT4125 | ConnectX-7 |"
    echo "| MT4124 | ConnectX-6 Lx |"
    echo "| MT4123 | ConnectX-6 Dx |"
    echo "| MT4121 / MT4122 | ConnectX-6 |"
    echo "| MT2892 / MT2893 | ConnectX-5 |"
    echo "| MT2884 / MT2883 | ConnectX-4 |"
    echo ""
    echo "> ConnectX-9 / BlueField-4（NVIDIA Rubin 平台配套，SuperNIC 达 1.6 Tb/s RoCE）已发布，其 MT 编号待厂商资料确认后补入——未确认前不猜编号，避免误标"
fi)
---
*由 HwScope ${REPORT_VERSION:-unknown} 报告生成器生成（数据采集版本: ${VERSION:-unknown}）*

> 数据来源：只读解析采集日志（不重新采集）；"额定"为硬件规格，检测值为采集时刻实际状态；明细见 output/&lt;SN&gt;/&lt;模块&gt;/。
EOF
    echo -e "${GREEN}[REPORT] MD: ${f}${NC}"
}
