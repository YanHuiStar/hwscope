#!/bin/bash
# =============================================================================
# HwScope — NVLink 解析库
# lib/nvlink.sh
# 纯解析逻辑，不执行任何命令；输入为 nvidia-smi 输出文本
# 调用方: tools/nvlink_verify.sh (实时) / tools/report.sh (读采集日志)
# =============================================================================

# 解析 topo -m 拓扑矩阵，输出 GPU→GPU 降级链路（非 NVLink 连接）
# 每行格式: "GPU0 -> GPU4: PIX (非 NVLink)"
# 正常互联(NV18/NV12 等 NV 前缀)不输出；GPU→NIC 的 PIX/NODE/SYS 不输出（正常 PCIe）
nvlink_parse_topo() {
    local topo_text="$1"
    echo "$topo_text" | awk '
        # 跳过注释行
        /^#/ { next }
        # 表头行：\tGPU0\tGPU1\t...
        /^\t*GPU[0-9]+/ && !hdr {
            gpu_count = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^GPU[0-9]+$/) {
                    gpu_count++
                    col[i] = $i
                }
            }
            hdr = 1
            next
        }
        # GPU 数据行
        $1 ~ /^GPU[0-9]+/ {
            src = $1
            # 只检查 GPU→GPU 列（前 gpu_count+1 列，跳过第一列 src）
            for (i = 2; i <= gpu_count+1; i++) {
                v = $i
                if (v == "X" || v ~ /^NV[0-9]+$/) continue
                dst = (i in col) ? col[i] : ("COL" i)
                print src " -> " dst ": " v " (非 NVLink)"
            }
        }
    '
}

# 解析 nvlink --status：输出 CRC 错误非零的链路行
nvlink_parse_crc() {
    echo "$1" | grep -iE "CRC errors" | grep -vE "CRC errors *: *0$"
}

# 解析 nvlink --status：输出 down/degraded 的链路行（全量不截断，展示截取交报告端）
nvlink_parse_down() {
    echo "$1" | grep -iE "is down|degraded"
}

# 从采集目录加载 NVLink 状态（供 report.sh 调用）
# 读取 gpu/gpu_topo.log + gpu/gpu_nvlink_status.log，设置全局变量:
#   NVLINK_DEGRADED  降级链路列表（非 NVLink 路径）
#   NVLINK_CRC       CRC 错误非零行
#   NVLINK_DOWN      down/degraded 链路
nvlink_load_from_logs() {
    local gpu_dir="$1"
    NVLINK_DEGRADED=""; NVLINK_CRC=""; NVLINK_DOWN=""
    NVLINK_DATA=0   # 是否有 NVLink 采集数据（0=无数据，判定用 N/A 而非 OK）

    local topo_file="${gpu_dir}/gpu_topo.log"
    local status_file="${gpu_dir}/gpu_nvlink_status.log"

    # NVLINK_DATA 判定需内容有效：文件存在但内容为采集报错（如 "-n" 语法错）时不算有数据
    if [ -f "$topo_file" ] && grep -v "^#" "$topo_file" 2>/dev/null | grep -qE "^GPU[0-9]+"; then
        NVLINK_DEGRADED=$(nvlink_parse_topo "$(cat "$topo_file")")
        NVLINK_DATA=1
    fi

    if [ -f "$status_file" ]; then
        local st
        st=$(cat "$status_file")
        # status 文件有有效内容（含 Link 行或 CRC 行）才算有数据
        if echo "$st" | grep -qE "GPU [0-9]|Link [0-9]|CRC errors"; then
            NVLINK_CRC=$(nvlink_parse_crc "$st")
            NVLINK_DOWN=$(nvlink_parse_down "$st")
            NVLINK_DATA=1
        fi
    fi
}

# 综合结论: 0=健康 1=存在问题
nvlink_is_healthy() {
    if [ -n "$NVLINK_DEGRADED" ] || [ -n "$NVLINK_CRC" ] || [ -n "$NVLINK_DOWN" ]; then
        return 1
    fi
    return 0
}
