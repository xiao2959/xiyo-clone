# XiYO 同款 App 骨架（Swift：PacketTunnel + 本地 NAT + 配对 + idevice 桥）

> 这是**骨架**，不是能直接编译通过的成品。目标是把拆包得到的结构（见 `../docs/xiyouo-ipa-analysis.md`）
> 变成一份可以交给 iOS 开发照填的工程：
>
> ```
> App(SwiftUI) ──NETunnelProviderSession──> LocalVPNExtension(NEPacketTunnelProvider + NAT 10.7.0.0/24)
>      │                                            │
>      └── idevice FFI(Rust) ── 配对/RSD ──────────┘──> 设备本地 remoted ──> DVT simulateLocation
> ```
>
> **我没法在 Windows 上编译验证**（需要 Xcode）。下面标 `TODO` 的地方是你要补的。

---

## 1. 目录

```
app-skeleton/
├─ project.yml                      # XcodeGen 配置（不用手点 Xcode 建工程）
├─ App/
│  ├─ App.swift
│  ├─ ContentView.swift             # 地图/坐标/连接状态
│  ├─ TunnelManager.swift           # 起停 VPN 扩展
│  ├─ PairingView.swift             # 6 位码配对页
│  ├─ Bridge/
│  │  ├─ IDeviceBridge.swift        # Rust idevice 的 Swift 包装
│  │  └─ include/idevice_ffi.h      # C 头（和 Rust 那边对齐）
│  ├─ Info.plist
│  └─ App.entitlements
└─ Extension/
   ├─ PacketTunnelProvider.swift    # ★ 隧道 + 本地 NAT
   ├─ Info.plist
   └─ Extension.entitlements
```

## 2. 构建（两种方式）

**A. 有 Mac**

```bash
brew install xcodegen
xcodegen generate            # 生成 XiYOClone.xcodeproj
open XiYOClone.xcodeproj
# 设置 Team，编译 App + Extension 两个 target
```

**B. 没 Mac（GitHub Actions）**

```yaml
- uses: actions/checkout@v4
- run: brew install xcodegen && xcodegen generate
- run: |
    xcodebuild -project XiYOClone.xcodeproj -scheme XiYOClone \
               -configuration Release -sdk iphoneos \
               -archivePath build/a.xcarchive CODE_SIGNING_ALLOWED=NO archive
- run: |
    mkdir -p Payload && cp -R build/a.xcarchive/Products/Applications/XiYOClone.app Payload/
    zip -qr XiYOClone.ipa Payload
- uses: actions/upload-artifact@v4
  with: { name: XiYOClone.ipa, path: XiYOClone.ipa }
```

## 3. Rust 库怎么进来（最难的一步）

他的包里是 `libstikpair_ffi.a`（13 MB）+ `OpenSSL.framework`，来自：

- [jkcoxson/idevice](https://github.com/jkcoxson/idevice) —— Rust，`lockdownd_pair` / `lockdownd_connect_rsd` / RSD 服务
- [StikDebug](https://github.com/StikDebug/StikDebug) —— 纯手机端配对（pairing file）

做法：

```bash
# 在 Mac 上
rustup target add aarch64-apple-ios
cargo build --release --target aarch64-apple-ios
# 产出 target/aarch64-apple-ios/release/libidevice_ffi.a
```

然后把它加进 App target 的 "Link Binary With Libraries"，并在 `Bridge/include/idevice_ffi.h` 里声明你要调的 C ABI
（`IDeviceBridge.swift` 里已经按这个约定写好了调用点）。

> 如果不想碰 Rust：先用**电脑侧** [pymobiledevice3](xiyo-lab/tools/venv) 把流程跑通，验证"配对 → RSD → 注入"，
> 再决定要不要把它搬进手机。

## 4. 签名（这一步会决定你成不成）

| 需要 | 为什么 |
|---|---|
| 证书必须带 `com.apple.developer.networking.networkextension = packet-tunnel-provider` | 否则扩展**启动即失败**（`NEVPNErrorDomain error 1`） |
| 主 App 和 Extension 用**同一张证书/同一个 Team** | 两个 target 的 entitlements 必须匹配 |
| 装机后要允许 VPN 配置 | 首次启动会弹"XX 想添加 VPN 配置"，点允许 |

**去问全能签三个问题**（这决定你能不能做）：
1. 你们签的证书带不带 **NetworkExtension（packet-tunnel-provider）** 权限？
2. 主 App + App Extension 能不能用同一个证书签？
3. 有没有"NSE/扩展签名"的成功案例？

如果你自己办个人开发者账号（$99/年），在 Xcode 里勾上 NetworkExtension capability 即可，但要向 Apple 申请该权限（个人账号通常能批）。

## 5. 验收顺序（别跳）

1. **空壳能装能开**（用现成的 Demo.ipa 走一遍你的发卡/签名链）；
2. **扩展能起**：点"连接"→ 系统 VPN 图标出现 → 扩展日志打印 `tunnel started`；
3. **NAT 通**：App 内访问 `10.7.0.1:62078` 能建立连接（`lockdownd` 端口）；
4. **配对成功**：`PairingView` 显示 6 位码 → 手机上完成 pair-setup → `pairing.plist` 落盘；
5. **服务能连**：`simulate_location` 返回 0（内部走 `lockdown.start_service` + `provider.connect`）；
6. **注入生效**：地图 App 显示新位置；点"恢复真实定位"能变回来。

## 6. 进度（本轮更新）

| 文件 | 状态 |
|---|---|
| `Rust/src/pairing.rs` | ✅ **纯手机端配对完整实现**：`PairableHost::accept` + PIN 回调 + pairing file 落盘 + Bonjour 三项导出 |
| `Rust/src/lib.rs` | ✅ 定位注入：`TcpProvider` + `LocationSimulationService::{connect,set,clear}` |
| `App/PairingView.swift` | ✅ `NetService` 发布 `_remotepairing-pairable-host._tcp` + 轮询 6 位码 + 结果处理 |
| `App/Bridge/Bridge.swift` | ✅ 9 个 C 函数封装（三端符号已校验一致） |
| `Extension/TCPRelay.swift` | ✅ 三次握手/转发/ACK/FIN/校验和 |
| `docs/API-VERIFIED.md` | ✅ 所有调用都对着 crates.io 源码核对过（含源码片段） |

**还缺**：

- [ ] `PairableHostInfo.alt_irk` 需要**持久化**（重启后保持不变，否则已配对设备认不出本机）
- [ ] 重传 / 乱序重组 / 窗口通告（长连接需要）
- [ ] 真机联调（**必须插一次线**；配对本身不需要电脑，但调试要）
- [ ] `Map` 点击选点（现在固定为北京坐标）

## 7. 成本与风险

| 项 | 数字 |
|---|---|
| 开发 | 2–4 周（一个人，会 Swift + 愿意读 Rust FFI） |
| 维护 | 每个 iOS 大版本返工 1–2 周 |
| 签名 | 超级签一机一签；企业签要资质 |
| 最大风险 | 签名证书不带 NE 权限 → 全盘白做（先问清） |
