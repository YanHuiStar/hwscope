@echo off
chcp 65001 >nul
rem ============================================
rem  Unblock PowerShell scripts (first-time use)
rem  (set execution policy RemoteSigned + unblock files)
rem ============================================
title Unblock PS1
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0unblock_ps.ps1"
echo.
pause
