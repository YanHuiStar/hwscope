#!/bin/bash
# =============================================================================
# redfish_fw_list.sh — 从 Redfish 收集固件版本，输出「名字=版本」行
#   用法: bash redfish_fw_list.sh <BMC_IP> <NETRC_FILE>
#   密码经 netrc 文件传入（调用方用 mktemp 600 创建，命令行/ps 不出现密码）
#
#   为什么要这份脚本：各厂 Redfish 暴露固件的路径不一样——
#     · Dell/AMI：/UpdateService/FirmwareInventory 有集合，可枚举 BIOS/BMC/CPLD/PSU
#     · **NVIDIA DGX（实测 22.90，Redfish UpdateService v1_5_0）：该集合 404**，
#       版本在 /Managers/Self 的 FirmwareVersion（完整号 0.18.3，比 ipmitool 的 0.18 全）
#       与 /Systems/Self 的 BiosVersion（1.13）
#   故按「能取到哪个就取哪个」分层收集，全部失败才输出空（报告端据此隐藏该行）。
# =============================================================================
set -u
IP="${1:-}"; NETRC="${2:-}"
[ -n "$IP" ] && [ -n "$NETRC" ] || { echo "用法: $0 <BMC_IP> <NETRC_FILE>" >&2; exit 1; }

_g() { curl -sk --connect-timeout 5 --netrc-file "$NETRC" "https://$IP$1" 2>/dev/null; }
_jget() { _g "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s|.*:[[:space:]]*\"||; s|\"$||"; }

# ① UpdateService/FirmwareInventory（Dell/AMI 有，DGX 无）
_inv=$(_g "/redfish/v1/UpdateService/FirmwareInventory")
_ids=$(printf '%s' "$_inv" | grep -oE '"@odata.id":"[^"]*FirmwareInventory/[^"]*"' | sed 's|.*FirmwareInventory/||; s|"||')
if [ -n "$_ids" ]; then
    for _m in $_ids; do
        _j=$(_g "/redfish/v1/UpdateService/FirmwareInventory/$_m")
        _n=$(printf '%s' "$_j" | grep -oE '"Name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's|.*:[[:space:]]*"||; s|"$||')
        _v=$(printf '%s' "$_j" | grep -oE '"Version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's|.*:[[:space:]]*"||; s|"$||')
        [ -n "${_v:-}" ] && printf '%s=%s\n' "${_n:-$_m}" "$_v"
    done
fi

# ② Managers → FirmwareVersion（BMC 固件；DGX 给完整号 0.18.3）
for _mid in $( _g "/redfish/v1/Managers" | grep -oE '"@odata.id":"/redfish/v1/Managers/[^"]*"' | sed 's|.*Managers/||; s|"||' ); do
    _v=$(_jget "/redfish/v1/Managers/$_mid" "FirmwareVersion")
    [ -n "$_v" ] && { printf 'BMC Firmware=%s\n' "$_v"; break; }
done

# ③ Systems → BiosVersion（DGX 系统成员是 Self；部分厂是 System.Embedded.1 / 1）
for _sid in $( _g "/redfish/v1/Systems" | grep -oE '"@odata.id":"/redfish/v1/Systems/[^"]*"' | sed 's|.*Systems/||; s|"||' ); do
    case "$_sid" in Capabilities) continue ;; esac
    _v=$(_jget "/redfish/v1/Systems/$_sid" "BiosVersion")
    [ -n "$_v" ] && { printf 'System BIOS=%s\n' "$_v"; break; }
done

# ④ Chassis/*/Power → PowerSupplies[].FirmwareVersion（有则给，无则跳过）
for _cid in $( _g "/redfish/v1/Chassis" | grep -oE '"@odata.id":"/redfish/v1/Chassis/[^"]*"' | sed 's|.*Chassis/||; s|"||' ); do
    _pw=$(_g "/redfish/v1/Chassis/$_cid/Power")
    _pv=$(printf '%s' "$_pw" | grep -oE '"FirmwareVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's|.*:[[:space:]]*"||; s|"$||')
    [ -n "${_pv:-}" ] && { printf 'PSU Firmware=%s\n' "$_pv"; break; }
done
exit 0
