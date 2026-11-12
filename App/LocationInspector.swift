//
//  LocationInspector.swift
//  读取系统定位的原始字段，看清「App 到底能拿到什么」
//
//  为什么需要它：
//    打卡类 App 判定「虚拟定位」通常是读 location.sourceInformation，
//    这里把同样的字段直接显示出来，一眼就能看出问题在哪。
//

import Foundation
import CoreLocation
import Combine

final class LocationInspector: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var authorized: CLAuthorizationStatus = .notDetermined
    @Published var lat: Double = 0
    @Published var lon: Double = 0
    @Published var accuracy: Double = -1
    @Published var altitude: Double = 0
    @Published var speed: Double = -1
    @Published var course: Double = -1
    @Published var ts: Date?
    @Published var ageText: String = "—"

    /// 关键：系统是否认为这是软件模拟的位置
    @Published var simulatedBySoftware: Bool?
    /// 关键：位置是否来自外接配件
    @Published var producedByAccessory: Bool?

    @Published var running = false

    private let mgr = CLLocationManager()

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
        mgr.distanceFilter = kCLDistanceFilterNone
        authorized = mgr.authorizationStatus
    }

    func start() {
        running = true
        if mgr.authorizationStatus == .notDetermined {
            mgr.requestWhenInUseAuthorization()
        }
        mgr.startUpdatingLocation()
    }

    func stop() {
        running = false
        mgr.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorized = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.lat = loc.coordinate.latitude
            self.lon = loc.coordinate.longitude
            self.accuracy = loc.horizontalAccuracy
            self.altitude = loc.altitude
            self.speed = loc.speed
            self.course = loc.course
            self.ts = loc.timestamp

            let age = -loc.timestamp.timeIntervalSinceNow
            self.ageText = age < 1 ? "刚刚" : String(format: "%.0f 秒前", age)

            if #available(iOS 15.0, *) {
                if let src = loc.sourceInformation {
                    self.simulatedBySoftware = src.isSimulatedBySoftware
                    self.producedByAccessory = src.isProducedByAccessory
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 忽略，页面上看最后一帧即可
    }

    var authText: String {
        switch authorized {
        case .notDetermined: return "未询问"
        case .restricted:    return "受限"
        case .denied:        return "已拒绝"
        case .authorizedAlways: return "始终允许"
        case .authorizedWhenInUse: return "使用期间"
        @unknown default:    return "未知"
        }
    }

    /// 一句话结论
    var verdict: String {
        if simulatedBySoftware == true {
            return "系统标记为「软件模拟」——打卡类 App 一读就知道"
        }
        if producedByAccessory == true {
            return "系统标记为「外设提供」——高德会提示断开外设"
        }
        if simulatedBySoftware == false || producedByAccessory == false {
            return "系统认为这是真实定位（没有被标记为模拟）"
        }
        return "等待第一次定位…"
    }

    // MARK: - 环境自查（企业微信类 App 能看到的东西）

    /// 是否有 utun 虚拟网卡（=有 VPN 在运行）
    func hasTunnelInterface() -> (Bool, [String]) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (false, []) }
        defer { freeifaddrs(addrs) }
        var names: Set<String> = []
        var cur = first
        while true {
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") {
                names.insert(name)
            }
            guard let next = cur.pointee.ifa_next else { break }
            cur = next
        }
        return (!names.isEmpty, names.sorted())
    }

    /// 系统代理是否开着
    func proxySettings() -> (Bool, String) {
        guard let cf = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let d = cf as? [String: Any] else { return (false, "读不到") }
        var on = false
        var parts: [String] = []
        if let http = d["HTTPEnable"] as? Int, http == 1 {
            on = true; parts.append("HTTP")
        }
        if let https = d["HTTPSEnable"] as? Int, https == 1 {
            on = true; parts.append("HTTPS")
        }
        if let pac = d["ProxyAutoConfigEnable"] as? Int, pac == 1 {
            on = true; parts.append("PAC")
        }
        if let socks = d["SOCKSEnable"] as? Int, socks == 1 {
            on = true; parts.append("SOCKS")
        }
        return (on, parts.isEmpty ? "无" : parts.joined(separator: " + "))
    }

    /// 把当前系统定位字段打成一段文本（用于上传排查）
    func snapshotText() -> String {
        var out = ""
        out += "coords=\(String(format: "%.7f,%.7f", lat, lon))\n"
        out += "accuracy=\(String(format: "%.2f", accuracy))\n"
        out += "altitude=\(String(format: "%.2f", altitude))\n"
        out += "speed=\(String(format: "%.2f", speed))\n"
        out += "course=\(String(format: "%.2f", course))\n"
        out += "age=\(ageText)\n"
        out += "auth=\(authText)\n"
        out += "simulated=\(simulatedBySoftware.map { $0 ? "是" : "否" } ?? "未提供")\n"
        out += "accessory=\(producedByAccessory.map { $0 ? "是" : "否" } ?? "未提供")\n"
        let ut = hasTunnelInterface()
        out += "utun=\(ut.0 ? ut.1.joined(separator: ",") : "无")\n"
        let px = proxySettings()
        out += "proxy=\(px.0 ? px.1 : "无")\n"
        return out
    }
}
