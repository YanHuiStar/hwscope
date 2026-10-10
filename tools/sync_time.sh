#!/bin/bash
# =============================================================================
# HwScope — 通过 SSH 将本机时间同步到目标机（OS / RTC / BMC 三处）
# tools/sync_time.sh
# 用法: bash tools/sync_time.sh root@10.0.0.1 [root@10.0.0.2 ...]
#       bash tools/sync_time.sh --dry-run root@10.0.0.1     # 只探测，不改
#       bash tools/sync_time.sh --bmc root@10.0.0.1         # 强制校 BMC
#       bash tools/sync_time.sh --no-bmc root@10.0.0.1      # 跳过 BMC
#       bash tools/sync_time.sh -h
#
# 功能: 以本机（运维机）时间为基准，SSH 同步目标机三处时间：
#   ① OS 系统时间（date -s @epoch）—— **成败只由这一处决定**
#   ② RTC 硬件时钟 —— hwclock 优先；缺失则 python3 直写 /dev/rtc0；都无则 WARN
#   ③ BMC 时间（--bmc，或默认 auto：目标机有 ipmitool + /dev/ipmi0 时自动启用）
#      —— 用**目标机本地** ipmitool（带内，无需 BMC 凭据/网络）
#
# 为什么 RTC/BMC 失败不算整体失败（v1.53.0 修正）：
#   采集时间戳只依赖 **OS 系统时间**；RTC 只影响"重启后是否还准"，BMC 时间只影响
#   SEL 时间轴。旧实现在 `date -s && hwclock -w` 链上取合并退出码，于是**目标机缺
#   hwclock（Ubuntu 24.04 基础包不含，在 util-linux-extra 里）时退出码 127**，
#   把"OS 已设成功"渲染成 `[ERROR] 同步失败` —— 运维据此反复重试、每次都白改。
#
# 实现要点:
#   - epoch 秒传递（date -s @<epoch>）：无时区歧义，目标机按自身时区显示
#   - **远程脚本用 base64 传参**（`echo <b64> | base64 -d | bash`）：参数里只有
#     base64 字符，无从被引号/括号/$ 破坏 —— 命令行引号地狱的根治办法（Windows
#     OpenSSH 侧尤其重要，见 tools/win/sync_time.ps1）
#   - NTP：先记原值，设完**无条件还原**（旧实现只停不还原，把机器留在 NTP off）
#   - 交互式密码默认（与 remote_collect.sh 一致的安全立场），ControlMaster 复用
#
# 依赖: 运维机 ssh/date/base64；目标机 date/base64 +（可选）timedatectl/hwclock/
#       python3/ipmitool。**注意：Ubuntu 24.04 不预装 hwclock**（util-linux-extra）。
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "用法: $0 [--dry-run] [--bmc|--no-bmc] <user@host> [user@host2 ...]"
    echo "功能: 将本机时间通过 SSH 同步到目标机（OS 系统时间 + RTC + 可选 BMC）"
    echo "选项:"
    echo "  -h, --help    显示本帮助"
    echo "  --dry-run     只显示三处当前值与偏差、并探测目标机工具，不做修改"
    echo "  --bmc         强制同步 BMC 时间（目标机本地 ipmitool）"
    echo "  --no-bmc      跳过 BMC（默认 auto：有 ipmitool + /dev/ipmi0 才做）"
    echo "示例:"
    echo "  bash $0 root@10.0.0.1                          # 单台"
    echo "  bash $0 --dry-run root@10.0.0.1                # 先看一眼"
    echo "  bash $0 root@<h1> root@<h2> root@<h3>          # 多台"
    echo ""
    echo "说明: OS 系统时间是成败判据；RTC/BMC 失败各自输出 WARN，不影响整体判定。"
}

# v1.50.5：-h/--help 先于 HOST 解析（此前仅判 $# -eq 0，`-h` 会被当目标机去 `ssh -h`）
# v1.52.28：加 --dry-run；v1.53.0：加 --bmc/--no-bmc
DRY_RUN=0
BMC_MODE="auto"     # auto | yes | no
HOSTS=()
for _arg in "$@"; do
    case "$_arg" in
        -h|--help)   usage; exit 0 ;;
        --dry-run)   DRY_RUN=1 ;;
        --bmc)       BMC_MODE="yes" ;;
        --no-bmc)    BMC_MODE="no" ;;
        -*)          echo "[ERROR] 未知参数: ${_arg}"; usage; exit 1 ;;
        *)           HOSTS+=("$_arg") ;;
    esac
done
[ ${#HOSTS[@]} -eq 0 ] && { usage; exit 1; }

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ControlMaster=auto -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h -o ControlPersist=300"
rm -f /tmp/ssh_hwscope_mux_* 2>/dev/null || true

EPOCH=$(date +%s)
LOCAL_HMS=$(date '+%Y-%m-%d %H:%M:%S %Z')
echo "============================================"
echo "  本机时间: ${LOCAL_HMS} (epoch=${EPOCH})"
[ "$DRY_RUN" -eq 1 ] && echo "  [DryRun] 只检查偏差与工具，不做修改"
echo "============================================"

cleanup() {
    ssh -O exit -o ControlPath=/tmp/ssh_hwscope_mux_%r@%h "${1:-x}" >/dev/null 2>&1 || true
    rm -f /tmp/ssh_hwscope_mux_* 2>/dev/null || true
}
trap 'cleanup "${HOSTS[0]:-}"' EXIT INT TERM

# ─── 远程脚本模板 ───
#   用**单引号**包裹（本地不做任何插值），仅 __EPOCH__/__BMC__/__SUDO__ 三个占位符
#   在发送前替换。因此模板内可放心使用 $、双引号、括号；
#   ⚠️ 但模板内**不得出现单引号**（会提前闭合）——凡需引号处一律用双引号。
REMOTE_TPL='
set -u
_old=$(date +%s)
echo "  目标机当前: $(date "+%Y-%m-%d %H:%M:%S %Z")  (epoch=${_old}, 与本机差 $((_old - __EPOCH__)) 秒)"
echo "  目标机时区: $(cat /etc/timezone 2>/dev/null || echo unknown)  （若为 Etc/UTC，显示与运维机差 8 小时属同一时刻）"

if [ "__BMC__" = "dry" ]; then
    echo "  ── 工具探测 ──"
    printf "  timedatectl : %s\n" "$(command -v timedatectl || echo 缺失)"
    printf "  hwclock     : %s\n" "$(command -v hwclock || echo 缺失)"
    printf "  python3     : %s\n" "$(command -v python3 || echo 缺失)"
    printf "  ipmitool    : %s\n" "$(command -v ipmitool || echo 缺失)"
    if [ -e /dev/ipmi0 ]; then echo "  /dev/ipmi0  : 存在"; else echo "  /dev/ipmi0  : 不存在"; fi
    if [ -e /dev/rtc0 ]; then echo "  /dev/rtc0   : 存在"; else echo "  /dev/rtc0   : 不存在"; fi
    echo "  ── 当前值 ──"
    grep -hE "rtc_time|rtc_date" /proc/driver/rtc 2>/dev/null | sed "s/^/  /" || echo "  (/proc/driver/rtc 不可读)"
    if command -v ipmitool >/dev/null 2>&1 && [ -e /dev/ipmi0 ]; then
        echo "  BMC 时间: $(ipmitool sel time get 2>/dev/null || echo 读取失败)"
    fi
    exit 0
fi

# ── ① OS 系统时间：唯一决定成败 ──
_ntp_orig="$(timedatectl show -p NTP --value 2>/dev/null || echo unknown)"
__SUDO__timedatectl set-ntp false 2>/dev/null || true
if __SUDO__date -s @__EPOCH__ >/dev/null 2>&1; then
    echo "  [OK]   OS 系统时间已设置"
    _os_ok=1
else
    echo "  [FAIL] OS 系统时间设置失败（需 root 或 CAP_SYS_TIME）"
    _os_ok=0
fi

# ── ② RTC 硬件时钟：三级兜底，失败只 WARN ──
_rtc_done=0
if command -v hwclock >/dev/null 2>&1; then
    if __SUDO__hwclock -w >/dev/null 2>&1; then
        _rtc_done=1
        echo "  [OK]   RTC 已写入（hwclock -w）"
    fi
fi
if [ "$_rtc_done" -eq 0 ] && command -v python3 >/dev/null 2>&1 && [ -e /dev/rtc0 ]; then
    # RTC_SET_TIME = _IOW("p",0x0a,struct rtc_time[9*int]) = 0x4024700a
    # 必须写 UTC（gmtime）：目标机通常 RTC in local TZ: no，写本地时间会再错 8 小时
    if python3 -c "
import struct,fcntl,time
t=time.gmtime(__EPOCH__)
buf=struct.pack(\"9i\",t.tm_sec,t.tm_min,t.tm_hour,t.tm_mday,t.tm_mon-1,t.tm_year-1900,0,0,0)
f=open(\"/dev/rtc0\",\"wb\");fcntl.ioctl(f,0x4024700a,buf);f.close()
" >/dev/null 2>&1; then
        _rtc_done=1
        echo "  [OK]   RTC 已写入（python3 ioctl 兜底，UTC）"
    fi
fi
if [ "$_rtc_done" -eq 0 ]; then
    echo "  [WARN] RTC 未写入（缺 hwclock 且无 python3+/dev/rtc0）—— 重启后系统时间会回到 RTC 旧值，需重新校时"
fi

# ── ③ BMC 时间：--bmc/auto；失败只 WARN；无带内 IPMI 按平台固有跳过 ──
if [ "__BMC__" = "yes" ] || [ "__BMC__" = "auto" ]; then
    if command -v ipmitool >/dev/null 2>&1 && [ -e /dev/ipmi0 ]; then
        _bt="$(date -u -d @__EPOCH__ "+%m/%d/%Y %I:%M:%S %p" 2>/dev/null)"
        _b_ok=0
        # ipmitool 1.8.19 只认 12h AM/PM（24 小时制报 Specified time could not be parsed）
        if [ -n "$_bt" ] && __SUDO__ipmitool sel time set "$_bt UTC" >/dev/null 2>&1; then
            if __SUDO__ipmitool sel time get 2>/dev/null | grep -q "$(date -u -d @__EPOCH__ "+%m/%d/%Y" 2>/dev/null)"; then
                _b_ok=1
            fi
        fi
        if [ "$_b_ok" -eq 0 ]; then
            # 回退：raw 0x0a 0x49，4 字节小端 epoch（每字节必须带 0x 前缀）
            _E=__EPOCH__
            __SUDO__ipmitool raw 0x0a 0x49 \
              0x$(printf "%02x" $((_E & 0xff))) 0x$(printf "%02x" $(((_E >> 8) & 0xff))) \
              0x$(printf "%02x" $(((_E >> 16) & 0xff))) 0x$(printf "%02x" $(((_E >> 24) & 0xff))) >/dev/null 2>&1 \
              && _b_ok=1
        fi
        if [ "$_b_ok" -eq 1 ]; then
            echo "  [OK]   BMC 时间已设置（目标机本地 ipmitool）→ $(__SUDO__ipmitool sel time get 2>/dev/null)"
        else
            echo "  [WARN] BMC 时间设置失败（有 ipmitool + /dev/ipmi0 但写入未生效，请用 sel list 复核）"
        fi
    else
        echo "  [SKIP] 平台无带内 IPMI（缺 ipmitool 或 /dev/ipmi0）—— 平台固有，不计 WARN"
    fi
fi

# ── NTP 还原（无条件恢复到原值；旧实现只停不还原）──
if [ "$_ntp_orig" = "yes" ] || [ "$_ntp_orig" = "no" ]; then
    if __SUDO__timedatectl set-ntp "$_ntp_orig" >/dev/null 2>&1; then
        echo "  [OK]   NTP 已还原为原值: ${_ntp_orig}"
    else
        echo "  [WARN] NTP 还原失败（原值 ${_ntp_orig}，请手工执行 timedatectl set-ntp ${_ntp_orig}）"
    fi
else
    echo "  [WARN] NTP 原值未知（timedatectl 不可用），未做还原"
fi

echo "  目标机新时间: $(date "+%Y-%m-%d %H:%M:%S %Z")  (epoch=$(date +%s))"
exit $(( 1 - _os_ok ))
'

OK=0; FAIL=0
for HOST in "${HOSTS[@]}"; do
    echo ""
    echo "── 同步 → ${HOST}"
    # root 免 sudo；普通用户加 sudo 前缀 + -t 供交互输密码
    SUDO_PRE=""
    TTY_OPTS=""
    case "$HOST" in
        root@*) : ;;
        *)      SUDO_PRE="sudo "; TTY_OPTS="-t" ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
        _bmc_mark="dry"
    else
        _bmc_mark="$BMC_MODE"
    fi

    _script=$(printf '%s' "$REMOTE_TPL" \
        | sed -e "s/__EPOCH__/${EPOCH}/g" -e "s/__BMC__/${_bmc_mark}/g" -e "s/__SUDO__/${SUDO_PRE}/g")

    # base64 传参：参数中只有 [A-Za-z0-9+/=]，不被任何层的引号/括号/$ 破坏
    _b64=$(printf '%s' "$_script" | base64 -w0 2>/dev/null || printf '%s' "$_script" | base64 | tr -d '\n')

    if ssh $SSH_OPTS $TTY_OPTS "$HOST" "echo ${_b64} | base64 -d | bash"; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[OK] ${HOST} 已检查（未修改）"
        else
            echo "[OK] ${HOST} OS 时间已同步（RTC/BMC 见上方逐项结果）"
        fi
        OK=$((OK+1))
    else
        echo "[ERROR] ${HOST} 同步失败（OS 系统时间未设置成功）"
        FAIL=$((FAIL+1))
    fi
done

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "完成。本次为 DryRun，未做任何修改（本机时间基准：${LOCAL_HMS}）"
else
    echo "完成。成功 ${OK} 台，失败 ${FAIL} 台（本机时间基准：${LOCAL_HMS}）"
fi
[ "$FAIL" -gt 0 ] && exit 1
exit 0
