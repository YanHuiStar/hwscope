@echo off
:: Set console codepage to UTF-8
chcp 65001 >nul

:: Switch to project workspace (<project root>\workspace; script at <project root>\tools\win\, up two levels; create if missing)
if not exist "%~dp0..\..\workspace" mkdir "%~dp0..\..\workspace"
cd /d "%~dp0..\..\workspace"

title DeepSeek Harness Launcher
echo ========================================
echo      DeepSeek Harness Launcher
echo ========================================
echo.

:: Invoke PowerShell launcher (idempotent / auto-open browser / auto-locate dsh)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-DeepSeekHarness.ps1" %*

if errorlevel 1 (
    echo.
    echo [ERROR] Launch failed, check output above.
    echo.
    pause
)
