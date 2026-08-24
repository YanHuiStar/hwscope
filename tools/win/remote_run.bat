@echo off
chcp 65001 >nul
rem ============================================
rem  远程执行（Windows 版）
rem  用法: remote_run.bat <user@ip1,user@ip2,...> [命令]
rem  示例: remote_run.bat root@192.168.1.100 "uptime"
rem  v1.43.0 由 ssh_batch.bat 改名（Linux 对应 tools/remote_run.sh）
rem ============================================
title 远程执行
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: remote_run.bat ^<user@ip1,user@ip2,...^> ["命令"]
    echo 示例: remote_run.bat root@192.168.1.100 "uptime"
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
