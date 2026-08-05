@echo off
chcp 65001 >nul
rem ============================================
rem  BMC 识别 — 从 IP 列表找出 BMC（MAC 前缀+端口评分）
rem  用法: detect_bmc.bat 192.168.1.1,192.168.1.100
rem ============================================
title BMC 识别
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: detect_bmc.bat ^<IP1,IP2,...^>
    echo 示例: detect_bmc.bat 192.168.1.1,192.168.1.100
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0detect_bmc.ps1" -Hosts "%~1"
echo.
pause
