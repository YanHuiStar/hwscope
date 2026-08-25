#!/bin/bash
# =============================================================================
# HwScope - 变量解析：环境/OS + 主板 + CPU + 内存
# report/sections/10_env_mb_cpu.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# ─── 环境（OS/内核/驱动/CUDA） ───
OS_DIR="${OUT}/os"
load_manifest "${OS_DIR}" os_release "os-release.log"
load_manifest "${OS_DIR}" os_uname "uname.log"
OS_NAME=$(grep -m1 "PRETTY_NAME" "${os_release}" 2>/dev/null | cut -d'"' -f2)
KERNEL=$(grep -m1 -v "^#" "${os_uname}" 2>/dev/null | awk '{print $3}')
GPU_DIR="${OUT}/gpu"
load_manifest "${GPU_DIR}" gpu_full "gpu_full.log"
# PCIe 拓扑（lspci 直读型号用，走 manifest 解耦）
PCIE_DIR="${OUT}/pcie"
load_manifest "${PCIE_DIR}" lspci_all "lspci_all.log"
# PCIe Fabric Switch（PEX89xxx/PEX97xxx/Switchtec）：提取无条件（JSON 字段需要原始检测值）；
# MD/TXT 展示仅在无 GPU 时（有 GPU 的一体化/SXM 主机主板也带 PEX89，单独展示会误导为"机头"）
FABRIC_SW=""
if [ -f "${lspci_all}" ]; then
    FABRIC_SW=$(grep -v "^#" "${lspci_all}" 2>/dev/null | grep -oiE "PEX89[0-9xX]*|PEX97[0-9xX]*|Switchtec [A-Za-z0-9]+" | sort -u | tr '\n' ',' | sed 's/,$//')
fi

# ─── PCIe 拓扑与链路（v1.41.0：交付验收看 PEX 枚举 + 关键链路满速/降速）───
load_manifest "${PCIE_DIR}" pcie_full "pcie_full.log"
load_manifest "${PCIE_DIR}" pcie_speed_width "pcie_speed_width.log"
# PEX Fabric Switch 汇总（型号 × 数量——lspci 每个 switch 端口都是独立 bridge 设备，
# 明细行会爆炸；交付核对看"有哪些 switch、共多少端口"）
PCIE_PEX_DETAILS=""
if [ -f "${lspci_all}" ]; then
    PCIE_PEX_DETAILS=$(grep -v "^#" "${lspci_all}" 2>/dev/null | grep -oiE "PEX89[0-9xX]*|PEX97[0-9xX]*|Switchtec [A-Za-z0-9]+" | sort | uniq -c | awk '{printf "%s ×%d; ", $2, $1}' | sed 's/; $//')
fi
# 降速/降宽检测（pcie_full.log 按设备块解析 LnkCap vs LnkSta；排除空闲 Gen1 x16——PEX 下行未接模组/板卡的特征）
# v1.44.0 表格化：全量有效链路三态判定（降速/管理芯片/满速）；排序 = 管理芯片排后（非 0 列升序） + BDF 升序
PCIE_SLOW_LINKS=""
PCIE_LINKS_TOTAL=0
PCIE_LINK_TABLE=""       # 全量链路行：BDF|设备|LnkCap|LnkSta|判定（排序 = 管理芯片排后 + BDF 升序）
PCIE_SLOW_COUNT=0
PCIE_MGMT_COUNT=0
if [ -f "${pcie_full}" ]; then
    PCIE_LINK_TABLE=$(awk '
        /^[0-9a-f]{2}:/ { if (b != "") check(); b=$1; d=substr($0,index($0,$2)); c=""; s="" }
        /LnkCap:/ { c=$0 }
        /LnkSta:/ { s=$0 }
        END { if (b != "") check() }
        function spd(x,   t) { t=x; sub(/.*Speed /,"",t); sub(/GT\/s.*/,"",t); gsub(/ /,"",t); return t+0 }
        function wdt(x,   t) { t=x; sub(/.*Width /,"",t); sub(/,.*/,"",t); gsub(/[^0-9]/,"",t); return t+0 }
        function gname(x) { if (x >= 31.9) return "Gen5"; if (x >= 15.9) return "Gen4"; if (x >= 7.9) return "Gen3"; if (x >= 4.9) return "Gen2"; return "Gen1" }
        function fmt(w, s) { return "x" w " " gname(s) }
        function check(   csp,cwd,ssp,swd,mgmt,verdict) {
            if (c == "" || s == "") return
            csp=spd(c); cwd=wdt(c); ssp=spd(s); swd=wdt(s)
            if (swd == 0) return            # x0 = 端口未连接（PEX 下行空置）
            if (ssp == 5 && swd == 16) return   # 空闲 Gen1 x16 = PEX 下行未接模组/板卡
            total++
            mgmt = (d ~ /ASPEED|AST[0-9]+|Matrox|VGA compatible|Display controller/) ? 1 : 0
            if (mgmt) {
                verdict = "管理芯片固有"
            } else if (ssp < csp || swd < cwd) {
                verdict = (swd < cwd && ssp < csp) ? "⚠️ 降宽+降速" : ((swd < cwd) ? "⚠️ 降宽" : "⚠️ 降速")
            } else {
                verdict = "✓ 满速"
            }
            printf "%d|%s|%s|%s|%s|%s\n", mgmt, b, substr(d,1,58), fmt(cwd,csp), fmt(swd,ssp), verdict
        }
    ' "${pcie_full}" 2>/dev/null | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2-)
    if [ -n "$PCIE_LINK_TABLE" ]; then
        PCIE_LINKS_TOTAL=$(printf '%s\n' "$PCIE_LINK_TABLE" | grep -c '|')
        PCIE_SLOW_COUNT=$(printf '%s\n' "$PCIE_LINK_TABLE" | grep -c '⚠️')
        PCIE_MGMT_COUNT=$(printf '%s\n' "$PCIE_LINK_TABLE" | grep -c '管理芯片')
        PCIE_SLOW_LINKS=$(printf '%s\n' "$PCIE_LINK_TABLE" | awk -F'|' '$5 ~ /⚠️/ {print $1" "$2" | cap "$3", sta "$4}')
    fi
# 旧采集无 pcie_full：pcie_speed_width.log 是 grep 行流（缺 LnkCap 的设备导致 cap/sta 错配，
# 未连接端口 x0），配对不可靠——不判降速，验收项判 N/A 不计数（v1.41.0 实测教训）
else
    PCIE_LINK_TABLE=""
    PCIE_LINKS_TOTAL=0
fi
if [ -n "$PCIE_SLOW_LINKS" ]; then PCIE_LINKS_OK=0; else PCIE_LINKS_OK=1; fi
GPU_DRIVER=$(grep -m1 "Driver Version" "${gpu_full}" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
GPU_CUDA=$(grep -m1 "CUDA Version" "${gpu_full}" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')

# ─── 主板 ───
MB_DIR="${OUT}/motherboard"
load_manifest "${MB_DIR}" dmidecode_system "dmidecode_system.log"
load_manifest "${MB_DIR}" dmidecode_bios "dmidecode_bios.log"
load_manifest "${MB_DIR}" dmidecode_chassis "dmidecode_chassis.log"
load_manifest "${MB_DIR}" baseboard_summary "baseboard_summary.log"
MB_MANUFACTURER=$(extract "Manufacturer" "${dmidecode_system}")
MB_PRODUCT=$(extract "Product Name" "${dmidecode_system}")
MB_SN=$(extract "Serial Number" "${dmidecode_system}")
# 主板独立 SN（Base Board 与整机 System SN 是不同物理组件序列号，华硕 B300 实测三者各异）
MB_BOARD_SN=$(extract "Serial Number" "${baseboard_summary}")
BIOS_VERSION=$(extract "Version" "${dmidecode_bios}" | head -c 80)
CHASSIS_SN=$(extract "Serial Number" "${dmidecode_chassis}")

# ─── CPU ───
CPU_DIR="${OUT}/cpu"
load_manifest "${CPU_DIR}" cpu_summary "cpu_summary.log"
load_manifest "${CPU_DIR}" proc_cpuinfo_full "proc_cpuinfo_full.log"
load_manifest "${CPU_DIR}" cpu_stepping "cpu_stepping.log"
load_manifest "${CPU_DIR}" lscpu "lscpu.log"
load_manifest "${CPU_DIR}" dmidecode_processor "dmidecode_processor.log"
CPU_MODEL=$(grep -m1 -iE "^model name" "${cpu_summary}" 2>/dev/null | cut -d':' -f2- | tr -d '\t' | sed 's/^ *//' | head -c 100)
CPU_CORES=$(grep -m1 -iE "^cpu cores|^Core Count" "${cpu_summary}" 2>/dev/null | cut -d':' -f2- | tr -d ' \t')
CPU_SOCKETS=$(grep "physical id" "${proc_cpuinfo_full}" 2>/dev/null | cut -d':' -f2- | sort -u | wc -l)
# 总核心数 = 每颗核心数 × 路数（如 48×2=96），与"每颗核心数"区分展示
CPU_TOTAL_CORES=""
if [ -n "$CPU_CORES" ] && [ "${CPU_SOCKETS:-0}" -gt 0 ] 2>/dev/null; then
    CPU_TOTAL_CORES=$((CPU_CORES * CPU_SOCKETS))
fi
CPU_STEPPING=$(grep -m1 "^Stepping" "${cpu_stepping}" 2>/dev/null | awk '{print $2}')
[ -z "$CPU_STEPPING" ] && CPU_STEPPING=$(grep -m1 "Stepping:" "${lscpu}" 2>/dev/null | awk '{print $2}')
CPU_MAX_SPEED=$(grep -m1 "Max Speed" "${dmidecode_processor}" 2>/dev/null | awk '{print $(NF-1)}')
# "Max Speed: Unknown" 会取到 "Speed:"——非数字置空走 lscpu 回退
echo "$CPU_MAX_SPEED" | grep -qE "^[0-9]+$" || CPU_MAX_SPEED=""
[ -z "$CPU_MAX_SPEED" ] && CPU_MAX_SPEED=$(grep -m1 "CPU max MHz" "${lscpu}" 2>/dev/null | awk '{print $NF}')
CPU_CUR_SPEED=$(grep -m1 "Current Speed" "${dmidecode_processor}" 2>/dev/null | awk '{print $(NF-1)}')
echo "$CPU_CUR_SPEED" | grep -qE "^[0-9]+$" || CPU_CUR_SPEED=""
[ -z "$CPU_CUR_SPEED" ] && CPU_CUR_SPEED=$(grep -m1 "CPU MHz" "${lscpu}" 2>/dev/null | awk '{print $NF}')

# CPU 每颗明细（从 dmidecode_processor.log 按 Processor Information 块解析）
# SN 列：有真实 SN 才显示（Not Specified/空 → 空标记，报告端不展示该列）
CPU_DETAILS=""
if [ -f "${dmidecode_processor}" ]; then
    CPU_DETAILS=$(awk '/^Processor Information/{
        socket=""; model=""; cores=""; threads=""; maxspd=""; curspd=""; step=""; sn=""
        while((getline line) > 0) {
            if(line ~ /^$/) break
            if(line ~ /Handle 0x/) break
            if(line ~ /Socket Designation:/) {sub(/.*: /,"",line); socket=line}
            if(line ~ /Version:/) {sub(/.*: /,"",line); model=line}
            if(line ~ /Core Count:/) {sub(/.*: /,"",line); cores=line}
            if(line ~ /Thread Count:/) {sub(/.*: /,"",line); threads=line}
            if(line ~ /Max Speed:/) {sub(/.*: /,"",line); maxspd=line}
            if(line ~ /Current Speed:/) {sub(/.*: /,"",line); curspd=line}
            if(line ~ /Stepping:/) {sub(/.*: /,"",line); step=line}
            if(line ~ /Serial Number:/) {sub(/.*: /,"",line); sn=line}
            # 有的平台 Stepping 在 Signature 行内（如 "Signature: Type 0, Family 6, Model 173, Stepping 1"）
            if(line ~ /Signature:.*Stepping/) {match(line, /Stepping [0-9]+/); step=substr(line, RSTART+9, RLENGTH-9)}
        }
        # SN 为 Not Specified/UNKNOWN/空 → 置空（报告端不显示）；仅保留真实 SN
        if(sn ~ /Not Specified|UNKNOWN|Unknown/) sn=""
        if(socket!="") print socket"|"model"|"cores"|"threads"|"maxspd"|"curspd"|"step"|"sn
    }' "${dmidecode_processor}" 2>/dev/null)
fi

# ─── 内存 ───
MEM_DIR="${OUT}/memory"
load_manifest "${MEM_DIR}" proc_meminfo "proc_meminfo.log"
load_manifest "${MEM_DIR}" dmidecode_memory_full "dmidecode_memory_full.log"
MEM_TOTAL=$(grep -m1 "MemTotal" "${proc_meminfo}" 2>/dev/null | awk '{printf "%.1f GiB", $2/1024/1024}')
# 速率：优先取实际运行速率（Configured Memory Speed），fallback 额定 Speed
MEM_SPEED=$(extract "Configured Memory Speed" "${dmidecode_memory_full}")
[ -z "$MEM_SPEED" ] && MEM_SPEED=$(extract "^[[:space:]]*Speed:" "${dmidecode_memory_full}")
MEM_SPEED_NOTE=""
# 降速检测：额定 Speed 与运行速率不一致时提示（如 6400 额定 / 5200 实际）
# 插满降速是 DDR5 物理必然（信号负载/散热），不算故障；未插满仍降速才需关注
# 正文保留提示（信息价值），验收清单判定时再结合插满状态区分
MEM_NOM=$(extract "^[[:space:]]*Speed:" "${dmidecode_memory_full}")
if [ -n "$MEM_SPEED" ] && [ -n "$MEM_NOM" ] && [ "$MEM_SPEED" != "$MEM_NOM" ] 2>/dev/null; then
    MEM_SPEED_NOTE="⚠️ 降速运行（额定 ${MEM_NOM}）"
fi
# 插槽数：锚定 "Memory Device" 段头（子串匹配会命中 type20 "Memory Device Mapped Address"，插槽数恒为总槽+已插 → MEM_FULL 恒 0 误判 WARN）
MEM_SLOTS=$(grep -cE "^[[:space:]]*Memory Device$" "${dmidecode_memory_full}" 2>/dev/null)
MEM_POPULATED=$(grep -cE "^[[:space:]]*Size: [0-9]" "${dmidecode_memory_full}" 2>/dev/null)
# 插满状态标记（验收清单用：插满降速=正常，不算 WARN）
MEM_FULL=0
[ "${MEM_POPULATED:-0}" -ge "${MEM_SLOTS:-0}" ] 2>/dev/null && [ "${MEM_SLOTS:-0}" -gt 0 ] && MEM_FULL=1
# 每槽 DIMM 明细（插槽|容量|厂商|SN|部件号|原速率|现速率|Rank），空槽跳过
# 行模式状态机：从 "Memory Device" 段头开始，空行结束（Size 行在 Locator 之前）
# 速率语义：Speed=模块额定（原速率），Configured Memory Speed=当前实际运行（现速率）
MEM_DIMMS=""
if [ -f "${dmidecode_memory_full}" ]; then
    MEM_DIMMS=$(awk '
        /^Memory Device/ { in_dimm=1; slot=""; size=""; mfr=""; sn=""; pn=""; nom=""; cur=""; rank=""; next }
        in_dimm && /^[[:space:]]*Locator:/ && !/Bank Locator/ {slot=$0;  sub(/^[[:space:]]*Locator:[[:space:]]*/,"",slot); next}
        in_dimm && /^[[:space:]]*Size:/              {size=$0; sub(/^[[:space:]]*Size:[[:space:]]*/,"",size); sub(/ No Module.*/,"",size); next}
        in_dimm && /^[[:space:]]*Manufacturer:/      {mfr=$0;  sub(/^[[:space:]]*Manufacturer:[[:space:]]*/,"",mfr); next}
        in_dimm && /^[[:space:]]*Serial Number:/     {sn=$0;   sub(/^[[:space:]]*Serial Number:[[:space:]]*/,"",sn); next}
        in_dimm && /^[[:space:]]*Part Number:/       {pn=$0;   sub(/^[[:space:]]*Part Number:[[:space:]]*/,"",pn); sub(/[[:space:]]+$/,"",pn); next}
        in_dimm && /^[[:space:]]*Speed:/             {nom=$0;  sub(/^[[:space:]]*Speed:[[:space:]]*/,"",nom); next}
        in_dimm && /^[[:space:]]*Configured Memory Speed:/ {cur=$0; sub(/^[[:space:]]*Configured Memory Speed:[[:space:]]*/,"",cur); next}
        in_dimm && /^[[:space:]]*Rank:/              {rank=$0; sub(/^[[:space:]]*Rank:[[:space:]]*/,"",rank); next}
        in_dimm && /^[[:space:]]*$/ { if(size!="") printf "%s|%s|%s|%s|%s|%s|%s|%s\n", slot, size, mfr, sn, pn, nom, cur, rank; in_dimm=0 }
    ' "${dmidecode_memory_full}" 2>/dev/null)
fi
# 物理额定总量（每槽 Size 求和，64GB×32=2048GB）——与系统可见(MEM_TOTAL)区分，需在 MEM_DIMMS 之后计算
MEM_TOTAL_PHYS=""
if [ -n "$MEM_DIMMS" ]; then
    MEM_TOTAL_PHYS=$(echo "$MEM_DIMMS" | awk -F'|' '{gsub(/[^0-9.]/,"",$2); if($2+0>0) sum+=$2} END{if(sum>0) printf "%.0fGB", sum; else print ""}')
fi
# 内存类型（DDR4/DDR5）与 ECC 类型（Single-bit ECC 等；供日志展示，报告不输出 ECC）
MEM_TYPE=$(grep -m1 "^[[:space:]]*Type: DDR" "${dmidecode_memory_full}" 2>/dev/null | awk '{print $2}')
MEM_ECC_TYPE=$(grep -m1 "Error Correction Type" "${dmidecode_memory_full}" 2>/dev/null | cut -d: -f2- | xargs)
# EDAC 错误计数（日志展示用；报告不输出）
MEM_EDAC="N/A"
load_manifest "${MEM_DIR}" edac_errors "edac_errors.log"
if [ -f "${edac_errors}" ]; then
    MEM_EDAC=$(grep -E "CE_count|UE_count" "${edac_errors}" 2>/dev/null | grep -vE "N/A|^#" | awk -F': ' '{sum[$1]+=$2} END{if(NR>0) printf "CE:%d UE:%d", sum["CE_count"], sum["UE_count"]; else print "0/0"}')
fi
