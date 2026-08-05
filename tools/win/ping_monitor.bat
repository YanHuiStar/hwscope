@echo off
chcp 65001 >nul
rem ============================================
rem  在线状态监控（宕机弹通知）
rem  用法: ping_monitor.bat <IP1,IP2,...> [间隔秒]
rem  示例: ping_monitor.bat 192.168.1.100,192.168.1.101
rem ============================================
title 在线监控
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: ping_monitor.bat ^<IP1,IP2,...^> [间隔秒]
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ping_monitor.ps1" -Hosts "%~1" -Interval %~2
echo.
pause
