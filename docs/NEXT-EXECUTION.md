# 接下来怎么执行（三条路，按代价排序）

> 当前状态：**Rust 侧已编译验证通过**（9 个符号导出、三端一致）。
> 剩下的事都有一个共同前提：**需要一个能编译 Swift 的环境**（Mac，或 GitHub 的 macOS runner）。
> Windows 上装不了 iOS SDK，这一步绕不过去。

---

## 路线 A：GitHub Actions 出未签名 IPA（**推荐，今天就能跑**）

**代价**：0 元、不用买 Mac、不用插线。
**能验证**：Swift 代码能不能编译、entitlements 对不对、工程结构有没有问题。
**拿到的**：一个 `XiYOClone-unsigned.ipa`，再用全能签签一下就能装到手机。

### 步骤

1. **建一个 GitHub 仓库**（私有也行，私有仓库每月 2000 分钟免费）
2. 把 `xiyo-lab/app-skeleton/` 整个目录推上去
   （`.github/workflows/ios.yml` 我已经写好了，在 `app-skeleton/.github/` 里）
3. 仓库页面 → **Actions** → 选 `build-ios` → **Run workflow**
4. 等 10–20 分钟 → 下载 artifact `XiYOClone-unsigned-ipa`
5. 用全能签签这个 IPA（它需要 NE 权限，你那张证书**有**）

### 大概率会遇到什么（我提前说）

| 报错 | 原因 | 我这边怎么修 |
|---|---|---|
| `Missing package product` / `no such module` | `project.yml` 的 target 配置 | 改 yml |
| `Swift Compiler Error`（具体行号） | 我写的 Swift 有语法/API 错 | 贴给我，逐行修 |
| `requires a provisioning profile` | `CODE_SIGNING_ALLOWED=NO` 没生效 | 调 xcodebuild 参数 |
| `NetworkExtension` 相关链接错 | 扩展 target 没链 framework | 改 yml |

**把报错日志贴给我就行，这类我能直接修。**

---

## 路线 B：一台 Mac（最快，但要硬件）

**代价**：借一台 Mac / 云 Mac（MacStadium、AWS EC2 mac 约 ¥2–5/小时）。
**能验证**：全部（编译 + 真机安装 + 配对 + 注入）。

```bash
# 在 Mac 上
git clone <你的仓库>
cd app-skeleton/Rust && ./build-ios.sh      # 编 Rust 静态库
brew install xcodegen
cd .. && xcodegen generate && open XiYOClone.xcodeproj
# Xcode 里：选 Team（你的个人开发者账号）、连手机、Run
```

**注意**：你的个人账号要在 Apple Developer 后台给 App ID 勾上
`Network Extensions`（企业证书那张已经确认带 NE 权限）。

---

## 路线 C：先不碰 iOS，把服务端和发卡跑起来（**现在就能做**）

如果目标是"先能收钱"，App 不是第一优先：

| 已完成 | 能力 |
|---|---|
| `cardsync/` | 发卡 + 核销 + 签名任务队列（21 项自测全过） |
| `shop/` | 下单/支付/自动发货/对账 |
| `server/` | UDID 采集 + OTA 分发 + 安装页 |
| `wps/` + `103.119.2.243` | VPN + PAC + 证书那套（已部署，只差 WPS 改写） |

这条路上**唯一还缺的一次性动作**：手机连 WiFi 装描述文件连 VPN，
我抓一次 `gs-loc` 明文就能把 `rewrite_wps()` 写完（3–7 天出可用产品）。

---

## 我的建议顺序

```
今天：路线 A（推 GitHub，跑 Actions）→ 拿到第一个"能编译"的证据
     ↓ 同时
今天：路线 C（手机连 VPN，我抓包写完 WPS 改写）→ 1 周内有能卖的东西
     ↓ 等 App 编译通过
之后：路线 B（真机联调配对 + 注入）→ 3–4 周拿到完整 App
```

**理由**：路线 A 只在"有报错时"需要你配合（贴日志），不占用你的时间；
路线 C 能让你先有收入；两者不冲突。

---

## 你现在只需要做一件事

**选一条告诉我：**

- 说 **「A」** → 我给你推 GitHub 的完整命令（含 `.gitignore`、仓库结构、怎么触发）
- 说 **「B」** → 我给你 Mac 上的逐步命令（含 Apple 后台勾 Network Extension 的路径）
- 说 **「C」** → 我给你手机端的操作步骤，你把 VPN 连上，我抓包写改写代码
- 或者你把 **Actions 报错日志** 直接贴给我 → 我逐行修

> 提醒：无论哪条，**证书这步你已经过了**（网络扩展权限确认有），
> 这是这个项目最大的不确定性，现在没了。
