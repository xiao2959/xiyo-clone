//
//  src/pairing_kind.rs
//  配对文件类型判定 + 注入报文编码
//
//  这两块是从 pairing.rs 里抽出来、可以独立测试的纯逻辑。
//  目的：不再把 RpPairingFile 当 PairingFile 误判（上一轮「格式不对 501B」的根因）。
//

/// 配对文件类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairingKind {
    /// iOS 27 开发者模式配对产物：XML plist，键 public_key/private_key/identifier/alt_irk
    RemotePairing,
    /// 传统 lockdown 配对：含 DeviceCertificate/HostCertificate/RootCertificate
    Lockdown,
    /// 无法识别
    Unknown,
    /// 文件不存在 / 空
    Missing,
}

/// 判定配对文件类型（看头部 + 键名，不依赖任何解析器）
///
/// - `RpPairingFile::to_bytes()` 写 XML plist，头是 `<?xml version="1`，约 500 B
/// - lockdown pairing 常见是二进制 plist `bplist00`，1~2 KB，含 `HostID` 等
pub fn classify_pairing(bytes: &[u8]) -> PairingKind {
    if bytes.is_empty() {
        return PairingKind::Missing;
    }
    // 前 512 字节足够覆盖 rppairing 文件全文
    let window = &bytes[..bytes.len().min(1024)];
    let has = |needle: &[u8]| window.windows(needle.len()).any(|w| w == needle);

    if has(b"public_key") && has(b"private_key") && has(b"identifier") {
        return PairingKind::RemotePairing;
    }
    if has(b"DeviceCertificate")
        || has(b"HostCertificate")
        || has(b"RootCertificate")
        || has(b"HostID")
    {
        return PairingKind::Lockdown;
    }
    PairingKind::Unknown
}

/// 编码 `com.apple.dt.simulatelocation` 的 set 报文
///
/// 与 idevice `src/services/simulate_location.rs:29-38` 完全一致：
///   [0,0,0,0] + [lat_len BE u32] + lat_bytes + [lng_len BE u32] + lng_bytes
pub fn encode_location_set(lat: &str, lng: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + 4 + lat.len() + 4 + lng.len());
    out.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]);
    out.extend_from_slice(&(lat.len() as u32).to_be_bytes());
    out.extend_from_slice(lat.as_bytes());
    out.extend_from_slice(&(lng.len() as u32).to_be_bytes());
    out.extend_from_slice(lng.as_bytes());
    out
}

/// clear 报文
pub fn encode_location_clear() -> Vec<u8> {
    vec![0x00, 0x00, 0x00, 0x01]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_remote_pairing_xml() {
        // 与 idevice RpPairingFile::to_bytes() 同结构
        let xml = br#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN">
<plist version="1.0"><dict>
<key>public_key</key><data>AAAA</data>
<key>private_key</key><data>BBBB</data>
<key>identifier</key><string>A1B2-5678</string>
<key>alt_irk</key><data>CCCC</data>
</dict></plist>"#;
        assert_eq!(classify_pairing(xml), PairingKind::RemotePairing);
        // 用户截图里那个 501B 文件就是这一类
        assert_eq!(classify_pairing(b""), PairingKind::Missing);
        assert_eq!(classify_pairing(b"garbage"), PairingKind::Unknown);
    }

    #[test]
    fn classify_lockdown_binary() {
        let mut b = b"bplist00".to_vec();
        b.extend_from_slice(b"DeviceCertificateHostIDSystemBUID");
        assert_eq!(classify_pairing(&b), PairingKind::Lockdown);
    }

    #[test]
    fn location_set_wire_format() {
        // 对照 idevice 源码的字节布局
        let m = encode_location_set("36.7074262", "119.1567379");
        assert_eq!(&m[0..4], &[0, 0, 0, 0]);
        assert_eq!(u32::from_be_bytes(m[4..8].try_into().unwrap()), 10);
        assert_eq!(&m[8..18], b"36.7074262");
        let off = 8 + 10;
        assert_eq!(
            u32::from_be_bytes(m[off..off + 4].try_into().unwrap()),
            11
        );
        assert_eq!(&m[off + 4..], b"119.1567379");
        assert_eq!(m.len(), 4 + 4 + 10 + 4 + 11);
    }

    #[test]
    fn location_clear_wire_format() {
        assert_eq!(encode_location_clear(), vec![0, 0, 0, 1]);
    }
}
