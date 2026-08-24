@echo off
chcp 65001 >nul
rem remote_collect.bat — HwScope 远程采集（Windows 版）启动器
rem 用法: remote_collect.bat -H root@10.0.0.1 [--modules gpu,cpu] [-OutDir D:\hwout] [-InstallItems 1,2]
rem 注: 密码交互建议直接 ps1（PowerShell 控制台）运行；bat 为双击便捷入口
cd /d "%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote_collect.ps1" %*
