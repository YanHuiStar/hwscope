@echo off
chcp 65001 >nul
rem ============================================
rem  BMC detection - find BMC from IP list (MAC prefix + port scoring)
rem  Usage: detect_bmc.bat 192.168.1.1,192.168.1.100
rem ============================================
title BMC Detection
cd /d "%~dp0"
if "%~1"=="" (
    echo Usage: detect_bmc.bat ^<IP1,IP2,...^>
    echo Example: detect_bmc.bat 192.168.1.1,192.168.1.100
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0detect_bmc.ps1" -Hosts "%~1"
echo.
pause
