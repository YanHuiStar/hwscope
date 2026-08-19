@echo off
chcp 65001 >nul
rem cleanup.bat — 清理 HwScope 采集输出（output/ 与 logs/）Windows 版启动器
rem 用法: cleanup.bat            （输入 yes 确认后删除）
rem       cleanup.bat -Force     （跳过确认）
cd /d "%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1" %*
