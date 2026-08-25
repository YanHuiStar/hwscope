@echo off
chcp 65001 >nul
rem ============================================
rem  Fetch hwscope reports from machines (archive to desktop)
rem  Usage: fetch_report.bat <user@ip1,user@ip2,...>
rem ============================================
title Fetch Reports
cd /d "%~dp0"
if "%~1"=="" (
    echo Usage: fetch_report.bat ^<user@ip1,user@ip2,...^>
    echo Example: fetch_report.bat root@192.168.1.100,root@192.168.1.101
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fetch_report.ps1" -Hosts "%~1"
echo.
pause
