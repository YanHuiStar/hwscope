@echo off
chcp 65001 >nul
rem ============================================
rem  SSH time sync (Windows version)
rem  Usage: sync_time.bat <user@ip1,user@ip2,...> [-DryRun] [-Bmc:auto|yes|no]
rem  Example: sync_time.bat root@192.168.1.100
rem           sync_time.bat root@192.168.1.100,root@192.168.1.101 -DryRun
rem           sync_time.bat root@192.168.1.100 -Bmc:yes
rem  Linux equivalent: tools/sync_time.sh
rem  Note: syncs OS time + RTC (+ BMC when -Bmc:yes/auto). OS time is the
rem        pass/fail criterion; RTC/BMC failures are reported as WARN only.
rem ============================================
title SSH Time Sync
cd /d "%~dp0"
if "%~1"=="" (
    echo Usage: sync_time.bat ^<user@ip1,user@ip2,...^> [-DryRun] [-Bmc:auto^|yes^|no]
    echo Example: sync_time.bat root@192.168.1.100
    echo          sync_time.bat root@192.168.1.100,root@192.168.1.101 -DryRun
    echo          sync_time.bat root@192.168.1.100 -Bmc:yes
    echo.
    echo Options:
    echo   -DryRun             only probe and show offsets, change nothing
    echo   -Bmc:auto^|yes^|no   BMC time sync mode (default auto)
    pause
    exit /b 1
)

set "PS1=%~dp0sync_time.ps1"
set "HOSTS=%~1"
set "DRYARG="
set "BMCARG="
if /i "%~2"=="-DryRun"   set "DRYARG=-DryRun"
if /i "%~2"=="-Bmc:yes"  set "BMCARG=-Bmc yes"
if /i "%~2"=="-Bmc:no"   set "BMCARG=-Bmc no"
if /i "%~2"=="-Bmc:auto" set "BMCARG=-Bmc auto"
if /i "%~3"=="-DryRun"   set "DRYARG=-DryRun"
if /i "%~3"=="-Bmc:yes"  set "BMCARG=-Bmc yes"
if /i "%~3"=="-Bmc:no"   set "BMCARG=-Bmc no"
if /i "%~3"=="-Bmc:auto" set "BMCARG=-Bmc auto"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Hosts "%HOSTS%" %DRYARG% %BMCARG%
if errorlevel 1 (
    echo.
    echo [WARN] sync reported failures ^(see output above^)
)
pause
