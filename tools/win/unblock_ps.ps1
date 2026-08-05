<#
.SYNOPSIS
  解除 PowerShell 脚本运行限制 — 让本目录 .ps1 可直接运行
.DESCRIPTION
  1. 设置当前用户执行策略为 RemoteSigned（本地脚本可运行，远程脚本需签名）
  2. 解除 .ps1 文件的"来自互联网"标记（Unblock-File，防下载文件被阻止运行）
  无需管理员（CurrentUser 范围）。运行后即可直接双击 .ps1 或右键"使用 PowerShell 运行"。
.EXAMPLE
  .\unblock_ps.ps1
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 1. 执行策略（CurrentUser 范围，无需管理员）
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -notin @('RemoteSigned', 'Unrestricted')) {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    Write-Host "[完成] 当前用户执行策略 → $(Get-ExecutionPolicy -Scope CurrentUser)" -ForegroundColor Green
} else {
    Write-Host "[提示] 当前用户执行策略已是 $policy" -ForegroundColor Green
}

# 2. 解除 .ps1 的"来自互联网"标记（下载的文件默认被 Zone.Identifier 阻止）
$files = @(Get-ChildItem -Path $PSScriptRoot -Filter *.ps1 -ErrorAction SilentlyContinue)
$unblocked = 0
foreach ($f in $files) {
    Unblock-File -Path $f.FullName -ErrorAction SilentlyContinue
    $unblocked++
}
Write-Host "[完成] 已解除 $unblocked 个 .ps1 的互联网标记" -ForegroundColor Green

Write-Host ""
Write-Host "现在可以：双击运行 tools/win/ 下的 .bat，或右键 .ps1 选'使用 PowerShell 运行'" -ForegroundColor Cyan
