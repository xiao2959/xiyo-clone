//
//  TunnelManager.swift
//  负责：安装/启动/停止 VPN 配置，以及给扩展发控制消息
//
import NetworkExtension
import os.log

private let log = Logger(subsystem: "com.lab.xiyoclone", category: "tunnel")

@MainActor
final class TunnelManager: ObservableObject {

    @Published var status: NEVPNStatus = .invalid
    @Published var lastError: String?

    private(set) var manager: NETunnelProviderManager?

    /// 自检用：配置是否已创建
    var hasConfiguration: Bool { manager != nil }

    /// 扩展 bundle id：不写死，跟随主 App 的 bundle id
    /// （全能签这类重签工具可能改主包 id，写死就对不上了）
    var providerBundleID: String {
        let base = Bundle.main.bundleIdentifier ?? "com.lab.xiyoclone"
        return base + ".LocalVPNExtension"
    }

    /// 自检用：当前会话类型
    var sessionKind: String {
        guard let c = manager?.connection else { return "无 connection" }
        return (c as? NETunnelProviderSession) != nil ? "NETunnelProviderSession" : "其他类型"
    }

    func load() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error { self.lastError = error.localizedDescription; return }
            if let existing = managers?.first {
                self.manager = existing
                self.observe(existing)
                self.status = existing.connection.status
            } else {
                self.create()
            }
        }
    }

    private func create() {
        let m = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        // 扩展里通过 tunnelRemoteAddress 判断；这里给一个占位
        proto.serverAddress = "127.0.0.1"
        m.protocolConfiguration = proto
        m.localizedDescription = "本地定位隧道"
        m.isEnabled = true
        m.saveToPreferences { [weak self] error in
            guard let self else { return }
            if let error { self.lastError = error.localizedDescription; return }
            m.loadFromPreferences { _ in
                self.manager = m
                self.observe(m)
            }
        }
    }

    private func observe(_ m: NETunnelProviderManager) {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: m.connection, queue: .main
        ) { [weak self] _ in
            self?.status = m.connection.status
        }
    }

    func start() {
        guard let manager else { lastError = "VPN 配置还没加载"; return }
        do {
            try manager.connection.startVPNTunnel()
            status = manager.connection.status
        } catch {
            lastError = error.localizedDescription
            log.error("startVPNTunnel failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
        status = .disconnected
    }

    /// 给扩展发消息（例如触发一次注入）
    /// ★ 加了 4 秒兜底：扩展如果不回，也要让 UI 拿到结果，不能永远"无响应"
    func send(_ text: String, completion: @escaping (String?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            lastError = "connection 不是 NETunnelProviderSession"
            completion(nil); return
        }

        var finished = false
        let finish: (String?) -> Void = { value in
            if finished { return }
            finished = true
            completion(value)
        }

        do {
            try session.sendProviderMessage(Data(text.utf8)) { data in
                finish(data.flatMap { String(data: $0, encoding: .utf8) })
            }
        } catch {
            lastError = error.localizedDescription
            finish(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
    }
}
