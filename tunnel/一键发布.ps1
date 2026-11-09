# 一键发布：登录 GitHub -> 建仓库 -> 推代码 -> 触发构建
#
# 全程只需要你做一件事：在浏览器里输入 gh 显示的一次性验证码。

$ErrorActionPreference = "Continue"
$projRoot = Split-Path $PSScriptRoot -Parent          # app-skeleton
$labRoot  = Split-Path $projRoot -Parent              # xiyo-lab
$key      = Join-Path $labRoot "tools\deploy_key"
$ssh      = "C:\Program Files\Git\usr\bin\ssh.exe"
$git      = "C:\Program Files\Git\cmd\git.exe"
$gh       = "C:\Program Files\GitHub CLI\gh.exe"
$socksPort = 1080

function Say($t) { Write-Host $t -ForegroundColor Cyan }
function Ok($t)  { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Bad($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t){ Write-Host "         $t" -ForegroundColor Gray }

Say "==============================================="
Say "  一键发布：登录 -> 建库 -> 推送 -> 构建"
Say "==============================================="
Write-Host ""

# ---------- 1. 隧道 ----------
Say "[1/5] 检查 GitHub 通道（SSH 隧道 -> 香港）"
$up = Test-NetConnection -ComputerName 127.0.0.1 -Port $socksPort -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $up) {
    Info "启动隧道..."
    Start-Process -FilePath $ssh -ArgumentList @(
        "-i", "`"$key`"", "-N", "-D", "$socksPort",
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL",
        "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes",
        "root@103.119.2.243"
    ) -WindowStyle Hidden
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-NetConnection -ComputerName 127.0.0.1 -Port $socksPort -InformationLevel Quiet -WarningAction SilentlyContinue) { break }
    }
}
if (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port $socksPort -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Bad "隧道起不来，无法访问 GitHub"
    Read-Host "按回车退出"; exit 1
}
Ok "隧道就绪 127.0.0.1:$socksPort"

# gh / git 都走这条隧道
$env:HTTP_PROXY  = "socks5://127.0.0.1:$socksPort"
$env:HTTPS_PROXY = "socks5://127.0.0.1:$socksPort"
$env:ALL_PROXY   = "socks5://127.0.0.1:$socksPort"
$env:BROWSER     = Join-Path $PSScriptRoot "open-with-proxy.cmd"
& $git config --global http.https://github.com.proxy "socks5h://127.0.0.1:$socksPort"
Ok "git / gh 已指向代理"

# ---------- 2. 安装检查 ----------
Say "[2/5] 检查工具"
if (-not (Test-Path $gh))  { Bad "没装 GitHub CLI：winget install GitHub.cli"; Read-Host "回车退出"; exit 1 }
if (-not (Test-Path $git)) { Bad "没装 Git：winget install Git.Git"; Read-Host "回车退出"; exit 1 }
Ok "git + gh 就绪"

# ---------- 3. 登录 ----------
Say "[3/5] 登录 GitHub"
$null = & $gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  接下来 gh 会显示一个 6~8 位的一次性验证码（形如 ABCD-1234）" -ForegroundColor Yellow
    Write-Host "  它会自动用带代理的 Edge 打开 https://github.com/login/device" -ForegroundColor Yellow
    Write-Host "  把验证码输进去 -> 点 Continue -> Authorize 即可" -ForegroundColor Yellow
    Write-Host ""
    & $gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { Bad "登录失败"; Read-Host "回车退出"; exit 1 }
}
$me = (& $gh api user --jq .login 2>$null)
if (-not $me) { Bad "拿不到用户名，登录可能没成功"; Read-Host "回车退出"; exit 1 }
Ok "已登录：$me"

# ---------- 4. 建仓库并推送 ----------
Say "[4/5] 创建仓库并推送"

$repoName = Read-Host "  仓库名（直接回车用 xiyo-clone）"
if ([string]::IsNullOrWhiteSpace($repoName)) { $repoName = "xiyo-clone" }

Set-Location $projRoot
& $git add -A | Out-Null
& $git -c user.name="lab" -c user.email="lab@local" commit -m "chore: sync" 2>$null | Out-Null

$hasOrigin = (& $git remote) -contains "origin"
if ($hasOrigin) {
    Info "已有 origin，直接推送"
    & $git push -u origin main
} else {
    Info "用 gh 创建 $me/$repoName 并推送"
    & $gh repo create $repoName --private --source=. --remote=origin --push
}
if ($LASTEXITCODE -ne 0) {
    Bad "推送失败。可能原因："
    Info "1. 仓库名已被占用 -> 换一个名字重跑"
    Info "2. 网络抖动 -> 重跑一次"
    Read-Host "回车退出"; exit 1
}
Ok "推送成功"

# ---------- 5. 触发并跟踪构建 ----------
Say "[5/5] 触发构建"
& $git commit --allow-empty -m "ci: trigger" | Out-Null
& $git push | Out-Null
Start-Sleep -Seconds 3

$repo = (& $gh repo view --json nameWithOwner --jq .nameWithOwner 2>$null)
if (-not $repo) { $repo = "$me/$repoName" }
Ok "仓库：$repo"

# 有 workflow 的话 gh 能直接看到运行
$runs = (& $gh run list --limit 1 --json databaseId,status,conclusion,url 2>$null)
Write-Host ""
if ($runs) {
    Write-Host "  最近的运行：" -ForegroundColor Cyan
    Write-Host "  $runs"
} else {
    Info "还没检测到运行（Actions 可能需要在网页上手动启用一次）"
}

$url = "https://github.com/$repo/actions"
Write-Host ""
Write-Host "  Actions 页面：$url" -ForegroundColor Yellow
$openNow = Read-Host "  现在用代理 Edge 打开？(y/n)"
if ($openNow -ne "n") { Start-Process (Join-Path $PSScriptRoot "open-with-proxy.cmd") -ArgumentList $url }

Write-Host ""
Say "接下来："
Write-Host "  1. 等 15-25 分钟（第一次要编 Rust 依赖）"
Write-Host "  2. 构建变绿后，在运行页面【最底部】Artifacts 里点 XiYOClone-unsigned-ipa"
Write-Host "  3. 下载的 zip 解压出 .ipa，拿去全能签签名"
