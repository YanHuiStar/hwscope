@echo off
chcp 65001 >nul
rem ============================================
rem  BMC 远程电源控制（开机/关机/重启/状态）
rem  用法: ipmi_power.bat <BMC_IP> [status|on|off|cycle]
rem  示例: ipmi_power.bat 192.168.1.1 on
rem        密码优先用环境变量 IPMI_PASSWORD，否则交互输入
rem ============================================
title BMC 电源控制
cd /d "%~dp0"
if "%~1"=="" (
    echo 用法: ipmi_power.bat ^<BMC_IP^> [status^|on^|off^|cycle]
    echo 示例: ipmi_power.bat 192.168.1.1 on
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ipmi_power.ps1" -BmcIP %~1 -Action %~2
echo.
pause
