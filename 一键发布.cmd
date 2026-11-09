@echo off
chcp 65001 >nul
title 一键发布到 GitHub
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tunnel\一键发布.ps1"
echo.
pause
