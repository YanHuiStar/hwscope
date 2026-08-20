#!/bin/bash
# shellcheck disable=SC2010  # /sys/class 接口名无空格，ls|grep 过滤安全
# =============================================================================
# HwScope — 网卡运维工具
# tools/nic_tool.sh
# 用法: sudo bash tools/nic_tool.sh
# 功能: IB 端口状态/重置、固件查询、mlxconfig 配置查看
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
parse_help "$@"

# ─── 工具检查 ───
if ! check_cmd mlxlink && ! check_cmd mlxfwmanager; then
    echo -e "${RED}[ERROR] 未找到 MFT 工具 (mlxlink/mlxfwmanager)${NC}"
    echo "        安装: bash tools/install_tool.sh (MFT)"
    exit 1
fi

# ─── 设备列表（不截断：>8 个 mlx5 设备也全列出，选择校验基于完整列表——v1.33.3） ───
DEVS=$(ls /sys/class/infiniband/ 2>/dev/null | grep -E 'mlx5_')
if [ -z "$DEVS" ]; then
    echo -e "${YELLOW}[WARN] 未发现 mlx5 IB 设备${NC}"
    echo "      非 IB 服务器可跳过本工具"
    exit 1
fi
echo -e "${CYAN}发现 IB 设备:${NC} $DEVS"

# ─── 功能表 ───
OPS=(
    "1:查看所有设备状态:mlxlink -d DEV 2>&1 | head -25:只读"
    "2:查看光模块信息:mlxlink -d DEV -m 2>&1 | head -25:只读"
    "3:查询固件版本:mlxfwmanager --query 2>&1 | grep -E 'Device|Firmware|PSID' | head -10:只读"
    "4:查看配置:mlxconfig query -d DEV 2>&1 | head -20:只读"
    "5:端口复位:mlxlink -d DEV -r 2>&1:写入操作"
    "6:设置 MTU (9000):ip link set DEV mtu 9000 2>&1:写入操作"
    "7:切换端口模式 (IB↔ETH):模式切换子菜单:写入操作"
)

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  网卡运维工具${NC}"
echo -e "${CYAN}========================================${NC}"
for op in "${OPS[@]}"; do
    IFS=':' read -r num name cmd warn <<< "$op"
    echo -e "  ${GREEN}[${num}]${NC} ${name}  ${YELLOW}(${warn})${NC}"
done
echo ""
read -p "选择操作 (1-7, 逗号分隔): " -r choices
[ -z "$choices" ] && echo "跳过" && exit 0

# ─── 选择设备（校验在列表内，防任意路径经 bash -c 执行——v1.33.3） ───
read -p "选择设备 (默认 ${DEVS%% *}): " -r dev
[ -z "$dev" ] && dev="${DEVS%% *}"
if ! echo "$DEVS" | grep -qw "$dev"; then
    echo -e "${RED}[ERROR] 无效设备 ${dev}（可用: ${DEVS//$'\n'/ }）${NC}"; exit 1
fi

REPORT_DIR="${SCRIPT_DIR}/output/nic_tool_$(date '+%Y%m%d%H%M%S')"
mkdir -p "$REPORT_DIR"

# ─── 模式切换子菜单（选项 7） ───
switch_port_mode() {
    local dev="$1"
    echo -e "${CYAN}━━━ 端口模式切换 (${dev}) ━━━${NC}"

    # 当前模式
    local modes
    modes=$(mlxconfig query -d "$dev" 2>/dev/null | grep -E "LINK_TYPE_P[12]")
    if [ -z "$modes" ]; then
        echo -e "${YELLOW}[WARN] 未获取到 LINK_TYPE 配置（该设备可能不支持或需 mst start）${NC}"
        return 1
    fi
    echo -e "当前配置:"
    echo "$modes" | sed 's/^/  /'

    # 目标模式
    echo ""
    echo "目标模式:"
    echo "  [1] InfiniBand  (LINK_TYPE=1)"
    echo "  [2] Ethernet    (LINK_TYPE=2)"
    read -p "选择目标模式 (1/2, Enter 取消): " -r target
    [ -z "$target" ] && echo "取消" && return 0
    case "$target" in
        1) target_val=1 ;;
        2) target_val=2 ;;
        *) echo -e "${RED}[ERROR] 无效选择${NC}"; return 1 ;;
    esac

    # 确认（写入操作）
    read -p " ${YELLOW}⚠ 修改端口模式需要重启/重置才生效，确认修改所有 P1/P2 为模式 ${target_val}? (y/N)${NC} " -r confirm
    [[ ! "$confirm" =~ ^[Yy] ]] && echo "跳过" && return 0

    # 批量修改（仅改与目标不同的端口）
    local changed=0
    while IFS= read -r line; do
        local port
        port=$(echo "$line" | awk '{print $1}')
        local cur
        cur=$(echo "$line" | awk '{print $2}' | grep -oE '[0-9]+' | head -1)
        [ -z "$port" ] && continue
        if [ -z "$cur" ]; then
            echo -e "${YELLOW}[SKIP] ${port} 无法解析当前值${NC}"
            continue
        fi
        if [ "$cur" = "$target_val" ]; then
            echo -e "${GREEN}[OK] ${port} 已是模式 ${cur}，跳过${NC}"
        else
            echo -e "${YELLOW}修改 ${port}: ${cur} → ${target_val}${NC}"
            echo yes | mlxconfig -d "$dev" set "${port}=${target_val}" 2>&1 | tail -3
            changed=1
        fi
    done < <(printf '%s\n' "$modes")   # 进程替换（函数内 herestring 在 MSYS 空读——v1.33.3）

    if [ "$changed" -eq 1 ]; then
        echo ""
        echo -e "${YELLOW}⚠ 配置已修改，需重启系统或 mlxfwreset 生效:${NC}"
        echo "  sudo mlxfwreset -d $dev r -y   # 热重置（不重启主机）"
        echo "  或重启主机"
    else
        echo -e "${GREEN}无需修改${NC}"
    fi
}

IFS=',' read -ra SELECTED <<< "$choices"
for sel in "${SELECTED[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    for op in "${OPS[@]}"; do
        IFS=':' read -r num name cmd warn <<< "$op"
        [ "$sel" != "$num" ] && continue
        echo -e "${CYAN}━━━ ${name} (${dev}) ━━━${NC}"
        if [ "$warn" = "写入操作" ]; then
            read -p " ${YELLOW}⚠ 此操作会修改网卡配置，确认? (y/N)${NC} " -r confirm
            [[ ! "$confirm" =~ ^[Yy] ]] && echo "  跳过" && continue
        fi
        if [ "$num" = "7" ]; then
            switch_port_mode "$dev"
            continue
        fi
        final_cmd=$(echo "$cmd" | sed "s/DEV/${dev}/g")
        LOGFILE="${REPORT_DIR}/${name// /_}.log"
        bash -c "$final_cmd" | tee "$LOGFILE"
        echo ""
    done
done

echo -e "${GREEN}操作完成${NC}"
echo "日志: $REPORT_DIR/"
