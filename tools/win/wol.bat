@echo off
chcp 65001 >nul
rem ============================================
rem  Wake-on-LAN 远程唤醒
rem  用法: wol.bat <MAC> [广播地址]
rem  示例: wol.bat 6c-b1-58-8b-a0-51
rem ============================================
title 远程唤醒 (WoL)
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: wol.bat ^<MAC^> [广播地址]
    echo 示例: wol.bat 6c-b1-58-8b-a0-51
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wol.ps1" -Mac %~1
echo.
pause
