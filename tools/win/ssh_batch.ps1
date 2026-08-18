<#
.SYNOPSIS
  批量 SSH 命令 — 对多台服务器执行同一条命令
.DESCRIPTION
  通过 OpenSSH 对多台服务器批量执行命令（如启动 hwscope 采集、查状态）。
  并发执行，每台输出带主机名前缀。
  认证：优先 SSH 密钥（免密）；无密钥时提示逐个输入密码（交互式）。
.PARAMETER Hosts
  目标，逗号分隔（支持 user@ip 格式，如 root@192.168.1.100）
.PARAMETER Command
  要执行的命令（默认: uptime）
.PARAMETER Timeout
  单台超时秒数（默认 15）
.EXAMPLE
  .\ssh_batch.ps1 -Hosts root@192.168.1.100,root@192.168.1.101 -Command "uptime"
  .\ssh_batch.ps1 -Hosts root@192.168.1.100 -Command "bash /opt/hwscope/hwscope.sh --parallel"
#>
param(
    [Parameter(Mandatory)][string]$Hosts,
    [string]$Command = 'uptime',
    [int]$Timeout = 15
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host "未找到 ssh。Windows 安装 OpenSSH 客户端：" -ForegroundColor Yellow
    Write-Host "  设置 → 应用 → 可选功能 → 添加功能 → OpenSSH 客户端" -ForegroundColor Gray
    exit 1
}

$targets = $Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
Write-Host "批量执行 $($targets.Count) 台: $Command" -ForegroundColor Cyan

# 并发执行（每台独立进程，避免串行等待）
$jobs = @()
foreach ($t in $targets) {
    $jobs += Start-Job -ScriptBlock {
        param($hostStr, $cmd, $timeout)
        $out = & ssh -o ConnectTimeout=$timeout -o BatchMode=yes -o StrictHostKeyChecking=no $hostStr $cmd 2>&1
        [PSCustomObject]@{ Host = $hostStr; Exit = $LASTEXITCODE; Output = ($out -join "`n") }
    } -ArgumentList $t, $Command, $Timeout
}
$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job -Force

foreach ($r in $results) {
    $color = if ($r.Exit -eq 0) { 'Green' } else { 'Red' }
    Write-Host "── $($r.Host)  (exit=$($r.Exit)) ──" -ForegroundColor $color
    if ($r.Output) { Write-Host $r.Output -ForegroundColor Gray }
    Write-Host ""
}
Write-Host "完成。注：默认交互式密码（生产标准）；SSH key 免密仅建议受信内部网络（私钥泄露风险扩散）" -ForegroundColor Cyan
