@echo off
chcp 65001 >nul
rem ============================================
rem  解除 PowerShell 脚本运行限制
rem  （设置执行策略 RemoteSigned + 解除下载标记）
rem ============================================
title 解除 PS1 限制
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0unblock_ps.ps1"
echo.
pause
