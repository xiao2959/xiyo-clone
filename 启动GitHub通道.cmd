@echo off
chcp 65001 >nul
title 启动 GitHub 通道
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0启动GitHub通道.ps1"
echo.
pause
