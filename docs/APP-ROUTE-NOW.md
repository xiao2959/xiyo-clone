# 转 App 路线：现在只差你推一次 GitHub

> 手机网络：我已把服务器上所有劫持规则清空（443 重定向删掉、透明代理和 dnsmasq 都停了）。
> 如果你手机还连着我那台 VPN，断开或删掉描述文件就彻底恢复，不会有残留影响。

---

## 一、为什么转这条路（结论）

| 事实 | 说明 |
|---|---|
| 你手机**一次都没查过 WPS**（dnsmasq 里 0 条来自 10.10.0.2 的查询） | iOS 在用 GPS/缓存，WPS 这条路对你无效 |
| WPS 方案本质只能骗 Wi-Fi 定位 | 户外、有 GPS 时必败，这是原理限制 |
| **App 路线不依赖 WPS** | 走 `com.apple.dt.simulatelocation`，室内外都有效 |

---

## 二、我已经做完的（这轮修的 7 个真问题）

| # | 问题 | 不修的后果 |
|---|---|---|
| 1 | `deploymentTarget` 是 15.0，但 ContentView 用了 iOS 17 的 `Map(position:)` | **编译直接失败** |
| 2 | 缺 `LIBRARY_SEARCH_PATHS` | 链接时找不到 `libidevice_ffi.a` → `Undefined symbols: _pairing_start` |
| 3 | `sources: App` 会把 `Bridge/lib/*.a` 当源码 | xcodegen 报错/异常 |
| 4 | 多余 bridging header（代码用 `@_silgen_name`） | 可能重复声明冲突 |
| 5 | entitlements 里有 `com.apple.security.application-groups` | **全能签几乎无法加 App Group → 签名/安装失败** |
| 6 | Extension Info.plist 放了 entitlement key | 无效项，可能被校验拒绝 |
| 7 | `excludedRoutes = [default]` 与 `includedRoutes` 矛盾 | 分流行为不可预期 |

另外：**没有显式 scheme** 的话 `xcodebuild -scheme XiYOClone` 会报 "scheme not found"，已补上。

---

## 三、你只需要做三步

### 第 1 步：建仓库（30 秒）

打开 https://github.com/new

- 名字：`xiyo-clone`
- 选 **Private**
- **不要**勾 Add README / .gitignore / license

### 第 2 步：推代码（复制粘贴，1 分钟）

```powershell
$env:Path += ";C:\Program Files\Git\cmd"
cd C:\Users\Administrator\Documents\deepseek-harness\default-workspace\xiyo-lab\app-skeleton

git remote add origin https://github.com/你的用户名/xiyo-clone.git
git push -u origin main
```

第一次会要求登录：
- 点「Sign in with your browser」用浏览器授权，**或**
- 粘贴 Personal Access Token（GitHub → Settings → Developer settings → Tokens (classic) → 勾 `repo`）

### 第 3 步：跑构建

仓库页面 → **Actions** → 左侧 **build-ios** → 右侧 **Run workflow** → 绿色按钮

等 10–20 分钟，下载 artifact `XiYOClone-unsigned-ipa`。

---

## 四、构建会做什么

```
1. rustup + aarch64-apple-ios      → 编 Rust 静态库
2. cargo build --release           → libidevice_ffi.a（本地已验证能编过）
3. npm i -g xcodegen（brew）        → 生成 .xcodeproj
4. xcodebuild CODE_SIGNING_ALLOWED=NO → 编未签名 App
5. 打包 Payload/ → zip             → 输出 IPA
```

**本地已验证的部分**：Rust `cargo build` 通过（9 个符号导出）。
**未验证的部分**：Swift 编译（Windows 上做不到）。

---

## 五、最可能报错的地方（附对策）

| 报错关键字 | 原因 | 我会怎么改 |
|---|---|---|
| `Swift Compiler Error ... .swift:NN` | Swift 语法/API | 贴给我，逐行改 |
| `no such module 'NetworkExtension'` | 扩展未链 framework | 改 project.yml |
| `Undefined symbols: _pairing_start` | 静态库没链接上 | 调 LIBRARY_SEARCH_PATHS |
| `The project 'XiYOClone' does not contain a scheme` | scheme 缺失 | 已在 yml 里补，仍报则调 workflow |
| `xcodegen: command not found` | brew 未装 | workflow 里改用 `brew install xcodegen`（已写） |
| `requires a provisioning profile` | 签名未关干净 | 检查 `CODE_SIGNING_ALLOWED=NO` 参数 |

**只要把 Actions 的红色日志贴给我，这类问题我基本一次能修好。**

---

## 六、拿到 IPA 之后

1. 用**全能签**上传 `XiYOClone-unsigned.ipa`
2. 填你的 UDID（`00008110-001658DC0C83801E`）
3. 用你那张 `iPhone Distribution: Anna Beer (BT8T5D9JD8)` 证书签
4. 安装到手机

**关键前提（已确认）**：你的证书带 **网络扩展** 权限 —— 这是这个 App 能不能跑的唯一硬门槛。
拆包证据也证明这条路可行：XiYO 的 IPA 用的就是 `com.apple.networkextension.packet-tunnel` + `10.7.0.0/24`。

---

## 七、装好之后怎么测（顺序别跳）

| 步骤 | 预期 |
|---|---|
| 1. 打开 App，点「连接隧道」 | 系统弹「XX 想要添加 VPN 配置」→ 允许；状态栏出现 VPN 图标 |
| 2. 点「配对设备」 | 显示 6 位数字 |
| 3. 手机上完成配对（设置里的开发者模式/配对入口） | App 显示「配对成功」 |
| 4. 地图上选点 → 「注入到手机」 | 地图 App 显示新位置 |
| 5. 「恢复真实定位」 | 变回真实位置 |

**第 1 步失败** = 签名/entitlement 问题（最容易卡，需要检查全能签是否保留了扩展的 entitlement）。
**第 2-3 步失败** = 配对流程问题（我能远程看日志）。
**第 4 步失败** = NAT/端口问题（我能改 TCPRelay）。
