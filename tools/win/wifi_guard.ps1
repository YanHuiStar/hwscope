<#
.SYNOPSIS
  Wi-Fi 保护 — 直连服务器时断开 Wi-Fi，避免路由冲突
.DESCRIPTION
  笔记本同时连着 Wi-Fi 和有线直连服务器时，两条默认路由可能冲突，
  导致流量走错口。直连前先 -Action Disable 关掉 Wi-Fi，完事 -Action Enable 恢复。
.PARAMETER Action
  Disable=禁用无线网卡, Enable=启用（默认 Disable）
.EXAMPLE
  .\wifi_guard.ps1 -Action Disable
  .\wifi_guard.ps1 -Action Enable
#>
param([ValidateSet('Disable', 'Enable')][string]$Action = 'Disable')

# 输出 UTF-8（配合 .bat 的 chcp 65001，也便于管道/重定向）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "需要管理员权限。" -ForegroundColor Yellow; exit 1
}

$wifi = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN|无线' } | Select-Object -First 1
if (-not $wifi) {
    Write-Host "未检测到无线网卡。" -ForegroundColor Yellow; exit 1
}

if ($Action -eq 'Disable') {
    Disable-NetAdapter -Name $wifi.Name -Confirm:$false
    Write-Host "已禁用 Wi-Fi: $($wifi.Name)  （直连完成后用 -Action Enable 恢复）" -ForegroundColor Green
} else {
    Enable-NetAdapter -Name $wifi.Name -Confirm:$false
    Write-Host "已启用 Wi-Fi: $($wifi.Name)" -ForegroundColor Green
}
