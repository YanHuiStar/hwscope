@echo off
chcp 65001 >nul
rem ============================================
rem  BMC remote power control (on/off/cycle/status)
rem  Usage: ipmi_power.bat <BMC_IP> [status|on|off|cycle]
rem  Example: ipmi_power.bat 192.168.1.1 on
rem  Password: prefer env IPMI_PASSWORD, else interactive
rem ============================================
title BMC Power Control
cd /d "%~dp0"
if "%~1"=="" (
    echo Usage: ipmi_power.bat ^<BMC_IP^> [status^|on^|off^|cycle]
    echo Example: ipmi_power.bat 192.168.1.1 on
    pause
    exit /b 1
)
rem v1.49.22: action is optional (ps1 default = status). Passing an empty %~2 left
rem "-Action" without a value -> parameter binding error, while this header documents
rem the action as optional and the trailing pause hid the failure (exit 0).
if "%~2"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ipmi_power.ps1" -BmcIP %~1
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ipmi_power.ps1" -BmcIP %~1 -Action %~2
)
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
