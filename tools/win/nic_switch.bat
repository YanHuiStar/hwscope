@echo off
chcp 65001 >nul
rem ============================================
rem  网卡 IP 一键切换 — 设固定 IP / 恢复 DHCP
rem  用法: nic_switch.bat set    设 192.168.1.100/24
rem        nic_switch.bat restore 恢复原配置
rem ============================================
title 网卡 IP 切换
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
    echo 需要管理员权限，正在提升...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"%~f0\" %*' -Verb RunAs"
    exit /b
)
if /i "%~1"=="restore" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0nic_switch.ps1" -Action Restore
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0nic_switch.ps1" -Action Set -IP 192.168.1.100
)
echo.
pause
