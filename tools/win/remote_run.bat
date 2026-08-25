@echo off
chcp 65001 >nul
rem ============================================
rem  Remote exec (Windows version)
rem  Usage: remote_run.bat <user@ip1,user@ip2,...> [command]
rem  Example: remote_run.bat root@192.168.1.100 "uptime"
rem  v1.43.0 renamed from ssh_batch.bat (Linux: tools/remote_run.sh)
rem ============================================
title Remote Exec
cd /d "%~dp0"
if "%~1"=="" (
    echo Usage: remote_run.bat ^<user@ip1,user@ip2,...^> ["command"]
    echo Example: remote_run.bat root@192.168.1.100 "uptime"
    pause
    exit /b 1
)
if "%~2"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote_run.ps1" -Hosts "%~1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote_run.ps1" -Hosts "%~1" -Command "%~2"
)
echo.
pause
