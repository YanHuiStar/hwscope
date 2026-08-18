#!/bin/bash
# =============================================================================
# tools/net_dhcp.sh — 一键配置网口 DHCP 自动获取 IP（Ubuntu 24.04 / netplan）
#
# 场景：服务器没配网 / 要改回自动获取。网线插上交换机即可拿到 IP。
# 功能：
#   1. 自动识别物理网口（排除 lo/docker/veth/br- 等虚拟接口）
#   2. 优先自动选择"插线 + 板载"的网口；无法确定时列出列表让用户选
#   3. 检查 netplan 是否已配置该接口
#   4. 备份 → 写入独立文件 99-hwscope-dhcp.yaml（netplan 多文件合并）→ 校验 → 应用
#
# 用法: sudo bash net_dhcp.sh [接口名]
# 安全：操作前备份全部 netplan 配置；generate 失败自动回滚
# =============================================================================
set -u

# ─── 帮助 ───
case "${1:-}" in
    -h|--help)
        sed -n '2,/^[^#]/p' "$0" | sed 's/^# \?//' | sed '/^$/d'
        echo ""
        echo "用法: sudo bash tools/net_dhcp.sh    # 交互式选择网口配置 DHCP"
        exit 0 ;;
esac

# ─── 检查 root ───
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 需要 root 运行: sudo bash $0"; exit 1
fi

# ─── 依赖检查 ───
for c in netplan ip; do
    command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] 缺少命令: $c"; exit 1; }
done

# ─── 虚拟接口模式（排除；IB/RDMA 口常见预测命名 ibp8s0/ibP260p0s0，[0-9]* 匹配不到 p 会漏进候选——v1.33.3） ───
VIRT_PAT='^(lo|docker[0-9]*|virbr[0-9]*|veth[0-9a-f]*|veth.*|br-[0-9a-f]*|br[0-9]*|tun[0-9]*|tap[0-9]*|vnet[0-9]*|vxlan[0-9]*|bond[0-9]*|wg[0-9]*|dummy[0-9]*|sit[0-9]*|ip6tnl[0-9]*|nb[0-9]*|nbd[0-9]*|ib.*)$'

# ─── 收集物理网口 ───
IFACES=()
for dev in /sys/class/net/*; do
    name=$(basename "$dev")
    [[ "$name" =~ $VIRT_PAT ]] && continue
    [ -e "$dev/device" ] || continue          # 无 device 目录 = 虚拟接口
    [ -f "$dev/address" ] || continue
    mac=$(cat "$dev/address" 2>/dev/null)
    carrier=$(cat "$dev/carrier" 2>/dev/null || echo 0)
    # PCI 总线号（板载网口通常 bus 00）
    pci=$(readlink "$dev/device" 2>/dev/null | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' | head -1)
    bus=$(echo "$pci" | cut -d: -f2)
    ipv4=$(ip -4 addr show "$name" 2>/dev/null | awk '/inet /{print $2; exit}')
    IFACES+=("$name|$mac|$carrier|$bus|$ipv4")
done

if [ ${#IFACES[@]} -eq 0 ]; then
    echo "[ERROR] 未检测到物理网口"; exit 1
fi

# ─── 已有 netplan 配置检查 ───
has_netplan_conf() {
    local iface="$1"
    grep -rlE "^[[:space:]]*${iface}:" /etc/netplan/*.y*ml 2>/dev/null | head -1
}

# ─── 展示网口列表 ───
echo "检测到物理网口:"
printf "  %-8s %-18s %-5s %-5s %s\n" "接口" "MAC" "插线" "板载" "当前IP"
for e in "${IFACES[@]}"; do
    IFS='|' read -r name mac carrier bus ipv4 <<< "$e"
    plug=$([ "$carrier" = "1" ] && echo "是" || echo "否")
    onboard=$([ -n "$bus" ] && [ "$bus" = "00" ] && echo "是" || echo "否")
    printf "  %-8s %-18s %-5s %-5s %s\n" "$name" "$mac" "$plug" "$onboard" "${ipv4:-无}"
done

# ─── 选择接口 ───
TARGET=""
if [ -n "${1:-}" ]; then
    TARGET="$1"
    # 校验参数是否在物理网口列表
    found=0
    for e in "${IFACES[@]}"; do
        IFS='|' read -r name _ <<< "$e"
        [ "$name" = "$TARGET" ] && found=1 && break
    done
    [ "$found" -eq 0 ] && echo "[ERROR] $TARGET 不是检测到的物理网口" && exit 1
else
    # 自动选择：插线板载(唯一) > 插线(唯一) > 唯一网口
    plugged_board=(); plugged=()
    for e in "${IFACES[@]}"; do
        IFS='|' read -r name mac carrier bus ipv4 <<< "$e"
        [ "$carrier" = "1" ] && plugged+=("$name")
        [ "$carrier" = "1" ] && [ "$bus" = "00" ] && plugged_board+=("$name")
    done
    if [ ${#plugged_board[@]} -eq 1 ]; then
        TARGET="${plugged_board[0]}"; echo ""
        echo "[自动] 唯一插线板载网口: $TARGET"
    elif [ ${#plugged[@]} -eq 1 ]; then
        TARGET="${plugged[0]}"; echo ""
        echo "[自动] 唯一插线网口: $TARGET"
    elif [ ${#IFACES[@]} -eq 1 ]; then
        TARGET=$(echo "${IFACES[0]}" | cut -d'|' -f1); echo ""
        echo "[自动] 唯一物理网口: $TARGET"
    else
        echo ""
        echo "[提示] 无法自动确定目标网口（多块插线/多块网口），请选择:"
        i=1
        for e in "${IFACES[@]}"; do
            IFS='|' read -r name mac carrier bus ipv4 <<< "$e"
            echo "  [$i] $name  ($mac)"
            i=$((i+1))
        done
        read -rp "选择接口编号: " sel
        # 校验输入（负数/非数字会静默取数组末元素或 set -u 崩溃——v1.33.3）
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#IFACES[@]}" ]; then
            echo "[ERROR] 无效选择: $sel（范围 1-${#IFACES[@]}）"; exit 1
        fi
        TARGET=$(echo "${IFACES[$((sel-1))]}" | cut -d'|' -f1)
        if [ -z "$TARGET" ]; then echo "无效选择"; exit 1; fi
    fi
fi

echo ""
echo "[目标] 接口: $TARGET"

# ─── 检查现有配置 ───
EXIST=$(has_netplan_conf "$TARGET")
if [ -n "$EXIST" ]; then
    echo "[提示] $TARGET 已在 $EXIST 中出现:"
    grep -A4 "^[[:space:]]*${TARGET}:" "$EXIST" | head -8
    echo ""
    echo "       将写入 99-hwscope-dhcp.yaml（netplan 多文件合并，99 号最后加载优先）"
else
    echo "[提示] $TARGET 当前无 netplan 配置，将新建 99-hwscope-dhcp.yaml"
fi

# ─── 确认 ───
read -rp "确认将 $TARGET 配置为 DHCP 自动获取 IP? (y/N) " ans
[[ ! "$ans" =~ ^[Yy] ]] && echo "已取消" && exit 0

# ─── 备份 ───
BK="/etc/netplan/backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BK"
cp -a /etc/netplan/*.y*ml "$BK"/ 2>/dev/null
echo "[备份] netplan 配置 → $BK/"

# ─── 写入新配置 ───
CFG="/etc/netplan/99-hwscope-dhcp.yaml"
cat > "$CFG" <<EOF
# 由 hwscope tools/net_dhcp.sh 生成 — 将 $TARGET 配置为 DHCP 自动获取 IP
network:
  version: 2
  ethernets:
    $TARGET:
      dhcp4: true
EOF
echo "[写入] $CFG"

# ─── 校验（按退出码判定，失败回滚——文本匹配 "error/Error" 不可靠，如 "Invalid YAML" 不含 error——v1.33.3） ───
if ! netplan generate > "${BK}/netplan.generate.log" 2>&1; then
    echo "[ERROR] netplan generate 失败:"
    tail -5 "${BK}/netplan.generate.log"
    echo "[回滚] 恢复备份..."
    cp -a "$BK"/*.y*ml /etc/netplan/ 2>/dev/null
    rm -f "$CFG"
    exit 1
fi

# ─── 断连警告（该接口有 IP 且是默认路由时） ───
MYIP=$(ip -4 addr show "$TARGET" 2>/dev/null | awk '/inet /{print $2; exit}')
if [ -n "$MYIP" ]; then
    echo ""
    echo "[警告] $TARGET 当前 IP: $MYIP — 应用 DHCP 后该 IP 可能变更"
    echo "       如果正在用 SSH 连接此接口，连接会断开！"
    read -rp "确认应用? (y/N) " ans2
    [[ ! "$ans2" =~ ^[Yy] ]] && echo "已取消（配置已写入 $CFG，可稍后手动 netplan apply）" && exit 0
fi

# ─── 应用（失败检查 + 回滚——之前 apply 失败无感知仍打印完成） ───
if ! netplan apply > "${BK}/netplan.apply.log" 2>&1; then
    echo "[ERROR] netplan apply 失败:"
    tail -5 "${BK}/netplan.apply.log"
    echo "[回滚] 恢复备份..."
    cp -a "$BK"/*.y*ml /etc/netplan/ 2>/dev/null
    rm -f "$CFG"
    exit 1
fi
echo ""
echo "[完成] $TARGET 已配置 DHCP。等待获取 IP..."
sleep 4
NEWIP=$(ip -4 addr show "$TARGET" 2>/dev/null | awk '/inet /{print $2; exit}')
if [ -n "$NEWIP" ]; then
    echo "  ✅ 获取到 IP: $NEWIP"
else
    echo "  ⚠ 尚未获取到 IP（检查网线/交换机 DHCP 服务）"
fi
