#!/bin/bash
# =============================================================================
# HwScope - 验收清单生成器 gen_acceptance（默认判定项 + 检出才追加的条件项 + 配置单）
#   注：默认判定项 17 项（随平台能力裁剪），条件项 6 项（GPU 功耗上限 / 采集时机 / PCIe AER /
#   GPU XID / CPU MCE / RAID 缓存电池）——
#   仅检出时追加、不改变默认项数（v1.48.90 立规）；早期注释写的"18 项"从未与实现一致（v1.49.23 更正）
# report/gen/gen_acceptance.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
gen_acceptance() {
    local f="${OUT}/hwscope_acceptance.md"
    local n=0 pass=0 fail=0 warn=0 na=0
    local rows="" st=""
    local verdict="合格"
    NA_INHERENT=""   # v1.48.41：平台固有 N/A 项名收集（表尾汇总；不渲染行避免满表 N/A）
    NA_PENDING=""    # v1.53.3：**未启用/未配置**类 N/A 项名收集——与「平台固有」严格分开。
    #   区分依据：平台固有 = 这台机物理上就没有（机头无模组→无 GPU/NVLink/DCGM/VBIOS）；
    #   未启用/未配置 = 机器**有**这个东西，只是没开开关（--bmc-verify）或没录基线
    #   （conf/fw_required.txt）。旧实现把两者一并归入固有并豁免，等于把"没做"说成"不适用"
    #   ——与项目「『0 条』不等于『没有』」(v1.48.88) 的口径冲突。

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
                if [ "${4:-0}" = "2" ]; then
                    # v1.53.3：未启用/未配置——同样不渲染行（避免噪音），但**单独汇总**，
                    #   不与平台固有混列。读者据此能看出"这台机本来能判、只是没开开关/没录基线"。
                    NA_PENDING="${NA_PENDING}${1}|"
                    return 0
                fi
                na=$((na + 1))
                ;;
        esac
        n=$((n + 1))
        # v1.49.19：说明文本里的 `|` 会撑破 Markdown 表格与 HTML 单元格——实测两处来源：
        #   ① PCIe 降速链路串自带分隔符（`37:00.0 X710 | cap 5GT/s x8, sta …`）
        #   ② 内存混插说明（`tr '\n' '|'` 把多值拼成"32 GB|64 GB"）
        #   结果该行 MD 出 6 个竖线、HTML 该行 5 个 <td>（其余行 4 个）→ 表格错位。
        #   在唯一出口统一替换为全角"／"，一处修复覆盖全部判定项。
        _desc=$(printf '%s' "$3" | tr '|' '／')
        # v1.54.29：说明里的「——」一律作为「结论 / 解释·建议」的分行点（13 处用法一致），
        #   避免一条长句把验收项表格拉宽；MD 里写 <br>，HTML 由 md2html 还原为真实换行。
        # v1.54.34：仅 WARN/FAIL（带解释或建议）才把 —— 断成第二行；
        #   PASS/N/A 的说明常常只是一句括注，断行反而零碎（实测 IB 误码的 N/A 说明被拆两行）。
        case "$2" in
            WARN|FAIL) _desc=$(printf '%s' "$_desc" | sed 's/——/<br>/g') ;;
        esac
        # v1.54.27：行按**报告章节顺序**排列（原先按代码执行顺序，读者看到的是东一个西一个）。
        #   存 `${rank}|${序号}|名称|状态|说明`，渲染时 sort 再重排序号；
        #   名称与说明里的 `|` 已在上方 / 下方各自处理，不会破坏分隔。
        rows="${rows}$(_acc_rank "$1")|${n}|$1|${st}|${_desc}|"$'\n'
    }

    # v1.54.27：验收项分组 rank —— 与报告正文章节顺序一致
    #   PCIe 链路 → CPU → 内存 → GPU → 存储 → 温度/风扇 → 电源 → 固件 → 健康检查（SEL/XID/MCE/AER）
    #   未命中映射的项排最后（rank 200），保持其原始插入顺序。
    _acc_rank() {
        # v1.54.27：验收项排序 = 「数据可信度 → 平台通路 → 部件（对齐配置单）→ 合规 → 事件」，
        #   条件项（AER/XID/MCE/RAID 电池）跟各自部件走，不集中堆在末尾——
        #   它们只是"检出才出现"，不代表优先级低。
        case "$1" in
            # ⓪ 数据可信度（命中即解释后续 GPU 项为何全 N/A，必须最先看到）
            "采集时机")                  echo 10 ;;
            # ① 平台通路
            "PCIe 链路完整")             echo 20 ;;
            "PCIe AER 错误")            echo 21 ;;   # 链路层错误，紧跟链路判定
            # ② 部件（顺序对齐验收清单「硬件概览/配置单」：CPU → 内存 → GPU → 存储 → 电源 → 风扇）
            "CPU 配置一致")              echo 30 ;;
            "CPU MCE")                  echo 31 ;;   # 机器检查异常归 CPU
            "内存容量一致")              echo 40 ;;
            "内存运行速率")              echo 41 ;;
            "内存 ECC")                 echo 42 ;;
            # GPU 组内顺序（用户口径 v1.54.27）：固件/静态配置 → 运行计数 → 链路 → 错误历史 → 互联 → 主动诊断
            "GPU VBIOS 版本一致")        echo 50 ;;
            "GPU 功耗上限")              echo 51 ;;
            "GPU ECC")                  echo 52 ;;
            "GPU PCIe 链路完整")         echo 53 ;;
            "GPU XID 错误历史")          echo 54 ;;
            "NVLink 互联")              echo 55 ;;
            "DCGM 诊断")                echo 56 ;;
            "磁盘寿命")                  echo 60 ;;
            "SMART 健康状态")            echo 61 ;;
            "RAID 缓存电池")             echo 62 ;;   # RAID 控制器归存储
            "电源状态")                  echo 70 ;;   # 配置单里电源在风扇之前
            "整机温度正常")              echo 80 ;;   # 环境读数，位于部件判定之后
            # ③ 合规与一致性（跨部件）
            "固件版本合规")              echo 90 ;;
            "OS-BMC 口径一致")           echo 91 ;;
            # ④ 平台事件汇总（SEL 跨部件，作兜底收口）
            "SEL 事件")                 echo 95 ;;
            *)                          echo 200 ;;
        esac
    }

    # v1.53.41：GPU 项在「读不到 GPU」时分两种情形——
    #   unknown（采集过早 / PCI 有卡但工具无数据）→ N/A 且**计入数据不足**（不许当成平台形态放过）
    #   absent （开机正常、PCI 无加速卡）→ N/A 平台固有（原行为）
    _gpu_item_na() {   # $1=项名；其余参数忽略
        if [ "${GPU_MODULE_STATE:-present}" = "unknown" ]; then
            add_item "$1" "N/A" "未识别到 GPU 模组（本次采集未枚举到加速卡：${GPU_MODULE_REASON}）——本项无法判定，计入数据不足；建议开机 ≥2 分钟后复采"
        else
            add_item "$1" "N/A" "未识别到 GPU 模组（PCI 未枚举到加速卡；采集时系统已运行 ${COLLECT_UPTIME_DISP:-较长时间}，不属采集过早）——如本机应有模组请现场核查在位/上电；模组经 PCIe Fabric 接入时单独采集验收" 1
        fi
    }

    # 1. GPU PCIe 链路完整（无 GPU 机器判 N/A 且不计入"数据不足"——无 GPU 是平台形态非数据缺失；
    #    有 GPU 但驱动异常（lspci 3D controller 存在但 nvidia-smi 无数据）→ WARN，无法验收即问题）
    if [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
        if [ "${GPU_MODULE_STATE:-present}" = "unknown" ]; then
            _gpu_item_na "GPU PCIe 链路完整"
        elif [ "$HEAD_NODE" -eq 1 ]; then
            add_item "GPU PCIe 链路完整" "N/A" "GPU 机头（无本地 GPU，模组单独采集验收）" 1
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
                  *)    if [ "${GPU_MODULE_STATE:-present}" = "unknown" ] && [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
                            _gpu_item_na "NVLink 互联"
                        elif [ "$HEAD_NODE" -eq 1 ]; then
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
                  *)    if [ "${GPU_MODULE_STATE:-present}" = "unknown" ] && [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
                            _gpu_item_na "DCGM 诊断"
                        elif [ "$HEAD_NODE" -eq 1 ]; then
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
    # v1.54.25：GPU 功耗上限被改（Current ≠ Default）——仅检出时追加，不改变无此项机器的项数
    if [ -n "${GPU_PL_MISMATCH:-}" ]; then
        add_item "GPU 功耗上限" "WARN" "功耗上限被改：${GPU_PL_MISMATCH}<br>满载仅部分预算，会掉频且各卡算力不均；恢复：sudo nvidia-smi -pl ${GPU_PL_DEFAULT:-默认值} 后复测"
    fi

    # 5. 内存运行速率（v1.48.69 先定 DPC 口径；v1.51.9 增「混插」独立一档）
    #   v1.51.10 判据顺序修正（用户口径："内存插满/超过 1DPC 降速很正常，不该一刀切；
    #   只是料号不同仍能用，最多兼容性风险；额定或 Rank 不同才是真混插"）：
    #   ① >1DPC（含插满）→ PASS：降速属平台规范，与是否混插无关，**优先于混插判定**
    #   ② 真混插（额定档或 Rank 不同）→ WARN：控制器只能按最低档训练，兼容性风险实质存在
    #   ③ 仅部件号不同（额定/Rank 一致）→ PASS：同规格不同料号
    #   ④ 不混插 + ≤1DPC 仍降速 → WARN（真问题，建议核查 BIOS）
    if [ -z "$MEM_SPEED" ] || [ "$MEM_SPEED" = "N/A" ]; then
        add_item "内存运行速率" "N/A" "内存速率数据不可用"
    elif [ "${MEM_OVER_1DPC:-0}" -eq 1 ] || [ "${MEM_FULL:-0}" -eq 1 ]; then
        _mix_tail=""
        [ "${MEM_MIXED_SPEC:-0}" -eq 1 ] && _mix_tail="；另有规格混插（${MEM_NOM_KINDS} 档额定 / ${MEM_RANK_KINDS} 种 Rank）"
        add_item "内存运行速率" "PASS" "降速运行（现速 ${MEM_SPEED}，额定 ${MEM_NOM}；已插 ${MEM_POPULATED}/${MEM_SLOTS} 槽属 >1DPC 配置，降速为平台规范正常现象${_mix_tail}）"
    elif [ "${MEM_MIXED_SPEC:-0}" -eq 1 ]; then
        _at_min=""
        [ "$MEM_SPEED" = "$MEM_NOM" ] && _at_min="；现速 ${MEM_SPEED} 即该配置的最低额定，无额外降速"
        add_item "内存运行速率" "WARN" "内存规格混插（${MEM_NOM_KINDS} 档额定速率 / ${MEM_RANK_KINDS} 种 Rank / ${MEM_PN_KINDS} 种部件号），控制器按最低额定 ${MEM_NOM} 训练${_at_min}"
    # 注：料号差异（规格一致）不单独提示（市场常态），直接走「额定速率运行」分支
    elif [ -n "$MEM_SPEED_NOTE" ]; then
        if [ "${MEM_OVER_1DPC:-0}" -eq 1 ] || [ "${MEM_FULL:-0}" -eq 1 ]; then
            add_item "内存运行速率" "PASS" "降速运行（额定 ${MEM_NOM}，现速 ${MEM_SPEED}；已插 ${MEM_POPULATED}/${MEM_SLOTS} 槽属 >1DPC 配置，降速为平台规范正常现象）"
        else
            add_item "内存运行速率" "WARN" "降速运行（额定 ${MEM_NOM}，现速 ${MEM_SPEED}；仅插 ${MEM_POPULATED:-0}/${MEM_SLOTS:-N/A} 槽 ≤1DPC 仍降速，建议核查 BIOS 设置）"
        fi
    else
        add_item "内存运行速率" "PASS" "额定速率运行（${MEM_SPEED:-N/A}）"
    fi

    # v1.49.17：移除原「IB 线缆配对」验收项。
    #   ⚠️ v1.51.4 更正：原注释写"`CABLE_PAIRS` 恒空"**不成立**——实测 24 个真实样本中
    #   有 2 台取到了值（mlx5_10↔mlx5_11 / mlx5_11↔mlx5_1,...），它只在"IB 链路未起或
    #   该口无光模块"的机器上为空。移除该验收项的真正理由是：**配对信息是拓扑描述，
    #   不是合格判据**（缺值也可能只是链路没起，判 N/A 无意义），故不入验收清单；
    #   但报告正文保留该行（有值时为拓扑证据），且 N/A 时必须写明原因。
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
    # v1.50.0：在位/槽位对比——交付验收常遇场地供电受限导致不满配，把"插了几个槽位"
    #   写进判定说明供验收人对照采购配置单；不做"必须插满"硬判（机型槽位差异大，硬判必误报）
    _pwr_slot=""
    if [ -n "${PSU_SLOT_TOTAL:-}" ]; then
        _pn=${PSU_SENSOR_SEEN:-0}
        [ "$_pn" -eq 0 ] 2>/dev/null && _pn=${PSU_COUNT_DMI:-0}
        if [ "$_pn" -gt 0 ] 2>/dev/null; then
            _pwr_slot="；在位 ${_pn}/${PSU_SLOT_TOTAL} 个电源槽位"
            [ "$_pn" -lt "$PSU_SLOT_TOTAL" ] 2>/dev/null && _pwr_slot="${_pwr_slot}（场地降配需确认冗余并在验收单备注）"   # v1.54.28 精简
        fi
    fi
    if [ "${PSU_STATUS_BAD:-0}" -gt 0 ] 2>/dev/null; then
        add_item "电源状态" "FAIL" "检测到 ${PSU_STATUS_BAD} 颗电源状态异常（IPMI PS*_Status 非 0x1）${PSU_STATUS_BAD_D:+：${PSU_STATUS_BAD_D}}${_pwr_slot}${_pwr_red}"
    elif [ "${PSU_STATUS_OK:-0}" -gt 0 ] 2>/dev/null; then
        add_item "电源状态" "PASS" "${PSU_STATUS_OK} 颗电源状态正常（IPMI PS*_Status=0x1${PSU_STATUS_TEMP:+；温度 ${PSU_STATUS_TEMP}}${PSU_STATUS_PWR:+；功耗 ${PSU_STATUS_PWR}}）${_pwr_slot}${_pwr_red}"
    elif [ "${PSU_COUNT_DMI:-0}" -ge 2 ] 2>/dev/null; then
        add_item "电源状态" "PASS" "SMBIOS 确认 ${PSU_COUNT_DMI} 颗电源在位（该平台 IPMI 未暴露电源状态传感器，按在位数量判定）${_pwr_slot}${_pwr_red}"
    elif [ -n "${PSU_DETAILS:-}" ]; then
        _pc=$(printf '%s\n' "$PSU_DETAILS" | grep -c .)
        add_item "电源状态" "PASS" "PSU 明细 ${_pc} 条（电源 FRU/传感器可见，IPMI 无状态等级数据）${_pwr_slot}${_pwr_red}"
    else
        add_item "电源状态" "N/A" "该平台未暴露电源状态（IPMI 无 PS*_Status、SMBIOS 无 Type 39、FRU 无 PSU 条目；平台固有，不计数）" 1
    fi

    # 10. 整机温度正常范围（进风/出风/CPU/内存/电源/PCH 传感器均 ok）
    #     v1.52.16：补 OS 侧兜底。此前只读 BMC 侧 `TEMP_SUMMARY`，而 OS 侧聚合结果
    #     `TEMP_SUMMARY_OS`（lm-sensors，v1.45.16 引入）**只用于报告正文**、从未进入判定 ——
    #     表现是报告正文写着 `温度 CPU 38-106°C（OS 侧 lm-sensors）`，验收项却判
    #     「N/A 无温度传感器数据」，同一份报告自相矛盾（实测一台 B300 机即如此）。
    if [ -n "${TEMP_SUMMARY:-}" ]; then
        add_item "整机温度正常" "PASS" "${TEMP_SUMMARY}"
    elif [ -n "${TEMP_SUMMARY_OS:-}" ]; then
        add_item "整机温度正常" "PASS" "${TEMP_SUMMARY_OS}（BMC 温度传感器未暴露，取 OS 侧读数）"
    elif [ "${BMC_LOG_EXISTS:-0}" -eq 1 ] && [ "${BMC_PRESENT:-0}" -eq 0 ]; then
        add_item "整机温度正常" "N/A" "平台无 BMC（无 IPMI 温度传感器，温度判定不适用）" 1
    else
        add_item "整机温度正常" "N/A" "无温度传感器数据"
    fi

    # 11. SEL 事件（v1.48.86：按「告警是否已解除」判，而非「是否出现过 Critical 字样」）
    #     旧实现只看 SEL_CRIT>0 → FAIL，而 SEL_CRIT 是 grep -ciE "critical|fatal" 的行数，
    #     连 Deasserted 行（描述里同样含 "Critical"）也计入 → 已自愈的历史事件被判 FAIL。
    #     现按终态：未解除=FAIL；已自愈=WARN（告知曾发生但不卡交付）；无 Critical=PASS。
    if [ "${SEL_DATA_VALID:-0}" -ne 1 ] 2>/dev/null; then
        add_item "SEL 事件" "N/A" "SEL 数据不可用（ipmitool 采集失败或无权限）"
    elif [ "${SEL_CRIT_UNRESOLVED:-0}" -gt 0 ] 2>/dev/null; then
        # v1.52.20：细分「未解除」的成因。未解除事件若**与断电事件同时间戳**，是掉电瞬间
        #   传感器读数触发的记录（风扇转速 0、温度骤降），BMC 恢复后不一定补 Deassert——
        #   实测一台 B300 机 8 条未解除的风扇 Lower Critical 全部落在同一秒，同秒有
        #   Power Supply AC lost，而当前风扇转速全部 ok。这类判 WARN（告知但不卡交付）；
        #   只有**存在与断电无关的未解除告警**时才判 FAIL。
        _sel_pwr="${SEL_CRIT_POWER_CAUSED:-0}"
        if [ "${_sel_pwr}" -gt 0 ] 2>/dev/null && [ "${_sel_pwr}" -ge "${SEL_CRIT_UNRESOLVED}" ] 2>/dev/null; then
            add_item "SEL 事件" "WARN" "共 ${SEL_TOTAL:-0} 条 SEL，${SEL_CRIT_UNRESOLVED} 条未收到解除事件，**全部落在断电时刻**（同秒伴随 Power Supply AC lost / Power off-down）——属掉电瞬间的传感器记录，非硬件故障；建议对照当前传感器读数确认"
        elif [ "${_sel_pwr}" -gt 0 ] 2>/dev/null; then
            add_item "SEL 事件" "FAIL" "共 ${SEL_TOTAL:-0} 条 SEL，${SEL_CRIT_UNRESOLVED} 条 Critical 告警尚未解除（其中 ${_sel_pwr} 条落在断电时刻）；**其余需处理后再交付**"
        else
            add_item "SEL 事件" "FAIL" "共 ${SEL_TOTAL:-0} 条 SEL，其中 ${SEL_CRIT_UNRESOLVED} 条 Critical 告警**尚未解除**（需处理后再交付）"
        fi
    elif [ "${SEL_PCIE_ERR:-0}" -gt 0 ] 2>/dev/null; then
        # v1.53.37：分级（旧实现只要 >0 就 FAIL，把「可纠正的 PCI PERR」与「不可纠正」同等对待）
        _pcie_detail="${SEL_PCIE_ERR} 条 PCIe/AER 记录"
        [ "${SEL_PCIE_ERR_UNCORR:-0}" -gt 0 ] 2>/dev/null && _pcie_detail="${_pcie_detail}（其中不可纠正 ${SEL_PCIE_ERR_UNCORR} 条）"
        if [ "${SEL_PCIE_ERR_UNCORR:-0}" -gt 0 ] 2>/dev/null; then
            add_item "SEL 事件" "FAIL" "${_pcie_detail}——含不可纠正错误，需处理后再交付"
        elif [ "${SEL_PCIE_ERR_HISTORY:-0}" -eq 1 ] 2>/dev/null; then
            add_item "SEL 事件" "WARN" "${_pcie_detail}，全部为历史记录${SEL_PCIE_ERR_NOTE#，}——非当前故障，建议交付前清 SEL"
        else
            add_item "SEL 事件" "WARN" "${_pcie_detail}（可纠正类，时间跨度 ${SEL_PCIE_ERR_SPAN:-未知}）——链路在持续纠错，建议结合「PCIe AER 错误」项一起看；如持续增长则交付前处理"
        fi
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
        # v1.53.37：区分「真没采」与「采了但没有可判定项」——实测 AMD 整机 15_firmware 正常执行
        #   （fw_versions.log 为空、fw_compliance.csv 仅表头），旧文案「未采集或旧数据」与事实不符，
        #   会让人以为模块失败而去排查采集。
        if [ -f "${OUT}/firmware/fw_versions.log" ] || [ -f "${OUT}/firmware/fw_compliance.csv" ]; then
            # 归类：**平台固有/宽容 N/A**（本机根本没这类固件项，不是数据缺口，不计入「数据不足」）
            add_item "固件版本合规" "N/A" "本机无可判定固件项（15_firmware 已执行：无 nvidia VBIOS / 网卡固件未匹配基线 / BMC 固件不在对比表）" 1
        else
            add_item "固件版本合规" "N/A" "无固件数据（该采集未跑 15_firmware，或为旧版本采集）"
        fi
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|落后|"; then
        _fw_behind=$(printf '%s\n' "$FW_COMPLIANCE_DETAILS" | awk -F'|' '$5=="落后"{printf "%s(%s→%s), ", $2, $4, $3}')
        add_item "固件版本合规" "FAIL" "固件落后于推荐版本: ${_fw_behind%,}"
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|无法比较|"; then
        add_item "固件版本合规" "WARN" "部分固件版本格式非标准，需人工核对"
    elif printf '%s\n' "$FW_COMPLIANCE_DETAILS" | grep -q "|未知|"; then
        add_item "固件版本合规" "N/A" "无基线配置（conf/fw_required.txt 未录入推荐版本，默认不对比；录入后自动启用）" 2
    else
        add_item "固件版本合规" "PASS" "全部固件版本满足推荐基线（较新不判落后）"
    fi

    # 13. OS vs BMC 口径一致（零新采集交叉校验；不一致=FAIL，仅单侧数据=WARN，无数据=N/A）
    # 默认关闭（--bmc-verify 开启）：未启用时 N/A 且不计入"数据不足"（该校验为可选深度核验，非交付必检项）
    if [ "$BMC_VERIFY" -eq 0 ]; then
        add_item "OS-BMC 口径一致" "N/A" "校验未启用（--bmc-verify 开启后执行，独立核验报告）" 2
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
        # v1.50.3：排除空槽（EMPTY_SLOT 标记）与缺失值，否则空槽会被当成一种"容量"→ 误报混插
        _mem_sizes=$(printf '%s\n' "$MEM_DIMMS" | awk -F'|' '$2!="" && $2!="N/A" && $2!="EMPTY_SLOT" && $2 !~ /No Module/{print $2}' | sort -u)
        _mem_kind=$(printf '%s\n' "$_mem_sizes" | grep -c .)
        # v1.48.42 修复：已插条数排除空槽（原 grep -c '|' 数全部行——32 槽插 16 条报"已插 32 条"）
        _mem_cnt=$(printf '%s\n' "$MEM_DIMMS" | awk -F'|' '$2!="" && $2!="N/A" && $2!="EMPTY_SLOT" && $2 !~ /No Module/{c++} END{print c+0}')
        if [ "${_mem_kind:-0}" -eq 0 ] 2>/dev/null; then
            add_item "内存容量一致" "N/A" "无容量数据（采集缺失）"
        elif [ "$_mem_kind" -le 1 ] 2>/dev/null; then
            add_item "内存容量一致" "PASS" "已插 ${_mem_cnt} 条同容量（$(printf '%s\n' "$_mem_sizes" | head -1)）"
        else
            add_item "内存容量一致" "WARN" "容量混插（$(printf '%s\n' "$_mem_sizes" | tr '\n' '、' | sed 's/、$//')）——建议对称配置"
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

    # 19. GPU ECC（v1.52.13：分性质与时机判定，不再把四类混加成一个数）
    #   口径依据 NVIDIA nvidia-smi：volatile = 本次驱动加载以来；aggregate = 终身计数（含出厂测试，RMA 依据）。
    #     volatile 不可纠正 > 0          → FAIL（当前存在不可纠正错误，数据完整性受影响）
    #     volatile 可纠正   > 0          → WARN（本次有可纠正错误，需观察是否持续增长）
    #     aggregate 不可纠正 > 0（vol=0）→ WARN（历史记录；建议压测复测确认 volatile 不增长）
    #     全 0                           → PASS
    #   背景：旧口径显示 "Enabled, errors: 48/0/849"，849 那台按旧读法像要坏了，
    #   实际 volatile 全为 0、真实情况是不可纠正累计 696 —— 混加会同时造成误读与误判。
    if [ -n "${GPU_ECC_MODE:-}" ]; then
        if [ "${GPU_ECC_AMD_RAS:-0}" = "1" ]; then
            _ecc_desc="AMD RAS 单比特(CE) ${GPU_ECC_CORR_VOL:-?} / 双比特(UE) ${GPU_ECC_UNCORR_VOL:-?}（ROCm 口径，本次驱动加载以来）"
        else
        # v1.54.29：短标签 + 去掉 volatile/aggregate 英文（术语表有）；结论与建议分两行
        _ecc_desc="本次 CE ${GPU_ECC_CORR_VOL:-?} / UE ${GPU_ECC_UNCORR_VOL:-?}；累计 CE ${GPU_ECC_CORR_AGG:-?} / UE ${GPU_ECC_UNCORR_AGG:-?}"
        fi
        [ -n "${GPU_ECC_BADCARDS:-}" ] && _ecc_desc="${_ecc_desc}（UE 集中在 GPU${GPU_ECC_BADCARDS//,/,GPU}）"
        case "${GPU_ECC_VERDICT:-PASS}" in
            FAIL) add_item "GPU ECC" "FAIL" "${_ecc_desc}<br>⚠️ 本次运行检出不可纠正错误（volatile > 0），数据完整性受影响，需报修" ;;
            WARN) add_item "GPU ECC" "WARN" "${_ecc_desc}<br>当前无正在发生的错误，仅历史记录；建议跑显存压力后复测是否增长" ;;
            *)    # v1.54.28：全 0 时不必复述四组计数，一句话够用
                  if echo "${GPU_ECC_CORR_VOL:-0}${GPU_ECC_UNCORR_VOL:-0}${GPU_ECC_CORR_AGG:-0}${GPU_ECC_UNCORR_AGG:-0}" | grep -qx '0000'; then
                      add_item "GPU ECC" "PASS" "本次与累计均无错误（volatile 0 / aggregate 0）"
                  else
                      add_item "GPU ECC" "PASS" "${_ecc_desc}"
                  fi ;;
        esac
    elif [ "${GPU_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        # v1.52.15：区分「采集缺失」与「平台工具链限制」——
        #   NVIDIA 无 gpu_ecc_inventory.csv = 采集缺失（该文件必生成）→ N/A 计入数据不足；
        #   AMD 的 ECC 由 ROCm 工具暴露（rocm-smi --showrasinfo / amd-smi metric -e / rocm-smi --query-ecc），
        #     驱动或工具版本不暴露时取不到，属平台工具链限制 → 平台固有 N/A，不计数。
        #   实测 MI300X 正因此项被计入「数据不足」，判定由「合格」掉成「基本通过」。
        if [ "${GPU_PLATFORM:-}" = "amd" ]; then
            add_item "GPU ECC" "N/A" "AMD ECC 依赖 ROCm 工具（rocm-smi / amd-smi），本次未取到（详见 gpu_amd_ras.log）——平台工具链限制，非采集缺失" 1
        else
            add_item "GPU ECC" "N/A" "无 ECC 数据（该采集版本未生成 gpu_ecc_inventory.csv）"
        fi
    fi

    # ── v1.53.40：采集时机（开机 <3 分钟且未发现 GPU）——条件项，仅检出才追加 ──
    #   实测事故：开机 13 秒采集 → GPU 未枚举 → 平台判 GPU 机头、GPU 四类项判「平台固有 N/A」，
    #   验收看似正常（合格/有条件通过），实则**根本没测到 GPU**。这种情况必须显式告警。
    if [ "${COLLECT_EARLY:-0}" -eq 1 ] 2>/dev/null && [ "${GPU_COUNT:-0}" -eq 0 ] 2>/dev/null; then
        add_item "采集时机" "WARN" "采集时系统运行时间 ${COLLECT_UPTIME_DISP}（不足 3 分钟），未发现 GPU——GPU/网卡可能尚未枚举完成；本次 GPU 相关结论无效，请开机 ≥2 分钟后重采"
    fi

    # ── v1.53.37：PCIe AER 错误（仅检出才追加项，不改变默认项数）──
    #   与「PCIe 链路完整」互补：后者只看 LnkCap vs LnkSta（速率/宽度），
    #   看不到 AER 计数——实测一台 8×MI300X 在 32:01.0 上持续 255 处可纠正接收错误，
    #   而「链路完整」判 PASS。可纠正 → WARN（建议重插/换槽/查线缆后再判）；
    #   不可纠正 → FAIL（数据完整性受损，必须处理）。
    if [ "${PCIE_AER_UNCORR:-0}" -gt 0 ] 2>/dev/null; then
        add_item "PCIe AER 错误" "FAIL" "不可纠正 ${PCIE_AER_UNCORR} 处 / 可纠正 ${PCIE_AER_CORR} 处（${PCIE_AER_BDFS}；来源 ${PCIE_AER_SRC}）"
    elif [ "${PCIE_AER_CORR:-0}" -gt 0 ] 2>/dev/null; then
        add_item "PCIe AER 错误" "WARN" "可纠正 ${PCIE_AER_CORR} 处（${PCIE_AER_BDFS}；来源 ${PCIE_AER_SRC}）——链路持续纠错，建议重插该卡/换槽位/查线缆后复测"
    fi

    # ── 硬件故障历史项（v1.48.90：GPU XID / CPU MCE / RAID 缓存电池）──
    # 判据取向：这些都是「已经出过事」的历史记录，**判 WARN 而非 FAIL**——
    #   ① 历史事件可能已通过换卡/复位解决，据此否决交付不合理；
    #   ② 但绝不能沉默放过：XID 79（掉卡）/ 双bit ECC / MCE / 电池失效，
    #      是跟供应商谈判时最硬的证据，报告必须留痕。
    # 仅在检出时添加：无检出不加项，保证验收项数与既有基线一致。
    if [ -n "${GPU_XID:-}" ]; then
        add_item "GPU XID 错误历史" "WARN" "XID ${GPU_XID_CODES:-?}：${GPU_XID_DEVS:-?} 张卡共 ${GPU_XID_TOTAL:-?} 条记录（去重 ${GPU_XID_COUNT} 行，来源 ${GPU_XID_SRC}）——需确认对应卡是否已更换/复位"
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
    # v1.54.32：网卡归类统计已移至 report/sections/65_nic_accounting.sh（一处计算三端共用）
    ACC_PSU_MODEL="N/A"; ACC_PSU_CAP="N/A"; ACC_PSU_COUNT=0
    if [ -n "$PSU_DETAILS" ]; then
        while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
            [ -z "$pdesc" ] && continue
            ACC_PSU_COUNT=$((ACC_PSU_COUNT+1))
            [ "$ACC_PSU_MODEL" = "N/A" ] && [ "$pmodel" != "N/A" ] && [ -n "$pmodel" ] && ACC_PSU_MODEL="$pmodel"
            # v1.52.25：规格行要干净 —— 剥离「N/A（成因说明）」中的说明部分
            #   （成因说明只服务人工可读的明细表；JSON 同样剥离）。原判据 `$pcap != "N/A"`
            #   会让「N/A（该机 SMBIOS 无 Type 39 记录…）」被当作有效容量取走。
            _pcap_clean=$(printf '%s' "$pcap" | sed 's/^N\/A（.*）$/N\/A/')
            [ "$ACC_PSU_CAP" = "N/A" ] && [ "$_pcap_clean" != "N/A" ] && [ -n "$_pcap_clean" ] && ACC_PSU_CAP="$_pcap_clean"
        done < <(printf '%s\n' "$PSU_DETAILS")
    fi
    ACC_DISK_MODEL="N/A"
    if [ -n "${STORAGE_MODELS:-}" ]; then
        ACC_DISK_MODEL=$(echo "$STORAGE_MODELS" | tr ',' '\n' | head -1)
    fi
    # 存储规格：按「型号 + 类型 + 单盘额定容量」分组计数，渲染成
    #   <型号>（<类型> <单盘容量>）×<n>，多组用 " + " 连接
    # 目的：让配置单能看出「几块多大、什么接口」，而不是只有型号 + 总容量
    # 细节：① dspec 自带「额定」前缀（30_storage_gpu_extra.sh 生成），显示前剥掉，型号含该容量时括号内不重复
    #   ② RAID 卡伪盘（MR9xxx/PERC/MegaRAID…）与 16 进制伪"额定"不计入分组（非物理盘）
    #   ③ 分组数与 STORAGE_COUNT（块设备数）不一致时，数量列注明「其中物理盘 N」，避免看的人误判
    ACC_DISK_SPEC=""; ACC_DISK_GRP_N=""
    if [ -n "${DISK_DETAILS:-}" ]; then
        _dspec_out=$(printf '%s\n' "$DISK_DETAILS" | awk -F'|' '
            NF >= 4 {
                model = $4; type = $2; spec = $11; size = $3
                gsub(/^[ \t]+|[ \t]+$/, "", model)
                gsub(/^[ \t]+|[ \t]+$/, "", type)
                gsub(/^[ \t]+|[ \t]+$/, "", spec)
                gsub(/^[ \t]+|[ \t]+$/, "", size)
                sub(/^额定/, "", spec)
                if (model == "" || model == "N/A") model = "未知型号"
                if (spec == "" || spec == "N/A") spec = size
                if (type == "" || type == "N/A") type = ""
                if (type ~ /MegaRAID|MR[0-9][0-9][0-9]|PERC|Smart Array|Adaptec|RAID/) next
                if (spec ~ /^[0-9a-fA-F]{16,}$/) spec = ""
                d = type
                if (spec != "" && index(model, spec) == 0) d = (d == "" ? spec : d " " spec)
                key = model SUBSEP d
                if (!(key in cnt)) { order[++n] = key; mdl[key] = model; dsc[key] = d }
                cnt[key]++; total++
            }
            END {
                for (i = 1; i <= n; i++)
                    for (j = i + 1; j <= n; j++) {
                        a = order[i]; b = order[j]
                        if (cnt[b] > cnt[a] || (cnt[b] == cnt[a] && mdl[b] < mdl[a])) {
                            t = order[i]; order[i] = order[j]; order[j] = t
                        }
                    }
                out = ""
                for (i = 1; i <= n; i++) {
                    k = order[i]
                    s = mdl[k] (dsc[k] == "" ? "" : "（" dsc[k] "）") "×" cnt[k]
                    out = out (out == "" ? "" : " + ") s
                }
                print (total + 0) "|" out
            }')
        ACC_DISK_GRP_N="${_dspec_out%%|*}"
        ACC_DISK_SPEC="${_dspec_out#*|}"
    fi

    {
        echo "# HwScope 验收清单（Acceptance Checklist）"
        echo ""
        echo "## 硬件概览（配置单，自动生成自检测数据）"
        echo ""
        echo "| 项目 | 规格型号描述（含配置） | 单位 | 数量 |"
        echo "|------|------------------------|------|------|"
        echo "| 准系统 | ${MB_MANUFACTURER:-N/A} ${MB_PRODUCT:-N/A}（系统 SN: ${MB_SN:-N/A}，机箱 SN: ${CHASSIS_SN:-N/A}，BIOS: ${BIOS_VERSION:-N/A}） | 台 | 1 |"
        echo "| CPU | ${CPU_MODEL:-N/A}（${CPU_CORES:-0} 核/颗，${CPU_MAX_SPEED:-N/A}MHz） | 颗 | ${CPU_SOCKETS:-0} |"
        echo "| 内存 | ${MEM_TYPE:-DDR} ${ACC_MEM_DIMM:-N/A} ECC RDIMM（额定 ${MEM_NOM:-N/A}，实际 ${MEM_SPEED:-N/A}；合计 ${MEM_TOTAL:-N/A}） | 条 | ${MEM_POPULATED:-0} |"
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
        elif [ "${GPU_MODULE_STATE:-present}" = "unknown" ] 2>/dev/null; then
            # v1.53.42：**未识别到**就写未识别到——不写「无」（会读成"确认没装"），
            #   也不写"可能装有"（那是猜）。原因放括号里，需要的动作写清楚。
            echo "| GPU模组 | 未识别到（本次采集未枚举到加速卡：${GPU_MODULE_REASON}） | — | — |"
        else
            echo "| GPU模组 | 未识别到（${MACHINE_CLASS_LABEL:-${PLATFORM_LABEL:-N/A}}） | — | — |"
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

        # v1.52.17：区分「平台无本地数据盘」与「采集失败」。实测一台 ASUS B300 本机只有
        #   USB 安装盘（sda 476.9G）+ 4 个 0B 虚拟盘 → STORAGE_COUNT=0，原渲染 `N/A（0 GiB）`
        #   让读者以为「没采到数据」；实际是「该机未配本地数据盘」（GPU 服务器常走网络存储）。
        #   判据：block_devices_all 有非注释数据行 → 采集本身成功。
        _stor_rows=$([ -f "${block_devices_all:-}" ] && grep -vcE '^#|^$' "${block_devices_all}" 2>/dev/null || echo 0)
        if [ "${STORAGE_COUNT:-0}" -eq 0 ] 2>/dev/null && [ "${_stor_rows:-0}" -gt 0 ] 2>/dev/null; then
            echo "| 存储 | 无本地数据盘（本机仅 USB/虚拟盘，块设备记录 ${_stor_rows} 条） | 块 | 0 |"
        else
            if [ -n "${ACC_DISK_SPEC:-}" ]; then
                _cntcell="${STORAGE_COUNT:-0}"
                if [ -n "${ACC_DISK_GRP_N:-}" ] && [ "${ACC_DISK_GRP_N}" != "${STORAGE_COUNT:-0}" ]; then
                    _cntcell="${STORAGE_COUNT:-0}（其中物理盘 ${ACC_DISK_GRP_N}）"
                fi
                echo "| 存储 | ${ACC_DISK_SPEC}（共 ${STORAGE_TOTAL:-0}） | 块 | ${_cntcell} |"
            else
                echo "| 存储 | ${ACC_DISK_MODEL:-N/A}（${STORAGE_TOTAL:-0}） | 块 | ${STORAGE_COUNT:-0} |"
            fi
        fi
        echo "| 电源模块 | ${ACC_PSU_MODEL:-N/A}（${ACC_PSU_CAP:-N/A}） | 个 | ${ACC_PSU_COUNT:-0} |"
        # v1.54.12：风扇补进概览——原来只在正文有，配置单/交接单上看不到。
        #   （阵列不进概览：硬件概览只列硬件部件，阵列属 RAID 段，有阵列卡时在 RAID 控制器段呈现。）
        if [ "${FAN_DATA_OK:-0}" -eq 1 ] 2>/dev/null; then
            echo "| 风扇 | ${FAN_COUNT_BREAKDOWN:-${FAN_COUNT:-0}} | 个 | ${FAN_COUNT:-0} |"
        fi
        # v1.54.27：① 无 BMC 的平台不显示本行（原先恒写 `BMC（固件 N/A）` 属噪音）
        #   ② 有 BMC 时补管理地址——交接单上登记管理口比"固件版本"更常用
        if [ "${BMC_PRESENT:-0}" = "1" ] 2>/dev/null || [ -n "${BMC_FW:-}" ]; then
            _sm_val="BMC（固件 ${BMC_FW:-N/A}"
            # v1.54.30：管理地址带来源（DHCP / 静态）——换网/换机是否需改回固定 IP 取决于此
            if [ -n "${BMC_IP:-}" ] && [ "${BMC_IP}" != "0.0.0.0" ]; then
                _sm_val="${_sm_val} · 管理地址 ${BMC_IP}"
                [ -n "${BMC_IP_SRC:-}" ] && _sm_val="${_sm_val}（${BMC_IP_SRC}）"
            elif [ "${BMC_IP:-}" = "0.0.0.0" ]; then
                # v1.54.30：地址全 0 表示管理口未配置，直接写 0.0.0.0 会被当成有效地址
                _sm_val="${_sm_val} · 管理地址未配置"
            fi
            _sm_val="${_sm_val}）"
            echo "| 系统管理 | ${_sm_val} | 套 | 1 |"
        fi
        echo ""
        echo "## 验收信息"
        echo ""
        # v1.48.41：验收口径声明——平台形态 + 适用项计数（固有 N/A 折叠后客户一眼看懂按什么口径验收）
        _na_n=$(printf '%s' "$NA_INHERENT" | tr -cd '|' | wc -c)
        _na_p=$(printf '%s' "$NA_PENDING" | tr -cd '|' | wc -c)
        # v1.54.27：三条信息改两列表格（原先 bullet 长短不齐、冒号不对齐）
        echo "| 项 | 内容 |"
        echo "|----|------|"
        echo "| 验收口径 | ${MACHINE_CLASS_LABEL:-N/A}（GPU 平台: ${GPU_PLATFORM:-none}；${_na_n:-0} 项平台固有 N/A 不适用，下表 ${n} 项为实际判定项） |"
        echo "| 生成时间 | $(date '+%Y-%m-%d %H:%M:%S') |"
        echo "| 采集版本 / 报告版本 | ${VERSION:-unknown} / ${REPORT_VERSION:-unknown} |"
        echo ""
        echo "## 验收项目"
        echo ""
        echo "| # | 检查项 | 结果 | 说明 |"
        echo "|---|--------|------|------|"
        # v1.54.27：按 rank（章节顺序）稳定排序后连续重排序号
        printf '%s' "$rows" | grep -v '^$' | sort -t'|' -k1,1n -k2,2n \
            | awk -F'|' '{ printf "| %d | %s | %s | %s |\n", NR, $3, $4, $5 } '
        if [ -n "$NA_INHERENT" ]; then
            echo ""
            echo "> 本平台固有/宽容 N/A（不计入数据不足，共 ${_na_n:-0} 项）：$(printf '%s' "$NA_INHERENT" | sed 's/|$//; s/|/、/g')"
        fi
        if [ "${_na_p:-0}" -gt 0 ] 2>/dev/null; then
            echo ""
            echo "> 本机待启用/待配置 N/A（**不计入平台固有**——这些项本机具备条件，只是开关未开或基线未录，共 ${_na_p} 项）：$(printf '%s' "$NA_PENDING" | sed 's/|$//; s/|/、/g')"
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
