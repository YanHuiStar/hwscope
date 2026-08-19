# =============================================================================
# cleanup.ps1 — 清理 HwScope 采集输出（output/ 与 logs/）Windows 版
# 用法: powershell -ExecutionPolicy Bypass -File cleanup.ps1          # 交互确认
#       powershell -ExecutionPolicy Bypass -File cleanup.ps1 -Force   # 跳过确认
# 安全: 默认显示将删除的目录/大小/文件数，必须输入 yes 才删除；输出目录为采集产物
#       （.gitignore 已排除），不影响项目源码
# =============================================================================
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent (Split-Path -Parent $ScriptRoot)   # tools\win → tools → 项目根

$targets = @((Join-Path $ProjectDir "output"), (Join-Path $ProjectDir "logs"))
$exist = @($targets | Where-Object { Test-Path $_ })

if ($exist.Count -eq 0) {
    Write-Host "[INFO] output/ 与 logs/ 均不存在，无需清理" -ForegroundColor Yellow
    exit 0
}

Write-Host "════ 将清理以下目录 ════" -ForegroundColor Cyan
foreach ($t in $exist) {
    $files = @(Get-ChildItem $t -Recurse -File -ErrorAction SilentlyContinue)
    $size = ($files | Measure-Object Length -Sum).Sum
    if (-not $size) { $size = 0 }
    $sizeStr = if ($size -gt 1GB) { "{0:N1} GB" -f ($size / 1GB) }
              elseif ($size -gt 1MB) { "{0:N1} MB" -f ($size / 1MB) }
              else { "{0:N1} KB" -f ($size / 1KB) }
    Write-Host "  $t  ($sizeStr, $($files.Count) 个文件)"
}

if (-not $Force) {
    $ans = Read-Host "输入 yes 确认删除（其他输入取消）"
    if ($ans -ne "yes" -and $ans -ne "YES") {
        Write-Host "已取消" -ForegroundColor Yellow
        exit 1
    }
}

foreach ($t in $exist) { Remove-Item $t -Recurse -Force }
Write-Host "[OK] 已清理 $($exist.Count) 个目录" -ForegroundColor Green
