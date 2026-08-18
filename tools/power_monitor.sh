#!/bin/bash
# =============================================================================
# HwScope — 能耗持续采样
# tools/power_monitor.sh
# 用法: bash tools/power_monitor.sh start|stop|status [选项]
# 功能: 后台常驻采样整机功耗（DCMI 优先，Redfish 兜底），生成时间序列 CSV，
#       停止/时长结束输出 小时/日 聚合与累计能耗核算（梯形积分 kWh）。
# 场景: 交付后供电核算、机房容量规划——补 16_power 模块"单点快照"的缺口。
# 依赖: ipmitool（或 curl+Redfish）；零新依赖
#
# 选项:
#   --interval N    采样间隔秒（默认 60）
#   --duration N    采样时长秒（默认 0 = 持续，stop 停止）
#   --output <dir>  输出目录（默认 <项目>/logs/power_monitor/）
#   --redfish       同时采集 Redfish PowerConsumedWatts（需 conf 配置 BMC_IP）
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true
[ -f "${SCRIPT_DIR}/conf/hwscope.conf" ] && source "${SCRIPT_DIR}/conf/hwscope.conf"

ACTION="${1:-help}"; shift 2>/dev/null || true
INTERVAL=60; DURATION=0; OUT_DIR="${SCRIPT_DIR}/logs/power_monitor"; USE_REDFISH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --output) OUT_DIR="$2"; shift 2 ;;
        --redfish) USE_REDFISH=1; shift ;;
        -h|--help) ACTION="help" ;;
        *) echo "[WARN] 未知参数: $1"; shift ;;
    esac
done

PID_FILE="${OUT_DIR}/power_monitor.pid"
CSV="${OUT_DIR}/power_samples.csv"
AGG="${OUT_DIR}/power_aggregate.txt"
mkdir -p "$OUT_DIR"

usage() {
    sed -n '1,24p' "$0" | grep -E "^#" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | grep -vE "^$|^HwScope —|^tools/"
}

# ─── 单次采样：输出 "时间戳,功率W" ───
sample_once() {
    local w=""
    # 1. DCMI（本地 IPMI）
    if check_cmd ipmitool; then
        w=$(ipmitool dcmi power reading 2>/dev/null | grep -im1 "Instantaneous power reading" | grep -oE "[0-9.]+" | head -1)
        # 2. 兜底 Total_Power 传感器
        [ -z "$w" ] && w=$(ipmitool sensor list 2>/dev/null | grep -iE "^Total_Power" | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -oE "[0-9.]+" | head -1)
    fi
    # 3. Redfish（配置了 BMC_IP + --redfish）
    if [ -z "$w" ] && [ "$USE_REDFISH" -eq 1 ] && [ -n "${BMC_IP:-}" ] && check_cmd curl; then
        local netrc member
        netrc=$(mktemp); chmod 600 "$netrc"
        printf 'machine %s login %s password %s\n' "$BMC_IP" "${BMC_USER:-admin}" "${BMC_PASS:-admin}" > "$netrc"
        member=$(curl -sk --connect-timeout 5 --netrc-file "$netrc" "https://${BMC_IP}/redfish/v1/Chassis" 2>/dev/null \
            | grep -oE '"@odata\.id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\(.*\)"/\1/')
        [ -n "$member" ] && w=$(curl -sk --connect-timeout 5 --netrc-file "$netrc" "https://${BMC_IP}${member}/Power" 2>/dev/null \
            | grep -oE '"PowerConsumedWatts"[^0-9]*[0-9.]+' | grep -oE "[0-9.]+" | head -1)
        rm -f "$netrc"
    fi
    [ -z "$w" ] && return 1
    echo "$(date '+%Y-%m-%d %H:%M:%S'),${w}"
}

# ─── 聚合核算：CSV → power_aggregate.txt（小时/日 + 梯形积分 kWh） ───
aggregate() {
    [ -f "$CSV" ] || return
    local n
    n=$(grep -v "^#" "$CSV" | grep -v "^timestamp" | grep -v "^$" | wc -l)
    [ "$n" -lt 2 ] && { echo "[INFO] 采样点不足（${n}），跳过聚合"; return; }
    {
        echo "============================================"
        echo "能耗采样聚合 $(date '+%Y-%m-%d %H:%M:%S')  共 ${n} 个采样点"
        echo "============================================"
        echo "--- 小时聚合 ---"
        awk -F, '$1!="timestamp" && $1!="" {
            split($1,a," "); split(a[2],t,":"); hour=a[1]" "t[1]":00"
            sum[hour]+=$2; cnt[hour]++; if($2>max[hour])max[hour]=$2; if(min[hour]==""||$2<min[hour])min[hour]=$2
        } END{for(h in sum) printf "  %s  平均:%dW 最小:%dW 最大:%dW  (%d点)\n", h, sum[h]/cnt[h], min[h], max[h], cnt[h]}' "$CSV" | sort
        echo "--- 日聚合 ---"
        awk -F, '$1!="timestamp" && $1!="" {
            split($1,a," "); d=a[1]
            sum[d]+=$2; cnt[d]++; if($2>max[d])max[d]=$2; if(min[d]==""||$2<min[d])min[d]=$2
        } END{for(d in sum) printf "  %s  平均:%dW 最小:%dW 最大:%dW  (%d点)\n", d, sum[d]/cnt[d], min[d], max[d], cnt[d]}' "$CSV" | sort
        echo "--- 累计能耗（梯形积分） ---"
        awk -F, 'NR>1 && $1!="timestamp" && $1!="" {
            ts=$1; gsub(/[-: ]/,"",ts); w=$2
            if(prev_ts!=""){
                dt=(substr(ts,9,2)*60+substr(ts,11,2))*60 - (substr(prev_ts,9,2)*60+substr(prev_ts,11,2))*60
                if(dt<0) dt+=86400
                energy+= (w+prev_w)/2 * dt
            }
            prev_ts=ts; prev_w=w
        } END{printf "  累计能耗: %.4f kWh（梯形积分）\n", energy/3600000}' "$CSV"
    } > "$AGG"
    echo -e "\033[0;32m[OK] 聚合与能耗核算 → ${AGG}\033[0m"
}

case "$ACTION" in
    help) usage ;;
    start)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo -e "\033[1;33m[WARN] 已在运行（pid $(cat "$PID_FILE")）；先 stop 再 start\033[0m"; exit 0
        fi
        if ! sample_once >/dev/null 2>&1; then
            echo -e "\033[0;31m[ERROR] 无法读取功耗（ipmitool dcmi/sensor 或 Redfish 均无数据）\033[0m"; exit 1
        fi
        [ -f "$CSV" ] || { echo "# HwScope 能耗采样 $(date '+%Y-%m-%d %H:%M:%S')  间隔 ${INTERVAL}s"; echo "timestamp,power_w"; } > "$CSV"
        # 子进程模式：后台重跑本脚本 __sampler（函数随脚本加载，避免 export -f 依赖）
        nohup bash "$0" __sampler --output "$OUT_DIR" --interval "$INTERVAL" --duration "$DURATION" --redfish > "${OUT_DIR}/power_monitor.log" 2>&1 &
        sleep 1
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo -e "\033[0;32m[OK] 能耗采样已启动（pid $(cat "$PID_FILE")）: 间隔 ${INTERVAL}s${DURATION:+, 时长 ${DURATION}s} → ${CSV}\033[0m"
            echo "    停止: bash $0 stop | 状态: bash $0 status"
        else
            echo -e "\033[0;31m[ERROR] 启动失败，日志: ${OUT_DIR}/power_monitor.log\033[0m"
            tail -5 "${OUT_DIR}/power_monitor.log" 2>/dev/null
            exit 1
        fi
        ;;
    __sampler)
        # 后台采样循环（仅由 start 以子进程启动；本段不对外）
        echo $$ > "$PID_FILE"
        local_end=$(( $(date +%s) + DURATION ))
        while true; do
            line=$(sample_once 2>/dev/null) || true
            [ -n "$line" ] && echo "$line" >> "$CSV"
            if [ "$DURATION" -gt 0 ] 2>/dev/null && [ "$(date +%s)" -ge "$local_end" ]; then break; fi
            sleep "$INTERVAL"
        done
        rm -f "$PID_FILE"
        aggregate
        ;;
    stop)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            kill "$(cat "$PID_FILE")" 2>/dev/null
            for _ in 1 2 3 4 5; do [ -f "$PID_FILE" ] || break; sleep 1; done
            rm -f "$PID_FILE"
            echo -e "\033[0;32m[OK] 已停止采样\033[0m"
        else
            rm -f "$PID_FILE"
            echo -e "\033[1;33m[INFO] 未在运行\033[0m"
        fi
        aggregate
        ;;
    status)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "运行中（pid $(cat "$PID_FILE")）  采样文件: $CSV"
            echo "最近采样:"
            grep -v "^#" "$CSV" 2>/dev/null | grep -v "^timestamp" | tail -5
        else
            echo "未运行。上次采样: $CSV"
            grep -v "^#" "$CSV" 2>/dev/null | grep -v "^timestamp" | tail -5
        fi
        ;;
    *) echo "未知动作: $ACTION"; usage; exit 1 ;;
esac
