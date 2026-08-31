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
rem v1.40.4: prefer explicit Git Bash paths - `where bash` on WSL machines hits
rem System32\bash.exe / WindowsApps\bash.exe (both WSL launchers), which call
rem back into WSL and recurse.
rem v1.47.2: the `where bash` fallback now ACCEPTS ONLY paths under a "\Git\"
rem directory (Git Bash installs always live there), so a WSL-only machine
rem prints a clean error instead of recursing into WSL.
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
rem v1.48.21: registry probe for non-standard install paths (e.g. D:\Programming\Git) -
rem Git for Windows always writes HKLM\SOFTWARE\GitForWindows\InstallPath
if not defined BASH for /f "tokens=2*" %%i in ('reg query "HKLM\SOFTWARE\GitForWindows" /v InstallPath 2^>nul') do (
    if exist "%%j\bin\bash.exe" set "BASH=%%j\bin\bash.exe"
)
if not defined BASH (
    for /f "delims=" %%b in ('where bash 2^>nul') do (
        echo %%b | findstr /i /c:"\Git\" >nul 2>nul
        if not errorlevel 1 set "BASH=%%b"
    )
)
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
