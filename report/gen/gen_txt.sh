#!/bin/bash
# =============================================================================
# HwScope - TXT 报告生成器 gen_txt
# report/gen/gen_txt.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
gen_txt() {
    local f="${OUT}/hwscope_report.txt"
    # 内存插槽明细纯文本（紧凑单行）
    local dimms_txt=""
    if [ -n "$MEM_DIMMS" ]; then
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur drank dwidth; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_txt="${dimms_txt}    ${dseq}. ${dslot}  ${dsize}  ${dmfr}  SN:${dsn}  P/N:${dpn}  额定${dnom}/现${dcur}  Rank:${drank:-N/A}${dwidth:+ ${dwidth}}"$'\n'
        done < <(printf '%s\n' "$MEM_DIMMS")
    fi
    # GPU 每卡明细纯文本
    local gpu_details_txt=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存 可用/总 + 功耗 当前/上限（双值让客户看到余量）
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gused glimit gvb; do
            [ -z "$gidx" ] && continue
            # PCIe 合并：满速只显当前值，降速才标注能力（如 "5x8 (能力 5x16)"）
            gpcie_disp="$gpcie"
            if [ "$gpcie" != "N/A" ] && [ "$gmax" != "N/A" ] && [ -n "$gmax" ] && [ "$gpcie" != "$gmax" ]; then
                gpcie_disp="${gpcie} (能力 ${gmax})"
            fi
            # 显存 检测/额定（检测=采集可见值 GiB，额定=规格 GB）
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
            # v1.44.0 SXM 适配：SXM 平台该值实为 NVLink 通道协商（模组无 CPU 直连 PCIe 链路）
            _gpu_link_lbl="PCIe(协商)"
            case "${PLATFORM_LABEL:-}" in *SXM*) _gpu_link_lbl="NVLink(协商)" ;; esac
            gpu_details_txt="${gpu_details_txt}    GPU${gidx}  ${gname}  SN:${gsn}  显存:${gmem_disp}  功耗:${gdraw_disp}  ${gtemp}  ${_gpu_link_lbl}:${gpcie_disp}  VBIOS:${gvb:-N/A}"$'\n'
        done < <(printf '%s\n' "$GPU_DETAILS")
    fi
    # 盘明细纯文本
    local disk_details_txt=""
    # 整列隐藏判定（同 MD）：寿命%/额定/健康 整列无值省略字段（旧采集无 SMART）
    local disk_has_spare=0 disk_has_spec=0 disk_has_health=0
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            [ -n "$dspare" ] && [ "$dspare" != "—" ] && [ "$dspare" != "N/A" ] && disk_has_spare=1
            [ -n "$dspec" ] && [ "$dspec" != "—" ] && [ "$dspec" != "N/A" ] && disk_has_spec=1
            [ -n "$dhealth" ] && [ "$dhealth" != "—" ] && [ "$dhealth" != "N/A" ] && disk_has_health=1
        done < <(printf '%s\n' "$DISK_DETAILS")
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            _spare_txt=""; [ "$disk_has_spare" -eq 1 ] && _spare_txt="  spare:${dspare}"
            _spec_txt="";  [ "$disk_has_spec" -eq 1 ] && _spec_txt="  ${dspec:-}"
            _health_txt=""; [ "$disk_has_health" -eq 1 ] && _health_txt="  健康:${dhealth}"
            disk_details_txt="${disk_details_txt}    ${dname}  ${dtype}  ${dsize}${_spec_txt}  ${dmodel}  SN:${dsn}  FW:${dfw}  ${dbdf}  ${dpo}h  cyc:${dpc}${_spare_txt}${_health_txt}"$'\n'
        done < <(printf '%s\n' "$DISK_DETAILS")
    fi
    # 网卡明细纯文本（TXT 专用；PSID/MST 提示并入开头，避免命令替换剥尾换行粘连）
    local nic_details_txt=""
    [ -n "$PSID_NOTICE" ] && nic_details_txt="  ${PSID_NOTICE}"$'\n'
    [ -n "$MST_NOTICE" ] && nic_details_txt="${nic_details_txt}  ⚠️ ${MST_NOTICE}"$'\n'
    if [ -n "$NIC_DETAILS" ]; then
        local _gd_col=0
        [ "${GPU_TOPO_AVAIL:-0}" -eq 1 ] && [ "${GPU_DIRECT_COUNT:-0}" -gt 0 ] && _gd_col=1
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip nport nlink; do
            [ -z "$nnic" ] && continue
            if [ "$_gd_col" -eq 1 ]; then
                nic_details_txt="${nic_details_txt}    ${nnic}  ${nnbdf}  口:${nport:-—}  ${nmac}  SN:${nsn}  ${npn}  FW:${nfw}  PCIe(协商):${npcie}  PSID:${npsid}  ${ngd:-}${nchip:+ 芯片:${nchip}}  Link:${nlink:-—}"$'\n'
            else
                nic_details_txt="${nic_details_txt}    ${nnic}  ${nnbdf}  口:${nport:-—}  ${nmac}  SN:${nsn}  ${npn}  FW:${nfw}  PCIe(协商):${npcie}  PSID:${npsid}${nchip:+ 芯片:${nchip}}  Link:${nlink:-—}"$'\n'
            fi
        done < <(printf '%s\n' "$NIC_DETAILS")
        if [ "${GPU_TOPO_AVAIL:-0}" -eq 1 ] && [ "${GPU_DIRECT_COUNT:-0}" -eq 0 ]; then
            nic_details_txt="${nic_details_txt}  (本机无 GPU 直连网卡，GPU直连列隐藏)"$'\n'
        fi
    fi
    # USB 外接网卡（非 PCIe）追加到明细末尾，独立成段
    if [ -n "$USB_NICS" ]; then
        nic_details_txt="${nic_details_txt}  -- USB 外接网卡（非 PCIe，不参与统计） --"$'\n'
        while IFS='|' read -r unnic unmac unpn unfw; do
            [ -z "$unnic" ] && continue
            nic_details_txt="${nic_details_txt}    ${unnic}  ${unmac}  ${unpn:-—}  FW:${unfw:-—}"$'\n'
        done < <(printf '%s\n' "$USB_NICS")
    fi
    # NVSwitch 纯文本
    local nvs_txt=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_txt="${nvs_txt}    NVSwitch${nidx}  ${nstat}  ${ntemp}  端口:${nports}"$'\n'
        done < <(printf '%s\n' "$NVS_DETAILS")
    fi
    # CPU 每 Socket 明细纯文本
    local cpu_details_txt=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_txt="${cpu_details_txt}    ${csocket}  ${cmodel}  ${ccores}C/${cthreads}T  ${cmaxspd}/${ccurspd}  ${cstep}"$'\n'
        done < <(printf '%s\n' "$CPU_DETAILS")
    fi
    # SEL 最近事件纯文本
    local sel_details_txt=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_txt="${sel_details_txt}    ${sid}  ${sdate} ${stime}  ${stype}  ${sdesc}"$'\n'
        done < <(printf '%s\n' "$SEL_DETAILS")
    fi
    # 风扇明细纯文本
    local fan_details_txt=""
    if [ -n "$FAN_DETAILS" ]; then
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fan_details_txt="${fan_details_txt}    ${fname}  ${frpm} RPM  ${fstatus}"$'\n'
        done < <(printf '%s\n' "$FAN_DETAILS")
    fi
    cat > "$f" << EOF
============================================
HwScope 硬件巡检报告
============================================
采集版本: ${VERSION:-unknown}    报告生成器: ${REPORT_VERSION:-unknown}    主机: ${HOSTNAME:-unknown}
平台: ${PLATFORM_LABEL:-unknown}   时间: ${TIMESTAMP:-unknown}

[环境]
  OS     : ${OS_NAME:-N/A}
  内核   : ${KERNEL:-N/A}
  驱动   : ${GPU_DRIVER:-N/A}
形态   : ${MACHINE_CLASS_LABEL:-${MACHINE_CLASS:-N/A}}
  CUDA   : ${GPU_CUDA:-N/A}
  采集耗时 : ${TIMING_TOTAL:-N/A}

[主板]
  制造商 : ${MB_MANUFACTURER:-N/A}
  型号   : ${MB_PRODUCT:-N/A}
  SN     : ${MB_SN:-N/A}
  主板SN : ${MB_BOARD_SN:-N/A}
  BIOS   : ${BIOS_VERSION:-N/A}
  机箱SN : ${CHASSIS_SN:-N/A}$(if [ -n "$FABRIC_SW" ] && [ "$GPU_COUNT" -eq 0 ]; then printf '\n  PCIe Fabric Switch: %s（HGX 模组互联通道）' "$FABRIC_SW"; fi)

-- PCIe 拓扑与链路 --$(if [ -n "$PCIE_PEX_DETAILS" ] || [ -n "$PCIE_SLOW_LINKS" ] || [ "$PCIE_LINKS_TOTAL" -gt 0 ]; then
    if [ -n "$PCIE_PEX_DETAILS" ]; then printf '\n  Fabric Switch : %s' "$PCIE_PEX_DETAILS"; fi
    if [ "$PCIE_LINKS_TOTAL" -gt 0 ] && [ -n "$PCIE_LINK_TABLE" ]; then
        printf '\n  链路统计     : %s 条 · 满速 %s · 降速/降宽 %s · 管理芯片 %s' "$PCIE_LINKS_TOTAL" "$((PCIE_LINKS_TOTAL - PCIE_SLOW_COUNT - PCIE_MGMT_COUNT))" "$PCIE_SLOW_COUNT" "$PCIE_MGMT_COUNT"
        if [ "$PCIE_SLOW_COUNT" -gt 0 ] 2>/dev/null; then
            printf '\n  ⚠️ 降速/降宽链路:'
            printf '%s\n' "$PCIE_LINK_TABLE" | while IFS='|' read -r lbdf ldesc lcap lsta lverdict; do
                [ -z "$lbdf" ] && continue
                case "$lverdict" in *⚠️*) printf '\n    %-9s %-42s %-9s %-9s %s' "$lbdf" "$(printf '%.40s' "$ldesc")" "$lcap" "$lsta" "$lverdict" ;; esac
            done
        else
            printf '\n  链路状态     : 全部非管理芯片链路满速（全量明细见文末附录）'
        fi
        if [ "$PCIE_MGMT_COUNT" -gt 0 ] 2>/dev/null; then
            printf '\n  管理芯片     : %s 条固有低速为正常现象，不计链路异常' "$PCIE_MGMT_COUNT"
        fi
    elif [ -n "$PCIE_SLOW_LINKS" ]; then
        printf '\n  ⚠️ 降速/降宽链路:'
        printf '%s\n' "$PCIE_SLOW_LINKS" | while IFS= read -r line; do printf '\n    - %s' "$line"; done
    elif [ "$PCIE_LINKS_TOTAL" -gt 0 ]; then
        printf '\n  链路状态     : ✅ 全部 %s 条链路满速（无降速/降宽）' "$PCIE_LINKS_TOTAL"
    fi
else
    printf '\n  链路数据     : N/A（旧采集无 pcie_full 全量日志，链路检测需重新采集）'
fi)

[CPU]
  型号   : ${CPU_MODEL:-N/A}
  核心数 : ${CPU_CORES:-N/A}/颗 × ${CPU_SOCKETS:-N/A} 路 = ${CPU_TOTAL_CORES:-N/A} 总核
  插槽数 : ${CPU_SOCKETS:-N/A}
  Stepping: ${CPU_STEPPING:-N/A}
  频率   : ${CPU_MAX_SPEED:-N/A} MHz (当前 ${CPU_CUR_SPEED:-N/A} MHz)
$(if [ -n "$CPU_DETAILS" ]; then
    echo "  CPU明细:"
    echo "$CPU_DETAILS" | while IFS='|' read -r cs cm cc ct cmx ccur cstep csn; do
        if [ -n "$csn" ]; then
            printf "    %-6s %-30s %sC/%sT  %s/%s  %s  SN:%s\n" "$cs" "$cm" "$cc" "$ct" "$cmx" "$ccur" "$cstep" "$csn"
        else
            printf "    %-6s %-30s %sC/%sT  %s/%s  %s\n" "$cs" "$cm" "$cc" "$ct" "$cmx" "$ccur" "$cstep"
        fi
    done
fi)

[内存]
  总量   : ${MEM_TOTAL_PHYS:-${MEM_TOTAL:-N/A}}/${MEM_TOTAL:-N/A} 可见
  类型   : ${MEM_TYPE:-N/A}
  速率   : ${MEM_SPEED:-N/A} ${MEM_SPEED_NOTE:-}
  插槽   : ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A}
$(printf '%s' "$dimms_txt")

[GPU]
$(if [ "$GPU_COUNT" -eq 0 ]; then
    if [ "$HEAD_NODE" -eq 1 ]; then
        echo "  HGX 机头（无本地 GPU，HGX 模组经 PCIe Fabric 单独接入，需单独采集）"
    elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
        echo "  ⚠️ 检测到 ${GPU_PCI_PRESENT} 个 ${GPU_PCI_VENDOR:-} GPU（PCI 3D controller/加速卡），但管理工具无数据（驱动未安装或异常）"
    else
        echo "  N/A (无 GPU)"
    fi
else
    echo "  数量   : ${GPU_COUNT:-0}"
    echo "  型号   : ${GPU_NAMES:-N/A}"
    echo "  显存   : ${GPU_MEM:-N/A}/${GPU_MEM_SPEC_TOTAL:-${GPU_MEM:-N/A}}（检测/额定${GPU_MEM_SPEC:+，${GPU_MEM_SPEC}}）${GPU_MEM_SPEC_NOTE:+ ${GPU_MEM_SPEC_NOTE}}"
   if [ -n "${GPU_AMD_SUSPECT:-}" ]; then
       echo "  显存异常: ⚠️ ${GPU_AMD_SUSPECT%, }（疑似显存魔改或伪装，需核实）"
   fi
    echo "  功耗   : ${GPU_POWER:-N/A}（额定）"
    echo "  温度   : ${GPU_TEMP:-N/A}"
    echo "  ECC    : ${GPU_ECC:-N/A}"
    echo "  退役行 : ${GPU_REMAP:-N/A}"
    echo "  VBIOS  : ${GPU_VBIOS:-N/A}"
    if [ -n "${GPU_ASCEND_NOTE:-}" ]; then
        echo "  昇腾   : ${GPU_ASCEND_NOTE}"
    fi
fi)$(if [ -n "$NV_LINK_SUMMARY" ] && [ "$NV_LINK_SUMMARY" != "N/A" ]; then echo "  NVLink   : ${NV_LINK_SUMMARY}"; fi)$(if [ -n "${GPU_XGMI_SUMMARY:-}" ]; then echo "  xGMI     : ${GPU_XGMI_SUMMARY}"; fi)$(if [ "$GPU_COUNT" -gt 0 ]; then printf '%s' "$gpu_details_txt"; fi)$(if [ -n "$nvs_txt" ]; then printf '\n[NVSwitch]\n'; printf '%s' "$nvs_txt"; fi)$(if [ -n "$FW_COMPLIANCE_DETAILS" ]; then
    printf '\n[固件合规]\n'
    echo "$FW_COMPLIANCE_DETAILS" | while IFS='|' read -r fc fd fcur fbase fst fnote; do
        [ -z "$fc" ] && continue
        case "$fst" in
            落后) fst="⚠️ $fst" ;;
            合规) fst="✅ $fst" ;;
        esac
        printf '  %-10s %-26s 当前:%s  推荐:%s  %s  %s\n' "$fc" "$fd" "$fcur" "$fbase" "$fst" "$fnote"
    done
    [ -n "$FW_SUMMARY" ] && printf '  %s\n' "$FW_SUMMARY"
fi)

[存储]
  盘数   : ${STORAGE_COUNT:-0}
  总容量 : ${STORAGE_TOTAL:-N/A}
  盘型号 : ${STORAGE_MODELS:-N/A}
  系统盘 : ${SYS_DISK:-N/A} (已从统计排除)$(if [ -n "$disk_details_txt" ]; then printf '\n%s' "$disk_details_txt"; fi)$(if [ -n "$RAID_VD_DETAILS" ]; then
    printf '\n  RAID虚拟盘（逻辑盘）:\n'
    echo "$RAID_VD_DETAILS" | while IFS='|' read -r rvdname rvdmodel rvdsize rvdsn; do
        [ -z "$rvdname" ] && continue
        printf '    %s  %s  %s  SN(LUN):%s\n' "$rvdname" "$rvdmodel" "$rvdsize" "${rvdsn:-N/A}"
    done
fi)$(if [ -n "$RAID_DETAILS" ]; then
    printf '\n[RAID控制器]\n'
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd rvd_list; do
        [ -z "$ridx" ] && continue
        printf '  %s  %s  SN:%s  固件:%s  虚拟盘:%s\n' "$ridx" "$rmodel" "$rsn" "$rfw" "$rvd"
        if [ -n "$rvd_list" ]; then
            echo "$rvd_list" | tr ';' '\n' | while IFS= read -r vdline; do
                [ -z "$vdline" ] && continue
                vdname="${vdline%%:*}"
                vdrest="${vdline#*:}"
                printf '    %s  %s\n' "$vdname" "$vdrest"
            done
        fi
    done
fi)$(if [ -z "$RAID_DETAILS" ] && [ -n "$RAID_PCI_PRESENT" ]; then
    printf '\n[RAID控制器]\n'
    printf '  ⚠️ 检测到 RAID 控制器（%s），但 storcli64 未安装或采集失败——RAID 配置/虚拟盘/底层盘信息不可用，需现场安装 storcli64 后重采\n' "$(echo "$RAID_PCI_PRESENT" | sed 's/.*: //' | xargs)"
elif [ -z "$RAID_DETAILS" ] && [ -n "$MD_RAID_LIST" ]; then
    printf '\n[RAID控制器]\n'
    printf '  ℹ️ Linux 软件 RAID（mdadm）: %s（系统级软 RAID，非硬件 RAID 卡）\n' "$MD_RAID_LIST"
elif [ -z "$RAID_DETAILS" ] && [ "${RAID_VMD_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
    printf '\n[RAID控制器]\n'
    printf '  ℹ️ 检测到 Intel VMD NVMe RAID（虚拟 RAID，非独立卡，由系统管理）\n'
fi)$(if [ -n "$HBA_DETAILS" ]; then
    printf '\n[HBA直通卡]\n'
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat hsas hports; do
        [ -z "$hname" ] && continue
        printf '  %s  %s  固件:%s  SN:%s  状态:%s  SAS:%s  端口:%s\n' "$hname" "$htype" "$hfw" "$hsn" "$hstat" "$hsas" "$hports"
    done
fi)$(if [ -z "$HBA_DETAILS" ] && [ -n "$HBA_PCI_PRESENT" ]; then
    printf '\n[HBA直通卡]\n'
    printf '  ⚠️ 检测到 SAS HBA（%s），但 sas3ircu/sas2ircu 未安装或采集失败——HBA 型号/固件/端口信息不可用\n' "$(echo "$HBA_PCI_PRESENT" | sed 's/.*: //' | xargs)"
fi)

[网络]
  IB设备 : ${IB_COUNT:-0}
  活动口 : ${IB_ACTIVE:-0}${IB_ACTIVE_SPEED:+ (${IB_ACTIVE_SPEED})}
  Link状态: Active ${IB_ACTIVE:-0} / Down ${IB_LINK_DOWN:-0}${IB_UNPLUGGED:+（未插线缆 ${IB_UNPLUGGED}）}
  额定速率: ${IB_NOMINAL:-N/A}
  网口up : ${ETH_LINK_UP:-0}$(net_extra_txt)$(if [ -n "$nic_details_txt" ]; then printf '\n%s' "$nic_details_txt"; fi)$(if printf '%s\n' "$nic_details_txt" | grep -q "能力 " 2>/dev/null; then printf '\n  注: PCIe(协商) 标"(能力 …)"= 卡能力高于当前协商，多为平台通路设计（扩展板卡/端口按 x8 配置、BIOS 端口拆分），非链路故障\n'; fi)$(if [ -z "$nic_details_txt" ] && [ -n "$NIC_FALLBACK_DETAILS" ]; then
    printf '\n  网卡明细（ibstat 回退，旧采集无 nic_inventory）:\n'
    echo "$NIC_FALLBACK_DETAILS" | while IFS='|' read -r fca ftype fguid fstate; do
        [ -z "$fca" ] && continue
        printf '    %s  %s  GUID:%s  %s\n' "$fca" "$ftype" "$fguid" "$fstate"
    done
fi)

[BMC]
  型号   : ${BMC_FRU:-N/A}
  固件   : ${BMC_FW:-N/A}
  IP     : ${BMC_IP:-N/A}
  MAC    : ${BMC_MAC:-N/A}
  SEL    : $(if [ "${SEL_DATA_VALID:-0}" -eq 1 ] 2>/dev/null; then echo "${SEL_TOTAL:-0} (Critical ${SEL_CRIT:-0})"; else echo "⚠️ 数据不可用"; fi)
$(if [ "${SEL_DATA_VALID:-0}" -eq 0 ] 2>/dev/null; then
    echo "  ⚠️ SEL 数据不可用（ipmitool 采集失败或无权限），事件列表不完整"
elif [ -n "$SEL_DETAILS" ]; then
    echo "  SEL告警事件:"
    echo "$SEL_DETAILS" | while IFS='|' read -r sid sdate stime stype sdesc; do
        printf "    %-4s %-12s %-10s %-25s %s\n" "$sid" "$sdate" "$stime" "$stype" "$sdesc"
    done
else
    echo "  告警事件: 无"
fi)$(if [ -n "$BMC_CONSISTENCY" ]; then
    printf '\n  BMC 一致性校验（OS vs BMC，零新采集）:\n'
    echo "$BMC_CONSISTENCY" | while IFS='|' read -r bitem bos bbmc bres; do
        [ -z "$bitem" ] && continue
        printf '    %-8s OS:%s  BMC:%s  %s\n' "$bitem" "$bos" "$bbmc" "$bres"
    done
    printf '    （不一致 = 潜在刷 SN/换件/固件不匹配风险）\n'
fi)

[风扇]
  数量   : ${FAN_COUNT:-0}
  转速   : ${FAN_SPEED:-N/A}
  冗余   : ${FAN_REDUNDANT:-N/A}$(if [ -n "$FAN_EXTRA" ]; then echo "（${FAN_EXTRA}）"; fi)
  温度   : ${TEMP_SUMMARY:-${TEMP_SUMMARY_OS:-N/A}}
$(if [ -n "$FAN_DETAILS" ]; then
    echo "  风扇明细:"
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        printf "    %-16s %8s RPM  %s\n" "$fname" "$fval" "$fstatus"
    done
elif [ "${FAN_COUNT:-0}" -eq 0 ] 2>/dev/null; then
    echo "  ⚠️ 未采集到风扇数据（ipmitool 风扇传感器不可读或平台无风扇传感器）"
fi)

[电源PSU]
$(if [ -n "$PSU_DETAILS" ]; then
    pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '  %s. %s  %s  PN:%s  SN:%s  容量:%s  当前功耗:%s\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "${pcap:-N/A}" "${ppower:-N/A}"
    done < <(printf '%s\n' "$PSU_DETAILS")
else echo "  N/A（无 PSU 数据：无电源 FRU 且电源传感器为空，可能采集时 BMC 传感器不可读）"; fi)$(if [ -n "$PSU_NOTE_TXT" ]; then printf '\n%s' "$PSU_NOTE_TXT"; fi)$(if [ -n "$PWR_CUR" ] || [ -n "$PWR_ENERGY" ]; then
    printf '\n[能耗台账]\n'
    [ -n "$PWR_CUR" ] && printf '  当前功耗 : %s\n' "$PWR_CUR"
    [ -n "$PWR_MIN" ] && printf '  采样最小 : %s\n' "$PWR_MIN"
    [ -n "$PWR_MAX" ] && printf '  采样最大 : %s\n' "$PWR_MAX"
    [ -n "$PWR_AVG" ] && printf '  采样平均 : %s\n' "$PWR_AVG"
    [ -n "$PWR_ENERGY" ] && printf '  累计能耗 : %s%s\n' "$PWR_ENERGY" "${PWR_ENERGY_SRC:+（${PWR_ENERGY_SRC}）}"
    [ -n "$PWR_NOTE" ] && printf '  %s\n' "$PWR_NOTE"
fi)

[健康检查]
$(printf '%s' "$HEALTH_TXT")
  SEL PCIe : ${SEL_PCIE_ERR:-0} 条错误
  线缆配对 : ${CABLE_PAIRS:-N/A}$(if [ -n "$TEST_DETAILS" ]; then
    printf '\n\n[压测归档]  目录: %s\n' "$TEST_DIR_LABEL"
    echo "$TEST_DETAILS" | while IFS='|' read -r tname tstatus telapsed tfile; do
        [ -z "$tname" ] && continue
        case "$tstatus" in
            通过) tst="✅ 通过" ;;
            异常*) tst="❌ $tstatus" ;;
            工具缺失) tst="— 工具缺失" ;;
            *) tst="$tstatus" ;;
        esac
        printf '  %-24s %-16s %5ss  %s\n' "$tname" "$tst" "$telapsed" "$tfile"
    done
fi)$(if [ -n "$FLD_SUMMARY" ]; then
    printf '\n\n[FLD 诊断参考]  %s\n' "$FLD_SUMMARY"
    printf '最终结果: '
    case "$FLD_RESULT" in
        PASS) echo "✅ PASS" ;;
        FAIL) echo "❌ FAIL" ;;
        *)    echo "${FLD_RESULT:-N/A}" ;;
    esac
    printf '%-24s %s\n' "测试项" "结果"
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
        printf '  %-22s %s\n' "$fvid" "$fst"
    done
    if printf '%s\n' "$FLD_DETAILS" | grep -vqE '\|OK'; then
        echo "非通过项明细:"
        printf '%s\n' "$FLD_DETAILS" | while IFS='|' read -r fvid fcomp fres fnote; do
            [ -z "$fvid" ] && continue
            case "$fres" in
                OK*) continue ;;
                *skip*) fdisp="— 跳过" ;;
                *) fdisp="❌ ${fres}" ;;
            esac
            printf '  %-22s %-12s %s  %s\n' "$fvid" "$fcomp" "$fdisp" "$fnote"
        done
    fi
fi)$(if [ -n "$BASELINE_COMPARE" ]; then
    printf '\n[基线对比]  %s\n' "$BASELINE_COMPARE_NOTE"
    echo "$BASELINE_COMPARE" | while IFS='|' read -r bitem bst bcur bbase; do
        [ -z "$bitem" ] && continue
        printf '  %-26s %-6s 当前:%s  基线:%s\n' "$bitem" "$bst" "$bcur" "$bbase"
    done
fi)

-- PCIe 链路明细（附录） --$(if [ "$PCIE_LINKS_TOTAL" -gt 0 ] 2>/dev/null && [ -n "$PCIE_LINK_TABLE" ]; then
    printf '\n  全量 %s 条链路逐条状态（交付核对扩展板卡通路/模组接口用；异常行见「PCIe 拓扑与链路」摘要）' "$PCIE_LINKS_TOTAL"
    printf '%s\n' "$PCIE_LINK_TABLE" | while IFS='|' read -r lbdf ldesc lcap lsta lverdict; do
        [ -z "$lbdf" ] && continue
        printf '\n    %-9s %-42s %-9s %-9s %s' "$lbdf" "$(printf '%.40s' "$ldesc")" "$lcap" "$lsta" "$lverdict"
    done
else
    printf '\n  数据: N/A（旧采集无 pcie_full 全量日志）'
fi)

[术语说明]
$(glossary_txt)
$(if [ -n "$NIC_MLX" ]; then
    echo ""
    echo "网卡型号对照 (MT 编号 → 型号, lspci 直读优先):"
    echo "  MT4131=ConnectX-8  MT4129/MT2910/MT4125=ConnectX-7  MT4124=ConnectX-6 Lx"
    echo "  MT4123=ConnectX-6 Dx  MT4121/MT4122=ConnectX-6  MT2892/MT2893=ConnectX-5  MT2884/MT2883=ConnectX-4"
fi)
--------------------------------------------
数据来源: 只读解析采集日志（不重新采集）；"额定"为硬件规格，检测值为采集时刻实际状态；明细见 output/<SN>/<模块>/。
--------------------------------------------
由 HwScope ${REPORT_VERSION:-unknown} 报告生成器生成（数据采集版本: ${VERSION:-unknown}）
EOF
    echo -e "${GREEN}[REPORT] TXT: ${f}${NC}"
}

# ─── HTML 报告（MD → HTML，md2html.awk 内嵌专业样式；交付/展示用）───
