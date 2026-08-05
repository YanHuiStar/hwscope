@echo off
chcp 65001 >nul
rem ============================================
rem  多机 GPU 巡检（SSH 批量 nvidia-smi）
rem  用法: gpu_status.bat <user@ip1,user@ip2,...>
rem ============================================
title GPU 巡检
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: gpu_status.bat ^<user@ip1,user@ip2,...^>
    echo 示例: gpu_status.bat root@192.168.1.100,root@192.168.1.101
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu_status.ps1" -Hosts "%~1"
echo.
pause
