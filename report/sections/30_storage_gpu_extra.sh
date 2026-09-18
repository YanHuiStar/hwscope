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
                # Micron 型号规则: MTFDKBA480TFR / MTFDHBE960TFR / MTFDKCC960TGP → 数字=容量GB（T 是家族代号非 TB）
                # v1.48.34：TFR 后缀扩展为 T+家族字母（TGP 等系列——960TGP 曾落通用提取被当 960TB）
                if echo "$dmodel" | grep -qE 'MTFD[KHC][A-Z]{2}[0-9]{3,4}T[A-Z]{1,2}'; then
                    micap=$(echo "$dmodel" | grep -oE '[0-9]{3,4}T[A-Z]{1,2}' | head -1 | grep -oE '[0-9]+')
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

# ─── NVMe 错误日志汇总（v1.48.90；v1.48.96 按 status_field 分类）───
# nvme error-log 给出每次错误的类型/时间戳/LBA，是「这块盘曾经出过错」的直接证据——
# SMART 只给健康度百分比，看不出错误发生过没有。
#
# 为什么必须分类（v1.48.96）：初版只统计「非零 error_count」，把两类性质完全不同的
#   错误混为一谈，导致误报。实测 B300（B300-sample-a）：nvme0n1/nvme1n1 各 1~2 条
#   `0x6002 Invalid Field in Command`（opcode=0、lba=0xffffffffffffffff、parm_err_loc=0x28
#   ——**没有任何读写失败**，是主机侧发了固件不支持的管理命令，典型成因是 nvme-cli/libnvme
#   比盘固件新），却被渲染成「2 块盘有非零错误」，看着像盘要坏了。
#
# 分类依据 = status_field 低 12 位（`0x6` 是固定前缀，其后 3 位是 status code）：
#   尾部 `0x28x/0x282` 等 = status code type **介质/掉电/路径类** → 盘自身或供电问题 → 报 WARN
#   尾部 `0x00x`        = status code type **通用（命令）类** → 主机侧命令不兼容 → 仅提示
#   无法归类            = 保守按介质类处理（宁可报，不可漏）
NVME_ERR_MEDIA=0; NVME_ERR_SHUTDOWN=0; NVME_ERR_CMD=0
NVME_ERR_MEDIA_D=""; NVME_ERR_SHUTDOWN_D=""; NVME_ERR_CMD_D=""
for _ne in "${STO_DIR}"/nvme_error_*.log; do
    [ -f "$_ne" ] || continue
    _devname=$(basename "$_ne" | sed 's/^nvme_error_//; s/\.log$//')
    # 逐条 Entry 取 status_field 的括号描述（每块盘可能有多种错误）
    _sf=$(grep -oE "status_field[[:space:]]*:[[:space:]]*0x[0-9a-f]+\([^)]*\)" "$_ne" 2>/dev/null \
          | sed -E 's/.*0x([0-9a-f]+)\(([^)]*)\).*/\1|\2/')
    [ -z "$_sf" ] && continue
    _m=0; _s=0; _c=0
    while IFS='|' read -r _code _desc; do
        [ -z "$_code" ] && continue
        case "$_desc" in
            # 命令/参数不兼容（主机侧问题，非盘故障）
            *"Invalid Field in Command"*|*"Invalid Opcode"*|*"Invalid Namespace"*|*"Invalid Field"*|*"Invalid Command Opcode"*)
                _c=$((_c+1)) ;;
            # 非正常掉电（供电环境问题，非盘坏）
            *"Unsafe Shutdown"*)
                _s=$((_s+1)) ;;
            # 其余（Write Fault/Unrecovered Read/Data Protection/介质/路径…）保守按介质类
            *)
                _m=$((_m+1)) ;;
        esac
    done < <(printf '%s\n' "$_sf")
    [ "$_m" -gt 0 ] && { NVME_ERR_MEDIA=$((NVME_ERR_MEDIA+_m)); NVME_ERR_MEDIA_D="${NVME_ERR_MEDIA_D}${_devname}:${_m}条 "; }
    [ "$_s" -gt 0 ] && { NVME_ERR_SHUTDOWN=$((NVME_ERR_SHUTDOWN+_s)); NVME_ERR_SHUTDOWN_D="${NVME_ERR_SHUTDOWN_D}${_devname}:${_s}条 "; }
    [ "$_c" -gt 0 ] && { NVME_ERR_CMD=$((NVME_ERR_CMD+_c)); NVME_ERR_CMD_D="${NVME_ERR_CMD_D}${_devname}:${_c}条 "; }
done
# 纯命令类 = 全部错误都在命令类（无介质/掉电）→ 报告按「兼容性提示」呈现，不计 WARN
NVME_CMD_ONLY=0
[ "$NVME_ERR_CMD" -gt 0 ] && [ "$NVME_ERR_MEDIA" -eq 0 ] && [ "$NVME_ERR_SHUTDOWN" -eq 0 ] && NVME_CMD_ONLY=1

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
# ─── NVSwitch 域（Fabric）健康判定（v1.48.72）───
# 原实现解析 nvswitch_smi_status.log 的 "Switch N:" 段——该文件自 v1.48.61 起不再生成（nvidia-smi
# 无 nvswitch 子命令），解析分支长期空转，且会误读历史残留文件（22.84 目录里还留着 v1.48.58 的残留）。
# 改用实测有效的四份数据合成一句判定（22.84 真机格式实证）：
#   nvswitch_fabric_q.log      nvidia-smi -q → Fabric 段（State=In Progress/Completed、ClusterUUID）
#   nvlink_remote_info.log     nvidia-smi nvlink -R → 各链路对端（FFFFFFFF = NVSwitch 未枚举）
#   fabricmanager_service.log  systemctl status nvidia-fabricmanager（Active: active/inactive/failed）
#   nvlink_error_count.log     nvidia-smi nvlink -e → 逐链路错误计数
# 判定的价值：FM 未运行时 NVLink 对端不可见/ClusterUUID 未注册/DCGM 全 Fail 是同一根因的五种表现，
# 报告里合成一句即可指向"FM 没起来"而非"硬件坏了"。
NVSWITCH_FABRIC=""
_fq="${NVS_DIR}/nvswitch_fabric_q.log"
_nr="${NVS_DIR}/nvlink_remote_info.log"
_fms="${NVS_DIR}/fabricmanager_service.log"
_ne="${NVS_DIR}/nvlink_error_count.log"
if [ -f "$_fq" ] || [ -f "$_nr" ]; then
    _fmst=""
    [ -f "$_fms" ] && _fmst=$(grep -v "^#" "$_fms" 2>/dev/null | grep -m1 "Active:" | sed 's/.*Active: *//; s/[ (].*//' | tr -d '\r')
    _fstate=""
    [ -f "$_fq" ] && _fstate=$(grep -v "^#" "$_fq" 2>/dev/null | grep -A2 "^[[:space:]]*Fabric$" | grep -m1 "State" | sed 's/.*: *//; s/ *$//' | tr -d '\r')
    _uuid=""
    [ -f "$_fq" ] && _uuid=$(grep -v "^#" "$_fq" 2>/dev/null | grep -m1 "ClusterUUID" | sed 's/.*: *//' | tr -d ' \r')
    _pt=0; _pg=0
    if [ -f "$_nr" ]; then
        _pt=$(grep -c "Remote Device" "$_nr" 2>/dev/null || true)
        _pg=$(grep -c "Remote Device FFFFFFFF" "$_nr" 2>/dev/null || true)
    fi
    _nerr=0
    [ -f "$_ne" ] && _nerr=$(grep -v "^#" "$_ne" 2>/dev/null | grep -cE "Errors: [1-9]" || true)

    if [ "$_fmst" = "failed" ] || [ "$_fmst" = "inactive" ]; then
        _seg="⚠️ NVSwitch 域未建立：Fabric Manager 未运行（Active: ${_fmst}）"
        [ -n "$_fstate" ] && _seg="${_seg}；Fabric State=${_fstate}"
        [ -n "$_uuid" ] && _seg="${_seg}；ClusterUUID=${_uuid}"
        [ "${_pt:-0}" -gt 0 ] && _seg="${_seg}；NVLink 对端不可见 ${_pg}/${_pt} 条"
        NVSWITCH_FABRIC="${_seg}。FM 未拉起会使 DCGM 对 NVSwitch 域的诊断整体失败，非 GPU/NVSwitch 硬件故障——拉起 nvidia-fabricmanager 后重测（FM 版本须与驱动一致）"
    elif [ "$_fmst" = "active" ] && [ "${_pg:-0}" -gt 0 ]; then
        NVSWITCH_FABRIC="⚠️ Fabric Manager 运行中，但 ${_pg}/${_pt} 条 NVLink 对端不可见（FFFFFFFF）——核查 NVSwitch 供电/复位状态与 FM 版本匹配"
    elif [ "$_fmst" = "active" ] && [ "${_nerr:-0}" -gt 0 ]; then
        NVSWITCH_FABRIC="⚠️ NVLink 链路错误计数非零（${_nerr} 项，详见 nvlink_error_count.log）"
    fi
fi
