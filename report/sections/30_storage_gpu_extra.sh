#!/bin/bash
# =============================================================================
# HwScope - 变量解析：存储 + GPU 补全(REMAP/VBIOS/NVLink) + NVSwitch
# report/sections/30_storage_gpu_extra.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# ─── 存储（只统计物理盘 TYPE=disk，避免把分区/LVM 计入容量） ───
STO_DIR="${OUT}/storage"
load_manifest "${STO_DIR}" block_devices_all "block_devices_all.log"
load_manifest "${STO_DIR}" disk_inventory "disk_inventory.csv"
STORAGE_COUNT=0; STORAGE_TOTAL="N/A"; STORAGE_MODELS=""
# 系统盘识别：根文件系统 / 挂载所在的物理盘（lsblk 树形回溯父盘）
SYS_DISK=""
if [ -f "${block_devices_all}" ]; then
    SYS_DISK=$(grep -v "^#" "${block_devices_all}" | awk '
        $1 ~ /^[a-zA-Z0-9_]+$/ {cur=$1}
        $0 ~ / \/ / && $0 !~ /\/boot/ {print cur; exit}
    ')
fi
if [ -f "${block_devices_all}" ]; then
    # 物理盘行遍历找 size 字段（model 可能含空格导致列偏移，不能用固定列）；默认排除系统盘
    STORAGE_COUNT=$(grep -v "^#" "${block_devices_all}" | awk -v sys="$SYS_DISK" '$NF=="disk" && $1 != sys {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/ && $i != "0B") c++} END{print c+0}')
    STORAGE_TOTAL=$(grep -v "^#" "${block_devices_all}" | awk -v sys="$SYS_DISK" '$NF=="disk" && $1 != sys {v=""; for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/ && $i != "0B") {v=$i; break}; \
        if(v!=""){n=substr(v,1,length(v)-1); u=substr(v,length(v)); \
        if(u=="T")s+=n*1024; else if(u=="G")s+=n; else if(u=="M")s+=n/1024; else if(u=="K")s+=n/1024/1024}} \
        END{printf "%.0f GiB", s}' 2>/dev/null)
    # 盘型号：从 disk_inventory.csv 取（MODEL/SERIAL 已分离）；排除系统盘（与盘数/容量口径一致）；回退 block_devices 提取
    if [ -f "${disk_inventory}" ]; then
        STORAGE_MODELS=$(grep -v "^#" "${disk_inventory}" 2>/dev/null | awk -F'|' -v sys="$SYS_DISK" '$1!="" && $1!=sys && $4!="N/A" && $4!="" && $4 !~ /MegaRAID|MR[0-9][0-9][0-9]|PERC|Smart Array|Adaptec/ {print $4}' | sort -u | sed 's/\(^.\{40\}\).*/\1…/' | tr '\n' ',' | sed 's/,$//')
    else
        STORAGE_MODELS=$(grep -v "^#" "${block_devices_all}" | awk -v sys="$SYS_DISK" '$NF=="disk" && $1 != sys {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/ && $i != "0B") {print $(i-1); break}}' | sort -u | sed 's/\(^.\{40\}\).*/\1…/' | tr '\n' ',' | sed 's/,$//')
    fi
fi

# 盘明细（disk_inventory.csv: name|type|size|model|serial|fw|bdf|power_on）
# RAID 虚拟盘（逻辑盘）与物理盘分表：虚拟盘型号是 RAID 卡型号，SN 是 LUN，无 SMART，混在物理盘表会误导
DISK_DETAILS=""
RAID_VD_DETAILS=""
if [ -f "${disk_inventory}" ]; then
    while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare; do
        [ -z "$dname" ] || [ "$dname" = "N/A" ] && continue
        [ "$dname" = "#" ] && continue
        [ "$dname" = "$SYS_DISK" ] && continue   # 默认排除系统盘
        # RAID 虚拟盘判定：型号是 RAID 卡型号（MegaRAID/MRxxxx/PERC/Smart Array/Adaptec）
        is_raid_vd=0
        case "$dmodel" in
            *MegaRAID*|*MR[0-9][0-9][0-9]*|*PERC*|*"Smart Array"*|*Adaptec*|*ServeRAID*) is_raid_vd=1 ;;
        esac
        # 额定容量：优先从型号字符串自动提取（如 "PM1733a RI 3.84TB"、"MTFDKBA480TFR"→480GB），
        # Samsung 硬编码表兜底（型号无容量字样时）
        dspec=""
        case "$dmodel" in
            *MZWL61T9HFLT*|*MZWL61T9HBLN*) dspec="额定1.92TB" ;;
            *MZWL63T8HFLT*|*MZWL63T8HBLN*) dspec="额定3.84TB" ;;
            *MZWL67T6HFLT*) dspec="额定7.68TB" ;;
            *MZ7L31T9*|*MZ7LH1T9*) dspec="额定1.92TB" ;;
            *MZ7L33T8*|*MZ7LH3T8*) dspec="额定3.84TB" ;;
            *MZ7L37T6*) dspec="额定7.68TB" ;;
            *MZQL21T9*) dspec="额定1.92TB" ;;
            *MZQL23T8*) dspec="额定3.84TB" ;;
            *MZQL27T6*) dspec="额定7.68TB" ;;
            *MZIL21T6*) dspec="额定1.6TB" ;;
            *MZIL23T8*) dspec="额定3.2TB" ;;
            *MZIL27T6*) dspec="额定6.4TB" ;;
            *)
                # Micron 型号规则: MTFDKBA480TFR / MTFDHBE960TFR → 数字=容量GB（T 是家族代号非 TB）
                if echo "$dmodel" | grep -qE 'MTFD[KHC][A-Z]{2}[0-9]{3,4}TFR'; then
                    micap=$(echo "$dmodel" | grep -oE '[0-9]{3,4}TFR' | head -1 | grep -oE '[0-9]+')
                    [ -n "$micap" ] && dspec="额定${micap}GB"
                # Micron N-T-N 结构（3T8=3.84TB 等；通用提取会把 "3T" 误判为 3TB）
                elif echo "$dmodel" | grep -qE 'MTFD[KHC][A-Z]{2}[0-9]T[0-9]TFR'; then
                    case "$dmodel" in
                        *1T9*) dspec="额定1.92TB" ;;
                        *3T8*) dspec="额定3.84TB" ;;
                        *7T6*) dspec="额定7.68TB" ;;
                        *1T6*) dspec="额定1.60TB" ;;
                        *3T2*) dspec="额定3.20TB" ;;
                        *6T4*) dspec="额定6.40TB" ;;
                        *15T*) dspec="额定15.36TB" ;;
                    esac
                fi
                # 通用提取：型号中显式容量（3.84TB / 1.92T / 480G 等）
                if [ -z "$dspec" ]; then
                    cap=$(echo "$dmodel" | grep -oE '[0-9]+(\.[0-9]+)?[TtGg][Bb]?' | head -1)
                    if [ -n "$cap" ]; then
                        # 统一单位：T→TB，G→GB（保留一位小数）
                        num=$(echo "$cap" | grep -oE '[0-9]+(\.[0-9]+)?')
                        unit=$(echo "$cap" | grep -oE '[TtGg]' | tr '[:lower:]' '[:upper:]')
                        dspec="额定${num}${unit}B"
                    fi
                fi
                ;;
        esac
        # 寿命归一化：N/A%（未采集到 SMART 数据）→ 显示 "—"（避免客户误读为盘异常）
        case "$dspare" in
            ""|N/A|N/A%|na|NA) dspare="—" ;;
        esac
        # SMART 整体健康（overall-health PASSED/FAILED 或 NVMe Critical Warning 0x00）
        dhealth="—"
        _disk_ctl=$(echo "$dname" | sed 's/n[0-9]*$//')   # nvme0n1 → nvme0（控制器），sda → sda
        for _hlog in "smart_${dname}.log" "smart_${_disk_ctl}.log"; do
            [ -f "${STO_DIR}/$_hlog" ] || continue
            _h=$(grep -m1 -iE "SMART overall-health|SMART Health Status" "${STO_DIR}/$_hlog" 2>/dev/null)
            if [ -n "$_h" ]; then
                case "$_h" in
                    *PASSED*|*OK*) dhealth="PASSED" ;;
                    *FAILED*|*FAILING*|*BAD*) dhealth="FAILED" ;;
                esac
                break
            fi
            _cw=$(grep -m1 -i "Critical Warning" "${STO_DIR}/$_hlog" 2>/dev/null | grep -oE "0x[0-9a-fA-F]+" | head -1)
            if [ -n "$_cw" ]; then
                [ "$_cw" = "0x00" ] && dhealth="OK" || dhealth="⚠️${_cw}"
                break
            fi
        done
        # SN/FW 回退：disk_inventory 的 SN/FW 为 N/A 时，从 smartctl 日志回退（RAID 逻辑盘是 SCSI 格式 Serial number:/Revision:）
        if [ "$dsn" = "N/A" ] || [ -z "$dsn" ]; then
            for _slog in "smart_${dname}_scsi.log" "smart_${dname}.log"; do
                [ -f "${STO_DIR}/$_slog" ] || continue
                _s=$(grep -m1 -iE "^Serial number:" "${STO_DIR}/$_slog" 2>/dev/null | cut -d: -f2- | xargs)
                [ -z "$_s" ] && _s=$(grep -m1 -iE "^Serial Number:" "${STO_DIR}/$_slog" 2>/dev/null | cut -d: -f2- | xargs)
                if [ -n "$_s" ] && [ "$_s" != "N/A" ]; then dsn="$_s"; break; fi
            done
        fi
        if [ "$dfw" = "N/A" ] || [ -z "$dfw" ]; then
            for _slog in "smart_${dname}_scsi.log" "smart_${dname}.log"; do
                [ -f "${STO_DIR}/$_slog" ] || continue
                _f=$(grep -m1 -iE "^Revision:" "${STO_DIR}/$_slog" 2>/dev/null | cut -d: -f2- | xargs)
                [ -z "$_f" ] && _f=$(grep -m1 -iE "Firmware Version:" "${STO_DIR}/$_slog" 2>/dev/null | cut -d: -f2- | xargs)
                if [ -n "$_f" ] && [ "$_f" != "N/A" ]; then dfw="$_f"; break; fi
            done
        fi
        if [ "$is_raid_vd" -eq 1 ]; then
            RAID_VD_DETAILS="${RAID_VD_DETAILS}${dname}|${dmodel}|${dsize}|${dsn}"$'\n'
        else
            DISK_DETAILS="${DISK_DETAILS}${dname}|${dtype}|${dsize}|${dmodel}|${dsn}|${dfw}|${dbdf}|${dpo}|${dpc}|${dspare}|${dspec}|${dhealth}"$'\n'
        fi
    done < <(grep -v "^#" "${disk_inventory}" 2>/dev/null)
fi

# GPU 退役行数（gpu_remapped_rows.csv）
GPU_REMAP="N/A"
load_manifest "${GPU_DIR}" gpu_remapped_rows "gpu_remapped_rows.csv"
if [ -f "${gpu_remapped_rows}" ]; then
    GPU_REMAP=$(grep -v "^#" "${gpu_remapped_rows}" | grep -v "^$" | awk -F',' '{gsub(/ /,"",$1); gsub(/ /,"",$2); gsub(/ /,"",$3); gsub(/ /,"",$4); c+=$1; u+=$2; p+=$3; f+=$4} END{if(NR>0) printf "CE:%d UE:%d pending:%d fail:%d", c, u, p, f; else print "N/A"}')
fi

# VBIOS 版本（每卡 detail 聚合去重；混插时标不一致而非只取第一张卡）
# v1.48.23：不再无条件重置——AMD 平台 GPU_VBIOS 已在 20_gpu 设置（SMC 固件一致性），
# 仅 NVIDIA detail map 非空时聚合覆盖；AMD 平台走 20_gpu 的值（此处 N/A 覆盖会误清）
GPU_VBIOS="${GPU_VBIOS:-N/A}"
if [ "${#GPU_VBIOS_MAP[@]}" -gt 0 ]; then
    _vbios_agg=$(for _k in "${!GPU_VBIOS_MAP[@]}"; do echo "${GPU_VBIOS_MAP[$_k]}"; done | sort | uniq -c | sort -rn)
    _vbios_uniq=$(printf '%s\n' "$_vbios_agg" | wc -l)
    if [ "$_vbios_uniq" -eq 1 ]; then
        GPU_VBIOS=$(printf '%s\n' "$_vbios_agg" | awk '{print $2}')
    else
        GPU_VBIOS="⚠️ 不一致（$(printf '%s\n' "$_vbios_agg" | awk '{printf "%s×%s ", $2, $1}' | sed 's/ $//')）"
    fi
fi
# 回退：无每卡 detail 日志（旧数据）时用 gpu_full 取第一个（gpu_full 已在环境段 load）
if [ "$GPU_VBIOS" = "N/A" ] && [ -f "${gpu_full}" ]; then
    GPU_VBIOS=$(grep -m1 "VBIOS Version" "${gpu_full}" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
    [ -z "$GPU_VBIOS" ] && GPU_VBIOS="N/A"
fi

# NVLink 链路（gpu_nvlink_status.log：每 GPU 链路数 + 速率 + 异常链路）
NV_LINK_SUMMARY="N/A"
load_manifest "${GPU_DIR}" gpu_nvlink_status "gpu_nvlink_status.log"
if [ -f "${gpu_nvlink_status}" ]; then
    NV_GPU_LINKS=$(grep -c "Link [0-9]" "${gpu_nvlink_status}" 2>/dev/null)
    NV_GPU_COUNT=$(grep -c "^GPU " "${gpu_nvlink_status}" 2>/dev/null)
    NV_LINK_RATE=$(grep -m1 "Link 0:" "${gpu_nvlink_status}" 2>/dev/null | awk '{print $(NF-1)" "$NF}')
    # 异常链路：速率明确为 0 / N/A / Down / Off（避免匹配 "200.0" 里的 0）
    NV_LINK_DOWN=$(grep -E "Link [0-9]+: *(0|N/A|Down|Off)( |$)" "${gpu_nvlink_status}" 2>/dev/null | wc -l)
    if [ "$NV_GPU_COUNT" -gt 0 ] 2>/dev/null; then
        # 每卡链路数 = 总链路/卡数（B300 每卡 18 条）；显示"卡数 × 每卡链路数 × 单链路速率"避免误读为整卡带宽
        NV_LINKS_PER_GPU=0
        if [ "$NV_GPU_COUNT" -gt 0 ] && [ "$NV_GPU_LINKS" -gt 0 ] 2>/dev/null; then
            NV_LINKS_PER_GPU=$((NV_GPU_LINKS / NV_GPU_COUNT))
        fi
        if [ "$NV_LINKS_PER_GPU" -gt 0 ]; then
            NV_LINK_SUMMARY="${NV_GPU_COUNT}卡 全互联 (${NV_LINKS_PER_GPU}条/卡 × ${NV_LINK_RATE})"
        else
            NV_LINK_SUMMARY="${NV_GPU_COUNT}卡 × ${NV_LINK_RATE}"
        fi
        [ "$NV_LINK_DOWN" -gt 0 ] && NV_LINK_SUMMARY="${NV_LINK_SUMMARY} ⚠️${NV_LINK_DOWN}链路异常"
    fi
fi

# NVSwitch（nvswitch_N.log：状态/温度/端口；只匹配数字索引，避免把 nvswitch_smi_status.log 混入）
NVS_DIR="${OUT}/nvswitch"
NVS_DETAILS=""
if ls ${NVS_DIR}/nvswitch_[0-9]*.log >/dev/null 2>&1; then
    for nf in ${NVS_DIR}/nvswitch_[0-9]*.log; do
        nidx=$(basename "$nf" | sed 's/nvswitch_//; s/\.log//')
        nstate=$(grep -m1 "Switch State" "$nf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
        ntemp=$(grep -m1 "Temperature" "$nf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ' | sed 's/C$//')
        nports=$(grep -m1 "Active Nvlink Ports" "$nf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
        ntotal=$(grep -m1 "Total Nvlink Ports" "$nf" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
        nstat="${nstate:-N/A}"
        [ "$nstat" != "Active" ] && [ "$nstat" != "N/A" ] && nstat="${nstat} ⚠️"
        NVS_DETAILS="${NVS_DETAILS}${nidx}|${nstat}|${ntemp:-N/A}°C|${nports:-N/A}/${ntotal:-N/A}"$'\n'
    done
fi
# B300/GB300 fallback：nvidia-smi nvswitch --status 输出（"Switch N:" 段 + NVSwitch State/Temperature/Link 行）
if [ -z "$NVS_DETAILS" ] && [ -f "${NVS_DIR}/nvswitch_smi_status.log" ]; then
    NVS_DETAILS=$(awk '
        /^Switch [0-9]+:/ { if(idx!="") flush(); idx=$2; gsub(/:/,"",idx); state=""; temp=""; pc=0 }
        idx!="" && /NVSwitch State/ { v=$0; sub(/.*:/,"",v); gsub(/ /,"",v); state=v }
        idx!="" && /NVSwitch Temperature/ { v=$0; sub(/.*:/,"",v); gsub(/ /,"",v); sub(/C.*/,"",v); temp=v }
        idx!="" && /Link [0-9]+ State/ { pt++; if($0 ~ /Active/) pc++ }
        function flush() {
            nstat=(state==""?"N/A":state)
            if(nstat!="Active" && nstat!="N/A") nstat=nstat" ⚠️"
            printf "%s|%s|%s°C|%s/%s\n", idx, nstat, (temp==""?"N/A":temp), pc+0, pt+0
        }
        END { if(idx!="") flush() }
    ' "${NVS_DIR}/nvswitch_smi_status.log" 2>/dev/null)
fi
