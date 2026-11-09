@echo off
chcp 65001 >nul
rem 用带 SOCKS 代理的 Edge 打开一个 URL（给 gh 当 BROWSER 用）
set "EDGE=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=C:\Program Files\Microsoft\Edge\Application\msedge.exe"
start "" "%EDGE%" --proxy-server="socks5://127.0.0.1:1080" --user-data-dir="%TEMP%\edge-github-profile" --no-first-run %1
