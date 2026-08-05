@echo off
chcp 65001 >nul
rem ============================================
rem  笔记本 DHCP 服务器 — 直连服务器自动分配 IP
rem  服务器侧运行 net_dhcp.sh 自动获取
rem  用法: dhcp_server.bat [网段]
rem  示例: dhcp_server.bat          (默认 192.168.50.x)
rem        dhcp_server.bat 192.168.1
rem ============================================
title DHCP 服务器
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
    echo 需要管理员权限，正在提升...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"%~f0\" %*' -Verb RunAs"
    exit /b
)
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dhcp_server.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dhcp_server.ps1" -Subnet %~1
)
echo.
pause
