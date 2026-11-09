# idevice 0.1.68 真实 API 核对表

> 全部来自 **crates.io 源码包**（`idevice-0.1.68.crate`），不是猜的。
> 复核方法：下载 `https://static.crates.io/crates/idevice/idevice-0.1.68.crate` → 解包 → 看 `src/`。

---

## 1. Provider（怎么连设备）

`src/provider.rs`

```rust
pub struct TcpProvider {
    pub addr: std::net::IpAddr,
    pub scope_id: Option<u32>,
    pub pairing_file: PairingFile,
    pub label: String,
}

impl IdeviceProvider for TcpProvider {
    fn connect(&self, port: u16) -> /* Future<Result<Idevice>> */;
    fn label(&self) -> &str;
    fn get_pairing_file(&self) -> /* Future<Result<PairingFile>> */;
}
```

- feature：`tcp`
- **对我们最关键**：`connect(port)` 就是往 `addr:port` 建 TCP。
  本地 VPN 把 `10.7.0.1:*` 转发到 `127.0.0.1:*`，所以 `addr = 10.7.0.1` 就能连到设备本机服务。

## 2. 服务连接（lockdown → 目标服务）

`src/lib.rs`

```rust
pub trait IdeviceService: Sized {
    fn service_name() -> Cow<'static, str>;

    async fn connect(provider: &dyn IdeviceProvider) -> Result<Self, IdeviceError> {
        let mut lockdown = LockdownClient::connect(provider).await?;   // → 62078
        let legacy = lockdown.start_session(&provider.get_pairing_file().await?).await?;
        let (port, ssl) = lockdown.start_service(Self::service_name()).await?;
        let mut idevice = provider.connect(port).await?;               // → 服务端口
        if ssl { idevice.start_session(..., legacy).await?; }
        Self::from_stream(idevice).await
    }
}
```

- `src/services/lockdown.rs`：`pub const LOCKDOWND_PORT: u16 = 62078;`
- **推论**：一条链路至少用到两个端口（62078 + 服务端口），所以 **VPN 的 NAT 必须转发任意端口**，
  不能只放行 62078。我们的 `TCPRelay` 正是按 `dstPort` 建的连接，符合要求。

## 3. 定位注入

`src/services/simulate_location.rs`（**全部源码就在下面，很短**）

```rust
pub struct LocationSimulationService { idevice: Idevice }

impl IdeviceService for LocationSimulationService {
    fn service_name() -> Cow<'static, str> { obf!("com.apple.dt.simulatelocation") }
    async fn from_stream(idevice: Idevice) -> Result<Self, IdeviceError> { Ok(Self::new(idevice)) }
}

impl LocationSimulationService {
    pub async fn clear(&mut self) -> Result<(), IdeviceError>;   // 发 [00 00 00 01]
    pub async fn set(&mut self, latitude: &str, longtiude: &str) -> Result<(), IdeviceError>;
    //                                              ^^^^^^^^^ 源码里就是拼错的 longtiude
}
```

`set` 的报文格式（照抄源码）：

```
[00 00 00 00] [lat_len(u32 BE)][lat 的 utf8 字节] [lng_len(u32 BE)][lng 的 utf8 字节]
```

- feature：`location_simulation`（依赖为空）
- 坐标传**字符串**，用 `format!("{:.7}", v)` 保证精度

## 4. 纯手机端配对（最关键的发现）

`src/remote_pairing/responder.rs`

```rust
pub const PAIRABLE_HOST_SERVICE_TYPE: &str = "_remotepairing-pairable-host._tcp.local.";

pub struct PairableHostInfo {
    pub name: String,                     // 设备上显示的名字
    pub model: String,                    // 必须是 Mac 标识，如 "Mac17,7"
    pub udid: String,                     // 可空
    pub identifier: String,               // 可空
    pub wire_protocol_version: u8,         // 近期 iOS = 26
    pub alt_irk: [u8; 16],                // mDNS 身份密钥，必须持久化
    pub allows_pinless_pairing: bool,      // true = 免 PIN
}

impl PairableHostInfo {
    pub fn generate(name, model) -> Self;                    // 随机生成 alt_irk
    pub fn mdns_txt_records(&self, service_identifier: &str) -> Vec<(String, String)>;
}

pub struct PairableHost<R: RpPairingSocketProvider> { ... }

impl<R> PairableHost<R> {
    pub fn new(inner: R, host_info: PairableHostInfo) -> Self;
    pub async fn accept<Fut>(
        &mut self,
        pairing_file: &mut RpPairingFile,
        pin_callback: impl FnOnce(String) -> Fut,   // Fut: Future<Output=()>
    ) -> Result<PeerDevice, IdeviceError>;
}
```

`src/remote_pairing/socket.rs`

```rust
pub struct RpPairingSocket<R: ReadWrite> { ... }
impl<R: ReadWrite> RpPairingSocket<R> {
    pub fn new(socket: R) -> Self;          // 主动方（host）
    pub fn new_device(socket: R) -> Self;   // 应答方（responder）← 我们用它
}
```

`src/remote_pairing/rp_pairing_file.rs`

```rust
pub struct RpPairingFile { ... }
impl RpPairingFile {
    pub fn generate(sending_host: &str) -> Self;
    pub fn identifier(&self) -> &str;
    pub fn alt_irk(&self) -> Option<&[u8]>;
    pub fn to_bytes(&self) -> Vec<u8>;
    pub async fn write_to_file(&self, path: impl AsRef<Path>) -> Result<(), IdeviceError>;
    pub async fn read_from_file(path: impl AsRef<Path>) -> Result<Self, IdeviceError>;
}
```

`src/remote_pairing/peer_device.rs`

```rust
pub struct PeerDevice {
    pub account_id: String,
    pub alt_irk: Vec<u8>,          // 16 字节
    pub model: String,             // "iPhone14,4"
    pub name: String,
    pub remotepairing_udid: String,
}
```

`src/remote_pairing/mod.rs` 导出：

```rust
pub use responder::{PAIRABLE_HOST_SERVICE_TYPE, PairableHost, PairableHostInfo};
pub use rp_pairing_file::RpPairingFile;
pub use socket::{RpPairingSocket, RpPairingSocketProvider};
pub use peer_device::{PeerDevice, compute_auth_tag};
```

- feature：`remote_pairing = ["_serde_json", "xpc", "dep:x25519-dalek"]`

**这条流程就是"纯手机端不用电脑"的全部秘密**：
App 以 **pairable host** 身份发布 `_remotepairing-pairable-host._tcp`，
设备（iOS 17+）主动连进来，App 跑 SRP pair-setup 并显示 6 位码。

## 5. PairingFile（注入时用）

`src/pairing_file.rs`

```rust
pub fn read_from_file(path: impl AsRef<Path>) -> Result<Self, IdeviceError>;  // L97
pub fn from_bytes(bytes: &[u8]) -> Result<Self, IdeviceError>;               // L115
pub fn from_value(v: &plist::Value) -> Result<Self, IdeviceError>;            // L149
```

注意是 `read_from_file`，**不是** `from_file`（我第一版写错过，已修）。

## 6. 相关 feature 依赖

| feature | 依赖 |
|---|---|
| `location_simulation` | 无 |
| `tcp` | `tokio/net` |
| `pair` | `chrono/default`, `tokio/time`, `sha2` |
| `remote_pairing` | `_serde_json`, `xpc`, `x25519-dalek` |
| `rsd` | `xpc` |

默认 feature 是 `aws-lc`（要 C 工具链，交叉编译到 iOS 麻烦）。
**建议**：`default-features = false` + 需要的功能，TLS 用 `rustcrypto`（纯 Rust）。
