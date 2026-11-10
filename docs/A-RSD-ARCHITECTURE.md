# A 轮：rppairing → 隧道 → RSD → simulatelocation 架构结论

> 本轮**不出包**。先把链路在本地验证通，再谈构建。
> 依据：`idevice 0.1.68` 源码（路径 `%USERPROFILE%\.cargo\registry\src\...\idevice-0.1.68`）。

## 一、两套 pairing 体系（这是前面所有误判的根源）

| | lockdown pairing | rppairing |
|---|---|---|
| 结构体 | `pairing_file.rs::PairingFile` | `remote_pairing/rp_pairing_file.rs::RpPairingFile` |
| 键 | DeviceCertificate / HostCertificate / RootCertificate / HostID / SystemBUID / WiFiMACAddress | public_key / private_key / identifier / alt_irk |
| 密钥 | RSA 证书 | Ed25519 |
| 大小 | 1~2 KB | **~500 B**（本地实测 438~502 B） |
| 文件头 | `bplist00` | `<?xml version="1` |
| 来源 | 传统 USB 配对 / usbmuxd | iOS 27「开发者模式 → 配对设备」 |

**你截图里 `501B` + `<?xml version="1` 就是合法的 `RpPairingFile`**，配对是成功的。
我上一版用 `PairingFile::read_from_file` 去读它，才误报「格式不对」，并导致 `注入失败(-1)`。

## 二、`LocationSimulationService` 走哪条路

`src/lib.rs:99-124`（`IdeviceService::connect`）：

```rust
let mut lockdown = LockdownClient::connect(provider).await?;
let legacy = lockdown.start_session(&provider.get_pairing_file().await?).await?;
let (port, ssl) = lockdown.start_service(Self::service_name()).await?;
```

- 它依赖 `IdeviceProvider::get_pairing_file() -> PairingFile`（**lockdown 证书文件**）
- `start_session` 需要 `HostID` + `SystemBUID`，且 `EnableSessionSSL=true` 后要用**证书**做 TLS
- 所以**不能**直接拿 `RpPairingFile` 喂给它

## 三、iOS 27 上正确的通道

`src/remote_pairing/mod.rs` 文档 + `src/services/rsd.rs`：

```
设备（iOS）发起配对 → 我们作为 PairableHost(responder)
   ↓ SRP 完成，产出 RpPairingFile + encryption_key
create_tcp_listener()        → 设备开一个 TCP 监听端口
   ↓
connect_tls_psk_tunnel_native(stream, &encryption_key)
   → TLS-PSK → CDTunnel 握手 → TunnelInfo{
        client_address (IPv6),
        server_address (IPv6),
        server_rsd_port,          ← 关键
        mtu
     }
   ↓
Adapter::new(...) / to_async_handle()   （需要 feature `tunnel_tcp_stack`）
   ↓
RsdHandshake::new(rsd_stream)  → services: HashMap<String, RsdService>
   ↓
在 RSD 表里找 com.apple.mobile.lockdown.remote.trusted
   ↓
LockdownClient (RsdService 实现，src/services/lockdown.rs:24)
   → start_service("com.apple.dt.simulatelocation")
   ↓
拿到端口 → 发 4 字节头 + [len BE][lat str] + [len BE][lng str]
```

关键源码位置：

| 环节 | 文件:行 |
|---|---|
| `create_tcp_listener` | `src/remote_pairing/mod.rs:838` |
| `connect_tls_psk_tunnel_native` | `src/remote_pairing/tunnel.rs:24` |
| `TunnelInfo.server_rsd_port` | `src/tunnel.rs:30` |
| `AdapterHandle: RsdProvider` | `src/tcp/mod.rs:10` |
| `RsdHandshake::new` | `src/services/rsd.rs:35` |
| `RsdHandshake::connect` | `src/services/rsd.rs:171` |
| `LockdownClient::RsdService` | `src/services/lockdown.rs:24` |
| 现成完整范例 | `src/services/dvt/xctest/mod.rs:563-593` |

## 四、一个必须正视的障碍

`simulate_location.rs` **没有实现 `RsdService`**（全库 grep 确认）。
它只实现 `IdeviceService`（走 62078 lockdown）。

所以有两条可行路线：

### 路线 1：RSD → remote.trusted lockdown → start_service
`com.apple.mobile.lockdown.remote.trusted` 有 `RsdService` 实现。
但 `start_session` 要 `PairingFile`（证书）。**我们手上没有**。
库里也没有「用 rppairing 升级出 lockdown pairing」的实现（`allowsUpgradeOfLockdownPairings: false`）。

### 路线 2（推荐）：绕开 lockdown，直接用 RSD 暴露的服务
`com.apple.coredevice.locationservice` 有 `RsdService` 实现
（`src/services/core_device/location_service.rs:19`），但库里只实现了
`available_location_scenarios()`，**没有设坐标的方法**。

→ 需要自己按 CoreDevice 的 XPC plist 协议实现 `simulatelocation` 动作。
库里 `CoreDeviceServiceClient::invoke_with_plist_action` 是现成的。

## 五、还有个独立问题：扩展不回话

自检显示 `状态=3 响应=nil`（VPN 报已连接，但 `sendProviderMessage` 无回复）。
这一层与上面链路**互相独立**，需要单独定位（设备日志 / 真机调试）。
即使注入链路改对，扩展仍要处理。

## 六、本轮要交付的验证（不出包）

分层测试，每层都能在本地跑：

1. ✅ `RpPairingFile` 落盘 438 B + 读回（已完成，`cargo test` 1 passed）
2. ⬜ `simulate_location` 报文编码：验证字节布局与库实现一致
3. ⬜ `RpPairingFile` 与 `PairingFile` 的判定函数：正确区分两种文件，不再误报
4. ⬜ CDTunnel 握手：用假设备模拟 `CDTunnel` magic + clientHandshakeRequest 响应
5. ⬜ RSD 服务表解析：构造 Services 字典，验证能查到目标服务端口

**只有 1~5 全绿，才重新构建 App。**

## 七、所需 Cargo features（当前缺）

当前 `Rust/Cargo.toml`：
```
tcp, pair, location_simulation, remote_pairing, rustcrypto
```

需要补：
```
xpc, rsd, tunnel_tcp_stack, core_device_proxy, core_device, _serde_json
```

⚠️ `xpc` 会引入 `indexmap/uuid/async-stream/futures` 等，
必须先验证 `aarch64-apple-ios` 能编译通过，否则不能出包。
