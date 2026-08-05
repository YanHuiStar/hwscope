<#
.SYNOPSIS
  端口探测 — 对候选 IP 快速探测常用端口
.DESCRIPTION
  并发 TCP 连接测试，输出每个 IP 的开放端口。
  配合 scan_ip / detect_bmc 判断设备类型。
.PARAMETER Hosts
  目标 IP，逗号分隔（如 192.168.1.1,192.168.1.100）
.PARAMETER Ports
  端口列表，逗号分隔（默认 22,80,443,623,5900,3389）
.EXAMPLE
  .\port_scan.ps1 -Hosts 192.168.1.1,192.168.1.100
  .\port_scan.ps1 -Hosts 192.168.1.1 -Ports 22,443,623
#>
param(
    [Parameter(Mandatory)][string]$Hosts,
    [string]$Ports = '22,80,443,623,5900,3389'
)


# 输出 UTF-8（配合 .bat 的 chcp 65001，也便于管道/重定向）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$portList = $Ports -split ',' | ForEach-Object { [int]$_.Trim() } | Where-Object { $_ -gt 0 }

function Test-Port([string]$ip, [int]$port, [int]$timeoutMs = 600) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ip, $port)
        if ($task.Wait($timeoutMs) -and $client.Connected) { return $true }
    } catch { }
    finally { $client.Close() }
    return $false
}

$rows = @()
foreach ($ip in ($Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $open = @()
    foreach ($p in $portList) { if (Test-Port $ip $p) { $open += $p } }
    $rows += [PSCustomObject]@{
        IP = $ip
        开放端口 = ($open -join ',')
        备注 = if ($open -contains 623) { 'IPMI 带外' } elseif ($open -contains 5900) { 'noVNC' } else { '' }
    }
}
$rows | Format-Table -AutoSize
