//
//  PairingView.swift —— 纯手机端配对页（对应视频里"输入 App 上显示的 6 位码"）
//
//  流程（全部在本机完成，不需要电脑）：
//    1. 调 Rust `pairing_start()` → 在 127.0.0.1 开 listener，返回端口
//    2. 用 NetService 把这个端口发布成 `_remotepairing-pairable-host._tcp.`
//       （这就是 idevice 的 PAIRABLE_HOST_SERVICE_TYPE，iOS 会把它当成一台"电脑"）
//    3. 手机去"设置 → 隐私与安全性 → 开发者模式"里点配对，设备连进来
//    4. Rust 跑 SRP pair-setup，pin_callback 把 6 位码交给这里显示
//    5. 配对成功 → pairing.plist 落到 App Group，后续注入用它
//

import SwiftUI

struct PairingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pin = "------"
    @State private var status = "点「开始配对」，然后在手机上打开设置完成配对"
    @State private var running = false
    @State private var done = false
    @State private var timer: Timer?

    private let service = BonjourPublisher()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(pin)
                    .font(.system(size: 46, weight: .bold, design: .monospaced))
                    .tracking(10)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))

                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 44)

                Button {
                    start()
                } label: {
                    HStack {
                        if running { ProgressView().tint(.white) }
                        Text(done ? "已配对" : (running ? "等待设备连接…" : "开始配对"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || done)

                if done {
                    Text("配对文件已保存，可以返回首页连接并注入坐标。")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Text("手机上怎么操作：").font(.footnote.bold())
                    Text("设置 → 隐私与安全性 → 开发者模式 → 找到本 App → 配对")
                        .font(.footnote)
                    Text("然后把上面这 6 位码输进去。")
                        .font(.footnote)
                    Text("（iOS 版本不同，入口叫法略有差异）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .navigationTitle("配对设备")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { stop(); dismiss() } } }
            .onDisappear { stop() }
        }
    }

    // MARK: - 动作

    private func start() {
        running = true
        status = "正在启动本地配对服务…"

        let path = Bridge.pairingPath
        let port = Bridge.pairingStart(name: "定位隧道", savePath: path)
        guard port > 0 else {
            running = false
            status = "启动配对服务失败（端口 = \(port)）"
            return
        }

        // 发布 Bonjour（服务类型/实例名/TXT 都由 Rust 侧给出）
        service.publish(port: UInt16(port))
        status = "已发布配对服务（端口 \(port)），请在手机上完成配对"

        // 每 0.6s 轮询一次：取 PIN / 取结果
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            poll()
        }
    }

    private func poll() {
        if let p = Bridge.pairingTakePin() {
            pin = p
            status = "已生成配对码，请在手机上输入"
        }

        let rc = Bridge.pairingWait(timeoutMs: 0)
        switch rc {
        case 0:
            timer?.invalidate(); timer = nil
            running = false
            done = true
            service.stop()
            let stat = Bridge.pairingStatus() ?? ""
            status = "配对成功 · \(stat)"
        case -2:
            timer?.invalidate(); timer = nil
            running = false
            service.stop()
            status = "配对失败：\(Bridge.pairingStatus() ?? "未知错误")"
        default:
            break
        }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        service.stop()
    }
}

// MARK: - Bonjour 发布

/// 用 NetService 把一个已存在的本地端口发布成 mDNS 服务。
/// 服务类型 / 实例名 / TXT 全部由 Rust 侧提供（保证和 idevice 的 PairableHost 一致）。
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
        let name = n ?? "\(UUID().uuidString.prefix(8))"
        let txtString = x ?? ""

        // "k=v\nk=v" → [String: Data]
        var txt: [String: Data] = [:]
        for line in txtString.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { txt[parts[0]] = Data(parts[1].utf8) }
        }

        let svc = NetService(domain: "local.", type: type, name: name, port: Int32(port))
        if !txt.isEmpty {
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

    func netServiceDidPublish(_ sender: NetService) {
        print("[bonjour] published \(sender.type) name=\(sender.name) port=\(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("[bonjour] publish failed: \(errorDict)")
    }
}
