@echo off
chcp 65001 >nul
rem ============================================
rem  Laptop DHCP server - auto-assign IP to direct-attached servers
rem  Server side: run net_dhcp.sh to auto-obtain
rem  Usage: dhcp_server.bat [subnet]
rem  Example: dhcp_server.bat          (default 192.168.50.x)
rem           dhcp_server.bat 192.168.1
rem ============================================
title DHCP Server
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
    echo Admin rights required, elevating...
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
