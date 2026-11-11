//
//  DirectInjectView.swift
//  直连注入 —— 用内置隧道（Rust idevice）直接注入，不再依赖 StikDebug
//
//  流程：
//    1. 选 rppairing 配对文件（iOS 开发者模式配对产出，约 500 B，<?xml 开头）
//    2. 建隧道（rppairing → TLS-PSK → CDTunnel → RSD）
//    3. 注入坐标
//

import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

struct DirectInjectView: View {
    @Environment(\.dismiss) private var dismiss

    /// 从主界面传进来的目标坐标
    let target: CLLocationCoordinate2D?

    @State private var pairingURL: URL?
    @State private var showPicker = false
    @State private var showPairing = false
    @State private var busy = false
    @State private var tunnelReady = false
    @State private var log: [String] = []
    @State private var status = "还没建隧道"

    /// 根据当前进度提示下一步该点哪个
    private var nextStepHint: String {
        if pairingURL == nil {
            return "① 还没配对文件 —— 点上面「生成配对文件（App 内配对）」"
        }
        return "② 配对文件已就绪 —— 点「① 建立隧道」"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("配对文件") {
                    if let u = pairingURL {
                        Text(u.lastPathComponent)
                            .font(.system(.footnote, design: .monospaced))
                    } else {
                        Text("还没配对")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showPairing = true
                    } label: {
                        Label(pairingURL == nil ? "生成配对文件（App 内配对）" : "重新配对",
                              systemImage: "person.badge.key")
                            .fontWeight(.semibold)
                    }
                    Button {
                        showPicker = true
                    } label: {
                        Label("从文件导入", systemImage: "doc.badge.plus")
                    }
                    Text("点「生成配对文件」→ 按提示到 设置 里输入 6 位码 → 自动保存，不用手动找文件")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("状态") {
                    Text(status)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(busy ? Color.orange : Color.primary)
                }

                Section("操作（按 1 → 2 → 3 顺序）") {
                    Button {
                        Task { await openTunnel() }
                    } label: {
                        HStack {
                            Text("①").foregroundStyle(.secondary)
                            Label("建立隧道", systemImage: "link")
                        }
                    }
                    .disabled(busy || pairingURL == nil || tunnelReady)

                    Button {
                        Task { await doInject() }
                    } label: {
                        HStack {
                            Text("②").foregroundStyle(.secondary)
                            Label("注入当前坐标", systemImage: "location.fill")
                        }
                    }
                    .disabled(busy || target == nil || tunnelReady == false)

                    Button {
                        Task { await doClear() }
                    } label: {
                        HStack {
                            Text("③").foregroundStyle(.secondary)
                            Label("清除模拟位置", systemImage: "arrow.uturn.backward")
                        }
                    }
                    .disabled(busy || tunnelReady == false)

                    Button {
                        Task { await showServices() }
                    } label: {
                        HStack {
                            Text("ⓘ").foregroundStyle(.secondary)
                            Label("查看 RSD 服务列表", systemImage: "list.bullet")
                        }
                    }
                    .disabled(busy || tunnelReady == false)

                    if tunnelReady == false {
                        Text(nextStepHint)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if let t = target {
                    Section("目标坐标") {
                        Text(String(format: "%.7f, %.7f", t.latitude, t.longitude))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }

                if log.isEmpty == false {
                    Section("日志") {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("说明") {
                    Text("这条链路不经过 StikDebug：rppairing → 用户态 TCP → RSD → "
                         + "com.apple.coredevice.locationservice。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("隧道是用户态实现的，不需要 utun，所以不需要安装 LocalDevVPN。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("直连注入")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.data, .item],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let u = urls.first {
                        // 需要安全作用域才能读
                        _ = u.startAccessingSecurityScopedResource()
                        pairingURL = u
                        append("已选择: \(u.lastPathComponent)")
                    }
                case .failure(let e):
                    append("选择失败: \(e.localizedDescription)")
                }
            }
            .sheet(isPresented: $showPairing, onDismiss: { checkPairingFile() }) {
                PairingView()
            }
            .onAppear {
                // 配对文件是持久化的，进页面就沿用，不需要每次重新配对
                checkPairingFile(silent: true)
            }
        }
    }

    /// 配对页关闭后，检查 App 内是否已生成 pairing.plist，有就自动选上
    private func checkPairingFile(silent: Bool = false) {
        let path = Bridge.pairingPath
        guard FileManager.default.fileExists(atPath: path) else {
            if silent == false { append("配对页已关闭，但还没生成配对文件") }
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        pairingURL = URL(fileURLWithPath: path)
        if silent {
            append("已载入已保存的配对文件（\(size ?? 0) 字节），不用重新配对")
        } else {
            append("已自动载入配对文件（\(size ?? 0) 字节）")
        }
        status = "配对文件就绪，可以建隧道了"
    }

    // MARK: - 动作

    private func append(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.insert("[\(f.string(from: Date()))] \(s)", at: 0)
        if log.count > 200 { log.removeLast() }
    }

    private func openTunnel() async {
        guard let url = pairingURL else { return }
        busy = true

        // ① 用 Bonjour 解析 _remotepairing._tcp 的地址和端口
        status = "正在解析配对端口…"
        append("① 浏览 _remotepairing._tcp")
        let (port, hosts, note) = await RpPortResolver.shared.resolve()
        append(note)

        // 候选主机：先试解析出来的真实地址，最后才试 loopback。
        // 只连 127.0.0.1 有可能连到别的东西上（连上后被断开 → io 失败）。
        var candidates: [String] = []
        for h in hosts where h.isEmpty == false && candidates.contains(h) == false {
            candidates.append(h)
        }
        // utun 网关（LocalDevVPN / 官方 VPN 扩展 用的是这个地址）
        if candidates.contains("10.7.0.1") == false {
            candidates.append("10.7.0.1")
        }
        if candidates.contains("127.0.0.1") == false {
            candidates.append("127.0.0.1")
        }

        let portNum: Int32 = port.map { Int32($0) } ?? 0
        append("② 开始建隧道（端口 \(port.map { String($0) } ?? "自动探测")，候选地址 \(candidates.joined(separator: ", "))）")
        status = "正在建立隧道…"

        var lastMsg = ""
        for host in candidates {
            append("   尝试 \(host):\(port.map { String($0) } ?? "?")")
            let r = await TunnelBridge.open(host: host,
                                           rpPort: portNum,
                                           pairingPath: url.path)
            if r.ok {
                tunnelReady = true
                status = "隧道已建立，可以注入了"
                append("✅ [\(r.code)] \(r.message)")
                // 把完整服务列表传到服务器，方便远端排查（不用截图）
                let svc = await TunnelBridge.services()
                let ls = svc.split(separator: "\n").map(String.init)
                let cdN = ls.filter { $0.lowercased().contains("coredevice") }.count
                let dtN = ls.filter { $0.lowercased().contains(".dt.") || $0.lowercased().contains("instruments") }.count
                append("服务统计: 共 \(ls.count) 个，coredevice=\(cdN) 个，dt/instruments=\(dtN) 个")
                if cdN > 0 {
                    for l in ls where l.lowercased().contains("coredevice") { append("  ★ " + l) }
                }
                uploadDiag(host: host, diag: r.message, services: svc)
                busy = false
                return
            }
            lastMsg = "[\(r.code)] \(r.message)"
            append("   ❌ \(lastMsg)")
            // 如果是「隧道层」的错误（TLS/RSD），换地址重试也没用，直接停
            if r.code == Int32(TunnelBridge.Code.noService.rawValue)
                || r.code == Int32(TunnelBridge.Code.connectFailed.rawValue) {
                break
            }
        }

        tunnelReady = false
        status = "失败：建隧道失败"
        append("❌ 全部候选地址都失败，最后一条：\(lastMsg)")
        busy = false
    }

    /// 把诊断信息 POST 到实验服务器（失败静默忽略，不影响使用）
    private func uploadDiag(host: String, diag: String, services: String) {
        guard let url = URL(string: "https://103-119-2-243.sslip.io/upload/lab2026/services.txt") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        let lines = services.split(separator: "\n").map(String.init)
        let cd = lines.filter { $0.lowercased().contains("coredevice") }
        let dt = lines.filter { $0.lowercased().contains(".dt.") || $0.lowercased().contains("instruments") }
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

    private func doInject() async {
        guard let t = target else { return }
        busy = true
        status = "正在注入…"
        append("注入 \(String(format: "%.7f, %.7f", t.latitude, t.longitude))")
        let r = await TunnelBridge.inject(lat: t.latitude, lon: t.longitude)
        if r.code == Int32(TunnelBridge.Code.noTunnel.rawValue) { tunnelReady = false }
        status = r.ok ? "注入成功" : "失败：\(r.codeText)"
        append("\(r.ok ? "✅" : "❌") [\(r.code)] \(r.message)")
        busy = false
    }

    private func doClear() async {
        busy = true
        append("清除模拟位置")
        let r = await TunnelBridge.clear()
        status = r.ok ? "已清除" : "失败：\(r.codeText)"
        append("\(r.ok ? "✅" : "❌") [\(r.code)] \(r.message)")
        busy = false
    }

    private func showServices() async {
        busy = true
        let s = await TunnelBridge.services()
        let all = s.split(separator: "\n").map(String.init)
        append("RSD 服务列表（共 \(all.count) 个）:")
        // 先列出含 location / simulate 的，再列其余（都进日志）
        let hits = all.filter { $0.lowercased().contains("location") || $0.lowercased().contains("simulate") }
        if hits.isEmpty {
            append("  ⚠️ 没有含 location/simulate 的服务")
        } else {
            append("  ★ 含 location/simulate 的:")
            for h in hits { append("    " + h) }
        }
        for line in all { append("  " + line) }
        append("（以上 \(all.count) 条已全部列出）")
        busy = false
    }
}
