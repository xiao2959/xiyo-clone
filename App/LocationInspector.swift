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
}
