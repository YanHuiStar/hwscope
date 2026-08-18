#!/bin/bash
# =============================================================================
# HwScope — DHCP 服务器工具（dnsmasq 封装）
# tools/dhcp_server.sh
# 用法: sudo bash tools/dhcp_server.sh <动作> [选项]
# 功能: 运维机给新上架服务器批量发 IP（交付场景）——安装 dnsmasq + 一键生成配置
#       + 启停 + 租约查询。
# 理由: DHCP 协议复杂度高，纯脚本实现不可行；dnsmasq 为开源轻量标准方案。
#       （Windows 侧对应 tools/win/dhcp_server.ps1，本工具服务 Linux 运维机）
#
# 动作:
#   install   安装 dnsmasq（apt/dnf 自动识别）
#   config    生成 /etc/dnsmasq.d/hwscope-dhcp.conf（默认 192.168.50.0/24, .100-.200）
#   start     启动服务（systemctl/service 自动识别）
#   stop      停止服务
#   restart   重启服务
#   status    服务状态 + 配置 + 租约数
#   leases    查看当前租约表（expiry MAC IP hostname）
#   leases-export <csv>   租约导出 CSV（与采集台账联动用）
#   reconcile <采集目录...>  租约 ↔ 采集报告 BMC IP/MAC 交叉核对（上架清单差异表）
#
# 选项:
#   --interface eth0    监听网卡（默认 eth0）
#   --subnet 192.168.50  网段前三段（默认 192.168.50）
#   --start 100          起始地址（默认 100）
#   --end 200            结束地址（默认 200）
#   --gateway 1          网关末段（默认 1；0=不下发网关）
#   --lease 12h          租约时长（默认 12h）
#   --dry-run            仅打印将生成的配置，不落盘
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

CONF_FILE="/etc/dnsmasq.d/hwscope-dhcp.conf"
LEASE_DEBIAN="/var/lib/misc/dnsmasq.leases"
LEASE_RHEL="/var/lib/dnsmasq/dnsmasq.leases"

ACTION="${1:-help}"; shift 2>/dev/null || true
IFACE="eth0"; SUBNET="192.168.50"; START=100; END=200; GW=1; LEASE="12h"; DRY=0
LEASE_FILE=""; POSARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --interface) IFACE="$2"; shift 2 ;;
        --subnet) SUBNET="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --end) END="$2"; shift 2 ;;
        --gateway) GW="$2"; shift 2 ;;
        --lease) LEASE="$2"; shift 2 ;;
        --lease-file) LEASE_FILE="$2"; shift 2 ;;   # 自定义租约文件（非默认路径/测试用）
        --dry-run) DRY=1; shift ;;
        -h|--help) ACTION="help" ;;
        *) POSARGS+=("$1"); shift ;;   # 位置参数（leases-export 的 CSV、reconcile 的采集目录）
    esac
done

need_root() {
    [ "$(id -u)" -eq 0 ] || { echo -e "\033[0;31m[ERROR] 需要 root：请用 sudo bash $0\033[0m"; exit 1; }
}

# 生成配置内容（dry-run 或写盘共用）
gen_conf() {
    {
        echo "# HwScope DHCP 配置（tools/dhcp_server.sh 生成，$(date '+%Y-%m-%d %H:%M:%S')）"
        echo "# 场景: 运维机直连新上架服务器批量发 IP；dnsmasq 轻量 DHCP/DNS 服务"
        echo "interface=${IFACE}"
        echo "dhcp-range=${SUBNET}.${START},${SUBNET}.${END},${LEASE}"
        if [ "${GW}" -gt 0 ] 2>/dev/null; then
            echo "dhcp-option=3,${SUBNET}.${GW}"
        fi
        echo "dhcp-authoritative"
        echo "log-dhcp"
    }
}

find_lease_file() {
    if [ -n "${LEASE_FILE:-}" ]; then echo "$LEASE_FILE"
    elif [ -f "$LEASE_DEBIAN" ]; then echo "$LEASE_DEBIAN"
    elif [ -f "$LEASE_RHEL" ]; then echo "$LEASE_RHEL"
    else echo "$LEASE_DEBIAN"; fi
}

case "$ACTION" in
    help)
        sed -n '1,30p' "$0" | grep -E "^#|^$" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | grep -vE "^$|^HwScope —|^tools/" 
        ;;
    install)
        need_root
        if command -v dnsmasq >/dev/null 2>&1; then
            echo -e "\033[0;32m[OK] dnsmasq 已安装: $(dnsmasq --version | head -1)\033[0m"
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y dnsmasq
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y dnsmasq
        elif command -v yum >/dev/null 2>&1; then
            yum install -y dnsmasq
        else
            echo -e "\033[0;31m[ERROR] 无法识别的包管理器，请手动安装 dnsmasq\033[0m"; exit 1
        fi
        command -v dnsmasq >/dev/null 2>&1 && echo -e "\033[0;32m[OK] dnsmasq 安装完成\033[0m"
        ;;
    config)
        if [ "$DRY" -eq 1 ]; then
            echo "--- 将写入 ${CONF_FILE} ---"
            gen_conf
            exit 0
        fi
        need_root
        mkdir -p "$(dirname "$CONF_FILE")"
        gen_conf > "$CONF_FILE"
        echo -e "\033[0;32m[OK] 配置已写入: ${CONF_FILE}\033[0m"
        cat "$CONF_FILE"
        ;;
    start|stop|restart)
        need_root
        if command -v systemctl >/dev/null 2>&1; then
            systemctl "$ACTION" dnsmasq
        else
            service dnsmasq "$ACTION"
        fi
        ;;
    status)
        echo "=== dnsmasq 服务状态 ==="
        if command -v systemctl >/dev/null 2>&1; then
            systemctl status dnsmasq --no-pager 2>/dev/null | head -8
        else
            service dnsmasq status 2>/dev/null | head -8
        fi
        echo ""
        echo "=== 当前配置 (${CONF_FILE}) ==="
        [ -f "$CONF_FILE" ] && cat "$CONF_FILE" || echo "  未生成配置，先运行: sudo bash $0 config"
        LF=$(find_lease_file)
        echo ""
        echo "=== 租约 (${LF}) ==="
        [ -f "$LF" ] && { echo "  当前租约: $(grep -vc '^#' "$LF" 2>/dev/null) 个"; grep -v '^#' "$LF" 2>/dev/null | awk '{printf "    %s  %s  %s  %s\n", $1, $2, $3, $4}'; } || echo "  无租约文件（尚无客户端）"
        ;;
    leases)
        LF=$(find_lease_file)
        if [ -f "$LF" ]; then
            echo "到期时间         MAC 地址             IP 地址        主机名"
            grep -v '^#' "$LF" 2>/dev/null | awk '{printf "%-17s %-20s %-15s %s\n", strftime("%Y-%m-%d %H:%M", $1), $2, $3, $4}'
            echo ""
            echo "租约总数: $(grep -vc '^#' "$LF" 2>/dev/null)"
        else
            echo "无租约文件（$LEASE_DEBIAN / $LEASE_RHEL），可能尚未有客户端或 dnsmasq 未运行"
        fi
        ;;
    leases-export)
        # 租约导出 CSV（expiry,mac,ip,hostname）——与采集台账联动（reconcile）用
        csv="${POSARGS[0]:-${SCRIPT_DIR}/logs/leases.csv}"
        mkdir -p "$(dirname "$csv")"
        LF=$(find_lease_file)
        {
            echo "# HwScope DHCP 租约导出 $(date '+%Y-%m-%d %H:%M:%S')"
            echo "expiry,mac,ip,hostname"
            [ -f "$LF" ] && grep -v '^#' "$LF" 2>/dev/null | awk '{print $1","$2","$3","$4}'
        } > "$csv"
        echo -e "\033[0;32m[OK] 租约已导出: ${csv}\033[0m"
        ;;
    reconcile)
        # 租约 ↔ 采集台账交叉核对：各采集目录报告 JSON 的 BMC IP/MAC vs 租约表
        [ "${#POSARGS[@]}" -eq 0 ] && { echo -e "\033[0;31m[ERROR] reconcile 需要采集目录参数（可多个，如 output/SN1 output/SN2）\033[0m"; exit 1; }
        LF=$(find_lease_file)
        [ ! -f "$LF" ] && echo -e "\033[1;33m[WARN] 无租约文件（${LEASE_DEBIAN} / ${LEASE_RHEL}），仅显示采集侧\033[0m"
        lease_map=""
        [ -f "$LF" ] && lease_map=$(grep -v '^#' "$LF" 2>/dev/null | awk '{print $3"|"$2}')
        echo "=== 租约 ↔ 采集台账 交叉核对 ==="
        echo "租约数: $(echo "$lease_map" | grep -c . )  采集目录: ${#POSARGS[@]} 个"
        # 注意：主脚本顶层不能用 local（非函数上下文），直接赋值即可
        tmatched=0; tunmatched=0; tnodata=0; _dir=""; json=""; sn=""; ip=""; mac=""; found=""
        for _dir in "${POSARGS[@]}"; do
            json="${_dir%/}/hwscope_report.json"
            [ ! -f "$json" ] && { echo -e "  \033[0;31m[ERROR] 无报告 JSON: ${_dir}\033[0m"; continue; }
            sn=$(basename "${_dir%/}")
            ip=$(grep -m1 -oE '"ip": "[^"]*"' "$json" 2>/dev/null | sed 's/.*"ip": "\([^"]*\)"/\1/')
            mac=$(grep -m1 -oE '"mac": "[^"]*"' "$json" 2>/dev/null | sed 's/.*"mac": "\([^"]*\)"/\1/')
            [ -z "$ip" ] && ip="N/A"; [ -z "$mac" ] && mac="N/A"
            if [ "$ip" = "N/A" ]; then
                tnodata=$((tnodata+1))
                echo -e "  \033[0;33m? ${sn}: 采集无 BMC IP（机器无 BMC 或未采集）\033[0m"
                continue
            fi
            found=$(echo "$lease_map" | grep -c "^${ip}|" 2>/dev/null || echo 0)
            [ "${found:-0}" -eq 0 ] && found=$(echo "$lease_map" | grep -ci "|${mac}$" 2>/dev/null || echo 0)
            if [ "${found:-0}" -gt 0 ]; then
                tmatched=$((tmatched+1))
                echo -e "  \033[0;32m✓ ${sn}: ${ip} ${mac} — 有租约\033[0m"
            else
                tunmatched=$((tunmatched+1))
                echo -e "  \033[0;31m✗ ${sn}: ${ip} ${mac} — 租约中无此 IP/MAC（未上线或未发租约）\033[0m"
            fi
        done
        # 反向：租约有但无对应采集（孤儿）
        orphan=0; lip=""; matched_any=""
        if [ -n "$lease_map" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                lip=$(echo "$line" | cut -d'|' -f1)
                matched_any=0
                for _dir in "${POSARGS[@]}"; do
                    json="${_dir%/}/hwscope_report.json"
                    [ -f "$json" ] && grep -q "\"ip\": \"${lip}\"" "$json" 2>/dev/null && matched_any=1 && break
                done
                [ "$matched_any" -eq 0 ] && orphan=$((orphan+1))
            done < <(printf '%s\n' "$lease_map")
        fi
        echo ""
        echo "汇总: 采集 ${#POSARGS[@]} 台 — 有租约 ${tmatched} / 无租约 ${tunmatched} / 无 BMC IP ${tnodata}；租约孤儿（无对应采集）${orphan} 个"
        ;;
    *)
        echo "未知动作: $ACTION"; sed -n '1,30p' "$0" | grep -E "^#   (install|config|start|stop|restart|status|leases|leases-export|reconcile)" | sed 's/^#   //'
        exit 1
        ;;
esac
