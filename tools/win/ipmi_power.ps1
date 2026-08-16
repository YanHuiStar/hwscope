<#
.SYNOPSIS
  BMC 远程电源控制 — 开机/关机/重启/状态查询
.DESCRIPTION
  通过服务器 BMC（IPMI）远程控制电源，不接屏幕也能开机/关机/重启。
  依赖 Windows 版 ipmitool（未安装时自动提示安装命令）。
  密码安全：优先读环境变量 IPMI_PASSWORD，不内嵌 -P 参数（防进程列表泄露）。
.PARAMETER BmcIP
  BMC 管理口 IP（必填，可用 detect_bmc.ps1 确认）
.PARAMETER User
  BMC 用户名（默认 admin）
.PARAMETER Action
  status=查询状态 / on=开机 / off=强制关机 / cycle=重启
.EXAMPLE
  .\ipmi_power.ps1 -BmcIP 192.168.1.1 -Action status
  .\ipmi_power.ps1 -BmcIP 192.168.1.1 -Action on
#>
param(
    [Parameter(Mandatory)][string]$BmcIP,
    [string]$User = 'admin',
    [ValidateSet('status', 'on', 'off', 'cycle')][string]$Action = 'status'
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── 依赖检查 ──
if (-not (Get-Command ipmitool -ErrorAction SilentlyContinue)) {
    Write-Host "未找到 ipmitool。安装方式：" -ForegroundColor Yellow
    Write-Host "  winget install ipmitool        (或下载 ipmitool.exe 放入 PATH)" -ForegroundColor Gray
    Write-Host "  或从 https://ipmitool.github.io/ 获取 Windows 版" -ForegroundColor Gray
    exit 1
}

# ── 密码获取（环境变量优先，其次交互输入，绝不内嵌 -P） ──
$pass = $env:IPMI_PASSWORD
if (-not $pass) {
    $sec = Read-Host "BMC 密码 (${User}@${BmcIP})" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
$env:IPMI_PASSWORD = $pass

$actionDesc = @{ status = '查询电源状态'; on = '开机'; off = '强制关机'; cycle = '重启' }
Write-Host "[BMC] $BmcIP  ${actionDesc[$Action]}..." -ForegroundColor Cyan

# 干净命令：密码走环境变量（-E 读 IPMI_PASSWORD），命令串不含密码
$output = & ipmitool -E -H $BmcIP -U $User -I lanplus power $Action 2>&1
$exitCode = $LASTEXITCODE

if ($exitCode -eq 0) {
    Write-Host "OK: $output" -ForegroundColor Green
} else {
    Write-Host "失败 (exit=$exitCode): $output" -ForegroundColor Yellow
    Write-Host "排查: 1) BMC IP 是否正确（detect_bmc.ps1 确认）  2) 用户名密码  3) 网卡 IP 是否与 BMC 同网段" -ForegroundColor Gray
}
exit $exitCode
