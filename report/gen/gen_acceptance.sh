#!/bin/bash
# =============================================================================
# HwScope - 验收清单生成器 gen_acceptance（18 项判定 + 配置单）
# report/gen/gen_acceptance.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
gen_acceptance() {
    local f="${OUT}/hwscope_acceptance.md"
    local n=0 pass=0 fail=0 warn=0 na=0
    local rows="" st=""
    local verdict="合格"
    NA_INHERENT=""   # v1.48.41：平台固有 N/A 项名收集（表尾汇总；不渲染行避免满表 N/A）

    # 逐项评估函数：add_item "名称" "状态" "说明" [不计入N/A=1]
    # 第4参数=1 时 N/A 为平台固有（不计数、不渲染行——折叠到表尾汇总，避免消费台式等平台满表 N/A 噪音）
    add_item() {
        case "$2" in
            PASS) pass=$((pass + 1)); st="✅ PASS" ;;
            FAIL) fail=$((fail + 1)); st="❌ FAIL" ;;
            WARN) warn=$((warn + 1)); st="⚠️ WARN" ;;
            *)
                st="— N/A"
                if [ "${4:-0}" = "1" ]; then
                    # v1.48.41：平台固有 N/A——不计入 na、不渲染行（表尾汇总），序号不占位
                    NA_INHERENT="${NA_INHERENT}${1}|"
                    return 0
                fi
                na=$((na + 1))
                ;;
        esac
        n=$((n + 1))
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
        OK)   if [ "${NVLINK_CAPABLE:-0}" -eq 0 ] 2>/dev/null; then
                  # v1.48.40：消费卡/无桥 PCIe 的 topo -m 矩阵也有 GPU0 行 → 假 OK；无 NVLink 能力判 N/A 而非 PASS
                  add_item "NVLink 互联" "N/A" "该 GPU 无 NVLink 能力（消费级 GeForce/RTX 或 A100-PCIe 无桥形态——topo 矩阵非 NVLink 数据）" 1
              else
                  add_item "NVLink 互联" "PASS" "全互联无降级链路"
              fi ;;
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
                                *)   if [ "${NVLINK_CAPABLE:-0}" -eq 0 ] 2>/dev/null; then
                                         # v1.48.40：无 NVLink 能力（消费卡）→ N/A 而非 WARN"驱动异常"
                                         add_item "NVLink 互联" "N/A" "该 GPU 无 NVLink 能力（消费级或无 NVLink 桥接的 PCIe 形态）" 1
                                     else
                                         add_item "NVLink 互联" "WARN" "检测到 NVIDIA GPU 但驱动异常，NVLink 状态不可用"
                                     fi ;;
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
                                *)   case "${GPU_NAMES:-}" in
                                         # v1.48.40：消费级 NVIDIA 无 DCGM 支持 → N/A；数据中心卡无数据 → WARN（真异常）
                                         # v1.48.42 修正：匹配模式去掉裸 *RTX*——nvidia-smi 输出消费卡带 GeForce 前缀（GeForce RTX 4090）、
                                         # 专业/数据中心卡不带（RTX 6000 Ada / RTX A6000 支持 DCGM），裸 RTX 会把专业卡误判消费级
                                         *GeForce*|*GTX*|*GeForce\ RTX*) add_item "DCGM 诊断" "N/A" "消费级 GPU 无 DCGM 支持（DCGM 面向数据中心 GPU，诊断走 GPU 段明细）" 1 ;;
                                         *) add_item "DCGM 诊断" "WARN" "检测到 NVIDIA GPU 但驱动异常，DCGM 无法运行" ;;
                                     esac ;;
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
            add_item "GPU VBIOS 版本一致" "N/A" "无固件数据（AMD 固件日志缺失或解析失败，见 GPU 段附录）"
        else
            add_item "GPU VBIOS 版本一致" "N/A" "无 VBIOS 数据（旧采集或驱动不可用）"
        fi
    elif echo "$GPU_VBIOS" | grep -q "不一致"; then
        add_item "GPU VBIOS 版本一致" "WARN" "${GPU_VBIOS#⚠️ }"
    else
        add_item "GPU VBIOS 版本一致" "PASS" "${GPU_VBIOS}"
    fi

    # 5. 内存运行速率（v1.48.69 判据修正：超过 1DPC——已插 > 槽位/2——降速属平台规范，
    #    典型 24 根插 32 槽；仅 ≤1DPC 每通道 1 条仍降速才需核查。无数据 → N/A）
    if [ -z "$MEM_SPEED" ] || [ "$MEM_SPEED" = "N/A" ]; then
        add_item "内存运行速率" "N/A" "内存速率数据不可用"
    elif [ -n "$MEM_SPEED_NOTE" ]; then
        if [ "${MEM_OVER_1DPC:-0}" -eq 1 ] || [ "${MEM_FULL:-0}" -eq 1 ]; then
            add_item "内存运行速率" "PASS" "降速运行（额定 ${MEM_NOM}，现速 ${MEM_SPEED}；已插 ${MEM_POPULATED}/${MEM_SLOTS} 槽属 >1DPC 配置，降速为平台规范正常现象）"
        else
            add_item "内存运行速率" "WARN" "降速运行（额定 ${MEM_NOM}，现速 ${MEM_SPEED}；仅插 ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} 槽 ≤1DPC 仍降速，建议核查 BIOS 设置或混插兼容性）"
        fi
    else
        add_item "内存运行速率" "PASS" "额定速率运行（${MEM_SPEED:-N/A}）"
    fi

    # v1.49.17：移除原「IB 线缆配对」验收项（用户判断 + 实测支持）——
    #   该项判的是 IB 卡**成对直连**（同机 mlx5_11↔mlx5_1），而交付场景 IB 卡接交换机 →
    #   CABLE_PAIRS 恒空 → 该项恒 N/A，属"永远不判"的占位项。线缆配对信息仍保留在报告
    #   「网络」段（真有卡间直连拓扑时照常展示），只是不再占验收项位。
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

    # 9. 电源状态（v1.49.17：取代原「电源冗余（N+N）」）
    #   原项判据是 IPMI 的 PS_Redundant 冗余等级传感器，但**多数平台不暴露**——实测 8 台样本
    #   仅 1 台有该数据 → 长期恒 N/A（用户反馈"经常采集不到"属实）。改为多级判据判「电源是否
    #   正常」，实测覆盖面 8/8：① PS*_Status 传感器 0x1=正常（5/8，能报 FAIL）；
    #   ② SMBIOS/dmidecode 在位数量（8/8，兜底"有没有"）；③ 温度/功耗读数（写进说明佐证）；
    #   附：冗余等级有数据才提，不再作为独立判定。
    _pwr_red=""
    [ -n "${PSU_REDUNDANT:-}" ] && [ "${PSU_REDUNDANT}" != "N/A" ] && _pwr_red="；冗余等级：${PSU_REDUNDANT}"
    if [ "${PSU_STATUS_BAD:-0}" -gt 0 ] 2>/dev/null; then
        add_item "电源状态" "FAIL" "检测到 ${PSU_STATUS_BAD} 颗电源状态异常（IPMI PS*_Status 非 0x1）${PSU_STATUS_BAD_D:+：${PSU_STATUS_BAD_D}}${_pwr_red}"
    elif [ "${PSU_STATUS_OK:-0}" -gt 0 ] 2>/dev/null; then
        add_item "电源状态" "PASS" "${PSU_STATUS_OK} 颗电源状态正常（IPMI PS*_Status=0x1${PSU_STATUS_TEMP:+；温度 ${PSU_STATUS_TEMP}}${PSU_STATUS_PWR:+；功耗 ${PSU_STATUS_PWR}}）${_pwr_red}"
    elif [ "${PSU_COUNT_DMI:-0}" -ge 2 ] 2>/dev/null; then
        add_item "电源状态" "PASS" "SMBIOS 确认 ${PSU_COUNT_DMI} 颗电源在位（该平台 IPMI 未暴露电源状态传感器，按在位数量判定）${_pwr_red}"
    elif [ -n "${PSU_DETAILS:-}" ]; then
        _pc=$(printf '%s\n' "$PSU_DETAILS" | grep -c .)
        add_item "电源状态" "PASS" "PSU 明细 ${_pc} 条（电源 FRU/传感器可见，IPMI 无状态等级数据）${_pwr_red}"
    else
        add_item "电源状态" "N/A" "该平台未暴露电源状态（IPMI 无 PS*_Status、SMBIOS 无 Type 39、FRU 无 PSU 条目；平台固有，不计数）" 1
    fi

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

    # 11. SEL 事件（v1.48.86：按「告警是否已解除」判，而非「是否出现过 Critical 字样」）
    #     旧实现只看 SEL_CRIT>0 → FAIL，而 SEL_CRIT 是 grep -ciE "critical|fatal" 的行数，
    #     连 Deasserted 行（描述里同样含 "Critical"）也计入 → 已自愈的历史事件被判 FAIL。
    #     现按终态：未解除=FAIL；已自愈=WARN（告知曾发生但不卡交付）；无 Critical=PASS。
    if [ "${SEL_DATA_VALID:-0}" -ne 1 ] 2>/dev/null; then
        add_item "SEL 事件" "N/A" "SEL 数据不可用（ipmitool 采集失败或无权限）"
    elif [ "${SEL_CRIT_UNRESOLVED:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "FAIL" "共 ${SEL_TOTAL:-0} 条 SEL，其中 ${SEL_CRIT_UNRESOLVED} 条 Critical 告警**尚未解除**（需处理后再交付）"
    elif [ "${SEL_PCIE_ERR:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "FAIL" "${SEL_PCIE_ERR} 条 PCIe/AER/uncorrectable 记录"
    elif [ "${SEL_CRIT_RECOVERED:-0}" -gt 0 ] 2>/dev/null; then
        add_item "SEL 事件" "WARN" "共 ${SEL_TOTAL:-0} 条 SEL，无未解除告警；其中 ${SEL_CRIT_RECOVERED} 条 Critical 已于 ${SEL_RECOVERED_WHEN:-N/A} 自愈（Asserted→Deasserted 成对，建议留意）"
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

    # 14.（已移除）风扇冗余（N+N）
    # v1.49.0 删除：实测 22 台样本（AMD/A100/B200/B300 全平台）无一提供有效信息——
    #   6 台采到的值是 `FAN_Redundancy | 0x00 | ok`（0x00 在 IPMI discrete 语义里是
    #   「无该状态/未定义」，**不是**「有冗余」；有冗余应为 0x01），另 16 台为空文件。
    #   且原解析 `*ok*` 会把 0x00 误判成「冗余满足」；即便修对，该平台也读不到冗余等级。
    #   结论：BMC 普遍不提供风扇冗余接口 → 本项为纯噪声，删除以免每次验收为「固有还是缺失」空纠结。
    #   （电源冗余（N+N）保留——B300 系列 7/22 台能读到 PSU 冗余等级，是有效信息）

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

    # 16. CPU 配置一致（v1.48.40 类A 自洽校验：多颗 CPU 型号/Stepping/核数混插是交付大忌）
    if [ -n "$CPU_DETAILS" ]; then
        _cpu_n=$(printf '%s\n' "$CPU_DETAILS" | grep -c '|')
        if [ "$_cpu_n" -gt 1 ] 2>/dev/null; then
            _cpu_var=$(printf '%s\n' "$CPU_DETAILS" | awk -F'|' '{print $2"|step"$7"|"$3"核"}' | sort -u | wc -l)
            if [ "$_cpu_var" -gt 1 ] 2>/dev/null; then
                add_item "CPU 配置一致" "FAIL" "多颗 CPU 型号/Stepping/核数不一致（$(printf '%s\n' "$CPU_DETAILS" | awk -F'|' '{print $1": "$2" step"$7" "$3"核"}' | tr '\n' '; ')）"
            else
                add_item "CPU 配置一致" "PASS" "${_cpu_n} 颗 CPU 型号/Stepping/核数一致"
            fi
        else
            add_item "CPU 配置一致" "N/A" "单颗 CPU（无对称性可判）" 1
        fi
    else
        add_item "CPU 配置一致" "N/A" "无 CPU 明细数据（采集缺失）"
    fi

    # 17. 内存容量一致（类A 自洽校验：全槽同容量为对称配置；混插 WARN 提示）
    if [ -n "$MEM_DIMMS" ]; then
        # 按行计数（size 值含空格如 "64 GB"——不能用 wc -w 空格分词；空槽 "No Module Installed" 排除）
        _mem_sizes=$(printf '%s\n' "$MEM_DIMMS" | awk -F'|' '$2!="" && $2!="N/A" && $2 !~ /No Module/{print $2}' | sort -u)
        _mem_kind=$(printf '%s\n' "$_mem_sizes" | grep -c .)
        # v1.48.42 修复：已插条数排除空槽（原 grep -c '|' 数全部行——32 槽插 16 条报"已插 32 条"）
        _mem_cnt=$(printf '%s\n' "$MEM_DIMMS" | awk -F'|' '$2!="" && $2!="N/A" && $2 !~ /No Module/{c++} END{print c+0}')
        if [ "${_mem_kind:-0}" -eq 0 ] 2>/dev/null; then
            add_item "内存容量一致" "N/A" "无容量数据（采集缺失）"
        elif [ "$_mem_kind" -le 1 ] 2>/dev/null; then
            add_item "内存容量一致" "PASS" "已插 ${_mem_cnt} 条同容量（$(printf '%s\n' "$_mem_sizes" | head -1)）"
        else
            add_item "内存容量一致" "WARN" "容量混插（$(printf '%s\n' "$_mem_sizes" | tr '\n' '|' | sed 's/|$//')）——建议对称配置"
        fi
    else
        add_item "内存容量一致" "N/A" "无内存明细（采集缺失）"
    fi

    # 18. 内存 ECC 类型（类A 自洽校验：有 ECC 纠错即 PASS 并注明类型；无 ECC/未知 WARN 提示——服务器平台应 ECC）
    case "${MEM_ECC_TYPE:-}" in
        *Multi-bit*|*multibit*) add_item "内存 ECC" "PASS" "${MEM_ECC_TYPE}（服务器标准，多比特纠错）" ;;
        *ECC*)  add_item "内存 ECC" "PASS" "${MEM_ECC_TYPE}（ECC 纠错已启用）" ;;
        *)      if [ -n "$MEM_DIMMS" ]; then
                    add_item "内存 ECC" "WARN" "ECC 类型未知或无 ECC（${MEM_ECC_TYPE:-未检测到}）——服务器平台应 ECC，消费平台属正常"
                else
                    add_item "内存 ECC" "N/A" "无内存数据"
                fi ;;
    esac

    # ── 硬件故障历史项（v1.48.90：GPU XID / CPU MCE / RAID 缓存电池）──
    # 判据取向：这些都是「已经出过事」的历史记录，**判 WARN 而非 FAIL**——
    #   ① 历史事件可能已通过换卡/复位解决，据此否决交付不合理；
    #   ② 但绝不能沉默放过：XID 79（掉卡）/ 双bit ECC / MCE / 电池失效，
    #      是跟供应商谈判时最硬的证据，报告必须留痕。
    # 仅在检出时添加：无检出不加项，保证验收项数与既有基线一致。
    if [ -n "${GPU_XID:-}" ]; then
        add_item "GPU XID 错误历史" "WARN" "检出 ${GPU_XID_COUNT} 类 XID 错误（来源 ${GPU_XID_SRC}）——需确认对应卡是否已更换/复位"
    fi
    if [ -n "${MCE_HITS:-}" ]; then
        add_item "CPU MCE" "WARN" "检出 ${MCE_COUNT} 条机器检查异常（来源 ${MCE_SRC}）——需复核 CPU/内存子系统"
    fi
    if [ "${RAID_BBU_WARN:-0}" -eq 1 ] 2>/dev/null; then
        add_item "RAID 缓存电池" "WARN" "${RAID_BBU_SUMMARY}（若写缓存为 WriteBack 则掉电有丢数据风险）"
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
            _nm_raw="${npn:-N/A}"
            _nm_suf=""
            case "$_nm_raw" in
                *（*口）) _nm_suf="$(printf '%s' "$_nm_raw" | sed 's/.*\(（[0-9]* 口）\)$/\1/')"
                          _nm_raw="$(printf '%s' "$_nm_raw" | sed 's/（[0-9]* 口）$//')" ;;
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
            echo "| GPU模组 | 无（${MACHINE_CLASS_LABEL:-${PLATFORM_LABEL:-N/A}}） | — | — |"
        fi
        if [ "${ACC_NIC_IB_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            # v1.48.85：计算网卡改按 GPU 直连归类后，不能再标 "（IB …）"——直连与协议模式无关。
            # v1.49.8：单位由「口」改「张」——按物理卡计数（同卡多口只算一张），
            #   与配置单的「张」对得上；口数放括号内保留，因为线缆/端口数同样有意义。
            _ibd=$(_dist_str ib)
            echo "| 计算网卡 | ${ACC_NIC_IB:-N/A}（GPU 直连） | 张 | ${ACC_NIC_IB_COUNT}（${_ibd:-${ACC_NIC_IB_PORT} 口}，共 ${ACC_NIC_IB_PORT} 口） |"
        fi
        if [ "${ACC_NIC_DPU_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            _dpud=$(_dist_str dpu)
            echo "| DPU | ${ACC_NIC_DPU:-N/A} | 张 | ${ACC_NIC_DPU_COUNT}（${_dpud:-${ACC_NIC_DPU_PORT} 口}，共 ${ACC_NIC_DPU_PORT} 口） |"
        fi
        if [ "${ACC_NIC_ETH_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            _ethd=$(_dist_str eth)
            echo "| 网卡&端口 | ${ACC_NIC_ETH:-N/A} | 张 | ${ACC_NIC_ETH_COUNT}（${_ethd:-${ACC_NIC_ETH_PORT} 口}，共 ${ACC_NIC_ETH_PORT} 口） |"
        fi
        echo "| 存储 | ${ACC_DISK_MODEL:-N/A}（${STORAGE_TOTAL:-0}） | 块 | ${STORAGE_COUNT:-0} |"
        echo "| 电源模块 | ${ACC_PSU_MODEL:-N/A}（${ACC_PSU_CAP:-N/A}） | 个 | ${ACC_PSU_COUNT:-0} |"
        echo "| 系统管理 | BMC（固件 ${BMC_FW:-N/A}） | 套 | 1 |"
        echo ""
        echo "## 验收信息"
        echo ""
        # v1.48.41：验收口径声明——平台形态 + 适用项计数（固有 N/A 折叠后客户一眼看懂按什么口径验收）
        _na_n=$(printf '%s' "$NA_INHERENT" | tr -cd '|' | wc -c)
        echo "- 验收口径: ${MACHINE_CLASS_LABEL:-N/A}（GPU 平台: ${GPU_PLATFORM:-none}；${_na_n:-0} 项平台固有 N/A 不适用，下表 ${n} 项为实际判定项）"
        echo "- 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- 采集版本: ${VERSION:-unknown} / 报告版本: ${REPORT_VERSION:-unknown}"
        echo ""
        echo "## 验收项"
        echo ""
        echo "| # | 检查项 | 结果 | 说明 |"
        echo "|---|--------|------|------|"
        printf '%s' "$rows"
        if [ -n "$NA_INHERENT" ]; then
            echo ""
            echo "> 本平台固有/宽容 N/A（不计入数据不足，共 ${_na_n:-0} 项）：$(printf '%s' "$NA_INHERENT" | sed 's/|$//; s/|/、/g')"
        fi
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
