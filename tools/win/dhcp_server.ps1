<#
.SYNOPSIS
  笔记本 DHCP 服务器 — 网线直连服务器时自动分配 IP
.DESCRIPTION
  场景：笔记本用网线直连服务器（无交换机/无路由器），服务器侧用 hwscope 的
  net_dhcp.sh 配置了"自动获取 IP"。本脚本在笔记本网卡上开一个简易 DHCP 服务，
  给直连的服务器分配 192.168.50.x 网段 IP，实现"插线即通"。
  特性：
    - 零依赖（纯 .NET UDP，实现 DHCP DISCOVER/OFFER/REQUEST/ACK 全流程）
    - 自动识别插线网卡，网卡自动设 192.168.50.1/24
    - 租约管理（MAC → IP，默认 12h）
    - Ctrl+C 停止后自动恢复网卡原配置（DHCP）
  限制：仅支持无中继（giaddr=0）的直连/单交换机场景。
.PARAMETER Subnet
  分配网段前三段（默认 192.168.50：网卡=.1，池=.100-.200）
.PARAMETER LeaseHours
  租约时长（默认 12）
.PARAMETER Port
  监听端口（默认 67；测试/调试可改高位端口）
.PARAMETER NoNIC
  跳过网卡配置（配合 Port 做协议测试）
.PARAMETER TestMode
  测试模式：不要求管理员，OFFER/ACK 回给请求来源而非广播
.EXAMPLE
  .\dhcp_server.ps1                      # 默认 192.168.50.x
  .\dhcp_server.ps1 -Subnet 192.168.1    # 自定义网段
#>
param(
    [string]$Subnet = '192.168.50',
    [int]$LeaseHours = 12,
    [int]$Port = 67,
    [switch]$NoNIC,
    [switch]$TestMode
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$SERVER_IP = "$Subnet.1"
$POOL_START = 100
$POOL_END = 200
$LEASE_SEC = $LeaseHours * 3600

# ── 管理员检查（绑定 67 端口 + 改网卡需要；测试模式跳过） ──
if (-not $TestMode) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "需要管理员权限（监听 UDP 67 + 设置网卡 IP）。请用管理员 PowerShell 运行，或双击 dhcp_server.bat" -ForegroundColor Yellow
        exit 1
    }
}

# ── 选网卡（插线优先，逻辑同 nic_switch.ps1；-NoNIC 跳过） ──
$adapter = $null
if (-not $NoNIC) {
    $candidates = @(Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback|Wireless|Wi-?Fi|Bluetooth|蓝牙'
    })
    $plugged = @($candidates | Where-Object { $_.MediaConnectionState -eq 'Connected' })
    if ($plugged.Count -eq 1) {
        $adapter = $plugged[0]; Write-Host "[网卡] 插线网卡: $($adapter.Name)" -ForegroundColor Cyan
    } elseif ($plugged.Count -gt 1) {
        Write-Host "多块插线网卡，请选择:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $plugged.Count; $i++) { Write-Host "  [$($i+1)] $($plugged[$i].Name)  ($($plugged[$i].InterfaceDescription))" }
        $adapter = $plugged[[int](Read-Host '选择') - 1]
    } elseif ($candidates.Count -eq 1) {
        $adapter = $candidates[0]; Write-Host "[网卡] 唯一有线网卡: $($adapter.Name)" -ForegroundColor Yellow
    } else {
        Write-Host "找不到可用有线网卡。" -ForegroundColor Yellow; exit 1
    }

    # ── 记录网卡原配置并设为静态 IP ──
    $stateFile = Join-Path $PSScriptRoot 'dhcp_server_nic_state.txt'
    $ipcfg = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $wasDhcp = (Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).Dhcp -eq 'Enabled'
    @(
        "adapter=$($adapter.Name)",
        "wasDhcp=$wasDhcp",
        "ip=$($ipcfg.IPAddress)",
        "prefix=$($ipcfg.PrefixLength)"
    ) | Set-Content -Path $stateFile -Encoding UTF8
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
    Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $SERVER_IP -PrefixLength 24 | Out-Null
    Write-Host "[网卡] $($adapter.Name) → $SERVER_IP/24" -ForegroundColor Green
} else {
    Write-Host "[测试模式] 跳过网卡配置" -ForegroundColor Gray
}

# ── DHCP 协议实现 ──
$leases = @{}   # MAC -> @{ IP; Expire }
$poolUsed = @{} # IP -> $true

function Get-FreeIp {
    for ($i = $POOL_START; $i -le $POOL_END; $i++) {
        $ip = "$Subnet.$i"
        if (-not $poolUsed.ContainsKey($ip)) { return $ip }
    }
    return $null
}

function New-DhcpPacket {
    param([byte]$Op, [byte[]]$Xid, [byte[]]$Mac, [byte[]]$Flags, [string]$Yiaddr, [byte]$MsgType)
    $pkt = New-Object byte[] 240
    $pkt[0] = $Op                       # 1=request 2=reply
    $pkt[1] = 1                         # htype Ethernet
    $pkt[2] = 6                         # hlen
    $pkt[3] = 0                         # hops
    [Array]::Copy($Xid, 0, $pkt, 4, 4)  # xid
    $pkt[10] = $Flags[0]; $pkt[11] = $Flags[1]
    if ($Yiaddr) {
        $octets = $Yiaddr -split '\.' | ForEach-Object { [byte]$_ }
        [Array]::Copy($octets, 0, $pkt, 16, 4)
    }
    [Array]::Copy($Mac, 0, $pkt, 28, 6) # chaddr
    $pkt[236] = 0x63; $pkt[237] = 0x82; $pkt[238] = 0x53; $pkt[239] = 0x63

    $opts = New-Object System.Collections.Generic.List[byte]
    $opts.Add(53); $opts.Add(1); $opts.Add($MsgType)
    $opts.Add(54); $opts.Add(4); $opts.AddRange([byte[]]([System.Net.IPAddress]::Parse($SERVER_IP).GetAddressBytes()))
    $opts.Add(1); $opts.Add(4); $opts.AddRange([byte[]]([byte]255,255,255,0))
    $opts.Add(3); $opts.Add(4); $opts.AddRange([byte[]]([System.Net.IPAddress]::Parse($SERVER_IP).GetAddressBytes()))
    $dns = [System.Net.IPAddress]::Parse('223.5.5.5').GetAddressBytes()
    $dns += [System.Net.IPAddress]::Parse('8.8.8.8').GetAddressBytes()
    $opts.Add(6); $opts.Add($dns.Length); $opts.AddRange([byte[]]$dns)
    $leaseBytes = [System.BitConverter]::GetBytes([int]$LEASE_SEC)
    [Array]::Reverse($leaseBytes)       # 网络序（大端）
    $opts.Add(51); $opts.Add(4); $opts.AddRange([byte[]]$leaseBytes)
    $opts.Add(255)
    $pkt = $pkt + $opts.ToArray()
    return ,$pkt
}

Write-Host ""
Write-Host "DHCP 服务器启动:" -ForegroundColor Cyan
Write-Host "  监听    : UDP 0.0.0.0:$Port  ($($adapter.Name))" -ForegroundColor Gray
Write-Host "  服务端  : $SERVER_IP" -ForegroundColor Gray
Write-Host "  分配池  : $Subnet.$POOL_START - $Subnet.$POOL_END  (租约 ${LeaseHours}h)" -ForegroundColor Gray
Write-Host "  服务器侧: 运行 net_dhcp.sh 即可自动获取 IP" -ForegroundColor Gray
Write-Host "  Ctrl+C 停止并恢复网卡配置" -ForegroundColor Yellow
Write-Host ""

$udp = New-Object System.Net.Sockets.UdpClient
try {
    $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $udp.ExclusiveAddressUse = $false
    $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
    $udp.EnableBroadcast = $true

    while ($true) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $udp.Receive([ref]$remote)
        if ($data.Length -lt 240) { continue }

        # ── 解析 BOOTP ──
        if ($data[0] -ne 1) { continue }                       # 只处理 BOOTREQUEST
        $xid = New-Object byte[] 4
        [Array]::Copy($data, 4, $xid, 0, 4)
        $flags = New-Object byte[] 2
        [Array]::Copy($data, 10, $flags, 0, 2)
        $macBytes = New-Object byte[] 6
        [Array]::Copy($data, 28, $macBytes, 0, 6)
        $mac = ($macBytes | ForEach-Object { $_.ToString('x2') }) -join ':'

        # ── 解析 DHCP options（53=msg type, 50=requested IP） ──
        $msgType = 0; $requestedIp = ''
        $i = 240
        while ($i -lt $data.Length - 1) {
            $code = $data[$i]; $i++
            if ($code -eq 0) { continue }
            if ($code -eq 255) { break }
            $len = $data[$i]; $i++
            if ($code -eq 53 -and $len -ge 1) { $msgType = $data[$i] }
            elseif ($code -eq 50 -and $len -ge 4) {
                $requestedIp = "$($data[$i]).$($data[$i+1]).$($data[$i+2]).$($data[$i+3])"
            }
            $i += $len
        }

        $ts = Get-Date -Format 'HH:mm:ss'
        switch ($msgType) {
            1 {  # DISCOVER → OFFER
                $ip = $null
                if ($leases.ContainsKey($mac)) {
                    $existing = $leases[$mac]
                    if ($existing.Expire -gt (Get-Date)) { $ip = $existing.IP }
                }
                if (-not $ip) {
                    $ip = Get-FreeIp
                    if (-not $ip) { Write-Host "[$ts] 池已满，忽略 $mac" -ForegroundColor Yellow; continue }
                    $poolUsed[$ip] = $true
                    $leases[$mac] = @{ IP = $ip; Expire = (Get-Date).AddSeconds($LEASE_SEC) }
                }
                $reply = New-DhcpPacket 2 $xid $macBytes $flags $ip 2
                if ($TestMode) { $udp.Send($reply, $reply.Length, $remote) | Out-Null }
                else { $udp.Send($reply, $reply.Length, [System.Net.IPAddress]::Broadcast, 68) | Out-Null }
                Write-Host "[$ts] DISCOVER $mac → OFFER $ip" -ForegroundColor Green
            }
            3 {  # REQUEST → ACK
                $ip = if ($leases.ContainsKey($mac)) { $leases[$mac].IP } else { '' }
                if (-not $ip) {
                    $ip = Get-FreeIp
                    if (-not $ip) { Write-Host "[$ts] 池已满，忽略 $mac" -ForegroundColor Yellow; continue }
                    $poolUsed[$ip] = $true
                }
                $leases[$mac] = @{ IP = $ip; Expire = (Get-Date).AddSeconds($LEASE_SEC) }
                $reply = New-DhcpPacket 2 $xid $macBytes $flags $ip 5
                if ($TestMode) { $udp.Send($reply, $reply.Length, $remote) | Out-Null }
                else { $udp.Send($reply, $reply.Length, [System.Net.IPAddress]::Broadcast, 68) | Out-Null }
                Write-Host "[$ts] REQUEST $mac → ACK $ip (租约 ${LeaseHours}h)" -ForegroundColor Green
            }
            7 {  # RELEASE
                if ($leases.ContainsKey($mac)) {
                    $poolUsed.Remove($leases[$mac].IP)
                    $leases.Remove($mac)
                    Write-Host "[$ts] RELEASE $mac → 租约释放" -ForegroundColor Gray
                }
            }
        }
    }
} finally {
    $udp.Close()
    Write-Host ""
    Write-Host "DHCP 服务已停止，恢复网卡配置..." -ForegroundColor Cyan
    if (-not $NoNIC -and (Test-Path $stateFile)) {
        $st = @{}
        Get-Content $stateFile | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { $st[$matches[1]] = $matches[2] } }
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
        Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        if ($st['wasDhcp'] -eq 'True') {
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Enabled
            Write-Host "已恢复 DHCP。" -ForegroundColor Green
        } else {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $st['ip'] -PrefixLength $st['prefix'] | Out-Null
            Write-Host "已恢复静态 IP: $($st['ip'])" -ForegroundColor Green
        }
        Remove-Item $stateFile -ErrorAction SilentlyContinue
    }
}
