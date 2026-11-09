//
//  ContentView.swift —— 主界面：连隧道 / 选点 / 注入
//
import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()

    @State private var camera = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))

    @State private var target = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
    @State private var message = "未连接"
    @State private var showPairing = false
    @State private var paired = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $camera) {
                    Marker("目标", coordinate: target)
                }
                .frame(height: 300)
                .onTapGesture { /* TODO: 长按/点击把屏幕点转成经纬度（见下方 MapTapHint） */ }

                Form {
                    Section("隧道") {
                        HStack {
                            Text("状态")
                            Spacer()
                            Text(statusText).foregroundStyle(tunnel.status == .connected ? .green : .secondary)
                        }
                        Button(tunnel.status == .connected ? "断开隧道" : "连接隧道") {
                            tunnel.status == .connected ? tunnel.stop() : tunnel.start()
                        }
                        Button(paired ? "已配对（重新配对）" : "配对设备（显示 6 位码）") {
                            showPairing = true
                        }
                    }

                    Section("目标坐标") {
                        Text(String(format: "%.6f, %.6f", target.latitude, target.longitude))
                            .font(.system(.body, design: .monospaced))
                        HStack {
                            Button("注入到手机") { inject() }
                                .disabled(tunnel.status != .connected || busy)
                            Button("恢复真实定位") { clearSim() }
                                .disabled(tunnel.status != .connected || busy)
                        }
                    }

                    Section("日志") {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("定位隧道")
            .onAppear {
                tunnel.load()
                paired = FileManager.default.fileExists(atPath: Bridge.pairingPath)
            }
            .sheet(isPresented: $showPairing, onDismiss: {
                paired = FileManager.default.fileExists(atPath: Bridge.pairingPath)
            }) {
                PairingView()
            }
        }
    }

    private var statusText: String {
        switch tunnel.status {
        case .connected:     return "已连接"
        case .connecting:    return "连接中…"
        case .disconnected:  return "未连接"
        case .invalid:       return "未配置"
        default:             return "状态 \(tunnel.status.rawValue)"
        }
    }

    // MARK: - 注入

    private func inject() {
        busy = true
        message = "正在注入…"
        // Rust 侧是阻塞调用，放后台线程，避免卡 UI
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = Bridge.simulate(lat: target.latitude, lng: target.longitude)
            DispatchQueue.main.async {
                busy = false
                message = rc == 0
                    ? String(format: "已注入 %.6f, %.6f", target.latitude, target.longitude)
                    : "注入失败（返回 \(rc)）：确认已配对、VPN 已连接、开发者模式已开"
            }
        }
    }

    private func clearSim() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = Bridge.clear()
            DispatchQueue.main.async {
                busy = false
                message = rc == 0 ? "已恢复真实定位" : "恢复失败（返回 \(rc)）"
            }
        }
    }
}
