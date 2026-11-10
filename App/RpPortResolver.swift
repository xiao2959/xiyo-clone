//
//  RpPortResolver.swift
//  解析 _remotepairing._tcp 的真实端口
//
//  为什么需要：
//    之前 Rust 侧是「硬编码候选端口逐个 TCP 探测」（49152/49153/…）。
//    实证表明这样找不到 —— 设备上的 remotepairingd 端口并不固定，
//    它是通过 mDNS 广播的。
//
//    StikDebug 里有 RemotePairingPortResolver 这个类，思路一致：
//    浏览 _remotepairing._tcp → resolve → 拿 host/port → 再连。
//
//  Info.plist 里已声明 NSBonjourServices 含 _remotepairing._tcp.，
//  否则浏览会被系统静默拒绝。
//

import Foundation
import os.log

final class RpPortResolver: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {

    static let shared = RpPortResolver()

    private let log = Logger(subsystem: "com.lab.xiyoclone", category: "portresolver")

    private var browser: NetServiceBrowser?
    private var pending: [NetService] = []
    private var completion: ((UInt16?, String) -> Void)?
    private var foundPort: UInt16?
    private var timer: Timer?
    private var finished = false

    /// 浏览并解析，最多等 `timeout` 秒
    /// - Returns: (端口, 说明)
    func resolve(timeout: TimeInterval = 7) async -> (UInt16?, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                self.begin(timeout: timeout) { port, note in
                    cont.resume(returning: (port, note))
                }
            }
        }
    }

    private func begin(timeout: TimeInterval, completion: @escaping (UInt16?, String) -> Void) {
        // 同一时刻只跑一个
        if self.completion != nil {
            completion(nil, "上一个解析还没结束")
            return
        }
        self.completion = completion
        foundPort = nil
        finished = false

        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        browser = b
        log.info("开始浏览 _remotepairing._tcp")

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            self.finish(note: "浏览超时（\(Int(timeout))s），未发现 _remotepairing._tcp")
        }
    }

    private func finish(note: String) {
        guard finished == false else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        browser?.stop()
        browser = nil
        for s in pending { s.stop() }
        pending.removeAll()

        let cb = completion
        completion = nil
        log.info("解析结束: \(note, privacy: .public)")
        cb?(foundPort, note)
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        log.info("发现服务: \(service.name, privacy: .public) type=\(service.type, privacy: .public)")
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 6)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        finish(note: "浏览失败: \(errorDict)")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        // 停止不代表失败，等 resolve 结果
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        let port = UInt16(truncatingIfNeeded: sender.port)
        if port > 0 {
            foundPort = port
            finish(note: "解析到端口 \(port)（\(sender.name)）")
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        log.error("resolve 失败: \(sender.name, privacy: .public) \(errorDict)")
    }
}
