<#
.SYNOPSIS
  Wake-on-LAN 远程唤醒 — 服务器断电后从 MAC 发魔术包开机
.DESCRIPTION
  向局域网广播发送魔术包（6x FF + 目标 MAC x16），唤醒支持 WoL 的设备。
  服务器网卡需开启 Wake-on-LAN（BIOS/网卡属性，或 BMC 设置）。
  MAC 可用 scan_ip.ps1 扫描获得。
.PARAMETER Mac
  目标 MAC 地址（必填，支持 6c-b1-58-8b-a0-51 或 6CB1588BA051 格式）
.PARAMETER Broadcast
  广播地址（默认 255.255.255.255；跨网段唤醒可指定目标网段广播，如 192.168.1.255）
.PARAMETER Port
  唤醒端口（默认 9；部分设备用 7）
.EXAMPLE
  .\wol.ps1 -Mac 6c-b1-58-8b-a0-51
  .\wol.ps1 -Mac 6CB1588BA051 -Broadcast 192.168.1.255
#>
param(
    [Parameter(Mandatory)][string]$Mac,
    [string]$Broadcast = '255.255.255.255',
    [int]$Port = 9
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── 解析 MAC ──
$hex = ($Mac -replace '[^0-9a-fA-F]', '')
if ($hex.Length -ne 12) {
    Write-Host "MAC 格式错误: $Mac（应为 12 位十六进制，如 6c-b1-58-8b-a0-51）" -ForegroundColor Yellow
    exit 1
}

# ── 构造魔术包：6x FF + MAC x16 ──
$packet = New-Object byte[] (6 + 16 * 6)
for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
for ($i = 0; $i -lt 16; $i++) {
    for ($j = 0; $j -lt 6; $j++) {
        $packet[6 + $i * 6 + $j] = [Convert]::ToByte($hex.Substring($j * 2, 2), 16)
    }
}

$udp = New-Object System.Net.Sockets.UdpClient
$udp.EnableBroadcast = $true
try {
    $udp.Send($packet, $packet.Length, $Broadcast, $Port) | Out-Null
    Write-Host "已发送唤醒包: MAC=$Mac → ${Broadcast}:${Port}" -ForegroundColor Green
    Write-Host "等待 30-60 秒后服务器应开始启动（可用 scan_ip.ps1 确认在线）" -ForegroundColor Gray
} catch {
    Write-Host "发送失败: $_" -ForegroundColor Yellow
    exit 1
} finally {
    $udp.Close()
}
