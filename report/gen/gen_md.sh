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
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur drank; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_md="${dimms_md}| ${dseq} | ${dslot} | ${dsize} | ${dmfr} | ${dsn} | ${dpn} | ${dnom} | ${dcur} | ${drank:-N/A} |"$'\n'
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
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip nport; do
            [ -z "$nnic" ] && continue
            nn=$((nn + 1))
            if [ "$_gd_col" -eq 1 ]; then
                nic_details_md="${nic_details_md}| ${nn} | ${nnic} | ${nnbdf} | ${nport:-—} | ${nmac} | ${nsn} | ${npn} | ${nchip:-} | ${nfw} | ${npcie} | ${npsid} | ${ngd:-} |"$'\n'
            else
                nic_details_md="${nic_details_md}| ${nn} | ${nnic} | ${nnbdf} | ${nport:-—} | ${nmac} | ${nsn} | ${npn} | ${nchip:-} | ${nfw} | ${npcie} | ${npsid} |"$'\n'
            fi
        done < <(printf '%s\n' "$NIC_DETAILS")
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
    cat > "$f" << EOF
# HwScope 硬件巡检报告

**采集版本:** ${VERSION:-unknown} · **报告生成器:** ${REPORT_VERSION:-unknown} · **主机:** ${HOSTNAME:-unknown} · **平台:** ${PLATFORM_LABEL:-unknown} · **时间:** ${TIMESTAMP:-unknown}

## 环境
| 项 | 值 |
|----|----|
| OS | ${OS_NAME:-N/A} |
| 内核 | ${KERNEL:-N/A} |
| 驱动 | ${GPU_DRIVER:-N/A} |
| CUDA | ${GPU_CUDA:-N/A} |
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
        _full=$((PCIE_LINKS_TOTAL - PCIE_SLOW_COUNT - PCIE_MGMT_COUNT))
        echo "| 链路统计 | ${PCIE_LINKS_TOTAL} 条 · 满速 ${_full} · 降速/降宽 ${PCIE_SLOW_COUNT} · 管理芯片 ${PCIE_MGMT_COUNT} |"
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
        echo "|---|--------|------|------|------|---------|---------|----------|"
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
| # | 插槽 | 容量 | 厂商 | SN | 部件号 | 额定速率 | 当前速率 | Rank |
|----|------|------|------|----|--------|--------|--------|------|
$(printf '%s' "$dimms_md")

## GPU
$(if [ "$GPU_COUNT" -eq 0 ]; then
    echo "| 项 | 值 |"
    echo "|----|----|"
    if [ "$HEAD_NODE" -eq 1 ]; then
        echo "| 状态 | HGX 机头（无本地 GPU，HGX 模组经 PCIe Fabric 单独接入，需单独采集） |"
    elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
        echo "| 状态 | ⚠️ 检测到 ${GPU_PCI_PRESENT} 个 NVIDIA GPU（PCI 3D controller），但 nvidia-smi 无数据（驱动未安装或异常） |"
    else
        echo "| 状态 | N/A（无 GPU） |"
    fi
else
    echo "| 项 | 值 |"
    echo "|----|----|"
    echo "| 数量 | ${GPU_COUNT:-0} |"
    echo "| 型号 | ${GPU_NAMES:-N/A} |"
    echo "| 显存总量 | ${GPU_MEM:-N/A}/${GPU_MEM_SPEC_TOTAL:-${GPU_MEM:-N/A}}（检测/额定${GPU_MEM_SPEC:+，${GPU_MEM_SPEC}}）${GPU_MEM_SPEC_NOTE:+ ${GPU_MEM_SPEC_NOTE}} |"
    echo "| 额定功耗 | ${GPU_POWER:-N/A} |"
    echo "| 温度 | ${GPU_TEMP:-N/A} |"
    echo "| ECC | ${GPU_ECC:-N/A} |"
    echo "| 退役行 | ${GPU_REMAP:-N/A} |"
    echo "| VBIOS | ${GPU_VBIOS:-N/A} |"
    if [ -n "$NV_LINK_SUMMARY" ] && [ "$NV_LINK_SUMMARY" != "N/A" ]; then
        echo "| NVLink | ${NV_LINK_SUMMARY} |"
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

$(if [ -n "$nvs_md" ]; then
    echo ""
    echo "## NVSwitch"
    echo "| 编号 | 状态 | 温度 | 活动/总端口 |"
    echo "|------|------|------|-------------|"
    printf '%s' "$nvs_md"
fi)

$(if [ -n "$FW_COMPLIANCE_DETAILS" ]; then
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

### 存储盘明细
| # | 设备 | 类型 | 容量$(if [ "$disk_has_spec" -eq 1 ]; then echo " | 额定"; fi) | 型号 | SN | 固件 | BDF | 通电(h) | 通电次数$(if [ "$disk_has_spare" -eq 1 ]; then echo " | 寿命%"; fi)$(if [ "$disk_has_health" -eq 1 ]; then echo " | 健康"; fi) |
|---|------|------|------$(if [ "$disk_has_spec" -eq 1 ]; then echo "|------"; fi)|------|----|------|-----|---------|----------$(if [ "$disk_has_spare" -eq 1 ]; then echo "|-------"; fi)$(if [ "$disk_has_health" -eq 1 ]; then echo "|------"; fi)|
$(printf '%s' "$disk_details_md")
$(if [ -n "$DISK_DETAILS" ] && { [ "$disk_has_spare" -eq 0 ] || [ "$disk_has_health" -eq 0 ]; }; then
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
| IB Link 状态 | Active ${IB_ACTIVE:-0} / Down ${IB_LINK_DOWN:-0}${IB_UNPLUGGED:+（未插线缆 ${IB_UNPLUGGED}）} |
| IB 额定速率 | ${IB_NOMINAL:-N/A} |
| 以太网口 up | ${ETH_LINK_UP:-0} |
$(net_extra_md)

### 网络适配器明细（NIC）
$(if [ "${GPU_TOPO_AVAIL:-0}" -eq 1 ] && [ "${GPU_DIRECT_COUNT:-0}" -gt 0 ]; then
    echo "| # | 接口 | BDF | 端口 | MAC | SN | 型号 | 芯片 | 固件 | PCIe(协商) | PSID | GPU直连 |"
    echo "|---|------|-----|------|-----|----|------|------|------|------|------|--------|"
elif [ "${GPU_TOPO_AVAIL:-0}" -eq 1 ]; then
    echo "> GPU直连 列已隐藏：本机无 GPU 直连网卡（网卡均不与 GPU 同 PCIe Switch；H200/B200 类 1:1 直连或 B300 板载网卡形态才会标记）"
    echo ""
    echo "| # | 接口 | BDF | 端口 | MAC | SN | 型号 | 芯片 | 固件 | PCIe(协商) | PSID |"
    echo "|---|------|-----|------|-----|----|------|------|------|------|------|"
else
    echo "| # | 接口 | BDF | 端口 | MAC | SN | 型号 | 芯片 | 固件 | PCIe(协商) | PSID |"
    echo "|---|------|-----|------|-----|----|------|------|------|------|------|"
fi)
$(printf '%s' "$nic_details_md")
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

$(if [ -n "$USB_NICS" ]; then
    echo "另发现 USB 外接网卡（非 PCIe，不参与网卡统计）:"
    echo ""
    echo "| 接口 | MAC | 型号 | 固件 |"
    echo "|------|-----|------|------|"
    while IFS='|' read -r unnic unmac unpn unfw; do
        [ -z "$unnic" ] && continue
        echo "| ${unnic} | ${unmac} | ${unpn:-—} | ${unfw:-—} |"
    done < <(printf '%s\n' "$USB_NICS")
fi)

## BMC
| 项 | 值 |
|----|----|
| 型号 | ${BMC_FRU:-N/A} |
| 固件 | ${BMC_FW:-N/A} |
| IP | ${BMC_IP:-N/A} |
| MAC | ${BMC_MAC:-N/A} |
| SEL 事件 | $(if [ "${SEL_DATA_VALID:-0}" -eq 1 ] 2>/dev/null; then echo "${SEL_TOTAL:-0}（Critical ${SEL_CRIT:-0}）"; else echo "⚠️ 数据不可用"; fi) |
$(if [ "${SEL_DATA_VALID:-0}" -eq 0 ] 2>/dev/null; then
    echo "> ⚠️ SEL 数据不可用（ipmitool 采集失败或无权限），事件列表不完整"
elif [ -n "$SEL_DETAILS" ]; then
    echo "### SEL 告警事件"
    echo "| # | 日期 | 时间 | 类型 | 描述 |"
    echo "|---|------|------|------|------|"
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

## 风扇
| 项 | 值 |
|----|----|
| 数量 | ${FAN_COUNT:-0} |
| 转速 | ${FAN_SPEED:-N/A} |
| 冗余 | ${FAN_REDUNDANT:-N/A}$(if [ -n "$FAN_EXTRA" ]; then echo "（${FAN_EXTRA}）"; fi) |
| 温度 | ${TEMP_SUMMARY:-N/A} |
$(if [ -n "$FAN_DETAILS" ]; then
    echo "### 散热风扇明细"
    echo "| # | 风扇 | 转速(RPM) | 状态 |"
    echo "|---|------|----------|------|"
    fan_seq=0
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        fan_seq=$((fan_seq+1))
        echo "| ${fan_seq} | ${fname} | ${fval} | ${fstatus} |"
    done
elif [ "${FAN_COUNT:-0}" -eq 0 ] 2>/dev/null; then
    echo "> ⚠️ 未采集到风扇数据（ipmitool 风扇传感器不可读或平台无风扇传感器）"
fi)

## 电源 PSU
### 电源模块明细（PSU）
| # | 描述 | 型号 | 部件号 | 序列号 | 额定容量 | 当前功耗 |
|----|------|------|--------|--------|---------|---------|
$(if [ -n "$PSU_DETAILS" ]; then
    pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "${pcap:-N/A}" "${ppower:-N/A}"
    done < <(printf '%s\n' "$PSU_DETAILS")
else
    echo "| — | N/A（无 PSU 数据：无电源 FRU 且电源传感器为空，可能采集时 BMC 传感器不可读） | — | — | — | — | — |"
fi)
$(
    # PSU 尾注（冗余/整机功耗/DCMI/平台说明），合并块避免空输出堆积空行
    if [ "$PSU_REDUNDANT" != "N/A" ] || [ -n "$PSU_EXTRA" ] || [ -n "$PSU_DCMI" ]; then
        echo ""
    fi
    [ "$PSU_REDUNDANT" != "N/A" ] && echo "**电源冗余: ${PSU_REDUNDANT}**"
    [ -n "$PSU_EXTRA" ] && echo "**${PSU_EXTRA}**"
    [ -n "$PSU_DCMI" ] && echo "**${PSU_DCMI}**"
    [ -n "$PSU_PLATFORM_NOTE" ] && echo "> ⚠️ ${PSU_PLATFORM_NOTE}"
)

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
)
| SEL PCIe 错误 | ${SEL_PCIE_ERR:-0} 条 |
| 线缆配对 | ${CABLE_PAIRS:-N/A} |

$(if [ -n "$TEST_DETAILS" ]; then
    echo ""
    echo "## 压测归档"
    echo "> 压测目录: ${TEST_DIR_LABEL}（test/ 压测脚本落盘，report 只读解析，不重跑）"
    echo ""
    echo "| 测试项 | 结果 | 耗时 | 详情文件 |"
    echo "|--------|------|------|---------|"
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
        echo "|--------|------|------|------|"
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
    echo "|----|------|------|------|"
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
fi)
---
*由 HwScope ${REPORT_VERSION:-unknown} 报告生成器生成（数据采集版本: ${VERSION:-unknown}）*

> 数据来源：只读解析采集日志（不重新采集）；"额定"为硬件规格，检测值为采集时刻实际状态；明细见 output/&lt;SN&gt;/&lt;模块&gt;/。
EOF
    echo -e "${GREEN}[REPORT] MD: ${f}${NC}"
}
