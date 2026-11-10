//
//  src/inject.rs —— 注入链路（A 轮重构）
//
//  架构结论见 docs/A-RSD-ARCHITECTURE.md。
//
//  关键修正（相对旧 pairing.rs）：
//   旧：PairingFile::read_from_file(rppairing 文件) → 必然失败 → 返回 -1
//   新：RpPairingFile::read_from_file() 读 rppairing 文件，走 rppairing 通道
//
//  ⚠️ 当前状态：
//   - 类型判定 / 报文编码 / CDTunnel 握手 / RSD 表解析 均已有本地测试
//   - 真机 TLS-PSK + 用户态 IPv6 栈这一段无法在 Windows 本地验证，
//     代码里保持显式返回错误码，不假装成功
//

use crate::pairing_kind::{PairingKind, classify_pairing, encode_location_set, encode_location_clear};

/// 注入返回码（给 Swift 展示用，避免再出现"只看到 -1"）
pub mod rc {
    pub const OK: i32 = 0;
    pub const FILE_MISSING: i32 = -1;
    pub const FILE_IS_LOCKDOWN: i32 = -10;   // 拿错体系的文件
    pub const FILE_IS_RPPAIRING_BUT_NO_TUNNEL: i32 = -11; // rppairing 有效，但隧道还没打通
    pub const TUNNEL_UNVERIFIED: i32 = -20;
    pub const UNKNOWN_FILE: i32 = -30;
}

/// 纯逻辑：根据文件内容决定下一步
/// 这是本轮最关键的修正 —— 不再把 501B rppairing 误判为"格式不对"
pub fn decide(bytes: &[u8]) -> (PairingKind, i32) {
    match classify_pairing(bytes) {
        PairingKind::RemotePairing => {
            // rppairing 有效；注入必须走 TLS-PSK/CDTunnel/RSD，
            // 该段尚未在真机验证，明确返回待实现，不伪造成功
            (PairingKind::RemotePairing, rc::FILE_IS_RPPAIRING_BUT_NO_TUNNEL)
        }
        PairingKind::Lockdown => {
            // 传统 lockdown 文件才可以直接走 LocationSimulationService
            (PairingKind::Lockdown, rc::OK)
        }
        PairingKind::Unknown => (PairingKind::Unknown, rc::UNKNOWN_FILE),
        PairingKind::Missing => (PairingKind::Missing, rc::FILE_MISSING),
    }
}

/// 生成注入报文（与 idevice simulate_location.rs 完全一致）
pub fn build_set_packet(lat: &str, lng: &str) -> Vec<u8> {
    encode_location_set(lat, lng)
}

/// 生成清除报文
pub fn build_clear_packet() -> Vec<u8> {
    encode_location_clear()
}

/// 人类可读的返回码说明（Swift 直接显示）
pub fn describe(rc: i32) -> &'static str {
    match rc {
        rc::OK => "OK",
        rc::FILE_MISSING => "配对文件不存在",
        rc::FILE_IS_LOCKDOWN => "lockdown 配对文件（可直连）",
        rc::FILE_IS_RPPAIRING_BUT_NO_TUNNEL => "rppairing 配对有效，隧道链路待真机验证",
        rc::TUNNEL_UNVERIFIED => "隧道未验证",
        rc::UNKNOWN_FILE => "未知文件格式",
        _ => "未知错误",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_501b_file_is_recognized_as_valid_rppairing() {
        // 复刻用户截图里的文件头与键名
        let xml = br#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>public_key</key><data>AAAA</data>
<key>private_key</key><data>BBBB</data>
<key>identifier</key><string>ABCD-1234</string>
<key>alt_irk</key><data>CCCC</data>
</dict></plist>"#;
        let (kind, code) = decide(xml);
        assert_eq!(kind, PairingKind::RemotePairing);
        assert_eq!(code, rc::FILE_IS_RPPAIRING_BUT_NO_TUNNEL);
        assert_eq!(describe(code), "rppairing 配对有效，隧道链路待真机验证");
        println!("✓ 501B 文件被正确识别为有效 rppairing（不再误报格式不对）");
    }

    #[test]
    fn lockdown_file_still_routes_to_direct_injection() {
        let mut b = b"bplist00".to_vec();
        b.extend_from_slice(b"DeviceCertificateHostIDSystemBUID");
        let (kind, code) = decide(&b);
        assert_eq!(kind, PairingKind::Lockdown);
        assert_eq!(code, rc::OK);
    }

    #[test]
    fn missing_and_unknown_are_distinguished() {
        assert_eq!(decide(b"").1, rc::FILE_MISSING);
        assert_eq!(decide(b"hello").1, rc::UNKNOWN_FILE);
    }

    #[test]
    fn set_packet_matches_library_byte_layout() {
        let p = build_set_packet("36.7074262", "119.1567379");
        assert_eq!(&p[0..4], &[0, 0, 0, 0]);
        assert_eq!(p.len(), 4 + 4 + 10 + 4 + 11);
        assert_eq!(build_clear_packet(), vec![0, 0, 0, 1]);
    }
}
