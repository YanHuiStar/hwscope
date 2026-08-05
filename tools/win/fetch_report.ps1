<#
.SYNOPSIS
  拉取服务器 hwscope 采集报告 — 一键汇总多台机器的巡检结果
.DESCRIPTION
  SSH 查找每台服务器最新的 hwscope 输出目录，scp 拉取报告三件套
  (json/md/txt) 到本机，按主机名归档。巡检完一键汇总。
  依赖 OpenSSH + 服务器已部署 hwscope。
.PARAMETER Hosts
  目标，逗号分隔（支持 root@192.168.1.100）
.PARAMETER HwscopeDir
  服务器上 hwscope 项目目录（默认 /opt/hwscope）
.PARAMETER DestDir
  本机保存目录（默认 桌面\hwscope_reports\）
.PARAMETER Timeout
  单台超时秒数（默认 15）
.EXAMPLE
  .\fetch_report.ps1 -Hosts root@192.168.1.100,root@192.168.1.101
#>
param(
    [Parameter(Mandatory)][string]$Hosts,
    [string]$HwscopeDir = '/opt/hwscope',
    [string]$DestDir = '',
    [int]$Timeout = 15
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $DestDir) { $DestDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'hwscope_reports' }
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Write-Host "未找到 scp。Windows 安装 OpenSSH 客户端：" -ForegroundColor Yellow
    exit 1
}

$targets = $Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
Write-Host "拉取报告到: $DestDir" -ForegroundColor Cyan

foreach ($t in $targets) {
    $hostShort = ($t -split '@')[-1]
    # 找服务器上最新输出目录
    $find = "ls -dt ${HwscopeDir}/output/*/ 2>/dev/null | head -1"
    $latestDir = (& ssh -o ConnectTimeout=$Timeout -o BatchMode=yes -o StrictHostKeyChecking=no $t $find 2>&1 | Out-String).Trim()
    if (-not $latestDir -or $latestDir -match 'No such|connect|refused|denied') {
        Write-Host "✗ $hostShort  无法定位输出目录: $latestDir" -ForegroundColor Red
        continue
    }
    $subDir = Join-Path $DestDir $hostShort
    New-Item -ItemType Directory -Force -Path $subDir | Out-Null
    # 拉三件套（存在才拉）
    foreach ($ext in 'json', 'md', 'txt') {
        & scp -o ConnectTimeout=$Timeout -o BatchMode=yes -o StrictHostKeyChecking=no "$t`:$latestDir/hwscope_report.$ext" (Join-Path $subDir "hwscope_report.$ext") 2>$null
    }
    $files = @(Get-ChildItem $subDir -Filter 'hwscope_report.*' -ErrorAction SilentlyContinue)
    if ($files.Count -gt 0) {
        Write-Host "✓ $hostShort  → $subDir  ($($files.Count) 个文件)" -ForegroundColor Green
    } else {
        Write-Host "✗ $hostShort  未拉到报告（服务器可能未跑过采集）" -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "汇总目录: $DestDir" -ForegroundColor Cyan
