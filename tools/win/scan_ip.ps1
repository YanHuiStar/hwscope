<#
.SYNOPSIS
  局域网 IP 扫描 — 网线直连服务器时找 BMC/网口 IP
.DESCRIPTION
  并发 Ping 整个网段 + ARP 表关联 MAC，快速找出在线主机。
  场景：笔记本用网线直连服务器 BMC 管理口或网口，不接屏幕、
  不知道服务器是否设了固定 IP 时，用它扫出网段里所有活着的设备。
  在线设备的 MAC 会出现在 ARP 表，TTL 可辅助判断系统类型。
.PARAMETER Subnet
  扫描网段，如 192.168.1（默认自动取本机有线网卡所在网段）
.PARAMETER Range
  扫描范围，如 1-254（默认 1-254）
.EXAMPLE
  .\scan_ip.ps1                     # 扫本机有线网卡网段
  .\scan_ip.ps1 -Subnet 192.168.1   # 扫指定网段
  .\scan_ip.ps1 -Subnet 192.168.0 -Range 100-200
#>
param(
    [string]$Subnet = "",
    [string]$Range = "1-254"
)

# 输出 UTF-8（配合 .bat 的 chcp 65001，也便于管道/重定向）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"

# ── 自动取网段（优先有线，回退任意 Up 网卡） ──
if (-not $Subnet) {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Virtual|Loopback|Wireless|Wi-?Fi|Bluetooth|蓝牙" } | Select-Object -First 1
    if (-not $adapter) { $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1 }
    $addr = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254*" } | Select-Object -First 1
    if (-not $addr) {
        Write-Host "无法确定本机网段（网卡无有效 IP）。请用 -Subnet 指定，如: .\scan_ip.ps1 -Subnet 192.168.1" -ForegroundColor Yellow
        exit 1
    }
    $Subnet = $addr.IPAddress.Substring(0, $addr.IPAddress.LastIndexOf('.'))
    Write-Host "[网卡] $($adapter.Name)  ($($adapter.InterfaceDescription))" -ForegroundColor Cyan
    Write-Host "[网段] 自动检测: $Subnet.x" -ForegroundColor Cyan
}

# ── 解析网段与范围 ──
$s = $Subnet.TrimEnd('.').TrimEnd('/24')
if ($s -match '/') { $s = ($s -split '/')[0] }
try { $start, $end = ($Range -split '-') | ForEach-Object { [int]$_ } } catch {
    Write-Host "范围格式错误: $Range（应为 1-254）" -ForegroundColor Yellow; exit 1
}
if ($start -lt 1) { $start = 1 }; if ($end -gt 254) { $end = 254 }

Write-Host "扫描 $s.$start - $s.$end ..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ── 并发 Ping（SendPingAsync，254 个约 3-6 秒；每个 IP 独立 Ping 实例，同一实例不允许并发） ──
$tasks = @{}
for ($i = $start; $i -le $end; $i++) {
    $ip = "$s.$i"
    $tasks[$ip] = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($ip, 800)
}
$alive = @{}
foreach ($ip in $tasks.Keys) {
    $reply = $tasks[$ip].Result
    if ($reply.Status -eq 'Success') { $alive[$ip] = $reply }
}
$sw.Stop()

# ── ARP 表关联 MAC ──
$arpMap = @{}
foreach ($line in (arp -a)) {
    if ($line -match '^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-f\-]{17})\s+(\S+)') {
        $arpMap[$matches[1]] = $matches[2]
    }
}

# ── 输出结果 ──
Write-Host ""
Write-Host ("=" * 60)
Write-Host "在线主机 ($($alive.Count) 个，耗时 $($sw.Elapsed.TotalSeconds.ToString('0.0'))s)"
Write-Host ("=" * 60)
$results = @()
foreach ($ip in ($alive.Keys | Sort-Object { [int]($_ -split '\.')[-1] })) {
    $reply = $alive[$ip]
    $ttl = $reply.Options.Ttl
    $os = if ($ttl -le 64) { 'Linux/网络设备' } elseif ($ttl -le 128) { 'Windows' } else { '未知' }
    $mac = if ($arpMap.ContainsKey($ip)) { $arpMap[$ip] } else { '-' }
    $results += [PSCustomObject]@{ IP = $ip; MAC = $mac; TTL = $ttl; 系统 = $os }
}
$results | Format-Table -AutoSize
Write-Host ""
Write-Host "提示:" -ForegroundColor Cyan
Write-Host "  1. 在线设备里 TTL 64 + MAC 带常见 BMC 厂商前缀的，很可能是服务器 BMC" -ForegroundColor Gray
Write-Host "  2. 用 .\detect_bmc.ps1 -Hosts 进一步确认哪个是 BMC" -ForegroundColor Gray
Write-Host "  3. 直连时若本机网卡没 IP，先跑 .\nic_switch.ps1 -Action Set 设个同网段 IP" -ForegroundColor Gray
