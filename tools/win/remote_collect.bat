@echo off
chcp 65001 >nul
rem remote_collect.bat - HwScope remote collect launcher (Windows)
rem Usage: remote_collect.bat -H root@10.0.0.1 [--modules gpu,cpu] [-OutDir D:\hwout] [-InstallItems 1,2]
rem Note: for interactive password, prefer running remote_collect.ps1 directly in PowerShell
cd /d "%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote_collect.ps1" %*
