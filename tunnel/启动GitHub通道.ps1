# 启动 GitHub 通道（SSH 隧道走香港 VPS）
#
# 作用：国内直连 GitHub 的 HTTPS 会被掐（TCP 通、TLS 断），
#       这里用已经在通的 SSH(22) 建一个 SOCKS 隧道，让 git 和浏览器借道香港。

$ErrorActionPreference = "Continue"
$root = Split-Path $PSScriptRoot -Parent
$key  = Join-Path $root "tools\deploy_key"
$ssh  = "C:\Program Files\Git\usr\bin\ssh.exe"
$port = 1080

function Say($t) { Write-Host $t -ForegroundColor Cyan }
function Ok($t)  { Write-Host $t -ForegroundColor Green }
function Bad($t) { Write-Host $t -ForegroundColor Red }

Say "检查隧道状态..."

$listening = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue

if (-not $listening) {
    if (-not (Test-Path $ssh)) { Bad "找不到 ssh.exe"; exit 1 }
    if (-not (Test-Path $key)) { Bad "找不到部署密钥 $key"; exit 1 }

    Say "启动 SSH SOCKS 隧道 127.0.0.1:$port -> 103.119.2.243 (HK)..."
    Start-Process -FilePath $ssh -ArgumentList @(
        "-i", "`"$key`"", "-N", "-D", "$port",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-o", "ServerAliveInterval=30",
        "-o", "ExitOnForwardFailure=yes",
        "root@103.119.2.243"
    ) -WindowStyle Hidden

    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue) { break }
    }
}

if (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Bad "隧道没起来。检查：能不能 SSH 到 103.119.2.243"
    exit 1
}
Ok "隧道就绪：127.0.0.1:$port"

# git 走这条代理（只影响 github.com）
& "C:\Program Files\Git\cmd\git.exe" config --global http.https://github.com.proxy "socks5h://127.0.0.1:$port"
Ok "git 已配置 github.com -> socks5h://127.0.0.1:$port"

# 实测
Say "测试 GitHub 连通性..."
$code = & curl.exe -s -o NUL -w "%{http_code}" -m 20 --socks5-hostname "127.0.0.1:$port" https://api.github.com
if ($code -eq "200") { Ok "api.github.com -> 200（通）" }
else { Bad "api.github.com -> $code（不通）" }

Say ""
Say "接下来："
Say "  1. 用下面这个专用 Edge 打开 GitHub（已带代理）"
Say "  2. 登录后建仓库，然后回来双击「推送.cmd」"
Write-Host ""

$open = Read-Host "现在打开 GitHub 建仓库页面？(y/n)"
if ($open -ne "n") {
    $edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
    if (Test-Path $edge) {
        Start-Process $edge -ArgumentList @(
            "--proxy-server=`"socks5://127.0.0.1:$port`"",
            "--user-data-dir=`"$env:TEMP\edge-github-profile`"",
            "--no-first-run",
            "https://github.com/new"
        )
        Ok "已用代理模式打开 Edge（独立配置目录，不影响你平时的浏览器）"
    } else {
        Bad "找不到 Edge，请手动在浏览器里设置 SOCKS5 代理 127.0.0.1:$port"
    }
}
