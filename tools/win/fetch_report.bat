@echo off
chcp 65001 >nul
rem ============================================
rem  拉取各机 hwscope 采集报告（汇总到桌面）
rem  用法: fetch_report.bat <user@ip1,user@ip2,...>
rem ============================================
title 拉取巡检报告
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: fetch_report.bat ^<user@ip1,user@ip2,...^>
    echo 示例: fetch_report.bat root@192.168.1.100,root@192.168.1.101
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fetch_report.ps1" -Hosts "%~1"
echo.
pause
