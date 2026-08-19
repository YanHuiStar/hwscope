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
$ProjectDir = Split-Path -Parent (Split-Path -Parent $ScriptRoot)   # tools\win → tools → 项目根（hwscope.sh 所在）
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $ProjectDir "output" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$TS = Get-Date -Format "yyyyMMddHHmmss"
$RemoteDir = "/tmp/hwscope_remote_$TS"
$RemoteOut = "$RemoteDir/remote_output"
# Windows OpenSSH 不支持 ControlMaster multiplexing（ControlPath=/tmp 无效会报 getsockname failed），
# 故合并 ssh 调用：推送一次、执行一次、回拉一次（共 3 次密码提示，每次认证失败自动重试最多 3 次）
$SSHOpts = "-o ConnectTimeout=10"
# root 用户自动免 sudo（root 登录无需提权）；普通用户 + sudo 步骤需要 tty（-t）才能交互输 sudo 密码
$IsRoot = $H -like "root@*"
$Sudo = if ($NoSudo -or $IsRoot) { "" } else { "sudo" }
$TtyOpt = if ($Sudo) { " -t" } else { "" }

# SSH 认证重试（最多 3 次）：仅对认证/连接类失败重试（输出含 Permission denied/密码错误），其他错误直接返回
# 注意：ForEach-Object 累积捕获 + Out-Host 强制显示——`$out = @( ... | Tee-Object )` 赋值上下文截获管道，
#       Tee-Object -Variable 是覆盖非追加（多行只留最后一行）
function Invoke-SSHRetry {
    param([string]$Desc, [scriptblock]$Action, [int]$MaxTries = 3)
    for ($i = 1; $i -le $MaxTries; $i++) {
        $out = @()
        & $Action 2>&1 | ForEach-Object { $out += $_; $_ } | Out-Host
        $code = $LASTEXITCODE
        if ($code -eq 0) { return 0 }
        $authFail = (($out -join "`n") -match "Permission denied|password.*incorrect|Authentication failed")
        if (-not $authFail -or $i -ge $MaxTries) { return $code }
        Write-Host "[WARN] $Desc 认证失败（密码错误？），重试 $i/$MaxTries ..." -ForegroundColor Yellow
    }
    return $code
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HwScope 远程采集 → $H (Windows)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
    # ─── 1. 本地打包项目（PowerShell 直调 bsdtar；避免 cmd /c 管道引号地狱——cmd 会剥 ssh 命令引号并把 && 当本地分隔符） ───
    Write-Host "[INFO] 打包项目（第 1 次密码提示：scp 推送）..." -ForegroundColor Yellow
    $pushFile = Join-Path $env:TEMP "hwscope_push_$TS.tgz"
    $hwArgs = ""
    if ($Modules) { $hwArgs = " --modules $Modules" }
    & tar czf $pushFile -C $ProjectDir --exclude=output --exclude=logs --exclude=.git --exclude=*.tmp .
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] 本地打包失败" -ForegroundColor Red; exit 1 }

    # ─── 2. scp 推送（认证失败自动重试） ───
    $rc = Invoke-SSHRetry "scp 推送" { & scp $SSHOpts.Split(" ") $pushFile "${H}:${RemoteDir}.tgz" }
    if ($rc -ne 0) { Write-Host "[ERROR] 项目推送失败 (exit=$rc)" -ForegroundColor Red; exit 1 }
    Remove-Item $pushFile -Force -ErrorAction SilentlyContinue

    # ─── 3. ssh 解包 + 远端执行（不传 --output：hwscope.sh 默认输出 <远端>/output/<MACHINE_ID>/，对标本地 output/<SN> 结构；普通用户 + sudo 时带 -t 供 sudo 交互输密码；认证失败自动重试） ───
    Write-Host "[INFO] 远端执行: $Sudo bash hwscope.sh$hwArgs（默认输出 output/<MACHINE_ID>/，第 2 次密码）" -ForegroundColor Yellow
    $rc = Invoke-SSHRetry "远端执行" { & ssh ($SSHOpts + $TtyOpt).Split(" ") $H "mkdir -p $RemoteDir && tar xzf ${RemoteDir}.tgz -C $RemoteDir && rm -f ${RemoteDir}.tgz && cd $RemoteDir && $Sudo bash hwscope.sh$hwArgs" }
    if ($rc -ne 0) { Write-Host "[ERROR] 推送或远端采集失败 (exit=$rc)" -ForegroundColor Red; exit $rc }

    # ─── 4. 回拉结果（-C 切换打包 output/<MACHINE_ID>/ 内容 + logs/；解包到 output\remote_output\ 固定层）+ 顺带清理远端（cmd /c 仅做二进制重定向；远端命令用 ; 连接——cmd 不拆 ;，bash 正常解析） ───
    Write-Host "[INFO] 回拉采集结果 + 归档包 → $OutDir\remote_output\（第 3 次密码）" -ForegroundColor Yellow
    $pullFile = Join-Path $env:TEMP "hwscope_pull_$TS.tgz"
    $rc = Invoke-SSHRetry "回拉" { & cmd /c ("ssh $SSHOpts$TtyOpt $H `"$Sudo tar czf - -C $RemoteDir/output . -C $RemoteDir logs; rm -rf $RemoteDir`" > `"$pullFile`"") }
    if ($rc -ne 0) { Write-Host "[ERROR] 结果回拉失败 (exit=$rc)" -ForegroundColor Red; exit 1 }
    $remoteOutDir = Join-Path $OutDir "remote_output"
    New-Item -ItemType Directory -Force -Path $remoteOutDir | Out-Null
    & tar xzf $pullFile -C $remoteOutDir
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] 回拉数据损坏或为空（远端打包失败？）" -ForegroundColor Red; exit 1 }   # 第二道防线：远端 tar 失败时 pullFile 空/坏
    Remove-Item $pullFile -Force -ErrorAction SilentlyContinue

    # 归档包移到 logs\remote_logs\（与本地采集日志区分；远端 logs/ 解包到了 remote_output\logs）
    $outLogs = Join-Path $remoteOutDir "logs"
    if (Test-Path $outLogs) {
        $remoteLogsDir = Join-Path $ProjectDir "logs\remote_logs"
        New-Item -ItemType Directory -Force -Path $remoteLogsDir | Out-Null
        Get-ChildItem $outLogs -Force | Move-Item -Destination $remoteLogsDir -Force -ErrorAction SilentlyContinue
        Remove-Item $outLogs -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[INFO] 已清理远端临时目录: $RemoteDir" -ForegroundColor Yellow

    # ─── 5. 完成信息（remote_output\<MACHINE_ID>\，取最新） ───
    $pulled = Get-ChildItem $remoteOutDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
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
