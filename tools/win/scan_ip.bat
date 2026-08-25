@echo off
chcp 65001 >nul
rem ============================================
rem  IP scan - find BMC/NIC IP on direct-attached servers
rem  Usage: double-click (scan local subnet)
rem         or scan_ip.bat 192.168.1   specify subnet
rem ============================================
title IP Scan
cd /d "%~dp0"
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan_ip.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan_ip.ps1" -Subnet %~1
)
echo.
pause
