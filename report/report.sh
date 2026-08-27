#!/bin/bash
# =============================================================================
# HwScope — 报告生成器（薄入口）
# report/report.sh
# 用法: bash report/report.sh [output_dir] [--acceptance|--json|--md|--txt|--both] [--test-dir <path>] [--baseline <dir>] [--bmc-verify]
# 功能: 从采集日志提取关键信息，生成 .json + .md + .txt + .html 汇总报告与验收清单。
#       本文件是装配入口：解析参数后 source report/lib（辅助+规格库）+ report/sections
#       （数据解析）×9 + report/gen（生成器）×7 各部件执行。
#       v1.35.0 自 tools/report.sh 拆分（行为不变，仅文件组织变化）；v1.35.3 移除 tools/ 兼容 wrapper，统一本路径。
# 依赖: lib/common.sh（颜色/帮助）、lib/nvlink.sh（NVLink 解析库）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # 项目根（report/ 的上级）
REPORT_DIR="${SCRIPT_DIR}/report"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true   # v1.46.2：detect_gpu_vendors / classify_machine
source "${SCRIPT_DIR}/lib/nvlink.sh" 2>/dev/null || true

# ─── 参数解析（兼容: report.sh [dir] [--acceptance|--json|--md|--txt|--both] [--test-dir <path>] [--baseline <dir>] [--bmc-verify] [--fld-dir <dir>]） ───
OUT=""; FORMAT=""; TEST_DIR=""; BASELINE_DIR=""; FLD_DIR=""
BMC_VERIFY=0   # OS-BMC 一致性校验默认关闭（对比项/单侧数据判定仍在完善；需用时 --bmc-verify 开启）
while [ $# -gt 0 ]; do
    case "$1" in
        --json|--md|--txt|--both|--acceptance) FORMAT="$1"; shift ;;
        --bmc-verify) BMC_VERIFY=1; shift ;;
        --test-dir)
            TEST_DIR="$2"
            if [ -z "$TEST_DIR" ] || [ ! -d "$TEST_DIR" ]; then
                echo -e "${RED}[ERROR] --test-dir 需要有效压测目录路径（如 logs/test/20260818120000）${NC}"; exit 1
            fi
            shift 2 ;;
        --baseline)
            BASELINE_DIR="$2"
            if [ -z "$BASELINE_DIR" ] || [ ! -d "$BASELINE_DIR" ]; then
                echo -e "${RED}[ERROR] --baseline 需要有效历史采集目录路径${NC}"; exit 1
            fi
            shift 2 ;;
        --fld-dir)
            # DGX FLD 诊断日志目录（NVIDIA Field Diagnostic logs-<TS>/，run.log + summary.csv；v1.37.0）
            FLD_DIR="$2"
            if [ -z "$FLD_DIR" ] || [ ! -d "$FLD_DIR" ]; then
                echo -e "${RED}[ERROR] --fld-dir 需要有效 FLD 诊断日志目录（如 logs-20251026-145655）${NC}"; exit 1
            fi
            shift 2 ;;
        --*) echo -e "${YELLOW}[WARN] 未知参数: $1${NC}"; shift ;;
        *)  [ -z "$OUT" ] && OUT="$1"; shift ;;
    esac
done
if [ -z "$OUT" ]; then
    OUT=$(ls -dt "${SCRIPT_DIR}/output"/*/ 2>/dev/null | head -1 | sed 's|/$||')
fi
[ -z "$OUT" ] || [ ! -d "$OUT" ] && echo -e "${RED}[ERROR] 未找到采集目录: $OUT${NC}" && exit 1
[ -z "$FORMAT" ] && FORMAT="both"
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}[REPORT] 开始生成报告...${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}[REPORT] 解析目录: ${OUT}${NC}"

# ─── 装配：解析辅助 + 规格库 + 数据解析段 + 生成器 ───
# source 顺序 = 原 report.sh 行序（依赖链：变量解析依赖辅助函数；sections 间有先后依赖，
# 如 GPU_DIR 定义在 30_gpu 之前、GPU_DETAILS 依赖 gpu_spec 函数——勿调整顺序）
source "${REPORT_DIR}/lib/report_common.sh"
source "${REPORT_DIR}/lib/gpu_spec.sh"
for _s in 10_env_mb_cpu 20_gpu 30_storage_gpu_extra 40_network_bmc 50_nvlink_dcgm 60_nic_fan_temp 70_psu_raid_hba 80_fw_power_bmc_verify 90_test_baseline; do
    source "${REPORT_DIR}/sections/${_s}.sh"
done
unset _s
# 设备形态分类（v1.46.2）：读日志信号（chassis/ECC/BMC/GPU），零新采集
if command -v classify_machine >/dev/null 2>&1; then
    classify_machine "$OUT"
fi
for _g in gen_common gen_json gen_md gen_txt gen_html gen_acceptance gen_bmc_verify; do
    source "${REPORT_DIR}/gen/${_g}.sh"
done
unset _g

# ─── 按格式分发生成 ───
case "$FORMAT" in
    --json) gen_json ;;
    --md)   gen_md; gen_html ;;
    --txt)  gen_txt ;;
    --acceptance) gen_acceptance ;;
    *)      gen_json; gen_md; gen_txt; gen_html ;;
esac
[ "$BMC_VERIFY" -eq 1 ] && gen_bmc_verify

echo -e "${GREEN}[REPORT] 生成完成${NC}"
echo ""
