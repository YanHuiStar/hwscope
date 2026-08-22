@echo off
chcp 65001 >nul
rem ============================================================================
rem git_push.bat — HwScope 一键推送更新（Windows 启动器）
rem 用法: 双击运行 或 命令行传参:
rem   git_push.bat            （审查并推送，交互确认）
rem   git_push.bat -y         （跳过确认直接推）
rem   git_push.bat --fetch    （先 fetch 检测落后）
rem   git_push.bat --dry-run  （只审查不推送）
rem 依赖: Git for Windows（自带 git-bash）。自动定位 bash.exe。
rem ============================================================================

rem 定位 bash（where 优先，兜底常见安装路径）
set "BASH="
where bash >nul 2>nul && set "BASH=bash"
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH (
    echo [ERROR] 未找到 git-bash（bash.exe）。请安装 Git for Windows: https://git-scm.com/download/win
    pause
    exit /b 1
)

rem 切到项目根（tools\win\..\.. = 项目根），调核心脚本
cd /d "%~dp0..\.."
"%BASH%" -lc "bash tools/git_push.sh %*"

echo.
pause
