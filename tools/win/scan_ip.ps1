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
.PARAMETER Ports
  端口探测列表（默认 22,80,443,623,5900）。
    22    SSH（Linux 主机 / 服务器 OS）
    443/80  Web 管理界面（BMC / 交换机 / 存储）
    623   IPMI（带外 BMC 的标志性端口；标准为 UDP，这里用 TCP 连接仅探"该 IP 是否在 623 上有监听/拒绝行为"，不能作为 BMC 的充分证据）
    5900  VNC/KVM 远程控制台
    用 -NoPortScan 关闭端口探测（退回纯 ping 扫描，更快）
.PARAMETER PortTimeout
  单端口连接超时毫秒（默认 600）。内网直连可降到 300 提速。
.PARAMETER Csv
  额外导出 CSV（IP,MAC,TTL,端口,类型），便于盘点留档
.EXAMPLE
  .\scan_ip.ps1                     # 扫本机有线网卡网段（含端口识别）
  .\scan_ip.ps1 -Subnet 192.168.1   # 扫指定网段
  .\scan_ip.ps1 -Subnet 192.168.0 -Range 100-200
  .\scan_ip.ps1 -NoPortScan         # 只找在线主机（快）
  .\scan_ip.ps1 -Subnet 192.168.22 -Csv .\scan.csv
#>
param(
    [string]$Subnet = "",
    [string]$Range = "1-254",
    [string]$Ports = "22,80,443,623,5900",
    [switch]$NoPortScan,
    [int]$PortTimeout = 600,
    [string]$Csv = ""
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
# v1.49.22：原来 `$Subnet.TrimEnd('.').TrimEnd('/24')` —— TrimEnd 的参数是**字符集**（'/', '2', '4'），
#   会把网段尾部的 2/4 一起削掉：192.168.2 → 192.168.、192.168.12 → 192.168.1、192.168.4 → 192.168.（实测）。
#   自动检测路径直接取网卡 IP，于是 192.168.2.x 主机会被扫成 192.168..1，SendPingAsync 对非法 IP 静默返回空
#   → 工具安静地报"在线主机 0 个"。改为先剥 /NN 后缀，再 TrimEnd('.')。
if ($Subnet -match '^(.*)/\d+$') { $Subnet = $Matches[1] }
$s = $Subnet.TrimEnd('.')
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

# ── 端口探测（识别 SSH / BMC Web / IPMI / KVM）──
#   为什么放在这里：ping 只能证明"活着"，分不清是服务器 OS、BMC 管理口还是交换机。
#   端口才是判据：22=SSH、443/80=Web 管理、623=IPMI、5900=KVM。
#   实现要点：先把所有 (IP,端口) 的 ConnectAsync 全部发起（异步并行），再统一按**全局截止时间**
#   等待——逐个 host 串行连接会让 254 个 IP 各等 600ms，扫一轮要几分钟。
$openPorts = @{}
$portList = @()
if (-not $NoPortScan) {
    $portList = @($Ports -split '[, ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique)
}
if ($portList.Count -gt 0 -and $alive.Count -gt 0) {
    Write-Host "探测端口 $($portList -join ',')（超时 ${PortTimeout}ms）..." -ForegroundColor Cyan
    $conns = New-Object System.Collections.ArrayList
    foreach ($ip in $alive.Keys) {
        foreach ($pt in $portList) {
            $c = New-Object System.Net.Sockets.TcpClient
            try {
                $t = $c.ConnectAsync($ip, $pt)
                [void]$conns.Add([PSCustomObject]@{ IP = $ip; Port = $pt; Client = $c; Task = $t })
            } catch {
                try { $c.Close() } catch { }
            }
        }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($PortTimeout)
    foreach ($cn in $conns) {
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -lt 1) { $left = 1 }
        $ok = $false
        try { $ok = ($cn.Task.Wait($left) -and $cn.Client.Connected) } catch { $ok = $false }
        if ($ok) {
            if (-not $openPorts.ContainsKey($cn.IP)) { $openPorts[$cn.IP] = @() }
            $openPorts[$cn.IP] += $cn.Port
        }
        try { $cn.Client.Close() } catch { }
    }
}

# 设备类型判定（**只按端口推断，不猜型号**；拿不准就如实写"未确定"）
function Get-DeviceKind {
    param([int[]]$OpenPorts, [int]$Ttl)
    $hasSsh = $OpenPorts -contains 22
    $hasWeb = ($OpenPorts -contains 443) -or ($OpenPorts -contains 80)
    $hasIpmi = $OpenPorts -contains 623
    $hasKvm = $OpenPorts -contains 5900
    if ($hasIpmi -and $hasSsh) { return '服务器（BMC+SSH 同网段）' }
    if ($hasIpmi -and $hasWeb) { return '服务器带外 BMC（Web+623）' }
    if ($hasIpmi) { return 'BMC/IPMI 设备（623）' }
    if ($hasSsh -and $hasWeb) { return '服务器/设备（SSH+Web）' }
    if ($hasSsh) { return 'Linux/Unix 主机（SSH）' }
    if ($hasWeb) { return 'Web 管理设备（80/443）' }
    if ($hasKvm) { return 'KVM/VNC 控制台（5900）' }
    if ($Ttl -gt 128) { return '可能网络设备（仅 ICMP）' }
    return '仅 ICMP（端口被过滤）'
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
    $op = @()
    if ($openPorts.ContainsKey($ip)) { $op = @($openPorts[$ip] | Sort-Object) }
    $portStr = if ($op.Count -gt 0) { ($op -join ' ') } elseif ($portList.Count -gt 0) { '（无）' } else { '—' }
    $kind = if ($portList.Count -gt 0) { Get-DeviceKind -OpenPorts $op -Ttl $ttl } else { $os }
    $results += [PSCustomObject]@{ IP = $ip; MAC = $mac; TTL = $ttl; 端口 = $portStr; 类型 = $kind }
}
$results | Format-Table -AutoSize

# 汇总（按判据分桶，便于快速挑出 BMC 与可 SSH 的主机）
if ($portList.Count -gt 0 -and $results.Count -gt 0) {
    $bmcCount = @($results | Where-Object { $_.端口 -match '(^| )623( |$)' }).Count
    $sshCount = @($results | Where-Object { $_.端口 -match '(^| )22( |$)' }).Count
    $webCount = @($results | Where-Object { $_.端口 -match '(^| )443( |$)' }).Count
    Write-Host ""
    Write-Host ("小结: 带 IPMI/623 $bmcCount 台 ｜ 可 SSH/22 $sshCount 台 ｜ 有 Web/443 $webCount 台") -ForegroundColor Cyan
}

if ($Csv) {
    try {
        $results | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
        Write-Host "已导出: $Csv" -ForegroundColor Green
    } catch {
        Write-Host "CSV 导出失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "提示:" -ForegroundColor Cyan
Write-Host "  1. 在线设备里 TTL 64 + MAC 带常见 BMC 厂商前缀的，很可能是服务器 BMC" -ForegroundColor Gray
Write-Host "  2. 用 .\detect_bmc.ps1 -Hosts 进一步确认哪个是 BMC" -ForegroundColor Gray
Write-Host "  3. 直连时若本机网卡没 IP，先跑 .\nic_switch.ps1 -Action Set 设个同网段 IP" -ForegroundColor Gray
Write-Host "  4. 端口判据: 623 是 IPMI 的标志性端口（BMC 带外）；22 是 SSH；443/80 是 Web 管理" -ForegroundColor Gray
Write-Host "     623 标准走 UDP，本工具用 TCP 连接探测——能连上/被拒绝说明该端口有响应，连不上不代表没有 BMC" -ForegroundColor DarkGray
Write-Host "     要确认 BMC 身份请用 .\detect_bmc.ps1（读 Redfish/IPMI 指纹），端口只是初筛" -ForegroundColor DarkGray
