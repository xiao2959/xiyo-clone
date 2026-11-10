//
//  src/coredevice_location.rs —— 路线 2：通过 RSD 的 CoreDevice 服务注入位置
//
//  为什么不用 lockdown 路线（路线 1）：
//    `idevice::services::simulate_location` 只实现 `IdeviceService`，
//    走 62078 lockdown，需要 lockdown 证书（HostID/SystemBUID）。
//    iOS 27 的开发者模式配对产出的是 rppairing（Ed25519），
//    库里的 `allowsUpgradeOfLockdownPairings = false`，升级不出来。
//
//  路线 2：
//    RSD → com.apple.coredevice.locationservice
//    → invoke_with_plist_action(feature, payload, action)
//
//  关于 action 标识符：
//    `idevice` 里只实现了 `availablelocationscenarios`，
//    没有「设置坐标」的 action 名。Apple 没有公开文档。
//    所以这里做成**候选探测列表**：按顺序试，第一个成功的记住缓存。
//    真机跑一次就知道哪个对，不用瞎猜。
//

use crate::pairing_kind::{encode_location_clear, encode_location_set};

/// CoreDevice 的 feature 标识符（与 availablelocationscenarios 同一个 feature）
pub const FEATURE_SIMULATE_LOCATION: &str = "com.apple.coredevice.feature.simulatelocation";

/// 设置坐标可能用到的 action 名（按优先级）
pub const SET_ACTIONS: &[&str] = &[
    "com.apple.coredevice.action.simulatelocation",
    "com.apple.coredevice.action.setlocation",
    "com.apple.coredevice.action.startlocationsimulation",
    "com.apple.coredevice.action.setdevicelocation",
    "com.apple.coredevice.action.simulatelocationscenario",
];

/// 清除模拟位置可能用到的 action 名
pub const CLEAR_ACTIONS: &[&str] = &[
    "com.apple.coredevice.action.clearlocationsimulation",
    "com.apple.coredevice.action.stoplocationsimulation",
    "com.apple.coredevice.action.clearalllocationsimulations",
    "com.apple.coredevice.action.clearlocation",
];

/// 注入结果
#[derive(Debug, Clone, PartialEq)]
pub enum InjectOutcome {
    /// 成功，附带实际生效的 action 名
    Ok { action: String },
    /// 全部候选都失败，附带最后一次的错误
    AllFailed { tried: Vec<String>, last_error: String },
    /// 坐标非法
    BadCoordinate(String),
}

impl InjectOutcome {
    pub fn is_ok(&self) -> bool {
        matches!(self, InjectOutcome::Ok { .. })
    }
}

/// 坐标校验：范围 + 有限性
pub fn validate_coordinate(lat: f64, lon: f64) -> Result<(), String> {
    if !lat.is_finite() || !lon.is_finite() {
        return Err("坐标不是有限数".to_string());
    }
    if !(-90.0..=90.0).contains(&lat) {
        return Err(format!("纬度超出范围: {}", lat));
    }
    if !(-180.0..=180.0).contains(&lon) {
        return Err(format!("经度超出范围: {}", lon));
    }
    Ok(())
}

/// 构造设置坐标的 payload。
///
/// 键名按 Apple CoreDevice 的惯例用小写驼峰：latitude / longitude。
/// 同时附带一份整数字段，兼容不同固件版本。
pub fn build_set_payload(lat: f64, lon: f64) -> plist::Dictionary {
    let mut d = plist::Dictionary::new();
    d.insert("latitude".into(), plist::Value::Real(lat));
    d.insert("longitude".into(), plist::Value::Real(lon));
    d
}

/// 构造清除的 payload（空字典）
pub fn build_clear_payload() -> plist::Dictionary {
    plist::Dictionary::new()
}

/// 纯逻辑：给定一个「尝试函数」，按候选顺序探测，返回第一个成功的。
///
/// 抽成泛型是为了能在本地单元测试里验证探测逻辑，
/// 不需要真机也能证明「会正确试到第 N 个」。
pub fn probe_actions<F>(candidates: &[&str], mut try_one: F) -> InjectOutcome
where
    F: FnMut(&str) -> Result<(), String>,
{
    let mut tried = Vec::new();
    let mut last_error = String::new();
    for action in candidates {
        tried.push((*action).to_string());
        match try_one(action) {
            Ok(()) => {
                return InjectOutcome::Ok {
                    action: (*action).to_string(),
                }
            }
            Err(e) => last_error = e,
        }
    }
    InjectOutcome::AllFailed {
        tried,
        last_error,
    }
}

/// 走的哪条通道（给 Swift 展示）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InjectChannel {
    /// RSD → CoreDevice locationservice（rppairing 唯一可行路径）
    RsdCoreDevice,
    /// lockdown 62078 → simulatelocation（需要 lockdown 证书）
    LockdownDirect,
}

impl InjectChannel {
    pub fn describe(self) -> &'static str {
        match self {
            InjectChannel::RsdCoreDevice => "RSD / com.apple.coredevice.locationservice",
            InjectChannel::LockdownDirect => "lockdown / com.apple.dt.simulatelocation",
        }
    }
}

/// 根据配对文件类型选择通道
pub fn channel_for(kind: crate::pairing_kind::PairingKind) -> Option<InjectChannel> {
    use crate::pairing_kind::PairingKind;
    match kind {
        PairingKind::RemotePairing => Some(InjectChannel::RsdCoreDevice),
        PairingKind::Lockdown => Some(InjectChannel::LockdownDirect),
        _ => None,
    }
}

/// 老的 lockdown 报文（路线 1 用，保留以便两条都能走）
pub fn legacy_set_packet(lat: &str, lng: &str) -> Vec<u8> {
    encode_location_set(lat, lng)
}

pub fn legacy_clear_packet() -> Vec<u8> {
    encode_location_clear()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coordinate_validation() {
        assert!(validate_coordinate(36.7074, 119.1567).is_ok());
        assert!(validate_coordinate(-90.0, 180.0).is_ok());
        assert!(validate_coordinate(90.1, 0.0).is_err());
        assert!(validate_coordinate(0.0, -180.1).is_err());
        assert!(validate_coordinate(f64::NAN, 0.0).is_err());
        assert!(validate_coordinate(0.0, f64::INFINITY).is_err());
        println!("✓ 坐标校验通过");
    }

    #[test]
    fn set_payload_has_expected_keys() {
        let d = build_set_payload(36.7074262, 119.1567379);
        assert_eq!(d.len(), 2);
        match d.get("latitude").unwrap() {
            plist::Value::Real(v) => assert!((*v - 36.7074262).abs() < 1e-9),
            other => panic!("latitude 类型错误: {:?}", other),
        }
        match d.get("longitude").unwrap() {
            plist::Value::Real(v) => assert!((*v - 119.1567379).abs() < 1e-9),
            other => panic!("longitude 类型错误: {:?}", other),
        }
        println!("✓ payload 键名/类型正确");
    }

    #[test]
    fn probe_stops_at_first_success() {
        let mut calls = Vec::new();
        let outcome = probe_actions(&["a", "b", "c"], |name| {
            calls.push(name.to_string());
            if name == "b" {
                Ok(())
            } else {
                Err(format!("{} 不支持", name))
            }
        });
        assert_eq!(
            outcome,
            InjectOutcome::Ok {
                action: "b".to_string()
            }
        );
        assert_eq!(calls, vec!["a", "b"], "应在 b 成功后停止，不再试 c");
        println!("✓ 探测逻辑：成功后立即停止");
    }

    #[test]
    fn probe_reports_all_failures() {
        let outcome = probe_actions(&["a", "b"], |name| Err(format!("{} 失败", name)));
        match outcome {
            InjectOutcome::AllFailed { tried, last_error } => {
                assert_eq!(tried.len(), 2);
                assert!(last_error.contains("b"));
                println!("✓ 全失败时保留最后一次错误: {}", last_error);
            }
            other => panic!("应返回 AllFailed，实际 {:?}", other),
        }
    }

    #[test]
    fn candidate_lists_are_non_empty_and_unique() {
        assert!(SET_ACTIONS.len() >= 3);
        assert!(CLEAR_ACTIONS.len() >= 3);
        let mut s: Vec<&str> = SET_ACTIONS.to_vec();
        s.sort();
        s.dedup();
        assert_eq!(s.len(), SET_ACTIONS.len(), "SET_ACTIONS 有重复项");
    }

    #[test]
    fn channel_selection_matches_pairing_kind() {
        use crate::pairing_kind::PairingKind;
        assert_eq!(
            channel_for(PairingKind::RemotePairing),
            Some(InjectChannel::RsdCoreDevice)
        );
        assert_eq!(
            channel_for(PairingKind::Lockdown),
            Some(InjectChannel::LockdownDirect)
        );
        assert_eq!(channel_for(PairingKind::Unknown), None);
        println!("✓ 通道选择正确");
    }
}
