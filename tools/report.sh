#!/bin/bash
# =============================================================================
# HwScope — 报告生成器
# tools/report.sh
# 用法: bash tools/report.sh [output_dir] [--md|--json|--both]
# 功能: 从采集日志提取关键信息，生成 .md + .json 汇总报告
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

# ─── 定位输出目录 ───
if [ -n "$1" ] && [ -d "$1" ]; then
    OUT="$1"
else
    OUT=$(ls -dt "${SCRIPT_DIR}/output"/*/ 2>/dev/null | head -1 | sed 's|/$||')
fi
[ -z "$OUT" ] || [ ! -d "$OUT" ] && echo -e "${RED}[ERROR] 未找到采集目录: $OUT${NC}" && exit 1

FORMAT="${2:-both}"
echo -e "${CYAN}[REPORT] 解析目录: ${OUT}${NC}"

# ─── 提取辅助：从日志取字段（第一个匹配，去注释，保留冒号后全部） ───
extract() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { echo ""; return; }
    grep -iE "$pattern" "$file" 2>/dev/null | grep -v "^#" | head -1 | cut -d':' -f2- | tr -d ' \t' | head -c 200
}

# ─── 收集基础信息 ───
SUMMARY="${OUT}/summary.txt"
HOSTNAME=$(extract "Hostname" "$SUMMARY")
VERSION=$(extract "Version" "$SUMMARY")
PLATFORM=$(grep -m1 "^Platform" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
TIMESTAMP=$(grep -m1 "^Timestamp" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | sed 's/^ //')

# ─── 主板 ───
MB_DIR="${OUT}/motherboard"
MB_MANUFACTURER=$(extract "Manufacturer" "${MB_DIR}/dmidecode_system.log")
MB_PRODUCT=$(extract "Product Name" "${MB_DIR}/dmidecode_system.log")
MB_SN=$(extract "Serial Number" "${MB_DIR}/dmidecode_system.log")
BIOS_VERSION=$(extract "Version" "${MB_DIR}/dmidecode_bios.log" | head -c 80)

# ─── CPU ───
CPU_DIR="${OUT}/cpu"
CPU_MODEL=$(grep -m1 -iE "^model name" "${CPU_DIR}/cpu_summary.log" 2>/dev/null | cut -d':' -f2- | tr -d '\t' | head -c 100)
CPU_CORES=$(grep -m1 -iE "^cpu cores|^Core Count" "${CPU_DIR}/cpu_summary.log" 2>/dev/null | cut -d':' -f2-)
CPU_SOCKETS=$(grep "physical id" "${CPU_DIR}/proc_cpuinfo_full.log" 2>/dev/null | cut -d':' -f2- | sort -u | wc -l)

# ─── 内存 ───
MEM_DIR="${OUT}/memory"
MEM_TOTAL=$(grep -m1 "MemTotal" "${MEM_DIR}/proc_meminfo.log" 2>/dev/null | awk '{printf "%.1f GB", $2/1024/1024}')
MEM_SPEED=$(extract "Configured Clock Speed|Speed:" "${MEM_DIR}/dmidecode_memory_full.log")
MEM_SLOTS=$(grep -c "Memory Device" "${MEM_DIR}/dmidecode_memory_full.log" 2>/dev/null)

# ─── GPU（解析 inventory.csv） ───
GPU_CSV="${OUT}/gpu/gpu_inventory.csv"
GPU_COUNT=0; GPU_NAMES=""
if [ -f "$GPU_CSV" ]; then
    GPU_COUNT=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | wc -l)
    GPU_NAMES=$(grep -v "^#" "$GPU_CSV" | tail -n +2 | awk -F',' '{print $2}' | tr -d ' ' | sort -u | tr '\n' ',' | sed 's/,$//')
fi

# ─── 存储（从 block_devices_all.log 按 SIZE 列求和） ───
STO_DIR="${OUT}/storage"
STORAGE_COUNT=$(ls "${STO_DIR}"/smart_*.log 2>/dev/null | grep -v health | grep -v scsi | wc -l)
STORAGE_TOTAL=$(grep -v "^#" "${STO_DIR}/block_devices_all.log" 2>/dev/null | tail -n +2 | \
    awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[KMGTP]$/) {v=$i; break}; \
    n=substr(v,1,length(v)-1); u=substr(v,length(v)); \
    if(u=="T")s+=n*1024; else if(u=="G")s+=n; else if(u=="M")s+=n/1024; else if(u=="K")s+=n/1024/1024} \
    END{printf "%.0f GB", s}' 2>/dev/null)

# ─── 网络 ───
NET_DIR="${OUT}/network"
IB_COUNT=$(ls "${NET_DIR}"/mlxlink_mlx5_*.log 2>/dev/null | grep -v module | grep -v _m | wc -l)
IB_SPEED=$(extract "Active Speed|Rate:" "${NET_DIR}/ibstat.log")

# ─── BMC ───
BMC_DIR="${OUT}/bmc"
BMC_FRU=$(extract "Product Name" "${BMC_DIR}/ipmi_fru_summary.log" | head -c 80)

# ─── 生成 JSON ───
gen_json() {
    local f="${OUT}/hwscope_report.json"
    cat > "$f" << EOF
{
  "hwscope": {
    "version": "${VERSION:-unknown}",
    "hostname": "${HOSTNAME:-unknown}",
    "platform": "${PLATFORM:-unknown}",
    "timestamp": "${TIMESTAMP:-unknown}"
  },
  "motherboard": {
    "manufacturer": "${MB_MANUFACTURER:-N/A}",
    "product": "${MB_PRODUCT:-N/A}",
    "serial": "${MB_SN:-N/A}",
    "bios": "${BIOS_VERSION:-N/A}"
  },
  "cpu": {
    "model": "${CPU_MODEL:-N/A}",
    "cores": "${CPU_CORES:-N/A}",
    "sockets": "${CPU_SOCKETS:-N/A}"
  },
  "memory": {
    "total": "${MEM_TOTAL:-N/A}",
    "speed": "${MEM_SPEED:-N/A}",
    "slots": "${MEM_SLOTS:-N/A}"
  },
  "gpu": {
    "count": "${GPU_COUNT:-0}",
    "models": "${GPU_NAMES:-N/A}"
  },
  "storage": {
    "disk_count": "${STORAGE_COUNT:-0}",
    "total_capacity": "${STORAGE_TOTAL:-N/A}"
  },
  "network": {
    "ib_devices": "${IB_COUNT:-0}",
    "ib_speed": "${IB_SPEED:-N/A}"
  },
  "bmc": {
    "fru": "${BMC_FRU:-N/A}"
  }
}
EOF
    echo -e "${GREEN}[REPORT] JSON: ${f}${NC}"
}

# ─── 生成 Markdown ───
gen_md() {
    local f="${OUT}/hwscope_report.md"
    cat > "$f" << EOF
# HwScope 硬件巡检报告

**版本:** ${VERSION:-unknown} · **主机:** ${HOSTNAME:-unknown} · **平台:** ${PLATFORM:-unknown} · **时间:** ${TIMESTAMP:-unknown}

## 主板
| 项 | 值 |
|----|----|
| 制造商 | ${MB_MANUFACTURER:-N/A} |
| 型号 | ${MB_PRODUCT:-N/A} |
| SN | ${MB_SN:-N/A} |
| BIOS | ${BIOS_VERSION:-N/A} |

## CPU
| 项 | 值 |
|----|----|
| 型号 | ${CPU_MODEL:-N/A} |
| 核心数 | ${CPU_CORES:-N/A} |
| 插槽数 | ${CPU_SOCKETS:-N/A} |

## 内存
| 项 | 值 |
|----|----|
| 总量 | ${MEM_TOTAL:-N/A} |
| 速率 | ${MEM_SPEED:-N/A} |
| 插槽数 | ${MEM_SLOTS:-N/A} |

## GPU
| 项 | 值 |
|----|----|
| 数量 | ${GPU_COUNT:-0} |
| 型号 | ${GPU_NAMES:-N/A} |

## 存储
| 项 | 值 |
|----|----|
| 盘数 | ${STORAGE_COUNT:-0} |
| 总容量 | ${STORAGE_TOTAL:-N/A} |

## 网络
| 项 | 值 |
|----|----|
| IB 设备数 | ${IB_COUNT:-0} |
| IB 速率 | ${IB_SPEED:-N/A} |

## BMC
| 项 | 值 |
|----|----|
| 型号 | ${BMC_FRU:-N/A} |

---
*由 HwScope ${VERSION:-unknown} 自动生成*
EOF
    echo -e "${GREEN}[REPORT] MD: ${f}${NC}"
}

# ─── 生成 TXT（纯文本，cat/less 直接看） ───
gen_txt() {
    local f="${OUT}/hwscope_report.txt"
    cat > "$f" << EOF
============================================
HwScope 硬件巡检报告
============================================
版本: ${VERSION:-unknown}    主机: ${HOSTNAME:-unknown}
平台: ${PLATFORM:-unknown}   时间: ${TIMESTAMP:-unknown}

[主板]
  制造商 : ${MB_MANUFACTURER:-N/A}
  型号   : ${MB_PRODUCT:-N/A}
  SN     : ${MB_SN:-N/A}
  BIOS   : ${BIOS_VERSION:-N/A}

[CPU]
  型号   : ${CPU_MODEL:-N/A}
  核心数 : ${CPU_CORES:-N/A}
  插槽数 : ${CPU_SOCKETS:-N/A}

[内存]
  总量   : ${MEM_TOTAL:-N/A}
  速率   : ${MEM_SPEED:-N/A}
  插槽数 : ${MEM_SLOTS:-N/A}

[GPU]
  数量   : ${GPU_COUNT:-0}
  型号   : ${GPU_NAMES:-N/A}

[存储]
  盘数   : ${STORAGE_COUNT:-0}
  总容量 : ${STORAGE_TOTAL:-N/A}

[网络]
  IB设备 : ${IB_COUNT:-0}
  IB速率 : ${IB_SPEED:-N/A}

[BMC]
  型号   : ${BMC_FRU:-N/A}

--------------------------------------------
由 HwScope ${VERSION:-unknown} 自动生成
EOF
    echo -e "${GREEN}[REPORT] TXT: ${f}${NC}"
}

case "$FORMAT" in
    --json) gen_json ;;
    --md)   gen_md ;;
    --txt)  gen_txt ;;
    *)      gen_json; gen_md; gen_txt ;;
esac
