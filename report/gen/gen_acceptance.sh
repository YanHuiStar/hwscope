#!/bin/bash
# =============================================================================
# HwScope - 验收清单生成器 gen_acceptance（15 项判定 + 配置单）
# report/gen/gen_acceptance.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
gen_acceptance() {
    local f="${OUT}/hwscope_acceptance.md"
    local n=0 pass=0 fail=0 warn=0 na=0
    local rows="" st=""
    local verdict="合格"

    # 逐项评估函数：add_item "名称" "状态" "说明" [不计入N/A=1]
    # 第4参数=1 时 N/A 不计数（机头 GPU 项：无 GPU 是平台固有形态，非数据缺失，不计入"数据不足"判定）
    add_item() {
        n=$((n + 1))
        case "$2" in
            PASS) pass=$((pass + 1)); st="✅ PASS" ;;
            FAIL) fail=$((fail + 1)); st="❌ FAIL" ;;
            WARN) warn=$((warn + 1)); st="⚠️ WARN" ;;
            *)    [ "${4:-0}" != "1" ] && na=$((na + 1)); st="— N/A" ;;
        esac
        rows="${rows}| ${n} | $1 | ${st} | $3 |"$'\n'
    }

    # 1. GPU PCIe 链路完整（无 GPU 机器判 N/A 且不计入"数据不足"——无 GPU 是平台形态非数据缺失；
    #    有 GPU 但驱动异常（lspci 3D controller 存在但 nvidia-smi 无数据）→ WARN，无法验收即问题）
    if [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
        if [ "$HEAD_NODE" -eq 1 ]; then
            add_item "GPU PCIe 链路完整" "N/A" "HGX 机头（无本地 GPU，模组单独采集验收）" 1
        elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
            add_item "GPU PCIe 链路完整" "WARN" "检测到 ${GPU_PCI_PRESENT} 个 ${GPU_PCI_VENDOR:-} GPU（PCI 3D controller）但对应管理工具无数据（驱动未安装或异常）"
        else
            add_item "GPU PCIe 链路完整" "N/A" "无 GPU" 1
        fi
    elif [ -n "$GPU_DEGRADED" ]; then
        add_item "GPU PCIe 链路完整" "FAIL" "${GPU_DEGRADED%%,}（期望最高速率）"
    else
        add_item "GPU PCIe 链路完整" "PASS" "全部 GPU 处于最高 PCIe 速率"
    fi

    # 2. NVLink 互联
    case "${NVLINK_HEALTH:-N/A}" in
        OK)   add_item "NVLink 互联" "PASS" "全互联无降级链路" ;;
        异常) add_item "NVLink 互联" "FAIL" "存在降级链路${NVLINK_CRC:+，且有非零 CRC 错误}" ;;
        *)    case "${GPU_PLATFORM:-}" in
                  amd) if [ -n "${GPU_XGMI_SUMMARY:-}" ]; then
                           add_item "NVLink 互联" "N/A" "AMD 平台无 NVLink（xGMI/Infinity Fabric 互联，拓扑日志已采集；链路健康判定待真机校准）" 1
                       else
                           add_item "NVLink 互联" "N/A" "AMD 平台无 NVLink（Instinct 经 xGMI/Infinity Fabric 互联，不适用）" 1
                       fi ;;
                  ascend) add_item "NVLink 互联" "N/A" "昇腾平台无 NVLink（Atlas 模组经 HCCS 互联；HCCS 拓扑日志已采集，判定解析待真机校准）" 1 ;;
                  *)    if [ "$HEAD_NODE" -eq 1 ]; then
                            add_item "NVLink 互联" "N/A" "机头无 NVLink（模组另采）" 1
                        elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
                            # v1.48.22：文案按 lspci 层厂商区分（原写死 NVIDIA）
                            case "${GPU_PCI_VENDOR:-}" in
                                AMD) add_item "NVLink 互联" "N/A" "AMD 平台无 NVLink（xGMI/Infinity Fabric 互联，拓扑日志已采集；链路健康判定待真机校准）" 1 ;;
                                *)   add_item "NVLink 互联" "WARN" "检测到 NVIDIA GPU 但驱动异常，NVLink 状态不可用" ;;
                            esac
                        elif [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
                            add_item "NVLink 互联" "N/A" "无 GPU" 1
                        else
                            add_item "NVLink 互联" "N/A" "无 topo 数据（旧采集）"
                        fi ;;
              esac ;;
    esac

    # 3. DCGM 诊断
    case "${DCGM_SUMMARY:-N/A}" in
        通过*) add_item "DCGM 诊断" "PASS" "${DCGM_SUMMARY}" ;;
        Fail*硬件:[1-9]*) add_item "DCGM 诊断" "FAIL" "${DCGM_SUMMARY}" ;;
        配置项*Fail*|Fail*) add_item "DCGM 诊断" "WARN" "${DCGM_SUMMARY}（软件/配置类，非硬件故障）" ;;
        *)    case "${GPU_PLATFORM:-}" in
                  amd) add_item "DCGM 诊断" "N/A" "AMD 平台无 DCGM（ROCm 诊断：rocminfo + amd-smi ras 见 GPU 段附录）" 1 ;;
                  ascend) add_item "DCGM 诊断" "N/A" "昇腾平台无 DCGM（Atlas 诊断：npu-smi info / npu-smi health 见 GPU 段附录）" 1 ;;
                  *)    if [ "$HEAD_NODE" -eq 1 ]; then
                            add_item "DCGM 诊断" "N/A" "机头无 GPU（模组另采）" 1
                        elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
                            # v1.48.22：文案按 lspci 层厂商区分（原写死 NVIDIA）
                            case "${GPU_PCI_VENDOR:-}" in
                                AMD) add_item "DCGM 诊断" "N/A" "AMD 平台无 DCGM（ROCm 诊断：rocminfo + amd-smi ras 见 GPU 段附录）" 1 ;;
                                *)   add_item "DCGM 诊断" "WARN" "检测到 NVIDIA GPU 但驱动异常，DCGM 无法运行" ;;
                            esac
                        elif [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
                            add_item "DCGM 诊断" "N/A" "无 GPU" 1
                        else
                            add_item "DCGM 诊断" "N/A" "未运行（DCGM 未安装或已禁用）"
                        fi ;;
              esac ;;
    esac

    # 4. GPU VBIOS 版本一致（混插固件是交付要记录的固件一致性问题）
    if [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
        if [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
            # v1.48.22：文案按 lspci 层厂商区分（原写死 NVIDIA——AMD 平台误报）
            case "${GPU_PCI_VENDOR:-}" in
                AMD) add_item "GPU VBIOS 版本一致" "WARN" "检测到 ${GPU_PCI_PRESENT} 个 AMD GPU 但管理工具无数据（驱动异常或 ROCm 采集失败），VBIOS 不可读" ;;
                *)   add_item "GPU VBIOS 版本一致" "WARN" "检测到 NVIDIA GPU 但驱动异常，VBIOS 不可读" ;;
            esac
        else
            add_item "GPU VBIOS 版本一致" "N/A" "无 GPU" 1
        fi
    elif [ "$GPU_VBIOS" = "N/A" ]; then
        if [ "${GPU_PLATFORM:-}" = "amd" ]; then
            add_item "GPU VBIOS 版本一致" "N/A" "无固件数据（ROCm 工具缺失，generic 降级）"
        else
            add_item "GPU VBIOS 版本一致" "N/A" "无 VBIOS 数据（旧采集或驱动不可用）"
        fi
    elif echo "$GPU_VBIOS" | grep -q "不一致"; then
        add_item "GPU VBIOS 版本一致" "WARN" "${GPU_VBIOS#⚠️ }"
    else
        add_item "GPU VBIOS 版本一致" "PASS" "${GPU_VBIOS}"
    fi

    # 5. 内存运行速率（2DPC 满插降速是平台规范/DDR5 物理必然，不算故障；未插满降速才提示；无数据 → N/A）
    if [ -z "$MEM_SPEED" ] || [ "$MEM_SPEED" = "N/A" ]; then
        add_item "内存运行速率" "N/A" "内存速率数据不可用"
    elif [ -n "$MEM_SPEED_NOTE" ]; then
        if [ "$MEM_FULL" -eq 1 ]; then
            add_item "内存运行速率" "PASS" "${MEM_SPEED_NOTE}（插满 ${MEM_POPULATED}/${MEM_SLOTS} 槽 2DPC，降速属平台规范正常现象）"
        else
            add_item "内存运行速率" "WARN" "${MEM_SPEED_NOTE}（仅插 ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} 槽仍降速，建议核查）"
        fi
    else
        add_item "内存运行速率" "PASS" "额定速率运行（${MEM_SPEED:-N/A}）"
    fi

    # 6. 线缆配对完整（条件驱动：按实际链路状态判定——无 IB 卡/未接线=场景固有不计数；已接线但无线缆数据=采集缺失计数）
    if [ -n "$CABLE_PAIRS" ]; then
        add_item "IB 线缆配对" "PASS" "${CABLE_PAIRS}"
    elif [ "${IB_ACTIVE:-0}" -gt 0 ] 2>/dev/null; then
        add_item "IB 线缆配对" "N/A" "IB 链路已 Active（已接线）但无线缆配对数据（采集缺失，需补采）"
    elif [ "${IB_LINK_DOWN:-0}" -gt 0 ] 2>/dev/null || [ "${IB_UNPLUGGED:-0}" -gt 0 ] 2>/dev/null; then
        add_item "IB 线缆配对" "N/A" "IB 链路未连接（交付验收通常不接线，场景固有）" 1
    else
        add_item "IB 线缆配对" "N/A" "无 IB 网卡（非 IB 平台，线缆配对不适用）" 1
    fi

    # 7. 磁盘寿命充足（spare 第10列；<90% 提示，<50% FAIL；无盘数据或无 spare 数据 → N/A 禁止假阳性 PASS）
    local disk_warn="" disk_fail="" disk_spare_known=0
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec; do
            [ -z "$dname" ] && continue
            local spare_num
            spare_num=$(echo "$dspare" | tr -dc '0-9')
            if [ -n "$spare_num" ]; then
                disk_spare_known=$((disk_spare_known+1))
                if [ "$spare_num" -lt 50 ] 2>/dev/null; then
                    disk_fail="${disk_fail}${dname}(${dspare}),"
                elif [ "$spare_num" -lt 90 ] 2>/dev/null; then
                    disk_warn="${disk_warn}${dname}(${dspare}),"
                fi
            fi
        done < <(printf '%s\n' "$DISK_DETAILS")
    fi
    if [ -z "$DISK_DETAILS" ]; then
        add_item "磁盘寿命" "N/A" "无数据盘（平台配置形态，磁盘寿命不适用）" 1
    elif [ "$disk_spare_known" -eq 0 ]; then
        add_item "磁盘寿命" "N/A" "无 SMART 剩余寿命数据（旧采集或盘不支持，无法判定）"
    elif [ -n "$disk_fail" ]; then
        add_item "磁盘寿命" "FAIL" "${disk_fail%,}（寿命不足 50%）"
    elif [ -n "$disk_warn" ]; then
        add_item "磁盘寿命" "WARN" "${disk_warn%,}（寿命 <90%，建议关注）"
    else
        add_item "磁盘寿命" "PASS" "全部磁盘寿命充足"
    fi

    # SMART 整体健康（overall-health PASSED/FAILED，比寿命%更直接的盘可用判定）
    local dhealth_fail="" dhealth_warn="" dhealth_known=0
    # 8. SMART 健康状态（有盘时必检；无盘=平台形态 N/A 不计数，有盘无数据=真缺数据计数）
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            case "$dhealth" in
                FAILED) dhealth_known=$((dhealth_known+1)); dhealth_fail="${dhealth_fail}${dname}," ;;
                ⚠️*)   dhealth_known=$((dhealth_known+1)); dhealth_warn="${dhealth_warn}${dname}(${dhealth#⚠️})," ;;
                PASSED|OK) dhealth_known=$((dhealth_known+1)) ;;
            esac
        done < <(printf '%s\n' "$DISK_DETAILS")
    fi
    if [ -z "$DISK_DETAILS" ]; then
        add_item "SMART 健康状态" "N/A" "无数据盘（平台配置形态，SMART 不适用）" 1
    elif [ "$dhealth_known" -eq 0 ]; then
        add_item "SMART 健康状态" "N/A" "无 SMART 健康数据（旧采集或盘不支持）"
    elif [ -n "$dhealth_fail" ]; then
        add_item "SMART 健康状态" "FAIL" "${dhealth_fail%,}（SMART 健康评估 FAILED）"
    elif [ -n "$dhealth_warn" ]; then
        add_item "SMART 健康状态" "WARN" "${dhealth_warn%,}（SMART 有警告）"
    else
        add_item "SMART 健康状态" "PASS" "全部盘 SMART 健康评估通过"
    fi

    # 9. 电源冗余（N+N 冗余是供电可靠性核心；失效=单点故障风险）
    # v1.43.9 条件区分：无 BMC（不计数）/ 平台无冗余等级传感器（SDR 有供电传感器，不计数）/ PSU≥2 但 IPMI 无冗余数据（计数）/ 采集缺失（计数）
    case "$PSU_REDUNDANT" in
        N/A)
            if [ "${BMC_LOG_EXISTS:-0}" -eq 1 ] && [ "${BMC_PRESENT:-0}" -eq 0 ]; then
                add_item "电源冗余（N+N）" "N/A" "平台无 BMC（IPMI 传感器不可用，冗余判定不适用）" 1
            elif [ "${PSU_SENSOR_PRESENT:-0}" -eq 1 ]; then
                add_item "电源冗余（N+N）" "N/A" "平台无 PSU 冗余等级传感器（供电传感器正常，无冗余等级读数；平台固有不计数）" 1
            elif [ "${PSU_COUNT_DMI:-0}" -ge 2 ] 2>/dev/null; then
                add_item "电源冗余（N+N）" "N/A" "PSU ${PSU_COUNT_DMI} 个（dmidecode），IPMI 无冗余等级数据（采集缺失，建议人工核对）"
            else
                add_item "电源冗余（N+N）" "N/A" "无冗余传感器数据（IPMI 采集缺失，需补采）"
            fi ;;
        *失效*) add_item "电源冗余（N+N）" "FAIL" "电源冗余失效（单点故障风险）" ;;
        *) add_item "电源冗余（N+N）" "PASS" "${PSU_REDUNDANT}" ;;
    esac

    # 10. 整机温度正常范围（进风/出风/CPU/内存/电源/PCH 传感器均 ok）
    if [ -z "$TEMP_SUMMARY" ]; then
        if [ "${BMC_LOG_EXISTS:-0}" -eq 1 ] && [ "${BMC_PRESENT:-0}" -eq 0 ]; then
            add_item "整机温度正常" "N/A" "平台无 BMC（无 IPMI 温度传感器，温度判定不适用）" 1
        else
            add_item "整机温度正常" "N/A" "无温度传感器数据"
        fi
    else
        add_item "整机温度正常" "PASS" "${TEMP_SUMMARY}"
    fi

    # 11. SEL 事件（合并 Critical + PCIe 错误；采集失败/无数据 → N/A，禁止假阳性 PASS）
    if [ "${SEL_DATA_VALID:-0}" -ne 1 ] 2>/dev/null; then
        add_item "SEL 事件" "N/A" "SEL 数据不可用（ipmitool 采集失败或无权限）"
    elif [ "${SEL_CRIT:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "FAIL" "共 ${SEL_TOTAL:-0} 条 SEL，其中 ${SEL_CRIT} 条 Critical"
    elif [ "${SEL_PCIE_ERR:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "FAIL" "${SEL_PCIE_ERR} 条 PCIe/AER/uncorrectable 记录"
    elif [ "${SEL_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "PASS" "${SEL_TOTAL} 条 SEL，无 Critical/PCIe 错误（有历史事件）"
    else
        add_item "SEL 事件" "PASS" "无 SEL 事件"
    fi

    # 12. 固件版本合规（15_firmware 输出；落后=FAIL，无基线判未知=N/A 不误报——未配置基线是
    #     验收配置缺口而非硬件问题；全部未知即整体 N/A 提示补录基线）
    if [ -z "$FW_COMPLIANCE_DETAILS" ]; then
        add_item "固件版本合规" "N/A" "无固件数据（15_firmware 未采集或旧数据）"
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|落后|"; then
        _fw_behind=$(printf '%s\n' "$FW_COMPLIANCE_DETAILS" | awk -F'|' '$5=="落后"{printf "%s(%s→%s), ", $2, $4, $3}')
        add_item "固件版本合规" "FAIL" "固件落后于推荐版本: ${_fw_behind%,}"
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|无法比较|"; then
        add_item "固件版本合规" "WARN" "部分固件版本格式非标准，需人工核对"
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|未知|"; then
        add_item "固件版本合规" "N/A" "无基线配置（conf/fw_required.txt 未录入推荐版本，默认不对比；录入后自动启用）" 1
    else
        add_item "固件版本合规" "PASS" "全部固件版本满足推荐基线（较新不判落后）"
    fi

    # 13. OS vs BMC 口径一致（零新采集交叉校验；不一致=FAIL，仅单侧数据=WARN，无数据=N/A）
    # 默认关闭（--bmc-verify 开启）：未启用时 N/A 且不计入"数据不足"（该校验为可选深度核验，非交付必检项）
    if [ "$BMC_VERIFY" -eq 0 ]; then
        add_item "OS-BMC 口径一致" "N/A" "校验未启用（--bmc-verify 开启后执行，独立核验报告）" 1
    elif [ "${BMC_PRESENT:-0}" -eq 0 ] 2>/dev/null; then
        if ls "${BMC_DIR}"/ipmi_*.log >/dev/null 2>&1; then
            add_item "OS-BMC 口径一致" "N/A" "机器无 BMC（IPMI 日志为错误输出，平台固有形态，交叉校验不适用）" 1
        else
            add_item "OS-BMC 口径一致" "N/A" "无 IPMI/Redfish 数据（ipmitool 未安装或模块关闭），无法交叉校验"
        fi
    elif [ -z "$BMC_CONSISTENCY" ]; then
        add_item "OS-BMC 口径一致" "N/A" "无 BMC 对比数据（旧采集或采集失败）"
    elif printf '%s\n' "$BMC_CONSISTENCY" | grep -q "⚠️ 不一致"; then
        _bc_bad=$(printf '%s\n' "$BMC_CONSISTENCY" | awk -F'|' '$4 ~ /不一致/{printf "%s, ", $1}')
        add_item "OS-BMC 口径一致" "FAIL" "${_bc_bad%,} 不一致（潜在刷 SN/换件/固件不匹配风险）"
    elif printf '%s\n' "$BMC_CONSISTENCY" | grep -qE "仅(OS|BMC)侧数据"; then
        add_item "OS-BMC 口径一致" "WARN" "部分对比项仅单侧数据（建议补采 Redfish 完整核验）"
    else
        add_item "OS-BMC 口径一致" "PASS" "OS 与 BMC 口径完全一致"
    fi

    # 14. 风扇冗余（N+N）（11_fan 采集 Fan Redundancy 传感器；无风扇平台=形态 N/A 不计入，
    #     有风扇但无冗余状态=采集缺失计入——参考电源冗余判定，v1.36.0）
    if [ "${FAN_COUNT:-0}" -eq 0 ] 2>/dev/null; then
        add_item "风扇冗余（N+N）" "N/A" "无风扇（平台配置形态，冗余不适用）" 1
    elif [ "$FAN_REDUNDANT" = "N/A" ]; then
        if [ "${BMC_LOG_EXISTS:-0}" -eq 1 ] && [ "${BMC_PRESENT:-0}" -eq 0 ]; then
            add_item "风扇冗余（N+N）" "N/A" "平台无 BMC（无 IPMI 风扇冗余传感器，判定不适用）" 1
        elif [ "${FAN_SENSOR_PRESENT:-0}" -eq 1 ]; then
            add_item "风扇冗余（N+N）" "N/A" "平台无风扇冗余等级传感器（风扇转速正常，无冗余等级读数；平台固有不计数）" 1
        else
            add_item "风扇冗余（N+N）" "N/A" "无风扇冗余状态数据（ipmitool 未采集到 Fan Redundancy 传感器，需补采）"
        fi
    elif [ "$FAN_REDUNDANT" = "冗余满足" ]; then
        add_item "风扇冗余（N+N）" "PASS" "${FAN_EXTRA:-冗余满足（N+N）}"
    else
        add_item "风扇冗余（N+N）" "FAIL" "风扇冗余失效（单点故障风险）"
    fi

    # 15. PCIe 链路完整（v1.41.0：PEX Fabric Switch 枚举 + 关键链路 LnkSta 满速/降速；
    #     交付验收看扩展板卡通路与模组接口链路——超微 H200 机头场景客户核对点）
    if [ -n "$PCIE_SLOW_LINKS" ]; then
        add_item "PCIe 链路完整" "WARN" "检测到降速/降宽链路: $(printf '%s\n' "$PCIE_SLOW_LINKS" | head -1 | cut -c1-60)..."
    elif [ "${PCIE_LINKS_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
        if [ -n "$PCIE_PEX_DETAILS" ]; then
            add_item "PCIe 链路完整" "PASS" "PEX Fabric Switch 已枚举（${PCIE_PEX_DETAILS}），${PCIE_LINKS_TOTAL} 条链路满速"
        else
            add_item "PCIe 链路完整" "PASS" "${PCIE_LINKS_TOTAL} 条链路满速（无降速/降宽）"
        fi
    else
        add_item "PCIe 链路完整" "N/A" "无链路数据（旧采集无 pcie_full 全量日志，链路检测需重新采集）" 1
    fi

    # 汇总判定（N/A 过多时不得判合格——数据不足无法验收）
    if [ "$fail" -gt 0 ]; then
        verdict="不合格（${fail} 项 FAIL，需处理后再交付）"
    elif [ "$warn" -gt 0 ]; then
        verdict="有条件通过（${warn} 项 WARN，建议记录后交付）"
    elif [ "$na" -ge 4 ]; then
        verdict="数据不足（${na} 项无数据，关键项缺失，无法完成验收判定）"
    elif [ "$na" -gt 0 ]; then
        verdict="基本通过（${na} 项无数据，其余项正常）"
    else
        verdict="合格（全部通过）"
    fi

    # ── 配置单派生（硬件概览表格数据：内存每槽/网卡归类/PSU 汇总/盘型号） ──
    ACC_MEM_DIMM="N/A"
    if [ "${MEM_POPULATED:-0}" -gt 0 ] 2>/dev/null && [ -n "${MEM_TOTAL_PHYS:-}" ]; then
        _mtp=$(echo "$MEM_TOTAL_PHYS" | grep -oE "[0-9.]+" | head -1)
        [ -n "$_mtp" ] && ACC_MEM_DIMM=$(awk -v t="$_mtp" -v p="$MEM_POPULATED" 'BEGIN{printf "%.0fGB", t/p}' < /dev/null)
    fi
    ACC_NIC_IB="N/A"; ACC_NIC_IB_COUNT=0; ACC_NIC_ETH="N/A"; ACC_NIC_ETH_COUNT=0
    if [ -n "$NIC_DETAILS" ]; then
        while IFS='|' read -r nnic nnbdf nmac nsn npn nfw npcie npsid ngd nchip nport; do
            [ -z "$nnic" ] && continue
            # v1.43.10 修正：按接口名归类（ibp*/ib* = IB 计算网卡；en*/eth* = 以太）。
            # 原按 ConnectX|MCX 前缀归类会把 CX5 以太（MCX556A）误入 IB——实测 6 张假 IB（2 以太+4 IB）
            if echo "$nnic" | grep -qE "^ib"; then
                ACC_NIC_IB_COUNT=$((ACC_NIC_IB_COUNT+1))
                [ "$ACC_NIC_IB" = "N/A" ] && ACC_NIC_IB="${npn:-N/A}"
            else
                ACC_NIC_ETH_COUNT=$((ACC_NIC_ETH_COUNT+1))
                # 以太型号聚合（多种卡混插都显示，如 "MCX556A-ECAT + AOC-ATG-i2TM"）
                _eth_m=$(echo "${npn:-N/A}" | sed 's/Intel Corporation Ethernet Controller //; s/ for 10GBASE-T.*//; s/ (rev [0-9]*)//')
                if [ "$ACC_NIC_ETH" = "N/A" ]; then
                    ACC_NIC_ETH="$_eth_m"
                elif ! echo "$ACC_NIC_ETH" | grep -qF "$_eth_m"; then
                    ACC_NIC_ETH="${ACC_NIC_ETH} + ${_eth_m}"
                fi
            fi
        done < <(printf '%s\n' "$NIC_DETAILS")
    fi
    ACC_PSU_MODEL="N/A"; ACC_PSU_CAP="N/A"; ACC_PSU_COUNT=0
    if [ -n "$PSU_DETAILS" ]; then
        while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
            [ -z "$pdesc" ] && continue
            ACC_PSU_COUNT=$((ACC_PSU_COUNT+1))
            [ "$ACC_PSU_MODEL" = "N/A" ] && [ "$pmodel" != "N/A" ] && [ -n "$pmodel" ] && ACC_PSU_MODEL="$pmodel"
            [ "$ACC_PSU_CAP" = "N/A" ] && [ "$pcap" != "N/A" ] && [ -n "$pcap" ] && ACC_PSU_CAP="$pcap"
        done < <(printf '%s\n' "$PSU_DETAILS")
    fi
    ACC_DISK_MODEL="N/A"
    if [ -n "${STORAGE_MODELS:-}" ]; then
        ACC_DISK_MODEL=$(echo "$STORAGE_MODELS" | tr ',' '\n' | head -1)
    fi

    {
        echo "# HwScope 验收清单（Acceptance Checklist）"
        echo ""
        echo "## 硬件概览（配置单，自动生成自检测数据）"
        echo ""
        echo "| 项目 | 规格型号描述（含配置） | 单位 | 数量 |"
        echo "|------|------------------------|------|------|"
        echo "| 准系统 | ${MB_MANUFACTURER:-N/A} ${MB_PRODUCT:-N/A}（机箱 SN: ${CHASSIS_SN:-N/A}，BIOS: ${BIOS_VERSION:-N/A}） | 台 | 1 |"
        echo "| CPU | ${CPU_MODEL:-N/A}（${CPU_CORES:-0} 核/颗，${CPU_MAX_SPEED:-N/A}MHz） | 颗 | ${CPU_SOCKETS:-0} |"
        echo "| 内存 | ${MEM_TYPE:-DDR} ${ACC_MEM_DIMM:-N/A} ECC RDIMM（额定 ${MEM_NOM:-N/A}，实际 ${MEM_SPEED:-N/A}） | 条 | ${MEM_POPULATED:-0} |"
        # GPU 显存类型（数据中心 HBM / 消费与专业 GDDR；未识别型号不标注，避免误导）
        ACC_GPU_MEMTYPE=""
        if [ "${GPU_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            if echo "$GPU_NAMES" | grep -qiE "B200|B300|H100|H200|H800|A100|A800|A30|A16|V100|P100|GH200|MI[0-9]"; then
                ACC_GPU_MEMTYPE="HBM"
            elif echo "$GPU_NAMES" | grep -qiE "GeForce|GTX|RTX|Quadro"; then
                ACC_GPU_MEMTYPE="GDDR"
            fi
        fi
        if [ "${GPU_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            echo "| GPU模组 | ${GPU_NAMES:-N/A}（${GPU_MEM_SPEC:-N/A}${ACC_GPU_MEMTYPE:+ ${ACC_GPU_MEMTYPE}}） | 张 | ${GPU_COUNT} |"
        elif [ "${GPU_PCI_PRESENT:-0}" -gt 0 ] 2>/dev/null; then
            echo "| GPU模组 | 检测到 ${GPU_PCI_PRESENT} 个 ${GPU_PCI_VENDOR:-} 加速卡（无对应管理工具，仅 PCI 存在性） | 张 | ${GPU_PCI_PRESENT} |"
        else
            echo "| GPU模组 | 无（${PLATFORM_LABEL:-N/A} 平台） | — | — |"
        fi
        if [ "${ACC_NIC_IB_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            echo "| 计算网卡 | ${ACC_NIC_IB:-N/A}（IB ${IB_NOMINAL:-N/A}） | 张 | ${ACC_NIC_IB_COUNT} |"
        fi
        if [ "${ACC_NIC_ETH_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            echo "| 网卡&端口 | ${ACC_NIC_ETH:-N/A} | 张 | ${ACC_NIC_ETH_COUNT} |"
        fi
        echo "| 存储 | ${ACC_DISK_MODEL:-N/A}（${STORAGE_TOTAL:-0}） | 块 | ${STORAGE_COUNT:-0} |"
        echo "| 电源模块 | ${ACC_PSU_MODEL:-N/A}（${ACC_PSU_CAP:-N/A}） | 个 | ${ACC_PSU_COUNT:-0} |"
        echo "| 系统管理 | BMC（固件 ${BMC_FW:-N/A}） | 套 | 1 |"
        echo ""
        echo "## 验收信息"
        echo ""
        echo "- 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- 采集版本: ${VERSION:-unknown} / 报告版本: ${REPORT_VERSION:-unknown}"
        echo ""
        echo "## 验收项"
        echo ""
        echo "| # | 检查项 | 结果 | 说明 |"
        echo "|---|--------|------|------|"
        printf '%s' "$rows"
        echo ""
        echo "## 结论"
        echo ""
        echo "| 项 | 数值 |"
        echo "|----|------|"
        echo "| 通过 | ${pass} |"
        echo "| 警告 | ${warn} |"
        echo "| 失败 | ${fail} |"
        echo "| 无数据 | ${na} |"
        echo "| **判定** | **${verdict}** |"
        echo ""
        echo "---"
        echo "*由 HwScope ${REPORT_VERSION:-unknown} 生成（--acceptance 模式）*"
    } > "$f"
    echo -e "${GREEN}[REPORT] 验收清单: ${f}${NC}"
    echo -e "${GREEN}[REPORT] 判定: ${verdict}${NC}"
    # 验收清单 HTML（同 md2html.awk 转换，交付交接单展示用）
    awk -f "${SCRIPT_DIR}/report/lib/md2html.awk" "$f" > "${OUT}/hwscope_acceptance.html" 2>/dev/null && \
        echo -e "${GREEN}[REPORT] 验收清单 HTML: ${OUT}/hwscope_acceptance.html${NC}"
}
