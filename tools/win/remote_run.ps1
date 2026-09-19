<#
.SYNOPSIS
  远程执行 — 对多台服务器执行同一命令（Windows 版；Linux 对应 tools/remote_run.sh）
.DESCRIPTION
  通过 OpenSSH 对多台服务器批量执行命令（如启动 hwscope 采集、查状态）。
  并发执行，每台输出带主机名前缀。
  认证：默认交互式密码（每次登录输入，不落盘）——生产环境标准做法；SSH key 免密仅建议受信内部网络
  （私钥泄露=所有配置了公钥的主机失守，风险扩散）。
  v1.43.0 由 ssh_batch.ps1 改名；Linux 版 --script/--pull-logs（脚本执行/日志回拉）Windows 侧为二期。
.PARAMETER Hosts
  目标，逗号分隔（支持 user@ip 格式，如 root@192.168.1.100）
.PARAMETER Command
  要执行的命令（默认: uptime）
.PARAMETER Timeout
  SSH 连接超时秒数（默认 15；对应 ssh -o ConnectTimeout，**不是**每台命令的总时长上限）
.EXAMPLE
  .\remote_run.ps1 -Hosts root@192.168.1.100,root@192.168.1.101 -Command "uptime"
  .\remote_run.ps1 -Hosts root@192.168.1.100 -Command "bash /opt/hwscope/hwscope.sh --parallel"
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
Write-Host "远程执行 $($targets.Count) 台: $Command" -ForegroundColor Cyan

# 并发执行（每台独立进程，避免串行等待）；无 BatchMode——默认交互式密码，有 key 自动走 key 认证
$jobs = @()
foreach ($t in $targets) {
    $jobs += Start-Job -ScriptBlock {
        param($hostStr, $cmd, $timeout)
        $out = & ssh -o ConnectTimeout=$timeout -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR $hostStr $cmd 2>&1
        [PSCustomObject]@{ Host = $hostStr; Exit = $LASTEXITCODE; Output = ($out -join "`n") }
    } -ArgumentList $t, $Command, $Timeout
}
# v1.49.22：**完成一台即输出一台**。原来 `$jobs | Wait-Job | Receive-Job` 会把所有主机的输出攒到
#   全部结束后才一次打印——本工具示例就是分钟级的 `hwscope.sh --parallel`，表现为长时间无输出、
#   被当成卡死（正是 AGENTS v1.48.53「native 输出必须流式」要防的回归；同机 Linux 版 remote_run.sh
#   本来就是逐台输出）。改为 `Wait-Job -Any` 循环，按完成顺序即时打印。
$pending = [System.Collections.ArrayList]::new()
foreach ($j in $jobs) { [void]$pending.Add($j) }
while ($pending.Count -gt 0) {
    $done = Wait-Job -Job $pending -Any
    $r = Receive-Job -Job $done
    [void]$pending.Remove($done)
    Remove-Job -Job $done -Force
    if ($null -ne $r) {
        $color = if ($r.Exit -eq 0) { 'Green' } else { 'Red' }
        Write-Host "── $($r.Host)  (exit=$($r.Exit)) ──" -ForegroundColor $color
        if ($r.Output) { Write-Host $r.Output -ForegroundColor Gray }
        Write-Host ""
    }
}
Write-Host "完成。注：默认交互式密码（生产标准）；SSH key 免密仅建议受信内部网络（私钥泄露风险扩散）" -ForegroundColor Cyan