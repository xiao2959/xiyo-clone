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
import UniformTypeIdentifiers

struct DirectInjectView: View {
    @Environment(\.dismiss) private var dismiss

    /// 从主界面传进来的目标坐标
    let target: CLLocationCoordinate2D?

    @State private var pairingURL: URL?
    @State private var showPicker = false
    @State private var busy = false
    @State private var log: [String] = []
    @State private var status = "还没建隧道"

    var body: some View {
        NavigationStack {
            List {
                Section("配对文件") {
                    if let u = pairingURL {
                        Text(u.lastPathComponent)
                            .font(.system(.footnote, design: .monospaced))
                    } else {
                        Text("还没选")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showPicker = true
                    } label: {
                        Label("选择配对文件", systemImage: "doc.badge.plus")
                    }
                    Text("iOS 开发者模式配对后生成，约 500 字节，文件头是 <?xml")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("状态") {
                    Text(status)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(busy ? Color.orange : Color.primary)
                }

                Section("操作") {
                    Button {
                        Task { await openTunnel() }
                    } label: {
                        Label("建立隧道", systemImage: "link")
                    }
                    .disabled(busy || pairingURL == nil)

                    Button {
                        Task { await doInject() }
                    } label: {
                        Label("注入当前坐标", systemImage: "location.fill")
                    }
                    .disabled(busy || target == nil)

                    Button {
                        Task { await doClear() }
                    } label: {
                        Label("清除模拟位置", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(busy)

                    Button {
                        Task { await showServices() }
                    } label: {
                        Label("查看 RSD 服务列表", systemImage: "list.bullet")
                    }
                    .disabled(busy)
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
        }
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
        status = "正在建立隧道…"
        append("开始建隧道")
        let r = await TunnelBridge.open(pairingPath: url.path)
        status = r.ok ? "隧道已建立" : "失败：\(r.codeText)"
        append("\(r.ok ? "✅" : "❌") [\(r.code)] \(r.message)")
        busy = false
    }

    private func doInject() async {
        guard let t = target else { return }
        busy = true
        status = "正在注入…"
        append("注入 \(String(format: "%.7f, %.7f", t.latitude, t.longitude))")
        let r = await TunnelBridge.inject(lat: t.latitude, lon: t.longitude)
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
