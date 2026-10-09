<#
.SYNOPSIS
    SSH 时间同步 — 把本机时间同步到目标机（Windows 版；Linux 对应 tools/sync_time.sh）
.DESCRIPTION
    以本机（运维机）时间为基准，通过 OpenSSH 设置目标机系统时间 + 硬件时钟（RTC）。
    用于内网无 NTP、目标机时钟偏差的场景 —— 采集时间戳的可信度依赖时钟。

    同步什么：
      · 系统时钟（date）与硬件时钟（RTC/hwclock）**都写** —— 重启不丢
      · 传递 epoch 秒 = 一个**绝对时刻**（日期 + 时间一起对，不是只对时分秒）
      · **不动目标机时区**：目标机按自身时区显示，但时刻与运维机一致
        （例：运维机 CST 10:00，目标机 UTC → 显示 02:00，两者是同一时刻）
      · 会先停 NTP（timedatectl set-ntp false）防止被立刻改回去

    认证：默认交互式密码（每次输入、不落盘）。Windows OpenSSH 不支持 ControlMaster，
    因此多台需分别认证（Linux 版可复用同一台连接，多台同样要分别输）。
.PARAMETER Hosts
    目标，逗号分隔（支持 user@ip 格式，如 root@192.168.1.100）
.PARAMETER DryRun
    只显示目标机当前时间与相对本机的偏差，不做任何修改（对时前先看一眼很有用）
.PARAMETER Timeout
    SSH 连接超时秒数（默认 10）
.EXAMPLE
    .\sync_time.ps1 -Hosts root@192.168.1.100
    .\sync_time.ps1 -Hosts root@192.168.1.100,root@192.168.1.101 -DryRun
#>
param(
    [Parameter(Mandatory)][string]$Hosts,
    [switch]$DryRun,
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
if ($DryRun) { Write-Host "  [DryRun] 只检查偏差，不做修改" -ForegroundColor Yellow }
Write-Host "============================================" -ForegroundColor Cyan

$okCount = 0; $failCount = 0
foreach ($hostStr in $targets) {
    Write-Host ""
    Write-Host "-- $hostStr" -ForegroundColor Cyan

    $isRoot = $hostStr -match '^root@'
    $pre = ''
    if (-not $isRoot) { $pre = 'sudo ' }
    $ttyArgs = @()
    if (-not $isRoot) { $ttyArgs = @('-t') }   # 普通用户需 tty 才能交互输 sudo 密码

    # 远程命令用单引号拼接构造：PowerShell 不插值，$( ) 交给远端 bash 展开
    $parts = @()
    $parts += '_old=$(date +%s)'
    $parts += 'echo "  目标机当前: $(date ' + "'+%Y-%m-%d %H:%M:%S %Z'" + ')  (epoch=$_old, 与本机差 $((_old - ' + $Epoch + ')) 秒)"'
    if (-not $DryRun) {
        $parts += ($pre + 'timedatectl set-ntp false 2>/dev/null')
        $parts += ($pre + ('date -s @{0}' -f $Epoch) + ' && ' + $pre + 'hwclock -w 2>/dev/null')
        $parts += '_rc=$?'
        $parts += 'echo "  目标机新时间: $(date ' + "'+%Y-%m-%d %H:%M:%S %Z'" + ')"'
        $parts += 'exit $_rc'
    }
    $remoteCmd = $parts -join '; '

    $sshArgs = @('-o', "ConnectTimeout=$Timeout", '-o', 'StrictHostKeyChecking=accept-new', '-o', 'LogLevel=ERROR')
    if ($ttyArgs.Count -gt 0) { $sshArgs += $ttyArgs }
    $sshArgs += $hostStr
    $sshArgs += $remoteCmd

    # 直接调用 ssh 让其输出流式到达（不要 $x = & ssh ... —— 那样会等命令全部结束才显示）
    & ssh @sshArgs
    if ($LASTEXITCODE -eq 0) {
        if ($DryRun) { Write-Host "  [OK] 已检查（未修改）" -ForegroundColor Green }
        else        { Write-Host "  [OK] 时间已同步（与运维机一致）" -ForegroundColor Green }
        $okCount++
    } else {
        Write-Host "  [ERROR] $hostStr 同步失败（退出码 $LASTEXITCODE）" -ForegroundColor Red
        $failCount++
    }
}

Write-Host ""
if ($DryRun) { Write-Host "完成。本次为 DryRun，未做任何修改。" -ForegroundColor Cyan }
else { Write-Host "完成。成功 $okCount 台，失败 $failCount 台（本机时间基准：$LocalHms）" -ForegroundColor Cyan }
if ($failCount -gt 0) { exit 1 }
