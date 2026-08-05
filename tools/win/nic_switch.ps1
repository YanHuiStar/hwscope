<#
.SYNOPSIS
  网卡 IP 一键切换 — 直连服务器前设固定 IP，扫完恢复 DHCP
.DESCRIPTION
  场景：笔记本网线直连服务器 BMC/网口，本机网卡需要设一个同网段的
  固定 IP 才能通信。跑完想恢复 DHCP 时再执行 -Action Restore。
  原配置（DHCP/静态）会记录，Restore 时还原。
.PARAMETER Action
  Set=设静态 IP, Restore=恢复 DHCP（默认 Set）
.PARAMETER AdapterName
  网卡名（默认自动选第一个有线 Up 网卡）
.PARAMETER IP
  要设置的 IP（如 192.168.1.100）
.PARAMETER Prefix
  前缀长度（默认 24 = 255.255.255.0）
.PARAMETER Gateway
  网关（可选，如 192.168.1.1）
.EXAMPLE
  .\nic_switch.ps1 -Action Set -IP 192.168.1.100
  .\nic_switch.ps1 -Action Restore
#>
param(
    [ValidateSet('Set', 'Restore')][string]$Action = 'Set',
    [string]$AdapterName = '',
    [string]$IP = '192.168.1.100',
    [int]$Prefix = 24,
    [string]$Gateway = ''
)


# 输出 UTF-8（配合 .bat 的 chcp 65001，也便于管道/重定向）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# ── 需要管理员权限（改网卡配置） ──
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "需要管理员权限。请右键"以管理员身份运行"，或从管理员 PowerShell 执行。" -ForegroundColor Yellow
    exit 1
}

# ── 选网卡：优先自动识别"插着网线"的那块（MediaConnectionState=Connected） ──
$adapter = $null
if ($AdapterName) {
    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
} else {
    $candidates = @(Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'Virtual|Loopback|Wireless|Wi-?Fi|Bluetooth|蓝牙'
    })
    $plugged = @($candidates | Where-Object { $_.MediaConnectionState -eq 'Connected' })
    if ($plugged.Count -eq 1) {
        $adapter = $plugged[0]
        Write-Host "[识别] 检测到插线网卡: $($adapter.Name)" -ForegroundColor Cyan
    } elseif ($plugged.Count -gt 1) {
        Write-Host "检测到多块插线网卡，请选择（对应实际连服务器网线的网卡）:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $plugged.Count; $i++) {
            Write-Host "  [$($i+1)] $($plugged[$i].Name)  ($($plugged[$i].InterfaceDescription))"
        }
        $sel = Read-Host "选择 (1-$($plugged.Count))"
        $adapter = $plugged[[int]$sel - 1]
    } elseif ($candidates.Count -eq 1) {
        $adapter = $candidates[0]
        Write-Host "[提示] 没有检测到插线网卡，使用唯一有线网卡: $($adapter.Name)" -ForegroundColor Yellow
    } else {
        Write-Host "找不到可用有线网卡。请确认：1) 网线已插入 2) 网卡已启用" -ForegroundColor Yellow
        exit 1
    }
}
if (-not $adapter) {
    Write-Host "找不到可用有线网卡。" -ForegroundColor Yellow; exit 1
}
Write-Host "[网卡] $($adapter.Name) ($($adapter.InterfaceDescription))" -ForegroundColor Cyan

# ── 原配置记录（存到脚本同目录） ──
$stateFile = Join-Path $PSScriptRoot 'nic_switch_state.txt'

if ($Action -eq 'Set') {
    $ipcfg = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $wasDhcp = (Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).Dhcp -eq 'Enabled'
    # 记录原状态
    @(
        "adapter=$($adapter.Name)",
        "wasDhcp=$wasDhcp",
        "ip=$($ipcfg.IPAddress)",
        "prefix=$($ipcfg.PrefixLength)",
        "gateway=$(if ($ipcfg) { (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop } else { '' })"
    ) | Set-Content -Path $stateFile -Encoding UTF8

    if ($wasDhcp) {
        # 原 DHCP → 断开 DHCP 设静态
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IP -PrefixLength $Prefix -ErrorAction SilentlyContinue | Out-Null
    } else {
        # 原静态 → 直接改 IP
        Set-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IP -PrefixLength $Prefix -ErrorAction SilentlyContinue
    }
    if ($Gateway) {
        Set-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $Gateway -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "已设置: $($adapter.Name) = $IP/$Prefix  (原配置已记录，恢复用 -Action Restore)" -ForegroundColor Green
} else {
    # Restore
    if (-not (Test-Path $stateFile)) {
        Write-Host "未找到原配置记录（$stateFile），无法恢复。" -ForegroundColor Yellow; exit 1
    }
    $st = @{}
    Get-Content $stateFile | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { $st[$matches[1]] = $matches[2] } }
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
    Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    if ($st['wasDhcp'] -eq 'True') {
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Enabled
        Write-Host "已恢复 DHCP。" -ForegroundColor Green
    } else {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $st['ip'] -PrefixLength $st['prefix'] | Out-Null
        if ($st['gateway']) {
            Set-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $st['gateway'] -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Host "已恢复静态 IP: $($st['ip'])" -ForegroundColor Green
    }
    Remove-Item $stateFile -ErrorAction SilentlyContinue
}
