//
//  DeepLink.swift
//  StikDebug 深链构造（纯函数，可单测）
//
//  协议来自 StikDebug 3.2.2 二进制中的字符串：
//     "Use stikdebug://simulate-location?lat=37.3349&lon=-122.0090"
//     "clear-location" / "stop-location" / "set-location"
//  以及动作名：simulate-location, set-location, stop-location, clear-location
//

import Foundation

enum DeepLink {

    /// 设置模拟位置
    /// - Parameters:
    ///   - lat/lon: 必须是 WGS-84（不能是 GCJ-02）
    static func simulate(lat: Double, lon: Double) -> String {
        let la = String(format: "%.7f", lat)
        let lo = String(format: "%.7f", lon)
        return "stikdebug://simulate-location?lat=" + la + "&lon=" + lo
    }

    /// 清除模拟位置（恢复真实定位）
    static func clear() -> String {
        return "stikdebug://clear-location"
    }

    /// 停止模拟（会终止 StikDebug 里可能存在的持续/路线模拟会话）
    static func stop() -> String {
        return "stikdebug://stop-location"
    }

    /// 停止当前模拟会话。二进制中确认 stopLocationSimulation 存在。
    static func stopSimulation() -> String {
        return "stikdebug://stop-location"
    }

    /// 校验 URL 是否可被系统接受（scheme + host + 必填参数）
    static func validate(_ s: String) -> Bool {
        guard let c = URLComponents(string: s) else { return false }
        guard c.scheme == "stikdebug" else { return false }
        if c.host == "simulate-location" {
            let names = (c.queryItems ?? []).map { $0.name }
            guard names.contains("lat"), names.contains("lon") else { return false }
            for item in (c.queryItems ?? []) where item.name == "lat" || item.name == "lon" {
                guard let v = item.value, Double(v) != nil else { return false }
            }
            return true
        }
        return c.host == "clear-location" || c.host == "stop-location"
    }
}
