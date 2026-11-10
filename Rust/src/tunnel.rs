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
//    3. RpPairingSocket::new_device + RemotePairingClient::connect
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
    // 1) 读配对文件
    let mut pf = RpPairingFile::read_from_file(pairing_path)
        .await
        .map_err(|e| format!("读 rppairing 失败: {e}"))?;

    // 2) 找 remotepairing 端口
    let port = if rp_port == 0 {
        probe_rp_port(host)
            .await
            .ok_or_else(|| "没找到 _remotepairing._tcp 端口（设备可能未开启开发者模式）".to_string())?
    } else {
        rp_port
    };

    // 3) 连接 + pair-verify（用已有配对，不需要 PIN）
    let addr = format!("{}:{}", host, port);
    let stream = tokio::time::timeout(Duration::from_secs(6), TcpStream::connect(&addr))
        .await
        .map_err(|_| format!("连接 {addr} 超时"))?
        .map_err(|e| format!("连接 {addr} 失败: {e}"))?;

    let sock = RpPairingSocket::new_device(stream);
    let mut client = RemotePairingClient::new(sock, "xiyo-lab");
    client
        .connect(&mut pf, || async { String::new() })
        .await
        .map_err(|e| format!("pair-verify 失败: {e}"))?;

    // 4) 让设备开一个 TCP 监听
    let listener_port = client
        .create_tcp_listener()
        .await
        .map_err(|e| format!("create_tcp_listener 失败: {e}"))?;
    let key = client.encryption_key().to_vec();

    // 5) 连到那个监听端口
    let laddr = format!("{}:{}", host, listener_port);
    let lstream = tokio::time::timeout(Duration::from_secs(6), TcpStream::connect(&laddr))
        .await
        .map_err(|_| format!("连接监听端口 {laddr} 超时"))?
        .map_err(|e| format!("连接监听端口 {laddr} 失败: {e}"))?;

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
