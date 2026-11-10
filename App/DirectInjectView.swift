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
                        Label("生成配对文件（App 内配对）", systemImage: "person.badge.key")
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
            .sheet(isPresented: $showPairing, onDismiss: checkPairingFile) {
                PairingView()
            }
        }
    }

    /// 配对页关闭后，检查 App 内是否已生成 pairing.plist，有就自动选上
    private func checkPairingFile() {
        let path = Bridge.pairingPath
        guard FileManager.default.fileExists(atPath: path) else {
            append("配对页已关闭，但还没生成配对文件")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        pairingURL = URL(fileURLWithPath: path)
        append("已自动载入配对文件（\(size ?? 0) 字节）")
        status = "配对文件就绪，可以建隧道了"
    }

    // MARK: - 动作

    private func append(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.insert("[\(f.string(from: Date()))] \(s)", at: 0)
        if log.count > 60 { log.removeLast() }
    }

    private func openTunnel() async {
        guard let url = pairingURL else { return }
        busy = true

        // ① 用 Bonjour 解析 _remotepairing._tcp 的真实端口
        //    （设备上的端口不固定，硬编码探测找不到）
        status = "正在解析配对端口…"
        append("① 浏览 _remotepairing._tcp")
        let (port, note) = await RpPortResolver.shared.resolve()
        append(note)

        // ② 建隧道
        status = "正在建立隧道…"
        let portText = port.map { String($0) } ?? "自动探测"
        append("② 建立隧道（端口 \(portText)）")
        let r = await TunnelBridge.open(rpPort: port.map { Int32($0) } ?? 0,
                                       pairingPath: url.path)
        tunnelReady = r.ok
        status = r.ok ? "隧道已建立，可以注入了" : "失败：\(r.codeText)"
        append("\(r.ok ? "✅" : "❌") [\(r.code)] \(r.message)")
        busy = false
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
        append("RSD 服务列表:")
        for line in s.split(separator: "\n").prefix(40) {
            append("  \(line)")
        }
        busy = false
    }
}
