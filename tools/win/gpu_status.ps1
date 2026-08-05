<#
.SYNOPSIS
  多机 GPU 巡检 — SSH 批量拉取 nvidia-smi 摘要
.DESCRIPTION
  对多台服务器并发执行 nvidia-smi 查询（温度/利用率/功耗/显存），
  一次看清整个集群的 GPU 状态。AI 集群日常巡检首选。
  依赖 OpenSSH + 服务器已装 NVIDIA 驱动（nvidia-smi）。
.PARAMETER Hosts
  目标，逗号分隔（支持 root@192.168.1.100）
.PARAMETER Timeout
  单台超时秒数（默认 10）
.EXAMPLE
  .\gpu_status.ps1 -Hosts root@192.168.1.100,root@192.168.1.101
#>
param(
    [Parameter(Mandatory)][string]$Hosts,
    [int]$Timeout = 10
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host "未找到 ssh。Windows 安装 OpenSSH 客户端：" -ForegroundColor Yellow
    Write-Host "  设置 → 应用 → 可选功能 → 添加功能 → OpenSSH 客户端" -ForegroundColor Gray
    exit 1
}

$query = 'nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,power.draw,memory.used --format=csv,noheader 2>/dev/null || echo NO_GPU'
$targets = $Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
Write-Host "GPU 巡检 $($targets.Count) 台..." -ForegroundColor Cyan

$jobs = @()
foreach ($t in $targets) {
    $jobs += Start-Job -ScriptBlock {
        param($hostStr, $q, $timeout)
        $out = & ssh -o ConnectTimeout=$timeout -o BatchMode=yes -o StrictHostKeyChecking=no $hostStr $q 2>&1
        [PSCustomObject]@{ Host = $hostStr; Exit = $LASTEXITCODE; Lines = @($out) }
    } -ArgumentList $t, $query, $Timeout
}
$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job -Force

foreach ($r in $results) {
    $hostShort = ($r.Host -split '@')[-1]
    $lines = @($r.Lines)
    if ($lines.Count -eq 0 -or $lines[0] -match 'NO_GPU|connect|refused|denied') {
        Write-Host "✗ $hostShort  ${lines[0]}" -ForegroundColor Red
        continue
    }
    Write-Host "─ $hostShort ─" -ForegroundColor Cyan
    $header = $false
    foreach ($ln in $lines) {
        if ($ln -match '^\d+\s*,') {
            $f = $ln -split ','
            $idx = $f[0].Trim(); $name = $f[1].Trim(); $temp = $f[2].Trim(); $util = $f[3].Trim(); $pow = $f[4].Trim(); $mem = $f[5].Trim()
            $warn = ($util -replace '[^0-9]', '') -ge 90 -or ($temp -replace '[^0-9]', '') -ge 85
            $mark = if ($warn) { '⚠' } else { ' ' }
            Write-Host ("{0} GPU{1} {2,-20} {3,4}C {4,5}% {5,7}W {6,10}" -f $mark, $idx, $name, $temp, $util, $pow, $mem) -ForegroundColor $(if ($warn) { 'Yellow' } else { 'Gray' })
        }
    }
}
Write-Host ""
Write-Host "提示: 90%+ 利用率或 85C+ 温度标 ⚠；免密需先配 SSH 密钥" -ForegroundColor Cyan
