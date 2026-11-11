//
//  TunnelModel.swift
//  共享的隧道状态 + 动作
//
//  为什么单独抽出来：
//    首页要显示「配对文件 / VPN / 隧道」三个状态灯，
//    地图页要能直接点「模拟」，两边都得读同一份状态。
//    所以把连接/注入都收在这里，视图只负责显示。
//

import Foundation
import Combine
import os.log

@MainActor
final class TunnelModel: ObservableObject {

    // MARK: - 状态（界面直接绑定）

    /// 有配对文件
    @Published var hasPairing: Bool = false
    /// 隧道是否连着
    @Published var tunnelReady: Bool = false
    /// LocalDevVPN 是否可达（nil = 还没试过）
    @Published var vpnUp: Bool? = nil
    /// 正在建隧道
    @Published var busy: Bool = false
    /// 一行状态文字
    @Published var status: String = "未连接"
    /// 最近一次注入的坐标
    @Published var lastInjected: String?
    /// 最近一次注入的纬经度（平滑移动的起点）
    @Published var lastCoord: (Double, Double)?
    /// 日志（诊断页显示）
    @Published var log: [String] = []

    private let logger = Logger(subsystem: "com.lab.xiyoclone", category: "tunnel")

    /// utun 网关：LocalDevVPN 建出来的隧道，设备的 remotepairingd 只能从这里进
    private let utunGateway = "10.7.0.1"

    var pairingPath: String { Bridge.pairingPath }

    // MARK: - 刷新本地状态

    func refresh() {
        hasPairing = FileManager.default.fileExists(atPath: pairingPath)
        let alive = TunnelBridge.alive()
        if alive && tunnelReady == false {
            tunnelReady = true
            status = "隧道已连接（复用）"
        }
        if alive == false && tunnelReady {
            tunnelReady = false
            status = "隧道已断开"
        }
    }

    func append(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("[\(f.string(from: Date()))] \(s)")
        if log.count > 200 { log.removeFirst() }
    }

    func clearLog() { log.removeAll() }

    // MARK: - 建立隧道

    func connect() async {
        guard busy == false else { return }

        guard hasPairing else {
            status = "还没有配对文件"
            append("没有配对文件，先去首页「导入配对」")
            return
        }

        // 已经连着就不重连
        if TunnelBridge.alive() {
            tunnelReady = true
            status = "隧道已连接（复用）"
            BackgroundKeeper.shared.start()
            append("隧道仍在保持，直接复用")
            return
        }

        busy = true
        defer { busy = false }

        status = "正在建立隧道…"
        append("① 浏览 _remotepairing._tcp")
        let (port, hosts, note) = await RpPortResolver.shared.resolve()
        append(note)

        // 10.7.0.1（utun 网关）是唯一能通的路径，放最前面
        var candidates: [String] = []
        for c in [utunGateway] + hosts + ["127.0.0.1"] where c.isEmpty == false {
            if candidates.contains(c) == false { candidates.append(c) }
        }

        let portNum: Int32 = port.map { Int32($0) } ?? 0
        append("② 开始建隧道（端口 \(port.map { String($0) } ?? "自动探测")）")

        var lastMsg = ""
        for host in candidates {
            append("尝试 \(host):\(port.map { String($0) } ?? "?")")
            let r = await TunnelBridge.open(host: host,
                                            rpPort: portNum,
                                            pairingPath: pairingPath)
            if r.ok {
                if host == utunGateway { vpnUp = true }
                tunnelReady = true
                status = "隧道已连接"
                append("✅ \(r.message)")
                BackgroundKeeper.shared.start()
                // 服务列表传服务器，方便远端排查
                let svc = await TunnelBridge.services()
                uploadDiag(host: host, diag: r.message, services: svc)
                return
            }
            lastMsg = r.message
            append("❌ \(lastMsg)")
            if host == utunGateway { vpnUp = false }
            // 隧道层错误换地址也没用
            if r.code == Int32(TunnelBridge.Code.noService.rawValue) { break }
        }

        tunnelReady = false
        if vpnUp == false {
            status = "请先打开 LocalDevVPN 并连接"
            append("10.7.0.1 不通 —— 需要 utun，请打开 LocalDevVPN 后重试")
        } else {
            status = "隧道连接失败"
        }
    }

    // MARK: - 注入

    /// 注入成功返回 true
    func inject(lat: Double, lon: Double) async -> Bool {
        guard busy == false else { return false }
        busy = true
        defer { busy = false }

        if TunnelBridge.alive() == false {
            append("隧道没连着，先建隧道")
            tunnelReady = false
        }

        status = "正在注入…"
        var r = await TunnelBridge.injectDVT(lat: lat, lon: lon)

        // 隧道断了就自动重连再试一次
        if r.ok == false {
            append("DVT 失败：\(r.message)")
            status = "隧道可能断了，正在重连…"
            await connectAfterFailure()
            r = await TunnelBridge.injectDVT(lat: lat, lon: lon)
        }

        if r.ok {
            tunnelReady = true
            lastInjected = String(format: "%.7f, %.7f", lat, lon)
            lastCoord = (lat, lon)
            status = "模拟成功"
            append("✅ \(r.message)")
            return true
        }

        status = "注入失败：\(r.codeText)"
        append("❌ \(r.message)")
        return false
    }

    /// 平滑移动注入：从上一个点沿直线逐步走到目标点
    ///
    /// 为什么：一步位置瞬移会被考勤类 App 判定「速度异常」，
    /// 分成 20 步、每步 150ms，看起来就像正常移动。
    @discardableResult
    func injectSmooth(from: (Double, Double)?,
                      lat: Double, lon: Double) async -> Bool {
        guard let start = from else {
            return await inject(lat: lat, lon: lon)
        }

        // 还没有会话就先在起点建一条
        if TunnelBridge.alive() == false {
            guard await inject(lat: start.0, lon: start.1) else { return false }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        guard busy == false else { return false }
        busy = true
        defer { busy = false }

        let steps = 20
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let la = start.0 + (lat - start.0) * t
            let lo = start.1 + (lon - start.1) * t
            _ = await TunnelBridge.moveDVT(lat: la, lon: lo)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        lastCoord = (lat, lon)
        lastInjected = String(format: "%.7f, %.7f", lat, lon)
        status = "模拟成功"
        append("✅ 平滑移动到位：" + lastInjected!)
        return true
    }

    func clear() async {
        _ = await TunnelBridge.clearDVT()
        _ = await TunnelBridge.clear()
        lastInjected = nil
        status = "已恢复真实定位"
        append("已清除模拟位置")
    }

    /// 注入失败后的重连（不复用走完整流程）
    private func connectAfterFailure() async {
        await TunnelBridge.close()
        tunnelReady = false
        busy = false
        await connect()
    }

    // MARK: - 断开

    func disconnect() async {
        _ = await TunnelBridge.clearDVT()
        await TunnelBridge.close()
        tunnelReady = false
        BackgroundKeeper.shared.stop()
        status = "已断开"
        append("已断开隧道")
    }

    // MARK: - 诊断上传（HTTPS，明文 HTTP 会被 ATS 拦掉）

    private func uploadDiag(host: String, diag: String, services: String) {
        guard let url = URL(string: "https://103-119-2-243.sslip.io/upload/lab2026/services.txt")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        let lines = services.split(separator: "\n").map(String.init)
        let cd = lines.filter { $0.lowercased().contains("coredevice") }
        let dt = lines.filter {
            $0.lowercased().contains(".dt.") || $0.lowercased().contains("instruments")
        }
        let body = """
        host=\(host)
        --- diag ---
        \(diag)
        --- counts ---
        total=\(lines.count) coredevice=\(cd.count) dt=\(dt.count)
        --- coredevice ---
        \(cd.joined(separator: "\n"))
        --- dt ---
        \(dt.joined(separator: "\n"))
        --- services ---
        \(services)
        """
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }
}
