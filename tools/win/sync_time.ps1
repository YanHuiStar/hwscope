<#
.SYNOPSIS
    SSH 时间同步 — 把本机时间同步到目标机（Windows 版；Linux 对应 tools/sync_time.sh）
.DESCRIPTION
    以本机（运维机）时间为基准，通过 OpenSSH 同步目标机三处时间：

      ① OS 系统时间（date -s）—— **成败只由这一处决定**
      ② RTC 硬件时钟 —— hwclock 优先；缺失则 python3 直写 /dev/rtc0；都无则 WARN
         （Ubuntu 24.04 基础包**不含 hwclock**，在 util-linux-extra 里）
      ③ BMC 时间（-Bmc）—— 用**目标机本地** ipmitool（带内，无需 BMC 凭据/网络）

    为什么 RTC/BMC 失败不算整体失败（v1.53.0 修正）：
      采集时间戳只依赖 OS 系统时间；RTC 只影响"重启后是否还准"，BMC 时间只影响 SEL
      时间轴。旧实现在 `date -s && hwclock -w` 链上取合并退出码，于是目标机缺 hwclock
      时退出码 127，把"OS 已设成功"渲染成 [ERROR] —— 运维据此反复重试、每次都白改。

    实现要点：
      · **远程脚本经 base64 传参**（`echo <b64> | base64 -d | bash`）：参数里只有
        base64 字符，无从被 PowerShell → ssh.exe 的引号处理破坏。旧实现直接把含
        单/双引号与括号的命令当参数传，PowerShell 5.1 重新拼命令行时会吃掉引号，
        远端 bash 收到 `(epoch=...)` 即报 `syntax error near unexpected token '('`。
      · NTP：先记原值，设完**无条件还原**（旧实现只停不还原，把机器留在 NTP off）
      · 不动目标机时区：目标机按自身时区显示，时刻与运维机一致
        （运维机 CST 10:00，目标机 UTC 显示 02:00，两者是同一时刻）

    认证：默认交互式密码（每次输入、不落盘）。Windows OpenSSH 不支持 ControlMaster，
    多台需分别认证。
.PARAMETER Hosts
    目标，逗号分隔（支持 user@ip 格式，如 root@192.168.1.100）
.PARAMETER DryRun
    只显示三处当前值与偏差、并探测目标机工具，不做任何修改（对时前先看一眼）
.PARAMETER Bmc
    BMC 时间同步模式：auto（默认，目标机有 ipmitool + /dev/ipmi0 才做）/ yes / no
.PARAMETER Timeout
    SSH 连接超时秒数（默认 10）
.EXAMPLE
    .\sync_time.ps1 -Hosts root@192.168.1.100
    .\sync_time.ps1 -Hosts root@192.168.1.100,root@192.168.1.101 -DryRun
    .\sync_time.ps1 -Hosts root@192.168.1.100 -Bmc no
#>
param(
    [Parameter(Mandatory)][string]$Hosts,
    [switch]$DryRun,
    [ValidateSet('auto','yes','no')][string]$Bmc = 'auto',
    [int]$Timeout = 10
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host "未找到 ssh。Windows 安装 OpenSSH 客户端：" -ForegroundColor Yellow
    Write-Host "  设置 -> 应用 -> 可选功能 -> 添加功能 -> OpenSSH 客户端" -ForegroundColor Gray
    exit 1
}

$targets = $Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($targets.Count -eq 0) { Write-Host "未提供目标主机（-Hosts user@ip[,user@ip...]）" -ForegroundColor Yellow; exit 1 }

# epoch 基准：取一次，之后所有目标机都对到同一时刻
$Epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$LocalHms = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  本机时间: $LocalHms  (epoch=$Epoch)"
if ($DryRun) { Write-Host "  [DryRun] 只检查偏差与工具，不做修改" -ForegroundColor Yellow }
Write-Host "============================================" -ForegroundColor Cyan

# ─── 远程脚本模板 ───
#   用 **单引号 here-string（@'...'@）**：PowerShell 不做任何插值，$、$( ) 、双引号、
#   括号全部原样进入模板；发送前只替换 __EPOCH__/__BMC__/__SUDO__ 三个占位符。
#   ⚠️ here-string 内不得出现独占一行的 '@（会提前结束）。
$remoteTpl = @'
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
'@

$okCount = 0; $failCount = 0
foreach ($hostStr in $targets) {
    Write-Host ""
    Write-Host "-- $hostStr" -ForegroundColor Cyan

    $isRoot = $hostStr -match '^root@'
    $pre = ''
    $ttyArgs = @()
    if (-not $isRoot) { $pre = 'sudo '; $ttyArgs = @('-t') }   # 普通用户需 tty 才能交互输 sudo 密码

    $bmcMode = if ($DryRun) { 'dry' } else { $Bmc }

    # 替换三个占位符（PS 的 .Replace 是字面替换，不涉及正则）
    $script = $remoteTpl.Replace('__EPOCH__', "$Epoch").Replace('__BMC__', $bmcMode).Replace('__SUDO__', $pre)
    # ⚠️ 必须剔除 CRLF：本 .ps1 在 Windows 上是 CRLF 行尾，here-string(@'...'@) 会把行尾 \r
    #    原样带进模板，base64 编码后远程 bash 每行末尾都多一个 \r —— 后果实测为
    #    `bash: line N: $'\r': command not found`、`set -u\r` 报 usage、`$((a-b\r))` 报
    #    invalid arithmetic operator、续行 `\` 被 \r 破坏后 `syntax error near unexpected token &&`。
    #    （Linux 侧 tools/sync_time.sh 是 LF，故无此问题。）
    $script = $script.Replace("`r`n", "`n").Replace("`r", "")

    # base64 传参：远程只收到 [A-Za-z0-9+/=]，彻底绕开 PowerShell → ssh.exe 的引号处理
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))

    $sshArgs = @('-o', "ConnectTimeout=$Timeout", '-o', 'StrictHostKeyChecking=accept-new', '-o', 'LogLevel=ERROR')
    if ($ttyArgs.Count -gt 0) { $sshArgs += $ttyArgs }
    $sshArgs += $hostStr
    $sshArgs += "echo $b64 | base64 -d | bash"

    # 直接调用 ssh 让其输出流式到达（不要 $x = & ssh ... —— 那样会等命令全部结束才显示）
    & ssh @sshArgs
    if ($LASTEXITCODE -eq 0) {
        if ($DryRun) { Write-Host "[OK] $hostStr 已检查（未修改）" -ForegroundColor Green }
        else        { Write-Host "[OK] $hostStr OS 时间已同步（RTC/BMC 见上方逐项结果）" -ForegroundColor Green }
        $okCount++
    } else {
        Write-Host "[ERROR] $hostStr 同步失败（OS 系统时间未设置成功，退出码 $LASTEXITCODE）" -ForegroundColor Red
        $failCount++
    }
}

Write-Host ""
if ($DryRun) { Write-Host "完成。本次为 DryRun，未做任何修改（本机时间基准：$LocalHms）" -ForegroundColor Cyan }
else { Write-Host "完成。成功 $okCount 台，失败 $failCount 台（本机时间基准：$LocalHms）" -ForegroundColor Cyan }
if ($failCount -gt 0) { exit 1 }
