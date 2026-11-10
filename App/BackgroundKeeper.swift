//
//  BackgroundKeeper.swift
//  配对期间保活
//
//  为什么需要：设备端配对要在「设置 → 开发者模式」里点，
//  这一步必然把我们的 App 切到后台。iOS 会很快挂起进程，
//  TCP 连接一断，SRP 握手就停在半路 —— 表现就是"输完密码没反应"。
//
//  做法：用「持续定位」保持后台运行。Info.plist 已有
//  UIBackgroundModes = location，所以这是被系统允许的正规方式。
//

import Foundation
import CoreLocation

final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {

    static let shared = BackgroundKeeper()

    private let manager = CLLocationManager()
    private var running = false

    /// 开始保活
    func start() {
        DispatchQueue.main.async {
            self.manager.delegate = self
            self.manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            self.manager.distanceFilter = 500

            // 关键：允许后台定位更新
            if #available(iOS 9.0, *) {
                self.manager.allowsBackgroundLocationUpdates = true
            }
            self.manager.pausesLocationUpdatesAutomatically = false

            let status = self.manager.authorizationStatus
            if status == .notDetermined {
                self.manager.requestAlwaysAuthorization()
            }

            self.manager.startUpdatingLocation()
            self.running = true
        }
    }

    /// 结束保活
    func stop() {
        DispatchQueue.main.async {
            guard self.running else { return }
            self.manager.stopUpdatingLocation()
            if #available(iOS 9.0, *) {
                self.manager.allowsBackgroundLocationUpdates = false
            }
            self.running = false
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 不关心坐标，只要进程活着
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 忽略
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // 用户授权后自动继续（startUpdatingLocation 已在 start() 里调用）
    }
}
