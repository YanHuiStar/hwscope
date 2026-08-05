<#
.SYNOPSIS
  在线状态监控 — 定时 ping 服务器列表，宕机时桌面通知
.DESCRIPTION
  循环 ping 目标列表，状态从在线变离线（或反之）时弹 Windows 通知 + 提示音。
  Ctrl+C 停止。可用 schtasks 做成开机自启的常驻监控。
.PARAMETER Hosts
  目标 IP/主机名，逗号分隔
.PARAMETER Interval
  检查间隔秒数（默认 10）
.EXAMPLE
  .\ping_monitor.ps1 -Hosts 192.168.1.1,192.168.1.100
#>
param(
    [Parameter(Mandatory)][string]$Hosts,
    [int]$Interval = 10
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms

$targets = $Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$prev = @{}
foreach ($t in $targets) { $prev[$t] = $null }

function Show-Notify([string]$title, [string]$text) {
    $balloon = New-Object System.Windows.Forms.NotifyIcon
    $balloon.Icon = [System.Drawing.SystemIcons]::Warning
    $balloon.Visible = $true
    $balloon.BalloonTipTitle = $title
    $balloon.BalloonTipText = $text
    $balloon.ShowBalloonTip(8000)
    [System.Media.SystemSounds]::Exclamation.Play()
    Start-Sleep -Seconds 10
    $balloon.Dispose()
}

Write-Host "监控 $($targets -join ', ')  （间隔 ${Interval}s，Ctrl+C 停止）" -ForegroundColor Cyan
try {
    while ($true) {
        foreach ($t in $targets) {
            $up = Test-Connection -ComputerName $t -Count 1 -Quiet -ErrorAction SilentlyContinue
            $ts = Get-Date -Format 'HH:mm:ss'
            if ($null -ne $prev[$t] -and $prev[$t] -ne $up) {
                if ($up) { Write-Host "[$ts] $t 恢复在线" -ForegroundColor Green; Show-Notify '服务器恢复' "$t 已恢复在线" }
                else     { Write-Host "[$ts] $t 宕机！" -ForegroundColor Red;   Show-Notify '服务器宕机' "$t 无法 ping 通" }
            } else {
                $status = if ($up) { '在线' } else { '离线' }
                Write-Host "[$ts] $t  $status" -ForegroundColor $(if ($up) { 'Gray' } else { 'DarkYellow' })
            }
            $prev[$t] = $up
        }
        Start-Sleep -Seconds $Interval
    }
} finally {
    Write-Host "监控已停止" -ForegroundColor Cyan
}
