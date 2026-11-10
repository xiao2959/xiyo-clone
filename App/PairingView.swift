//
//  PairingView.swift
//  配对页：发起配对 / 显示 6 位码 / 导入现成 pairing.plist
//
//  两种方式：
//    A. 本机配对：点「开始配对」→ 显示 6 位码 → 手机上输入 → 等待结果
//    B. 导入文件：本机配对卡住时，把别处生成的 pairing.plist 导进来
//
//  ⚠️ 保持简单：不用复杂 ViewBuilder，避免 swift-frontend 崩溃。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PairingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pin: String = "------"
    @State private var status: String = "点「开始配对」，然后按手机上的提示操作"
    @State private var detail: String = ""
    @State private var running: Bool = false
    @State private var done: Bool = false
    @State private var elapsed: Int = 0
    @State private var showPicker: Bool = false

    private let service = BonjourPublisher()
    @State private var timer: Timer?
    @State private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var body: some View {
        NavigationStack {
            List {
                Section("配对码") {
                    Text(pin)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                }

                Section("状态") {
                    Text(status).font(.footnote)
                    if detail.isEmpty == false {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("开始配对") { start() }
                        .disabled(running)
                    Button("从文件导入 pairing.plist") { showPicker = true }
                    if done {
                        Button("完成") { stop(); dismiss() }
                    }
                }

                Section("手机上的操作") {
                    Text("设置 → 隐私与安全性 → 开发者模式 → 配对设备下应出现 XiYO-Lab → 点它")
                        .font(.footnote)
                    Text("然后输入上面这 6 位数字，再输入锁屏密码。")
                        .font(.footnote)
                    Text("配对过程请保持本 App 在后台运行（切到设置时不要杀掉它），5 分钟内完成。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("配对")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { stop(); dismiss() }
                }
            }
            .onDisappear { stop() }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { url in
                    importPairing(url)
                }
            }
        }
    }

    // MARK: - 本机配对

    private func start() {
        running = true
        elapsed = 0
        detail = ""
        status = "正在启动本地配对服务…"

        let path = Bridge.pairingPath
        let port = Bridge.pairingStart(name: "XiYO-Lab", savePath: path)
        if port <= 0 {
            running = false
            status = "启动配对服务失败（端口 \(port)）"
            return
        }

        service.publish(port: UInt16(port))
        status = "已发布配对服务（端口 \(port)），请在手机上完成配对"

        // 关键：用户要切到「设置」里点配对，App 会被切到后台。
        // 不申请后台执行时间的话，socket 会被系统挂起，配对就"没反应"。
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "pairing") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            tick(t)
        }
    }

    private func tick(_ t: Timer) {
        elapsed += 1

        if let p = Bridge.pairingTakePin() {
            pin = p
            status = "已生成配对码，请在手机上输入"
        }

        let st = Bridge.pairingStatus() ?? ""
        if st.isEmpty == false && st != "idle" {
            detail = st
        }

        let rc = Bridge.pairingWait(timeoutMs: 0)
        if rc == 0 {
            t.invalidate()
            running = false
            done = true
            service.stop()
            status = "配对成功，配对文件已保存"
            return
        }
        if rc == -2 {
            t.invalidate()
            running = false
            service.stop()
            status = "配对失败（看下面那行状态）"
            return
        }

        if elapsed == 30 && done == false {
            status = "已等 30 秒。手机上应弹配对确认 → 输 6 位码 → 输锁屏密码。"
        }
        if elapsed == 75 && done == false {
            status = "已等 75 秒，本机配对可能失败。建议改用「从文件导入」。"
            running = false
            t.invalidate()
            service.stop()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        service.stop()

        UIApplication.shared.isIdleTimerDisabled = false
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - 导入配对文件

    private func importPairing(_ url: URL) {
        let dst = URL(fileURLWithPath: Bridge.pairingPath)
        do {
            let data = try Data(contentsOf: url)
            try data.write(to: dst, options: .atomic)
            done = true
            status = "导入成功：" + String(data.count) + " 字节"
            detail = dst.lastPathComponent
        } catch {
            status = "导入失败：" + error.localizedDescription
        }
    }
}

// MARK: - 文件选择器

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}

// MARK: - Bonjour 发布

final class BonjourPublisher: NSObject, NetServiceDelegate {
    private var netService: NetService?

    func publish(port: UInt16) {
        stop()

        var typeBuf = [CChar](repeating: 0, count: 128)
        var nameBuf = [CChar](repeating: 0, count: 128)
        var txtBuf = [CChar](repeating: 0, count: 1024)

        let t = Bridge.pairingServiceType(into: &typeBuf)
        let n = Bridge.pairingIdentifier(into: &nameBuf)
        let x = Bridge.pairingTXT(into: &txtBuf)

        let type = t ?? "_remotepairing-pairable-host._tcp."
        let name = n ?? "lab"
        let txtString = x ?? ""

        var txt: [String: Data] = [:]
        for line in txtString.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { txt[parts[0]] = Data(parts[1].utf8) }
        }

        let svc = NetService(domain: "local.", type: type, name: name, port: Int32(port))
        if txt.isEmpty == false {
            svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        }
        svc.delegate = self
        svc.publish()
        netService = svc
    }

    func stop() {
        netService?.stop()
        netService = nil
    }
}
