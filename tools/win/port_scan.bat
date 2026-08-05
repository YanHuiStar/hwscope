@echo off
chcp 65001 >nul
rem ============================================
rem  端口探测 — 对 IP 探测常用端口
rem  用法: port_scan.bat 192.168.1.1,192.168.1.100
rem ============================================
title 端口探测
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: port_scan.bat ^<IP1,IP2,...^>
    echo 示例: port_scan.bat 192.168.1.1
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0port_scan.ps1" -Hosts "%~1"
echo.
pause
