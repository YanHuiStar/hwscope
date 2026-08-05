@echo off
chcp 65001 >nul
rem ============================================
rem  IP 扫描 — 网线直连服务器找 BMC/网口 IP
rem  用法: 双击运行（扫本机网段）
rem        或  scan_ip.bat 192.168.1   指定网段
rem ============================================
title IP 扫描
cd /d "%~dp0"
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan_ip.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan_ip.ps1" -Subnet %~1
)
echo.
pause
