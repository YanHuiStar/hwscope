@echo off
chcp 65001 >nul
rem ============================================
rem  IP scan - find BMC/NIC IP on direct-attached servers
rem  Usage: double-click (scan local subnet, with port probe)
rem         scan_ip.bat 192.168.1            specify subnet
rem         scan_ip.bat 192.168.1 -NoPortScan   ping only (fast)
rem         scan_ip.bat 192.168.22 -Csv scan.csv
rem  All arguments are passed through to scan_ip.ps1 (%*).
rem ============================================
title IP Scan
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan_ip.ps1" %*
echo.
pause
