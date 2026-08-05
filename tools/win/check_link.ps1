<#
.SYNOPSIS
  物理链路检测 — 网线插上后查看网卡 link 状态与速率
.DESCRIPTION
  场景：网线直连服务器，先确认物理链路 up 且速率正常，
  再扫 IP（link 不通时扫描没意义）。
.PARAMETER AdapterName
  网卡名（默认列出所有有线网卡状态）
.EXAMPLE
  .\check_link.ps1
  .\check_link.ps1 -AdapterName "以太网"
#>
param([string]$AdapterName = '')

# 输出 UTF-8（配合 .bat 的 chcp 65001，也便于管道/重定向）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$adapters = Get-NetAdapter | Where-Object { $_.InterfaceDescription -notmatch 'Virtual|Loopback' }
if ($AdapterName) { $adapters = $adapters | Where-Object { $_.Name -eq $AdapterName } }

if (-not $adapters) { Write-Host "未找到网卡。" -ForegroundColor Yellow; exit 1 }

Write-Host "网卡链路状态:" -ForegroundColor Cyan
$rows = @()
foreach ($a in $adapters) {
    $media = Get-NetAdapter -Name $a.Name | Select-Object MediaConnectionState, LinkSpeed
    $rows += [PSCustomObject]@{
        名称 = $a.Name
        状态 = $a.Status
        链路 = $media.MediaConnectionState
        速率 = $media.LinkSpeed
        描述 = $a.InterfaceDescription
    }
}
$rows | Format-Table -AutoSize
Write-Host ""
Write-Host "说明:" -ForegroundColor Cyan
Write-Host "  链路=Connected + 速率正常（1 Gbps/2.5 Gbps/10 Gbps）→ 物理层 OK，可以扫描 IP" -ForegroundColor Gray
Write-Host "  链路=Disconnected → 检查网线/对端是否上电（服务器 BMC 口通常要开机或待机才有 link）" -ForegroundColor Gray
