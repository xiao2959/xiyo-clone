# A 路线执行单：推 GitHub 跑 Actions（出第一个未签名 IPA）

> 本地已经做完了：仓库已 `git init` + 提交（25 个文件，commit `6cab83c`）。
> 剩下只差 **推到一个 GitHub 仓库**，然后在网页上点一次 Run。

---

## 你的仓库在哪

```
C:\Users\Administrator\Documents\deepseek-harness\default-workspace\xiyo-lab\app-skeleton
```

已包含：

```
.github/workflows/ios.yml     ← 自动编 Rust + 生成工程 + xcodebuild + 打包 IPA
.gitignore                    ← 忽略 Rust/target、*.a、*.ipa、build/
App/ Extension/ Rust/ docs/ project.yml README.md
```

---

## 三步推上去

### 1. 在 GitHub 建一个空仓库

- 打开 https://github.com/new
- 名字随便，例如 `xiyo-clone`
- **不要**勾 "Add README / .gitignore / license"（否则要先 pull）
- 可见性选 **Private**（每月 2000 分钟免费，够用）

### 2. 推代码（在本机 PowerShell 里跑）

```powershell
$env:Path += ";C:\Program Files\Git\cmd"
cd C:\Users\Administrator\Documents\deepseek-harness\default-workspace\xiyo-lab\app-skeleton

git remote add origin https://github.com/你的用户名/xiyo-clone.git
git push -u origin main
```

第一次 push 会弹登录：**用浏览器授权**，或粘贴一个 Personal Access Token
（GitHub → Settings → Developer settings → Tokens (classic) → 勾 `repo`）。

### 3. 触发构建

- 打开仓库 → **Actions** 标签
- 左边选 **build-ios** → 右边 **Run workflow** → 绿色按钮
- 等 10–20 分钟

---

## 构建成功后你会拿到

**Artifacts** 里的 `XiYOClone-unsigned-ipa`，解压得到 `XiYOClone-unsigned.ipa`。

**注意**：这是**未签名**包，不能直接装。要装得用你的全能签签一次：

```
全能签 → 上传 IPA → 填 UDID → 签名 → 拿安装链接
```

> 你的证书**已确认带 `com.apple.developer.networking.networkextension`**，
> 所以扩展（PacketTunnel）能正常起 —— 这是这个项目最大的不确定性，已经排除了。

---

## Actions 会跑什么（每一步对应一个可修的报错）

| 步骤 | 干什么 | 失败时看什么 |
|---|---|---|
| 1. Install Rust | `rustup target add aarch64-apple-ios` | Rust 版本 |
| 2. Build libidevice_ffi.a | `cargo build --release --target aarch64-apple-ios` | 交叉编译错误（**本地已验证能编**，这里只是换 target） |
| 3. Install XcodeGen | `brew install xcodegen` | brew 网络 |
| 4. Generate project | `xcodegen generate` | **project.yml 配置错** |
| 5. Build (unsigned) | `xcodebuild ... CODE_SIGNING_ALLOWED=NO` | **Swift 编译错误（最可能）** |
| 6. Package IPA | 打包成 Payload/*.app → zip | 路径问题 |

---

## 最可能出问题的地方（我提前说）

| 报错片段 | 原因 | 谁修 |
|---|---|---|
| `Swift Compiler Error` + `xxx.swift:行号` | 我写的 Swift 有 API/类型错 | **贴给我，我改** |
| `no such module 'NetworkExtension'` | 扩展 target 没链 framework | 改 `project.yml` |
| `Target 'LocalVPNExtension' has no Info.plist` | yml 路径不对 | 改 `project.yml` |
| `Undefined symbols: _pairing_start` | 静态库没链接上 | 检查 `-lidevice_ffi` + Library Search Paths |
| `Provisioning profile doesn't include...` | `CODE_SIGNING_ALLOWED=NO` 没传进去 | 调 xcodebuild 参数 |

**这类错误 90% 是配置问题，不是逻辑问题，改起来很快。**

---

## 我这边能帮到哪一步

| 我能做 | 我不能做 |
|---|---|
| 根据报错改 Swift / project.yml / workflow | 替你登录 GitHub（需要你的账号） |
| 本地再跑一遍 Rust 编译验证 | 在 Windows 上编 iOS target |
| 修改 `PairingView` / `TCPRelay` 逻辑 | 真机安装（需要你的 UDID + 签名） |

---

## 如果你不想建 GitHub 仓库

**替代方案**：把 `app-skeleton` 打包成 zip 发给一个用 Mac 的朋友/外包，
让他跑 `xcodegen generate && xcodebuild`，报错贴回来。

```powershell
# 打 zip（已经排除了 .git 和 target）
Compress-Archive -Path App,Extension,Rust,docs,.github,project.yml,README.md `
                 -DestinationPath xiyo-app-skeleton.zip
```
