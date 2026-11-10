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

    /// 删掉所有旧 VPN 配置 → 重新建 → 启动 → 3 秒后 ping 一次
    /// 用来排除"配置指向旧扩展 id / 配置损坏"这类问题
    func rebuildAndStart(_ done: @escaping (String) -> Void) {
        lastError = "读取旧配置…"
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    done("读取配置失败: " + error.localizedDescription)
                }
                return
            }
            let list = managers ?? []
            DispatchQueue.main.async { self.lastError = "发现 \(list.count) 个旧配置" }
            if list.isEmpty {
                DispatchQueue.main.async { self.createAndStart(done) }
                return
            }
            var remaining = list.count
            for m in list {
                m.removeFromPreferences { _ in
                    remaining -= 1
                    if remaining == 0 {
                        DispatchQueue.main.async { self.createAndStart(done) }
                    }
                }
            }
        }
    }

    private func createAndStart(_ done: @escaping (String) -> Void) {
        lastError = "创建新配置…"
        let m = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "10.7.0.1"
        m.protocolConfiguration = proto
        m.localizedDescription = "本地定位隧道"
        m.isEnabled = true

        m.saveToPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    done("保存配置失败: " + error.localizedDescription)
                }
                return
            }
            m.loadFromPreferences { loadErr in
                DispatchQueue.main.async {
                    if let loadErr {
                        self.lastError = loadErr.localizedDescription
                        done("加载配置失败: " + loadErr.localizedDescription)
                        return
                    }
                    self.manager = m
                    self.observe(m)
                    do {
                        try m.connection.startVPNTunnel()
                    } catch {
                        self.lastError = error.localizedDescription
                        done("启动失败: " + error.localizedDescription)
                        return
                    }
                    self.lastError = "已发起连接，等 3 秒…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        let st = m.connection.status
                        self.status = st
                        self.send("ping") { reply in
                            DispatchQueue.main.async {
                                self.lastError = "状态=" + String(st.rawValue) + " 响应=" + (reply ?? "nil")
                                done("状态=" + String(st.rawValue) + "(" + TunnelManager.statusName(st) + ") 响应=" + (reply ?? "nil"))
                            }
                        }
                    }
                }
            }
        }
    }

    static func statusName(_ s: NEVPNStatus) -> String {
        switch s {
        case .invalid:      return "无效"
        case .disconnected: return "断开"
        case .connecting:   return "连接中"
        case .connected:    return "已连接"
        case .reasserting:  return "重建中"
        case .disconnecting:return "断开中"
        @unknown default:   return "未知"
        }
    }
}
