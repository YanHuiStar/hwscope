#!/bin/bash
# =============================================================================
# 模块: 04_gpu.sh — GPU 信息采集
# 输出目录: <OUTPUT_DIR>/gpu/
# =============================================================================

MODULE_NAME="GPU"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_gpu() {
    local output_dir="$1"
    local dir="${output_dir}/gpu"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # ─── GPU 平台检测（v1.46.1）：lspci 3D controller 厂商判定——决定采集路径 ───
    #   nvidia-smi 存在 → NVIDIA 路径；无 nvidia-smi 但 rocm-smi/amd-smi → AMD(ROCm) 路径；
    #   有 GPU 但工具全无 → 落盘 PCI 提示（报告显示"驱动未装"，不误报无 GPU）
    local gpu_pci_present=0 gpu_pci_vendor=""
    if check_cmd lspci; then
        gpu_pci_present=$(lspci 2>/dev/null | grep -cE "3D controller")
        gpu_pci_vendor=$(lspci 2>/dev/null | grep -m1 "3D controller" | sed 's/.*3D controller: //' | awk '{print $1}')
    fi

    if ! check_cmd nvidia-smi; then
        if [ "$gpu_pci_present" -gt 0 ] 2>/dev/null; then
            if check_cmd rocm-smi || check_cmd amd-smi; then
                run_amd_gpu "$dir"
                module_end "$MODULE_NAME"
                return 0
            fi
            # 有 GPU 但 NVIDIA/AMD 工具都无 → 落盘 PCI 提示（供报告"驱动未装"展示）
            echo "# GPU PCI detected but no vendor tool (nvidia-smi/rocm-smi/amd-smi)" > "${dir}/gpu_pci_only.log"
            echo "# Vendor line: $(lspci 2>/dev/null | grep -m1 '3D controller')" >> "${dir}/gpu_pci_only.log"
            echo -e "${YELLOW}[WARN] 检测到 ${gpu_pci_present} 个 GPU（${gpu_pci_vendor:-未知}）但 nvidia-smi/rocm-smi 均未安装——仅记录 PCI 存在性${NC}"
        else
            echo -e "${YELLOW}[SKIP] 无 GPU（无 3D controller 设备），跳过 GPU 模块${NC}"
        fi
        module_end "$MODULE_NAME"
        return 0
    fi

    # Phase 1: 串行获取 GPU 数量（后续命令依赖此值）
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)

    # Phase 2: 构建并行任务数组
    local gpu_jobs=()
    # 每 GPU 的 detail + ECC
    for ((i=0; i<gpu_count; i++)); do
        gpu_jobs+=("nvidia-smi -i $i -q" "${dir}/gpu_${i}_detail.log")
        gpu_jobs+=("nvidia-smi -i $i -q -d ECC" "${dir}/gpu_${i}_ecc.log")
    done
    # 独立命令（不分设备）
    gpu_jobs+=(
        "nvidia-smi -q"                                                              "${dir}/gpu_full.log"
        "nvidia-smi --query-gpu=index,name,serial,pci.bus_id,gpu_uuid,memory.total,memory.used,power.limit,power.draw,temperature.gpu,utilization.gpu,clocks.current.graphics,clocks.current.memory,ecc.mode.current,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv" "${dir}/gpu_inventory.csv"
        "nvidia-smi nvlink --status"                                                  "${dir}/gpu_nvlink_status.log"
        "nvidia-smi nvlink --capabilities"                                            "${dir}/gpu_nvlink_cap.log"
        "nvidia-smi -q -d ECC"                                                        "${dir}/gpu_ecc_full.log"
        "nvidia-smi --query-gpu=index,name,ecc.mode.current,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total --format=csv" "${dir}/gpu_ecc_inventory.csv"
        "nvidia-smi pmon -c 1"                                                        "${dir}/gpu_pmon.log"
        "nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_bus_id --format=csv" "${dir}/gpu_processes.csv"
        "nvidia-smi --query-gpu=driver_version --format=csv"                          "${dir}/gpu_driver_version.log"
        "nvidia-smi topo -m"                                                          "${dir}/gpu_topo.log"
        "nvidia-smi --query-remapped-rows=remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure --format=csv" "${dir}/gpu_remapped_rows.csv"
    )

    run_and_log_parallel 8 "${gpu_jobs[@]}"
    local parallel_ret=$?
    # gpu_topo_nic.log 与 gpu_topo.log 同命令（v1.26.27 起新版 topo -m 已含 NIC 列），
    # 并行采集完成后复制（须在 run_and_log_parallel 之后：此时 gpu_topo.log 已生成）
    cp "${dir}/gpu_topo.log" "${dir}/gpu_topo_nic.log" 2>/dev/null || true
    if [ "$parallel_ret" -ne 0 ]; then
        echo -e "${YELLOW}[WARN] GPU 采集部分失败，请检查 nvidia-smi 可用性及日志文件${NC}" >&2
    fi 

# NOTE: gpu_N_detail.log and gpu_N_ecc.log are generated per GPU (N=0,1,...)
    write_manifest "${dir}/manifest.txt" \
        "gpu_full" "gpu_full.log" \
        "gpu_inventory" "gpu_inventory.csv" \
        "gpu_nvlink_status" "gpu_nvlink_status.log" \
        "gpu_nvlink_cap" "gpu_nvlink_cap.log" \
        "gpu_ecc_full" "gpu_ecc_full.log" \
        "gpu_ecc_inventory" "gpu_ecc_inventory.csv" \
        "gpu_pmon" "gpu_pmon.log" \
        "gpu_processes" "gpu_processes.csv" \
        "gpu_driver_version" "gpu_driver_version.log" \
        "gpu_topo" "gpu_topo.log" \
        "gpu_topo_nic" "gpu_topo_nic.log" \
        "gpu_remapped_rows" "gpu_remapped_rows.csv"

    module_end "$MODULE_NAME"
}

# ─── AMD GPU 采集（v1.46.1，ROCm 生态）───
# rocm-smi（旧）/ amd-smi（ROCm 7+ 新）对标 nvidia-smi；rocminfo 对标 nvidia-smi -q（型号/gfx 架构）
# 全量落盘 + 清单提取（v1.41.1 全量原则）；report 端按厂商解析
run_amd_gpu() {
    local dir="$1"
    local amd_smi_cmd=""
    if check_cmd amd-smi; then
        amd_smi_cmd="amd-smi"
    elif check_cmd rocm-smi; then
        amd_smi_cmd="rocm-smi"
    else
        echo -e "${YELLOW}[SKIP] AMD GPU 已检测但 rocm-smi/amd-smi 均未安装（无 ROCm 环境）${NC}"
        echo "# AMD GPU detected but no ROCm tool" > "${dir}/gpu_amd_pci_only.log"
        module_end "$MODULE_NAME"
        return 0
    fi

    echo -e "${CYAN}[INFO] 检测到 AMD GPU（${amd_smi_cmd}），走 ROCm 采集路径${NC}"

    # 全量落盘（并行）
    local amd_jobs=()
    amd_jobs+=(
        "${amd_smi_cmd} --showallinfo --json"        "${dir}/gpu_amd_full.log"
        "${amd_smi_cmd} --showproductname --showuniqueid --showmeminfo vram --showtemp --showpower --showuse --showclocks --showpids --json" "${dir}/gpu_amd_inventory.json"
        "${amd_smi_cmd} --showmeminfo all --json"    "${dir}/gpu_amd_meminfo.log"
        "${amd_smi_cmd} --showtemp --json"           "${dir}/gpu_amd_temp.log"
        "${amd_smi_cmd} --showpower --json"          "${dir}/gpu_amd_power.log"
        "${amd_smi_cmd} --showuse --json"            "${dir}/gpu_amd_use.log"
        "${amd_smi_cmd} --showclocks --json"         "${dir}/gpu_amd_clocks.log"
        "${amd_smi_cmd} --showfwinfo --json"         "${dir}/gpu_amd_fw.log"
        "${amd_smi_cmd} --showrasinfo --json"        "${dir}/gpu_amd_ras.log"
    )
    # rocminfo 型号/架构（对标 nvidia-smi -q）
    if check_cmd rocminfo; then
        amd_jobs+=("rocminfo" "${dir}/gpu_amd_rocminfo.log")
    fi
    run_and_log_parallel 6 "${amd_jobs[@]}"

    # 每卡明细（按卡数循环）
    local amd_count
    amd_count=$("${amd_smi_cmd}" --showuniqueid --json 2>/dev/null | grep -c "unique_id\|uniqueid" || true)
    [ "$amd_count" -lt 1 ] 2>/dev/null && amd_count=0
    local _ai=0
    while [ "$_ai" -lt "$amd_count" ]; do
        run_and_log "${amd_smi_cmd} -d $_ai --showallinfo --json" "${dir}/gpu_amd_${_ai}_detail.json"
        _ai=$((_ai + 1))
    done

    write_manifest "${dir}/manifest.txt" \
        "gpu_amd_full" "gpu_amd_full.log" \
        "gpu_amd_inventory" "gpu_amd_inventory.json" \
        "gpu_amd_rocminfo" "gpu_amd_rocminfo.log" \
        "gpu_amd_ras" "gpu_amd_ras.log" \
        "gpu_amd_pci_only" "gpu_amd_pci_only.log"
}

# 允许单独执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_gpu "$1"
fi
