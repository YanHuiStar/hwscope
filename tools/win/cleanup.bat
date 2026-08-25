@echo off
chcp 65001 >nul
rem cleanup.bat - clean HwScope collection output (output/ and logs/) Windows launcher
rem Usage: cleanup.bat            (input yes to confirm deletion)
rem        cleanup.bat -Force     (skip confirmation)
cd /d "%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1" %*
