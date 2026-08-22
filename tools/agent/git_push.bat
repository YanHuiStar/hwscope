@echo off
chcp 65001 >nul
rem ============================================================================
rem git_push.bat - HwScope one-click git push (Windows launcher)
rem Usage: double-click, or pass args:
rem   git_push.bat            (review + push, interactive confirm)
rem   git_push.bat -y         (skip confirm)
rem   git_push.bat --fetch    (fetch first, detect behind)
rem   git_push.bat --dry-run  (review only, no push)
rem Deps: Git for Windows (git-bash). Locates bash.exe automatically.
rem NOTE: keep this file pure ASCII - Chinese output comes from git_push.sh.
rem ============================================================================

set "BASH="
rem v1.40.4: 优先 Git Bash 具体路径——`where bash` 在装有 WSL 的机器会命中 System32\bash.exe
rem （WSL bash），bat 调回 WSL 侧触发 git_push.sh 转交 → 无限递归；Git Bash 路径优先可避免
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH where bash >nul 2>nul && set "BASH=bash"
if not defined BASH (
    echo [ERROR] git-bash not found. Install Git for Windows: https://git-scm.com/download/win
    pause
    exit /b 1
)

rem cd to project root (tools\agent\..\..) and run core script
cd /d "%~dp0..\.."
"%BASH%" -lc "bash tools/agent/git_push.sh %*"

rem skip pause when invoked by agent/WSL (GIT_PUSH_NO_PAUSE=1) or stdin not interactive
if "%GIT_PUSH_NO_PAUSE%"=="1" goto :done
echo.
pause
:done
exit /b %ERRORLEVEL%
