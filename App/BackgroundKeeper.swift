//
//  BackgroundKeeper.swift
//  配对期间保活
//
//  为什么需要：设备端配对要在「设置 → 开发者模式」里点，
//  这一步必然把我们的 App 切到后台。iOS 会很快挂起进程，
//  TCP 连接一断，SRP 握手就停在半路 —— 表现就是"输完密码没反应"。
//
//  ⚠️ 两个会直接闪退的坑（已修）：
//    1. allowsBackgroundLocationUpdates = true
//       必须在 Info.plist 里声明 UIBackgroundModes 含 location，
//       否则 iOS 直接抛 NSInternalInconsistencyException。
//    2. requestAlwaysAuthorization()
//       必须有 NSLocationAlwaysAndWhenInUseUsageDescription，
//       否则同样会抛异常。
//  现在两个都先检查再调用，缺了就安静降级，不再崩。
//

import Foundation
import CoreLocation
import os.log

final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {

    static let shared = BackgroundKeeper()

    private let log = Logger(subsystem: "com.lab.xiyoclone", category: "keeper")
    private let manager = CLLocationManager()
    private var running = false

    /// Info.plist 是否声明了 location 后台模式
    private var hasLocationBackgroundMode: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        else { return false }
        return modes.contains("location")
    }

    /// Info.plist 是否有「始终允许」的说明字符串
    private var hasAlwaysUsageString: Bool {
        guard let s = Bundle.main
            .object(forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription") as? String
        else { return false }
        return s.isEmpty == false
    }

    /// 开始保活
    func start() {
        DispatchQueue.main.async {
            self.manager.delegate = self
            self.manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            self.manager.distanceFilter = 500
            self.manager.pausesLocationUpdatesAutomatically = false

            // 坑 1：没有 location 后台模式就别设，否则崩
            if self.hasLocationBackgroundMode {
                self.manager.allowsBackgroundLocationUpdates = true
            } else {
                self.log.info("Info.plist 缺 UIBackgroundModes=location，跳过后台定位设置")
            }

            // 坑 2：没有「始终允许」说明字符串就别请求，否则崩
            let status = self.manager.authorizationStatus
            if status == .notDetermined {
                if self.hasAlwaysUsageString {
                    self.manager.requestAlwaysAuthorization()
                } else {
                    self.manager.requestWhenInUseAuthorization()
                }
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
            if self.hasLocationBackgroundMode {
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
        // 用户授权后继续
    }
}
