@echo off
chcp 65001 >nul
rem ============================================
rem  链路检测 — 网卡 link 状态与速率
rem ============================================
title 链路检测
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_link.ps1"
echo.
pause
