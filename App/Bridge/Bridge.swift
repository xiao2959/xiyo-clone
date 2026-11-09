//
//  Bridge.swift —— Rust `idevice_ffi` 的 Swift 封装（配对 + 注入）
//
//  对应 Rust/src/pairing.rs 的导出：
//     pairing_start(name, save_path) -> port
//     pairing_take_pin(buf, cap)     -> len
//     pairing_wait(timeout_ms)       -> 0 ok / -1 超时 / -2 失败 / -3 无会话
//     pairing_status(buf, cap)       -> "paired:<udid>" / "waiting_pin" / "error:..."
//     pairing_service_type / pairing_identifier / pairing_txt
//     simulate_location(pairing_path, host, lat, lng)
//     clear_location(pairing_path, host)
//
//  ⚠️ 必须先连本地 VPN（10.7.0.1 可达），注入才会成功。
//

import Foundation

// MARK: - C ABI（符号名与 Rust #[no_mangle] 一一对应）

@_silgen_name("pairing_start")
private func c_pairing_start(_ name: UnsafePointer<CChar>?, _ savePath: UnsafePointer<CChar>?) -> Int32

@_silgen_name("pairing_take_pin")
private func c_pairing_take_pin(_ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32

@_silgen_name("pairing_wait")
private func c_pairing_wait(_ timeoutMs: Int32) -> Int32

@_silgen_name("pairing_status")
private func c_pairing_status(_ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32

@_silgen_name("pairing_service_type")
private func c_pairing_service_type(_ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32

@_silgen_name("pairing_identifier")
private func c_pairing_identifier(_ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32

@_silgen_name("pairing_txt")
private func c_pairing_txt(_ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32

@_silgen_name("simulate_location")
private func c_simulate_location(_ path: UnsafePointer<CChar>?, _ host: UnsafePointer<CChar>?,
                                 _ lat: Double, _ lng: Double) -> Int32

@_silgen_name("clear_location")
private func c_clear_location(_ path: UnsafePointer<CChar>?, _ host: UnsafePointer<CChar>?) -> Int32

// MARK: - 高层封装

enum Bridge {

    /// App Group 里的 pairing.plist 路径
    static var pairingPath: String {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lab.xiyoclone")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("pairing.plist").path
    }

    // MARK: 配对

    /// 启动本地配对服务，返回监听端口（>0 成功）
    static func pairingStart(name: String, savePath: String) -> Int32 {
        name.withCString { n in
            savePath.withCString { p in
                c_pairing_start(n, p)
            }
        }
    }

    /// 取 6 位码（没有则 nil）
    static func pairingTakePin() -> String? {
        var buf = [CChar](repeating: 0, count: 32)
        let n = c_pairing_take_pin(&buf, 32)
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// 等配对结果：0=成功 -1=超时/进行中 -2=失败 -3=无会话
    static func pairingWait(timeoutMs: Int32) -> Int32 {
        c_pairing_wait(timeoutMs)
    }

    /// "paired:<udid>" / "waiting_pin" / "error:..." / "idle"
    static func pairingStatus() -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = c_pairing_status(&buf, 256)
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    static func pairingServiceType(into buf: inout [CChar]) -> String? {
        let n = c_pairing_service_type(&buf, Int32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    static func pairingIdentifier(into buf: inout [CChar]) -> String? {
        let n = c_pairing_identifier(&buf, Int32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    static func pairingTXT(into buf: inout [CChar]) -> String? {
        let n = c_pairing_txt(&buf, Int32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: 注入

    /// 注入坐标（会新建一次到设备的连接）
    static func simulate(lat: Double, lng: Double, host: String = "10.7.0.1") -> Int32 {
        let path = pairingPath
        return path.withCString { p in
            host.withCString { h in
                c_simulate_location(p, h, lat, lng)
            }
        }
    }

    /// 恢复真实定位
    static func clear(host: String = "10.7.0.1") -> Int32 {
        let path = pairingPath
        return path.withCString { p in
            host.withCString { h in
                c_clear_location(p, h)
            }
        }
    }
}
