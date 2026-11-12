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
import AVFoundation
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
        startSilentAudio()
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
        stopSilentAudio()
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

    // MARK: - 静音保活
    //
    // 为什么要这个：
    //   切到别的 App（如企业微信）时，系统会挂起我们的进程，
    //   DVT 的 TCP 连接断开 → 模拟停止 → 位置跳回真实点。
    //   持续播放一段无声音频能让系统一直不挂起我们。

    private var silentPlayer: AVAudioPlayer?

    private func startSilentAudio() {
        if silentPlayer != nil { return }
        // 生成 0.5 秒静音 PCM
        let sampleRate = 8000.0
        let frames = Int(sampleRate * 0.5)
        let byteRate = 2
        let dataSize = frames * byteRate
        var wav = Data()
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(le32(UInt32(36 + dataSize)))
        wav.append("WAVEfmt ".data(using: .ascii)!)
        wav.append(le32(16))
        wav.append(le16(1))                       // PCM
        wav.append(le16(1))                       // 单声道
        wav.append(le32(UInt32(sampleRate)))
        wav.append(le32(UInt32(sampleRate) * UInt32(byteRate)))
        wav.append(le16(UInt16(byteRate)))
        wav.append(le16(16))                      // 位宽
        wav.append("data".data(using: .ascii)!)
        wav.append(le32(UInt32(dataSize)))
        wav.append(Data(count: dataSize))         // 全零 = 静音

        do {
            let player = try AVAudioPlayer(data: wav)
            player.numberOfLoops = -1
            player.volume = 0
            try AVAudioSession.sharedInstance().setCategory(.playback,
                    options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            player.play()
            silentPlayer = player
            log.info("静音保活已开启")
        } catch {
            log.error("静音保活失败: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                options: [.notifyOthersOnDeactivation])
    }
}
