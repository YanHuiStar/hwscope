# =============================================================================
# remote_collect.ps1 — Windows 原生远程采集（等价 tools/remote_collect.sh）
# 功能: 从 Windows 运维机 SSH 远程执行 HwScope 采集并回拉结果
#   1. tar 推送项目（排除 output/logs/.git）→ 2. 远端执行 hwscope.sh → 3. 结果回拉 → 4. 清理远端
# 依赖: Windows 自带 OpenSSH 客户端 (ssh/scp) + tar (bsdtar, Win10 1803+)——零新依赖
# 凭据（安全立场）: 默认交互式密码（每次登录输入，不落盘）——生产环境标准做法；
#   SSH key 免密仅建议受信内部网络使用（私钥泄露=所有配置了公钥的主机失守，风险扩散）。
# 用法:
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1 -Modules gpu,cpu
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1 -OutDir D:\hwout
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$H,          # SSH 目标 user@host
    [string]$Modules = "",                             # 可选: gpu,cpu 只采部分
    [string]$OutDir = "",                              # 本地回拉目录（默认脚本同级的 output\）
    [switch]$NoSudo = $false                           # 远端以当前用户执行（默认 sudo）
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ─── 依赖检查（Windows 自带） ───
foreach ($cmd in @("ssh", "scp", "tar")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] 未找到 $cmd。Windows 安装 OpenSSH 客户端：设置 → 应用 → 可选功能 → OpenSSH 客户端" -ForegroundColor Red
        exit 1
    }
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptRoot        # 项目根（tools\win\..）
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $ProjectDir "output" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$TS = Get-Date -Format "yyyyMMddHHmmss"
$RemoteDir = "/tmp/hwscope_remote_$TS"
$RemoteOut = "$RemoteDir/remote_output"
# Windows OpenSSH 不支持 ControlMaster multiplexing（ControlPath=/tmp 无效会报 getsockname failed），
# 故合并 ssh 调用：推送+执行一次、回拉一次（共 2 次密码提示，可接受）
$SSHOpts = "-o ConnectTimeout=10"
$Sudo = if ($NoSudo) { "" } else { "sudo" }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HwScope 远程采集 → $H (Windows)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
    # ─── 1+3. 推送项目 + 远端执行（一次 ssh：stdin 传 tar，远端解包后执行；失败即报错） ───
    Write-Host "[INFO] 推送项目并远端执行（首次提示输密码）..." -ForegroundColor Yellow
    $excludes = @("--exclude=output", "--exclude=logs", "--exclude=.git", "--exclude=*.tmp")
    $hwArgs = ""
    if ($Modules) { $hwArgs = " --modules $Modules" }
    $tarCmd = "tar czf - -C `"$ProjectDir`" $($excludes -join " ") ."
    $sshCmd = "mkdir -p $RemoteDir && tar xzf - -C $RemoteDir && cd $RemoteDir && $Sudo bash hwscope.sh$hwArgs --output $RemoteOut"
    & cmd /c "$tarCmd | ssh $SSHOpts $H `"$sshCmd`""
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] 推送或远端采集失败 (exit=$LASTEXITCODE)" -ForegroundColor Red; exit $LASTEXITCODE }

    # ─── 4. 回拉结果 + 顺带清理远端（一次 ssh：打包 → 本地解包；远端 rm 随命令完成，不再额外要密码） ───
    Write-Host "[INFO] 回拉采集结果 → $OutDir\" -ForegroundColor Yellow
    $pullFile = Join-Path $env:TEMP "hwscope_pull_$TS.tgz"
    $remoteParent = Split-Path -Parent $RemoteOut
    $remoteName = Split-Path -Leaf $RemoteOut
    & cmd /c "ssh $SSHOpts $H `"$Sudo tar czf - -C $remoteParent $remoteName && rm -rf $RemoteDir`" > `"$pullFile`"" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] 结果回拉失败" -ForegroundColor Red; exit 1 }
    & tar xzf $pullFile -C $OutDir
    Remove-Item $pullFile -Force -ErrorAction SilentlyContinue
    Write-Host "[INFO] 已清理远端临时目录: $RemoteDir" -ForegroundColor Yellow

    # ─── 5. 完成信息 ───
    $pulled = Get-ChildItem $OutDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  远程采集完成" -ForegroundColor Green
    Write-Host "  采集目录: $($pulled.FullName)"
    $reports = Get-ChildItem $pulled.FullName -Filter "hwscope_report.*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    if ($reports) { Write-Host "  报告: $($reports -join ' ')" }
    Write-Host "========================================" -ForegroundColor Green
}
finally {
    # 远端清理已在回拉命令内完成（rm -rf 随回拉 ssh 执行）；此处无额外 ssh（避免再要密码）
}
