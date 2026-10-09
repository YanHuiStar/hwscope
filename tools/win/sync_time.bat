@echo off
chcp 65001 >nul
rem ============================================
rem  SSH time sync (Windows version)
rem  Usage: sync_time.bat <user@ip1,user@ip2,...> [-DryRun]
rem  Example: sync_time.bat root@192.168.1.100
rem           sync_time.bat root@192.168.1.100,root@192.168.1.101 -DryRun
rem  Linux equivalent: tools/sync_time.sh
rem ============================================
title SSH Time Sync
cd /d "%~dp0"
if "%~1"=="" (
    echo Usage: sync_time.bat ^<user@ip1,user@ip2,...^> [-DryRun]
    echo Example: sync_time.bat root@192.168.1.100
    echo          sync_time.bat root@192.168.1.100,root@192.168.1.101 -DryRun
    echo.
    echo Options:
    echo   -DryRun    only show the current offset, change nothing
    pause
    exit /b 1
)
if /i "%~2"=="-DryRun" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_time.ps1" -Hosts "%~1" -DryRun
) else if "%~2"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_time.ps1" -Hosts "%~1"
) else (
    echo Unknown option: %~2
    echo Usage: sync_time.bat ^<user@ip1,user@ip2,...^> [-DryRun]
    exit /b 1
)
pause
