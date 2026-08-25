@echo off
chcp 65001 >nul
rem ============================================
rem  Wake-on-LAN remote wakeup
rem  Usage: wol.bat <MAC> [broadcast address]
rem  Example: wol.bat 6c-b1-58-8b-a0-51
rem ============================================
title Wake-on-LAN
cd /d "%~dp0"
if "%~1"=="" (
    echo Usage: wol.bat ^<MAC^> [broadcast address]
    echo Example: wol.bat 6c-b1-58-8b-a0-51
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wol.ps1" -Mac %~1
echo.
pause
