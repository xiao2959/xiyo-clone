# 配对流程（已按源码核实）

> 所有 API 来自 idevice 0.1.68 源码包，核对表见 API-VERIFIED.md。
> 结论：**纯手机端配对不需要电脑**，App 以 "pairable host" 身份广播，设备主动连入。

## 0. 先纠正一个常见误解

| 角色 | 谁 | 做什么 |
|---|---|---|
| device | 你的 iPhone | 发起连接、要求配对 |
| pairable host | 你的 App | 广播 mDNS、应答握手、跑 SRP、**显示 6 位码** |

6 位码是 App 显示、用户在手机上输入 —— 和视频里“输入 App 上显示的 6 位数字验证码”一致。

## 1. 服务类型（关键常量）

```rust
// idevice/src/remote_pairing/responder.rs:38
pub const PAIRABLE_HOST_SERVICE_TYPE: &str = "_remotepairing-pairable-host._tcp.local.";
```

Swift NetService 用 `_remotepairing-pairable-host._tcp.`（不带 .local.）。
拆包时看到的 `_stikpairprobe._tcp` 是 StikDebug 额外的探测服务，**不是配对必需**。

## 2. 六步流程

### 1. 开本地 listener（Rust）
```rust
let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
let port = listener.local_addr()?.port();
```
设备与 App 在同一台手机，回环地址就够，不需要外网/服务端。
验收：`pairing_start()` 返回 > 0。

### 2. 广播 Bonjour（Swift）
```swift
let svc = NetService(domain: "local.",
                     type: "_remotepairing-pairable-host._tcp.",
                     name: identifier,          // = RpPairingFile::identifier
                     port: Int32(port))
svc.setTXTRecord(NetService.data(fromTXTRecord: txt))  // PairableHostInfo::mdns_txt_records
svc.publish()
```
TXT 里的 authTag 让已配对设备认出本机。验收：`dns-sd -B _remotepairing-pairable-host._tcp` 能看到。

### 3. 设备连入 → 握手
```rust
let stream = listener.accept().await?.0;
let sock = RpPairingSocket::new_device(stream);   // 必须 new_device（responder）
let mut host = PairableHost::new(sock, host_info);
```
`host_info.model` **必须是 Mac 标识**（如 "Mac17,7"）—— iOS 把 pairable host 当电脑。
用 "iPhone" 会被拒绝。

### 4. SRP pair-setup + 6 位码
```rust
let mut pairing_file = RpPairingFile::generate(host_name.as_str());
let peer: PeerDevice = host.accept(&mut pairing_file, |pin: String| {
    // pin = 6 位码，存进共享状态给 Swift 显示
    std::future::ready(())
}).await?;
```
`accept()` 内部完成 handshake + 完整 SRP（3072-bit，用户名 `Pair-Setup`）。
`pin_callback` 是 FnOnce，只调一次。成功后 `pairing_file.alt_irk` 被写入设备 altIRK。

### 5. 保存两样东西（必须持久化）
```rust
pairing_file.write_to_file(&save_path).await?;   // <AppGroup>/pairing.plist
save_altirk(&save_path, &host_info.alt_irk);     // <AppGroup>/pairing.plist.altirk
```
| 存什么 | 漏了会怎样 |
|---|---|
| pairing.plist | 无法连接设备 |
| alt_irk (16B) | 每次启动身份都变，已配对设备当你是陌生主机，**每次都要重新配对** |

`PairableHostInfo::generate()` 每次随机生成 alt_irk，必须自己复用。本仓库 `pairing.rs` 已实现。

### 6. 注入
```rust
let provider = TcpProvider {
    addr: "10.7.0.1".parse()?,
    scope_id: None,
    pairing_file: PairingFile::read_from_file(&save_path)?,
    label: "lab-sim".into(),
};
let mut svc = LocationSimulationService::connect(&provider).await?;
svc.set("39.9042", "116.4074").await?;
svc.clear().await?;
```
内部（IdeviceService::connect 默认实现）：
```
provider.connect(62078) → lockdown.start_session(pairing_file)
  → lockdown.start_service("com.apple.dt.simulatelocation")
  → provider.connect(服务端口) → from_stream → set/clear
```
**VPN 硬要求**：NAT 必须转发任意端口（62078 + 服务端口），不能只放行 62078。
`TCPRelay` 按 dstPort 建连接，满足。

## 3. 五个真实卡点
| 卡点 | 处理 |
|---|---|
| 广播不出去 | Info.plist 加 NSBonjourServices；给本地网络权限 |
| 设备连不上 | Bonjour 端口与 listener 端口不一致；VPN 抢了回环流量 |
| 每次都要重配 | **alt_irk 没持久化**（最常见） |
| handshake 报错 | 用了 `new()` 而不是 `new_device()` |
| 注入连不上 | VPN 没连 / NAT 没转发服务端口 / 开发者模式没开 |

## 4. 工时（有参考代码，一个人）
| 事项 | 时间 |
|---|---|
| listener + Bonjour + 显示 PIN | 1–2 天 |
| SRP 跑通（用 crate，不手写） | 1–2 天 |
| pairing file + alt_irk 持久化 | 半天 |
| 注入 + VPN NAT 联调 | 2–3 天 |
| 收尾 | 1–2 天 |
| **合计** | **6–9 天** |
