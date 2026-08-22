<#
  Launch-DeepSeekHarness.ps1 — DeepSeek Harness Web GUI 一键启动器
  参照 D:\Program-Script 下各 Launch-*.bat 的风格制作，并做了智能增强：

    * 幂等: 端口已在监听时只打开浏览器，不重复启动服务
    * 单实例: 命名互斥锁防止快速连续启动时拉起多个服务进程
    * 自动: 后台等待服务就绪后自动打开浏览器（不依赖固定延时）
    * 自愈: 自动定位 dsh (PATH -> npx 缓存 -> npx 自动获取)
    * 一致: 从 DeepSeek-Harness 工作目录启动，保证会话存储路径正确

  用法:
    Launch-DeepSeekHarness.bat                 # 正常启动
    Launch-DeepSeekHarness.bat -NoBrowser      # 只启动服务，不打开浏览器
    Launch-DeepSeekHarness.bat -Port 8080      # 自定义端口
    Launch-DeepSeekHarness.bat -DryRun         # 只检查环境，不真正启动
#>
[CmdletBinding()]
param(
    [int]$Port = 3080,
    [switch]$NoBrowser,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# DeepSeek Harness 会话工作目录（会话 JSONL 按此目录归档；项目内 workspace/，已加入 .gitignore 不入库）
# 相对定位：脚本在 <项目根>\tools\agent\ 下，上溯两级即项目根，不依赖本机绝对路径
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Workspace = Join-Path $RepoRoot 'workspace'
if (-not (Test-Path $Workspace)) {
    New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
    Write-Host "[提示] 已创建工作区: $Workspace" -ForegroundColor Green
}
$Url = "http://127.0.0.1:$Port"

# 让中文在控制台正常显示
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Banner {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "     DeepSeek Harness 一键启动器" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-PortListening([int]$p) {
    # 优先用 netstat 检查，部分环境下 Get-NetTCPConnection 不可用
    $line = netstat -ano | Select-String ":$p\s" | Select-String "LISTENING" | Select-Object -First 1
    if ($line) { return $true }
    try {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop
        return [bool]$c
    } catch {
        return $false
    }
}

function Wait-PortReady([int]$p, [int]$timeoutSec = 180) {
    # 轮询等待端口就绪，就绪返回 $true，超时返回 $false
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortListening $p) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Resolve-Dsh {
    # 1) PATH 上的 dsh
    $cmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "[提示] 使用 PATH 中的 dsh: $($cmd.Source)" -ForegroundColor DarkGray
        return @{ Prog = 'dsh'; Args = @('web') }
    }
    # 2) npx 缓存中已安装的 @deepseek-ai/dsh (取最新)
    $bin = Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx\*\node_modules\@deepseek-ai\dsh\lib\bin.js" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($bin) {
        Write-Host "[提示] 使用 npx 缓存中的 dsh: $($bin.FullName)" -ForegroundColor DarkGray
        return @{ Prog = 'node'; Args = @($bin.FullName, 'web') }
    }
    # 3) 都没有则用 npx 自动获取
    Write-Host "[提示] 未找到已安装的 dsh，将使用 npx 自动获取..." -ForegroundColor Yellow
    return @{ Prog = 'npx'; Args = @('--yes', '@deepseek-ai/dsh', 'web') }
}

Write-Banner

# ---- 定位 dsh 命令 (DryRun 也要用到) ----
$dsh = Resolve-Dsh
if (-not $dsh) {
    Write-Host "[错误] 未找到 dsh，请先安装: npm install -g @deepseek-ai/dsh" -ForegroundColor Red
    exit 1
}

# ---- DryRun: 只打印环境信息，不启动任何东西 ----
if ($DryRun) {
    Write-Host "[检查] 环境正常，将执行:" -ForegroundColor Green
    Write-Host "       工作目录 : $Workspace" -ForegroundColor Green
    Write-Host "       启动命令 : $($dsh.Prog) $($dsh.Args -join ' ')" -ForegroundColor Green
    Write-Host "       页面地址 : $Url" -ForegroundColor Green
    if (Test-PortListening $Port) {
        Write-Host "       当前状态 : 端口 $Port 已有服务在运行" -ForegroundColor Yellow
    } else {
        Write-Host "       当前状态 : 端口 $Port 空闲，将启动新服务" -ForegroundColor Green
    }
    Write-Host ""
    exit 0
}

# ---- 已运行则直接打开浏览器 ----
if (Test-PortListening $Port) {
    Write-Host "[提示] 检测到端口 $Port 已有 DeepSeek Harness 在运行，无需重复启动。" -ForegroundColor Green
    if (-not $NoBrowser) {
        Write-Host "[提示] 正在打开浏览器: $Url" -ForegroundColor Green
        Start-Process $Url
    }
    Write-Host ""
    exit 0
}

# ---- 单实例互斥锁：防止连续启动时拉起多个服务 ----
$mutexName = "Local\DSH-Launch-$Port"
$mutex = $null
$mutexOwned = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        $mutexOwned = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # 上一个实例异常退出（如被强杀），锁已自动移交给我们
        $mutexOwned = $true
    }
} catch {
    $mutexOwned = $false
}

if (-not $mutexOwned) {
    # 另一个启动器实例正在冷启动中：只等待就绪并打开浏览器，不再拉起服务
    Write-Host "[提示] 检测到另一个启动器正在启动服务，本实例只负责等待并打开浏览器。" -ForegroundColor Yellow
    if (-not $NoBrowser) {
        if (Wait-PortReady $Port) {
            Write-Host "[成功] 服务已就绪，打开浏览器: $Url" -ForegroundColor Green
            Start-Process $Url
        } else {
            Write-Host "[警告] 等待超时，端口 $Port 未就绪。" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    exit 0
}

# ---- 本实例获得启动权 ----
try {
    # 获锁后再复查一次（极小的竞态窗口内可能已被其他进程占用）
    if (Test-PortListening $Port) {
        Write-Host "[提示] 端口 $Port 已被占用（可能是其他进程），直接打开浏览器。" -ForegroundColor Green
        if (-not $NoBrowser) {
            Start-Process $Url
        }
        Write-Host ""
        exit 0
    }

    # ---- 后台等待端口就绪后自动打开浏览器 ----
    $job = $null
    if (-not $NoBrowser) {
        $job = Start-Job -ScriptBlock {
            param($url, $port)
            $deadline = (Get-Date).AddSeconds(180)
            while ((Get-Date) -lt $deadline) {
                $ok = $false
                $line = netstat -ano | Select-String ":$port\s" | Select-String "LISTENING" | Select-Object -First 1
                if ($line) { $ok = $true }
                if (-not $ok) {
                    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
                    if ($c) { $ok = $true }
                }
                if ($ok) {
                    try { Start-Process $url } catch {}
                    break
                }
                Start-Sleep -Seconds 2
            }
        } -ArgumentList $Url, $Port
    }

    # ---- 前台启动服务 (Ctrl+C 可停止) ----
    Write-Host "[提示] 正在启动 DeepSeek Harness 服务..." -ForegroundColor Cyan
    Write-Host "[警告] 请勿关闭此窗口！如需停止服务，请按 Ctrl+C。" -ForegroundColor Yellow
    Write-Host "[提示] 浏览器将自动打开: $Url" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    Set-Location $Workspace
    $prog = $dsh.Prog
    $progArgs = $dsh.Args
    & $prog @progArgs @args

    Write-Host ""
    Write-Host "DeepSeek Harness 服务已退出。" -ForegroundColor Cyan
    Read-Host "按回车键关闭窗口"
} finally {
    if ($job) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    if ($mutex -and $mutexOwned) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
