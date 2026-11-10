//
//  DiagView.swift
//  自检页（极简版）
//
//  ⚠️ 不用数组状态、不做复杂 ViewBuilder —— swift-frontend 在复杂 SwiftUI 表达式上会崩。
//

import SwiftUI
import Network

struct DiagView: View {
    @Environment(\.dismiss) private var dismiss
    let tunnel: TunnelManager

    @State private var vpnText: String = "-"
    @State private var extText: String = "-"
    @State private var pairText: String = "-"
    @State private var portText: String = "-"
    @State private var kindText: String = "-"
    @State private var idText: String = "-"
    @State private var errText: String = "-"
    @State private var running: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section("检查项") {
                    row("VPN 状态", vpnText)
                    row("会话类型", kindText)
                    row("扩展 BundleID", idText)
                    row("扩展响应", extText)
                    row("配对文件", pairText)
                    row("10.7.0.1:62078", portText)
                    row("错误", errText)
                }
                Section {
                    Button(running ? "检测中…" : "开始自检") { runAll() }
                        .disabled(running)
                    Button("重建 VPN 配置并启动") { rebuild() }
                        .disabled(running)
                    Button("停止隧道") { tunnel.stop(); runAll() }
                        .disabled(running)
                }
                Section("说明") {
                    Text("哪一项不是 OK，就是那一层的问题。").font(.footnote)
                }
            }
            .navigationTitle("自检")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { runAll() }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.footnote)
            Spacer()
            Text(value).font(.system(.footnote, design: .monospaced))
        }
    }

    private func runAll() {
        running = true
        vpnText = tunnel.status == .connected ? "OK" : ("未连接(" + String(tunnel.status.rawValue) + ")")
        kindText = tunnel.sessionKind
        idText = tunnel.providerBundleID
        pairText = pairFileText()
        extText = "..."
        portText = "..."
        errText = tunnel.lastError ?? "-"

        tunnel.send("ping") { reply in
            DispatchQueue.main.async {
                extText = (reply == "pong") ? "OK" : ("无响应[" + (reply ?? "nil") + "]")
                errText = tunnel.lastError ?? "-"
            }
        }

        probe { ok in
            DispatchQueue.main.async {
                portText = ok ? "OK" : "不通"
                running = false
            }
        }
    }

    /// 配对文件体检：存在性 + 大小 + Rust 能否解析
    private func pairFileText() -> String {
        let path = Bridge.pairingPath
        let fm = FileManager.default
        if fm.fileExists(atPath: path) == false { return "不存在" }
        var size = 0
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            if let n = attrs[.size] as? Int { size = n }
        }
        let rc = Bridge.pairingFileCheck()
        var tag = "rc=" + String(rc)
        if rc == 0 { tag = "可解析" }
        if rc == -1 { tag = "读取失败" }
        if rc == -2 { tag = "空文件" }
        if rc == -3 { tag = "格式不对" }
        return tag + " " + String(size) + "B"
    }

    private func rebuild() {
        running = true
        errText = "重建中…"
        tunnel.rebuildAndStart { msg in
            DispatchQueue.main.async {
                errText = msg
                running = false
                runAll()
            }
        }
    }

    private func probe(completion: @escaping (Bool) -> Void) {
        let host = NWEndpoint.Host("10.7.0.1")
        let port = NWEndpoint.Port(rawValue: 62078) ?? 62078
        let conn = NWConnection(host: host, port: port, using: .tcp)
        var finished = false
        func done(_ ok: Bool) {
            if finished { return }
            finished = true
            conn.cancel()
            completion(ok)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                done(true)
            case .failed:
                done(false)
            case .waiting:
                done(false)
            default:
                break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { done(false) }
    }
}