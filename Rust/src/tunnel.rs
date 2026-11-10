//
//  src/tunnel.rs —— C3：rppairing → TLS-PSK/CDTunnel → 用户态 TCP → RSD
//
//  关键发现（本轮验证）：
//    idevice 的 `tunnel_tcp_stack` 用的是 jktcp —— 一个**纯用户态 TCP 栈**。
//      CdTunnel → into_inner() → Adapter::new(stream, our_ip, their_ip)
//      → to_async_handle() → connect_to_service_port(port)
//    也就是说**不需要 utun / NetworkExtension**。
//
//    这对我们是决定性的：省掉 appex，就不需要「通配符证书」，
//    现有的单 App ID 星玥证书就能签、就能装。
//
//  链路：
//    1. RpPairingFile::read_from_file           读 rppairing 配对文件
//    2. TcpStream::connect(host, rp_port)       连设备的 _remotepairing._tcp
//    3. RpPairingSocket::new（host 角色）+ RemotePairingClient::connect
//    4. client.create_tcp_listener()            设备开监听，拿到端口
//    5. TcpStream::connect(host, listener_port)
//    6. connect_tls_psk_tunnel_native           TLS-PSK + CDTunnel 握手
//    7. Adapter::new + to_async_handle          用户态 TCP
//    8. RsdHandshake::new                       拿到 RSD 服务表
//

use std::net::IpAddr;
use std::time::Duration;

use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, TunnelInfo,
    connect_tls_psk_tunnel_native,
};
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use idevice::tcp::handle::AdapterHandle;
use idevice::provider::RsdProvider;
use tokio::net::TcpStream;

/// `_remotepairing._tcp` 的候选端口。
///
/// Apple 没公开这个端口，它平时是 mDNS（`_remotepairing._tcp`）广播的。
/// 在设备本机上，`remotepairingd` 监听的端口在不同 iOS 版本可能不同，
/// 所以这里做候选探测，而不是写死一个。
pub const RP_PORT_CANDIDATES: &[u16] = &[
    49152, 49153, 49154, 49155, 49156, 62078, 32498, 32499,
];

/// 建立成功后的隧道描述（给 Swift 展示 / 排查用）
#[derive(Debug, Clone, Default)]
pub struct TunnelDiag {
    pub client_ipv6: String,
    pub server_ipv6: String,
    pub mtu: u16,
    pub rsd_port: u16,
    pub rp_port: u16,
    pub listener_port: u16,
    pub service_count: usize,
    pub has_location_service: bool,
}

impl TunnelDiag {
    pub fn to_json(&self) -> String {
        format!(
            "{{\"client\":\"{}\",\"server\":\"{}\",\"mtu\":{},\"rsdPort\":{},\
             \"rpPort\":{},\"listenerPort\":{},\"services\":{},\"location\":{}}}",
            self.client_ipv6,
            self.server_ipv6,
            self.mtu,
            self.rsd_port,
            self.rp_port,
            self.listener_port,
            self.service_count,
            self.has_location_service
        )
    }
}

/// 打开的隧道，持有用户态 TCP 句柄 + RSD 表
pub struct OpenTunnel {
    pub handle: AdapterHandle,
    pub services: std::collections::HashMap<String, u16>,
    pub diag: TunnelDiag,
}

/// 探测设备本机哪个端口是 `_remotepairing._tcp`
pub async fn probe_rp_port(host: &str) -> Option<u16> {
    for &p in RP_PORT_CANDIDATES {
        let addr = format!("{}:{}", host, p);
        if let Ok(Ok(_)) =
            tokio::time::timeout(Duration::from_millis(350), TcpStream::connect(&addr)).await
        {
            return Some(p);
        }
    }
    None
}

/// 通过 usbmuxd（127.0.0.1:27015）连接设备的某个 TCP 端口。
///
/// 设备上的 `remotepairingd` 不一定直接绑在 loopback 上，有时只能经
/// usbmuxd 转发访问。StikDebug 二进制里 usbmuxd 出现 4587 次，
/// 说明这是它实际走的路子 —— 我们加一层兜底。
///
/// usbmuxd 协议：
///   请求 = [4B 长度 LE][4B 版本=1][4B 类型=8(Plist)][4B tag] + plist
///   响应 = 同样的头 + plist {"MessageType":"Result","Number":0}
/// 成功后该 socket 即变成到设备端口的透明通道。
pub async fn usbmuxd_connect(port: u16) -> Result<TcpStream, String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let mut s = tokio::time::timeout(
        Duration::from_secs(4),
        TcpStream::connect("127.0.0.1:27015"),
    )
    .await
    .map_err(|_| "连 usbmuxd(27015) 超时".to_string())?
    .map_err(|e| format!("连 usbmuxd(27015) 失败: {e}"))?;

    let req = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
<plist version=\"1.0\"><dict>\
<key>MessageType</key><string>Connect</string>\
<key>DeviceID</key><integer>1</integer>\
<key>PortNumber</key><integer>{}</integer>\
<key>ClientVersionString</key><string>xiyo-lab</string>\
</dict></plist>",
        port
    );

    let mut pkt = Vec::with_capacity(16 + req.len());
    pkt.extend_from_slice(&((16 + req.len()) as u32).to_le_bytes());
    pkt.extend_from_slice(&1u32.to_le_bytes());
    pkt.extend_from_slice(&8u32.to_le_bytes());
    pkt.extend_from_slice(&1u32.to_le_bytes());
    pkt.extend_from_slice(req.as_bytes());

    s.write_all(&pkt)
        .await
        .map_err(|e| format!("usbmuxd 写请求失败: {e}"))?;

    let mut hdr = [0u8; 16];
    tokio::time::timeout(Duration::from_secs(4), s.read_exact(&mut hdr))
        .await
        .map_err(|_| "usbmuxd 响应超时".to_string())?
        .map_err(|e| format!("usbmuxd 读响应失败: {e}"))?;

    let total = u32::from_le_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as usize;
    if total < 16 || total > 8192 {
        return Err(format!("usbmuxd 响应长度异常: {total}"));
    }
    let body_len = total - 16;
    let mut body = vec![0u8; body_len];
    if body_len > 0 {
        s.read_exact(&mut body)
            .await
            .map_err(|e| format!("usbmuxd 读 body 失败: {e}"))?;
    }
    let text = String::from_utf8_lossy(&body).to_string();
    if text.contains("<key>Number</key><integer>0</integer>") == false {
        let short: String = text.chars().take(160).collect();
        return Err(format!("usbmuxd 拒绝端口 {port}: {short}"));
    }
    Ok(s)
}

/// 先试直连，失败再走 usbmuxd
async fn connect_to_device_port(host: &str, port: u16) -> Result<TcpStream, String> {
    let addr = format!("{}:{}", host, port);
    match tokio::time::timeout(Duration::from_secs(4), TcpStream::connect(&addr)).await {
        Ok(Ok(s)) => Ok(s),
        Ok(Err(e)) => match usbmuxd_connect(port).await {
            Ok(s) => Ok(s),
            Err(ue) => Err(format!("直连 {addr} 失败({e})；usbmuxd 也失败({ue})")),
        },
        Err(_) => match usbmuxd_connect(port).await {
            Ok(s) => Ok(s),
            Err(ue) => Err(format!("直连 {addr} 超时；usbmuxd 也失败({ue})")),
        },
    }
}

/// rppairing 的帧格式。
///
/// 库里 `RpPairingSocketProvider` 有两套实现：
///   - `RpPairingSocket`   → 旧版 JSON 帧（magic "RPPairing" + u16 长度 + JSON）
///   - `RemoteXpcClient`   → RemoteXPC 帧（mangledTypeName
///                            "RemotePairing.ControlChannelMessageEnvelope"）
///
/// iOS 17+ 的 `_remotepairing._tcp` 走的是 **RemoteXPC**。
/// 用旧 JSON 帧去连，设备收到就是乱码 → 直接关连接 → "device socket io failed"。
#[derive(Clone, Copy, Debug)]
pub enum Framing {
    Xpc,
    LegacyJson,
}

impl Framing {
    fn name(self) -> &'static str {
        match self {
            Framing::Xpc => "XPC",
            Framing::LegacyJson => "JSON",
        }
    }
}

/// 一次完整的 rppairing 握手：连接 → pair-verify → 让设备开监听
///
/// 返回 (设备开的监听端口, TLS-PSK 密钥)
async fn remote_pair_handshake(
    host: &str,
    port: u16,
    pairing_path: &str,
    framing: Framing,
) -> Result<(u16, Vec<u8>), String> {
    let mut pf = RpPairingFile::read_from_file(pairing_path)
        .await
        .map_err(|e| format!("读 rppairing 失败: {e}"))?;

    let stream = connect_to_device_port(host, port)
        .await
        .map_err(|e| format!("连 _remotepairing._tcp({port}) 失败: {e}"))?;

    let tag = framing.name();

    let (listener_port, key) = match framing {
        Framing::Xpc => {
            let mut xpc = idevice::RemoteXpcClient::new(stream)
                .await
                .map_err(|e| format!("[{tag}] RemoteXPC 建连失败: {e}"))?;
            xpc.do_handshake()
                .await
                .map_err(|e| format!("[{tag}] RemoteXPC 握手失败: {e}"))?;
            let mut client = RemotePairingClient::new(xpc, "xiyo-lab");
            client
                .connect(&mut pf, || async { String::new() })
                .await
                .map_err(|e| format!("[{tag}] pair-verify 失败: {e}"))?;
            let lp = client
                .create_tcp_listener()
                .await
                .map_err(|e| format!("[{tag}] create_tcp_listener 失败: {e}"))?;
            (lp, client.encryption_key().to_vec())
        }
        Framing::LegacyJson => {
            let sock = RpPairingSocket::new(stream);
            let mut client = RemotePairingClient::new(sock, "xiyo-lab");
            client
                .connect(&mut pf, || async { String::new() })
                .await
                .map_err(|e| format!("[{tag}] pair-verify 失败: {e}"))?;
            let lp = client
                .create_tcp_listener()
                .await
                .map_err(|e| format!("[{tag}] create_tcp_listener 失败: {e}"))?;
            (lp, client.encryption_key().to_vec())
        }
    };

    Ok((listener_port, key))
}

/// 打开完整隧道到 RSD
///
/// - `host`：设备地址（本机上通常是 127.0.0.1）
/// - `rp_port`：`_remotepairing._tcp` 端口；传 0 则自动探测
/// - `pairing_path`：rppairing 配对文件路径
pub async fn open_tunnel(
    host: &str,
    rp_port: u16,
    pairing_path: &str,
) -> Result<OpenTunnel, String> {
    // 1) 找 remotepairing 端口
    let port = if rp_port == 0 {
        probe_rp_port(host)
            .await
            .ok_or_else(|| "没找到 _remotepairing._tcp 端口（设备可能未开启开发者模式）".to_string())?
    } else {
        rp_port
    };

    // 2) 连接 + pair-verify + 开监听 —— 角色自动回退
    //
    //    originatedBy 到底该发 "host" 还是 "device"，库里的注释两处方向不同，
    //    与其猜，不如两个都试：先按「我方主动连设备 = host」，
    //    失败再翻转成 "device"。哪个成功，错误信息里会带出来。
    // 先按 iOS 17+ 的 RemoteXPC 帧，失败再退回旧版 JSON 帧
    let (listener_port, key) =
        match remote_pair_handshake(host, port, pairing_path, Framing::Xpc).await {
            Ok(v) => v,
            Err(e_xpc) => {
                eprintln!("[tunnel] XPC 帧失败({e_xpc})，改用旧版 JSON 帧重试");
                remote_pair_handshake(host, port, pairing_path, Framing::LegacyJson)
                    .await
                    .map_err(|e_json| {
                        format!("两种帧格式都失败 —— XPC: {e_xpc} ／ JSON: {e_json}")
                    })?
            }
        };

    // 5) 连到那个监听端口
    let lstream = connect_to_device_port(host, listener_port)
        .await
        .map_err(|e| format!("连监听端口 {listener_port} 失败: {e}"))?;

    // 6) TLS-PSK + CDTunnel
    let tunnel = connect_tls_psk_tunnel_native(lstream, &key)
        .await
        .map_err(|e| format!("TLS-PSK/CDTunnel 握手失败: {e}"))?;
    let info: TunnelInfo = tunnel.info.clone();

    // 7) 用户态 TCP 适配（不需要 utun）
    let our_ip: IpAddr = info
        .client_address
        .parse()
        .map_err(|_| format!("client_address 非法: {}", info.client_address))?;
    let their_ip: IpAddr = info
        .server_address
        .parse()
        .map_err(|_| format!("server_address 非法: {}", info.server_address))?;

    let inner = tunnel.into_inner();
    let mut adapter = Adapter::new(Box::new(inner), our_ip, their_ip);
    adapter.set_mss((info.mtu as usize).saturating_sub(60));
    let mut handle = adapter.to_async_handle();

    // 8) 连 RSD 端口并握手
    let rsd_stream = handle
        .connect_to_service_port(info.server_rsd_port)
        .await
        .map_err(|e| format!("连 RSD 端口 {} 失败: {e}", info.server_rsd_port))?;
    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|e| format!("RSD 握手失败: {e}"))?;

    let services: std::collections::HashMap<String, u16> = handshake
        .services
        .iter()
        .map(|(k, v)| (k.clone(), v.port))
        .collect();

    let diag = TunnelDiag {
        client_ipv6: info.client_address.clone(),
        server_ipv6: info.server_address.clone(),
        mtu: info.mtu,
        rsd_port: info.server_rsd_port,
        rp_port: port,
        listener_port,
        service_count: services.len(),
        has_location_service: services.contains_key("com.apple.coredevice.locationservice"),
    };

    Ok(OpenTunnel {
        handle,
        services,
        diag,
    })
}

/// 在 RSD 服务表里找目标服务端口
pub fn port_of(t: &OpenTunnel, name: &str) -> Option<u16> {
    t.services.get(name).copied()
}

/// 列出全部 RSD 服务名（排查用）
pub fn service_names(t: &OpenTunnel) -> Vec<String> {
    let mut v: Vec<String> = t.services.keys().cloned().collect();
    v.sort();
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diag_json_is_well_formed() {
        let d = TunnelDiag {
            client_ipv6: "fd00::1".into(),
            server_ipv6: "fd00::2".into(),
            mtu: 16000,
            rsd_port: 58783,
            rp_port: 49152,
            listener_port: 50000,
            service_count: 42,
            has_location_service: true,
        };
        let j = d.to_json();
        assert!(j.contains("\"client\":\"fd00::1\""));
        assert!(j.contains("\"rsdPort\":58783"));
        assert!(j.contains("\"location\":true"));
        // 能被 serde_json 解析（dev-dependency 里已有）
        let v: serde_json::Value = serde_json::from_str(&j).expect("JSON 应可解析");
        assert_eq!(v["serviceCount".to_string()], serde_json::Value::Null); // 键名是 services
        assert_eq!(v["services"], 42);
        println!("✓ 诊断 JSON 合法: {}", j);
    }

    #[test]
    fn port_candidates_are_plausible() {
        assert!(RP_PORT_CANDIDATES.len() >= 4);
        assert!(RP_PORT_CANDIDATES.iter().all(|&p| p > 1024));
        let mut v = RP_PORT_CANDIDATES.to_vec();
        v.sort();
        v.dedup();
        assert_eq!(v.len(), RP_PORT_CANDIDATES.len(), "候选端口有重复");
        println!("✓ 候选端口无重复");
    }
}
