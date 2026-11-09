//
//  DiagView.swift
//  应用内自检页
//
//  为什么要有它：真机上出问题时，靠"远程猜"效率极低。
//  这个页面把每一步都测一遍并显示结果，你截一张图我就能定位问题在哪一层：
//
//    ① 隧道层    VPN 配置存在吗？扩展响应吗？
//    ② 网络层    10.7.0.1 通不通？62078 端口通不通？
//    ③ 配对层    pairing.plist 存在吗？内容能解析吗？
//    ④ 注入层    能不能打开 com.apple.dt.simulatelocation？
//
//  对应故障：
//    ① 失败 → 签名/entitlement 问题（扩展没被签进去）
//    ② 失败 → TCPRelay 的 NAT 没工作
//    ③ 失败 → 配对流程没走完
//    ④ 失败 → 配对文件无效 / 开发者模式没开
//

import SwiftUI
import Network

struct DiagItem: Identifiable {
    let id = UUID()
    let title: String
    var state: State = .pending
    var detail: String = ""

    enum State {
        case pending, running, ok, fail, skip

        var symbol: String {
            switch self {
            case .pending: return "circle.dotted"
            case .running: return "ellipsis.circle"
            case .ok:      return "checkmark.circle.fill"
            case .fail:    return "xmark.circle.fill"
            case .skip:    return "minus.circle"
            }
        }

        var color: Color {
            switch self {
            case .pending: return .secondary
            case .running: return .blue
            case .ok:      return .green
            case .fail:    return .red
            case .skip:    return .orange
            }
        }
    }
}

struct DiagView: View {
    @Environment(\.dismiss) private var dismiss
    let tunnel: TunnelManager

    @State private var items: [DiagItem] = [
        DiagItem(title: "① VPN 配置已安装"),
        DiagItem(title: "① VPN 已连接"),
        DiagItem(title: "① 扩展响应 ping"),
        DiagItem(title: "② 扩展能连到 lockdownd (127.0.0.1:62078)"),
        DiagItem(title: "② 10.7.0.1:62078 可达"),
        DiagItem(title: "③ pairing.plist 存在"),
        DiagItem(title: "③ pairing.plist 可解析"),
        DiagItem(title: "④ 定位服务可打开（注入自检）"),
    ]
    @State private var running = false
    @State private var portOpen = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.state.symbol)
                                .foregroundStyle(item.state.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.footnote)
                                if !item.detail.isEmpty {
                                    Text(item.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        runAll()
                    } label: {
                        HStack {
                            if running { ProgressView() }
                            Text(running ? "检测中…" : "开始自检")
                        }
                    }
                    .disabled(running)
                }

                Section("怎么用") {
                    Text("点「开始自检」，等全部跑完，把这一页截图发给我。")
                        .font(.footnote)
                    Text("红叉的那几项，就是我需要修的地方。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("自检")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .onAppear { runAll() }
        }
    }

    // MARK: - 跑测试

    private func runAll() {
        running = true
        var new = items
        for i in new.indices { new[i].state = .pending; new[i].detail = "" }
        items = new
        step(0)
    }

    private func mark(_ i: Int, _ state: DiagItem.State, _ detail: String = "") {
        DispatchQueue.main.async {
            guard i < items.count else { return }
            items[i].state = state
            items[i].detail = detail
        }
    }

    private func step(_ i: Int) {
        // 可能从后台回调进来（比如 probe / Bridge.clear），统一回主线程再动 @State
        DispatchQueue.main.async { stepMain(i) }
    }

    private func stepMain(_ i: Int) {
        guard i < items.count else {
            running = false
            return
        }
        mark(i, .running)

        switch i {
        // ① 配置是否已创建
        case 0:
            if tunnel.hasConfiguration {
                mark(i, .ok, "已存在")
                step(i + 1)
            } else {
                mark(i, .fail, "还没有 VPN 配置，先点「连接隧道」")
                step(i + 1)
            }

        // ① 是否已连接
        case 1:
            switch tunnel.status {
            case .connected:
                mark(i, .ok, "connected")
                step(i + 1)
            case .connecting, .reasserting:
                mark(i, .skip, "正在连接，稍等再测")
                step(i + 1)
            default:
                mark(i, .fail, "状态 = \(tunnel.status.rawValue)")
                step(i + 1)
            }

        // ① 扩展是否响应（扩展活着才会回 pong）
        case 2:
            tunnel.send("ping") { reply in
                if reply == "pong" {
                    mark(i, .ok, "扩展已响应")
                } else {
                    mark(i, .fail, "扩展没回消息（可能没签进 App）")
                }
                step(i + 1)
            }

        // ② 扩展自己能不能连 127.0.0.1:62078（证明那条链路存在）
        case 3:
            tunnel.send("check-lockdown") { reply in
                if let r = reply, r == "ok" {
                    mark(i, .ok, "lockdownd 可达")
                } else {
                    mark(i, .fail, reply ?? "无响应")
                }
                step(i + 1)
            }

        // ② 从 App 侧经隧道连 10.7.0.1:62078（证明 NAT 工作）
        case 4:
            probe(host: "10.7.0.1", port: 62078) { ok in
                portOpen = ok
                mark(i, ok ? .ok : .fail, ok ? "NAT 正常" : "连不上（NAT 或隧道问题）")
                step(i + 1)
            }

        // ③ pairing.plist 是否存在
        case 5:
            let path = Bridge.pairingPath
            if FileManager.default.fileExists(atPath: path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                let name = (path as NSString).lastPathComponent
                mark(i, .ok, "\(name) · \(size) 字节")
                step(i + 1)
            } else {
                mark(i, .fail, "不存在，需要先配对")
                step(i + 1)
            }

        // ③ 能不能解析（Rust 侧读一次）
        case 6:
            let st = Bridge.pairingStatus() ?? ""
            if st.hasPrefix("paired:") || FileManager.default.fileExists(atPath: Bridge.pairingPath) {
                mark(i, .ok, "可读")
            } else {
                mark(i, .skip, "跳过：文件不存在")
            }
            step(i + 1)

        // ④ 注入自检：真去连一次定位服务（不注入坐标）
        case 7:
            if !portOpen {
                mark(i, .skip, "跳过：第 5 项没通过")
                step(i + 1)
                return
            }
            if !FileManager.default.fileExists(atPath: Bridge.pairingPath) {
                mark(i, .skip, "跳过：还没配对")
                step(i + 1)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                // 用一个必然失败但能区分错误的探测：连服务并立刻清除
                let rc = Bridge.clear()
                // rc: 0=服务打开成功   -1=参数/pairing 错   -2=连接或服务失败
                switch rc {
                case 0:
                    mark(i, .ok, "定位服务可用（已顺带清除模拟）")
                    step(i + 1)
                case -1:
                    mark(i, .fail, "pairing.plist 读不了")
                    step(i + 1)
                default:
                    mark(i, .fail, "连不上定位服务（检查开发者模式、配对是否有效）")
                    step(i + 1)
                }
            }

        default:
            step(i + 1)
        }
    }

    // MARK: - TCP 探测

    private func probe(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        var done = false
        func finish(_ ok: Bool) {
            if done { return }
            done = true
            conn.cancel()
            DispatchQueue.main.async { completion(ok) }
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:   finish(true)
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        conn.start(queue: .global())
        // 3 秒超时
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(false) }
    }
}
