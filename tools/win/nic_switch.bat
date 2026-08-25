@echo off
chcp 65001 >nul
rem ============================================
rem  NIC IP one-key switch - set static IP / restore DHCP
rem  Usage: nic_switch.bat set        set 192.168.1.100/24
rem         nic_switch.bat restore    restore original config
rem ============================================
title NIC IP Switch
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
    echo Admin rights required, elevating...
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
