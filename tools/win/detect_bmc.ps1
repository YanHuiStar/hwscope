<#
.SYNOPSIS
  BMC 识别 — 从 IP 列表里找出哪个是服务器 BMC
.DESCRIPTION
  对候选 IP 做 MAC 厂商前缀匹配 + 端口探测（623=IPMI, 443/80=Web, 5900=noVNC）。
  命中 2 个以上特征 = 高概率 BMC。可配合 scan_ip.ps1 使用。
.PARAMETER Hosts
  候选 IP，逗号分隔（如 192.168.1.1,192.168.1.100）
.PARAMETER Ports
  探测端口（默认 22,80,443,623,5900）
.EXAMPLE
  .\detect_bmc.ps1 -Hosts 192.168.1.1,192.168.1.100,192.168.1.200
#>
param(
    [Parameter(Mandatory)][string]$Hosts,
    [int[]]$Ports = @(22, 80, 443, 623, 5900)
)


# 输出 UTF-8（配合 .bat 的 chcp 65001，也便于管道/重定向）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# ── 常见 BMC 厂商 MAC 前缀（小写，无分隔符） ──
$bmcMacPrefix = @(
    '002590', '001b21', '0cc47a', '003048',   # SuperMicro (AST)
    '000af1', '000347', 'ac162d', 'bccfcc',   # 常见服务器网卡/BMC
    '506b4b', '9803d8', '3ce5a6'              # AST/其他 BMC
)

function Test-Port([string]$ip, [int]$port, [int]$timeoutMs = 800) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ip, $port)
        if ($task.Wait($timeoutMs) -and $client.Connected) { return $true }
    } catch { }
    finally { $client.Close() }
    return $false
}

$arp = @{}
foreach ($line in (arp -a)) {
    if ($line -match '^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-f\-]{17})') { $arp[$matches[1]] = $matches[2] }
}

Write-Host "探测 $((($Hosts -split ',') | Where-Object { $_ }).Count) 个 IP 的端口: $($Ports -join ',')" -ForegroundColor Cyan
$rows = @()
foreach ($ip in ($Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $open = @()
    foreach ($p in $Ports) { if (Test-Port $ip $p) { $open += $p } }
    $mac = if ($arp.ContainsKey($ip)) { $arp[$ip] } else { '-' }
    $macHex = ($mac -replace '[^0-9a-fA-F]', '').ToLower()
    $macHit = ($bmcMacPrefix | Where-Object { $macHex.StartsWith($_) }).Count -gt 0
    # 评分：IPMI(623) +2, Web(80/443) +1, noVNC(5900) +1, MAC 前缀 +2, SSH(22) +1
    $score = 0
    if ($open -contains 623) { $score += 2 }
    if ($open -contains 443 -or $open -contains 80) { $score += 1 }
    if ($open -contains 5900) { $score += 1 }
    if ($macHit) { $score += 2 }
    if ($open -contains 22) { $score += 1 }
    $rows += [PSCustomObject]@{
        IP = $ip; MAC = $mac; 开放端口 = ($open -join ',');
        评分 = $score; 判断 = if ($score -ge 3) { '★ 很可能是 BMC' } elseif ($score -ge 2) { '可能是 BMC' } else { '-' }
    }
}
$rows | Sort-Object 评分 -Descending | Format-Table -AutoSize
