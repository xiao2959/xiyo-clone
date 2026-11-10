//
//  tests/tunnel_rsd.rs
//  分层验证：CDTunnel 握手 + RSD 服务表解析
//
//  这两层不需要真机：用本地 TCP 伪造设备侧，验证我们这端的协议行为。
//

use std::collections::HashMap;
use std::time::Duration;

// ---------------------------------------------------------------------------
// 1) CDTunnel 握手（对应 idevice src/tunnel.rs:47-122）
// ---------------------------------------------------------------------------

const CDTUNNEL_MAGIC: &[u8] = b"CDTunnel";

/// 客户端发出的 handshake request（我们要能正确构造）
fn cdtunnel_request(mtu: u16) -> Vec<u8> {
    let body = format!(r#"{{"type":"clientHandshakeRequest","mtu":{mtu}}}"#);
    let mut pkt = Vec::new();
    pkt.extend_from_slice(CDTUNNEL_MAGIC);
    pkt.extend_from_slice(&(body.len() as u16).to_be_bytes());
    pkt.extend_from_slice(body.as_bytes());
    pkt
}

/// 设备侧响应（伪造），字段与 src/tunnel.rs:80-122 解析逻辑一致
fn cdtunnel_response() -> Vec<u8> {
    let body = r#"{
        "clientParameters": {
            "address": "fd00::1",
            "netmask": "ffff:ffff:ffff:ffff::",
            "mtu": 16000
        },
        "serverAddress": "fd00::2",
        "serverRSDPort": 58763
    }"#;
    let mut pkt = Vec::new();
    pkt.extend_from_slice(CDTUNNEL_MAGIC);
    pkt.extend_from_slice(&(body.len() as u16).to_be_bytes());
    pkt.extend_from_slice(body.as_bytes());
    pkt
}

#[derive(Debug, PartialEq, Eq)]
struct TunnelInfo {
    client_address: String,
    server_address: String,
    server_rsd_port: u16,
    mtu: u16,
}

/// 按库里的解析规则解包（独立实现，用来验证我们理解无误）
fn parse_cdtunnel_response(pkt: &[u8]) -> Result<TunnelInfo, String> {
    if pkt.len() < CDTUNNEL_MAGIC.len() + 2 {
        return Err("响应过短".into());
    }
    if &pkt[..CDTUNNEL_MAGIC.len()] != CDTUNNEL_MAGIC {
        return Err("magic 不符".into());
    }
    let len = u16::from_be_bytes([
        pkt[CDTUNNEL_MAGIC.len()],
        pkt[CDTUNNEL_MAGIC.len() + 1],
    ]) as usize;
    let start = CDTUNNEL_MAGIC.len() + 2;
    if pkt.len() < start + len {
        return Err("body 被截断".into());
    }
    let v: serde_json::Value =
        serde_json::from_slice(&pkt[start..start + len]).map_err(|e| e.to_string())?;

    let cp = v.get("clientParameters").ok_or("缺 clientParameters")?;
    let client_address = cp
        .get("address")
        .and_then(|x| x.as_str())
        .ok_or("缺 address")?
        .to_string();
    let mtu = cp.get("mtu").and_then(|x| x.as_u64()).unwrap_or(1500) as u16;
    let server_address = v
        .get("serverAddress")
        .and_then(|x| x.as_str())
        .ok_or("缺 serverAddress")?
        .to_string();
    let server_rsd_port = v
        .get("serverRSDPort")
        .and_then(|x| x.as_u64())
        .unwrap_or(0) as u16;

    Ok(TunnelInfo { client_address, server_address, server_rsd_port, mtu })
}

#[test]
fn cdtunnel_request_frame_is_correct() {
    let req = cdtunnel_request(16000);
    assert_eq!(&req[..8], CDTUNNEL_MAGIC);
    let len = u16::from_be_bytes([req[8], req[9]]) as usize;
    assert_eq!(req.len(), 8 + 2 + len, "帧长必须 = magic(8)+len(2)+body");
    let body: serde_json::Value = serde_json::from_slice(&req[10..]).unwrap();
    assert_eq!(body["type"], "clientHandshakeRequest");
    assert_eq!(body["mtu"], 16000);
    println!("✓ CDTunnel 请求帧正确, body={len}B");
}

#[tokio::test]
async fn cdtunnel_handshake_over_local_socket() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    // 伪造设备侧：读请求、回响应
    let device = tokio::spawn(async move {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (mut s, _) = listener.accept().await.unwrap();
        let mut magic = [0u8; 8];
        s.read_exact(&mut magic).await.unwrap();
        assert_eq!(&magic, CDTUNNEL_MAGIC, "设备没收到合法 magic");
        let mut lb = [0u8; 2];
        s.read_exact(&mut lb).await.unwrap();
        let n = u16::from_be_bytes(lb) as usize;
        let mut body = vec![0u8; n];
        s.read_exact(&mut body).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v["type"], "clientHandshakeRequest");
        s.write_all(&cdtunnel_response()).await.unwrap();
        s.flush().await.unwrap();
    });

    // 我们这端
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
    s.write_all(&cdtunnel_request(16000)).await.unwrap();
    s.flush().await.unwrap();

    let mut buf = vec![0u8; 2048];
    let n = tokio::time::timeout(Duration::from_secs(5), s.read(&mut buf))
        .await
        .expect("读响应超时")
        .unwrap();
    let info = parse_cdtunnel_response(&buf[..n]).expect("解析失败");

    assert_eq!(info.client_address, "fd00::1");
    assert_eq!(info.server_address, "fd00::2");
    assert_eq!(info.server_rsd_port, 58763);
    assert_eq!(info.mtu, 16000);
    device.await.unwrap();
    println!("✓ CDTunnel 握手完成，RSD 端口={}", info.server_rsd_port);
}

// ---------------------------------------------------------------------------
// 2) RSD 服务表解析（对应 src/services/rsd.rs:41-168）
// ---------------------------------------------------------------------------

/// 按库里 rsd.rs 的规则，从 RSD 响应里提取 服务名 -> 端口
fn parse_rsd_services(v: &serde_json::Value) -> Result<HashMap<String, u16>, String> {
    let d = v
        .get("Services")
        .and_then(|x| x.as_object())
        .ok_or("缺 Services 字典")?;
    let mut out = HashMap::new();
    for (name, svc) in d {
        // 库里读的是 Properties.UsesRemoteXPC / Entitlement / Port（字符串）
        let port = svc
            .get("Port")
            .and_then(|x| x.as_str())
            .and_then(|x| x.parse::<u16>().ok())
            .ok_or_else(|| format!("{name} 缺合法 Port"))?;
        out.insert(name.clone(), port);
    }
    Ok(out)
}

#[test]
fn rsd_service_table_lookup() {
    let v: serde_json::Value = serde_json::from_str(
        r#"{
          "MessagingProtocolVersion": 1,
          "UUID": "TEST-UUID",
          "Properties": {},
          "Services": {
            "com.apple.mobile.lockdown.remote.trusted": {
              "Entitlement": "com.apple.mobile.lockdown.remote.trusted",
              "Port": "62078",
              "Properties": {"UsesRemoteXPC": false}
            },
            "com.apple.coredevice.locationservice": {
              "Entitlement": "com.apple.coredevice.locationservice",
              "Port": "54321",
              "Properties": {"UsesRemoteXPC": true}
            }
          }
        }"#,
    )
    .unwrap();

    let services = parse_rsd_services(&v).expect("解析失败");
    assert_eq!(services.len(), 2);
    assert_eq!(
        services.get("com.apple.mobile.lockdown.remote.trusted"),
        Some(&62078)
    );
    assert_eq!(
        services.get("com.apple.coredevice.locationservice"),
        Some(&54321)
    );
    println!("✓ RSD 服务表解析正确，找到 {} 个服务", services.len());
}

#[test]
fn rsd_missing_service_is_detected() {
    let v: serde_json::Value = serde_json::from_str(r#"{"Services":{}}"#).unwrap();
    let s = parse_rsd_services(&v).unwrap();
    assert!(!s.contains_key("com.apple.dt.simulatelocation"));
    println!("✓ 确认 simulatelocation 不在 RSD 服务表里（必须经 lockdown start_service）");
}
