@echo off
chcp 65001 >nul
rem ============================================
rem  批量 SSH 命令
rem  用法: ssh_batch.bat <user@ip1,user@ip2,...> [命令]
rem  示例: ssh_batch.bat root@192.168.1.100 "uptime"
rem ============================================
title 批量 SSH
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: ssh_batch.bat ^<user@ip1,user@ip2,...^> ["命令"]
    echo 示例: ssh_batch.bat root@192.168.1.100 "uptime"
    pause
    exit /b 1
)
if "%~2"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh_batch.ps1" -Hosts "%~1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh_batch.ps1" -Hosts "%~1" -Command "%~2"
)
echo.
pause
