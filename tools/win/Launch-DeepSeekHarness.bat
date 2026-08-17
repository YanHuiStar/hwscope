@echo off
:: 设置当前 CMD 窗口编码格式为 UTF-8
chcp 65001 >nul

:: 切换至项目内工作区（<项目根>\workspace，脚本在 <项目根>\tools\win\ 下，上溯两级；不存在则创建）
if not exist "%~dp0..\..\workspace" mkdir "%~dp0..\..\workspace"
cd /d "%~dp0..\..\workspace"

title DeepSeek Harness 一键启动器
echo ========================================
echo      DeepSeek Harness 一键启动脚本
echo ========================================
echo.

:: 调用 PowerShell 启动器（智能版：幂等检测 / 自动开浏览器 / 自动定位 dsh）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-DeepSeekHarness.ps1" %*

if errorlevel 1 (
    echo.
    echo [错误] 启动流程异常，请检查上方信息。
    echo.
    pause
)