@echo off
chcp 65001 >nul
rem ============================================
rem  Wi-Fi 保护 — 直连服务器时断开/恢复 Wi-Fi
rem  用法: wifi_guard.bat disable  断开
rem        wifi_guard.bat enable   恢复
rem ============================================
title Wi-Fi 保护
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
    echo 需要管理员权限，正在提升...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"%~f0\" %*' -Verb RunAs"
    exit /b
)
if /i "%~1"=="enable" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wifi_guard.ps1" -Action Enable
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wifi_guard.ps1" -Action Disable
)
echo.
pause
