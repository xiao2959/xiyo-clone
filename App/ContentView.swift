//
//  ContentView.swift
//  主界面：地图点选 → 自动换算 → 注入
//
//  和 StikDebug 的关键区别（也是"官方 App 不偏"的原因）：
//
//    中国区 Apple 地图的底图是 GCJ-02，从地图上点出来的坐标也是 GCJ-02；
//    而定位注入必须用 WGS-84。
//    本 App 在点选后 **自动做 GCJ→WGS 转换**，所以落点就是你在图上点的那个位置。
//
//  StikDebug 没有这一步 → 你填地图坐标，它原样注入 → 偏 400~700 米。
//

import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()

    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.7069, longitude: 119.1618),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))

    // 选点：同时保存"地图坐标(GCJ)"和"注入坐标(WGS)"
    @State private var tapped: CLLocationCoordinate2D?
    @State private var injectPoint: CLLocationCoordinate2D?
    @State private var offsetMeters: Double = 0

    @State private var message = "在地图上点一下选位置"
    @State private var showPairing = false
    @State private var showDiag = false
    @State private var paired = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapView
                    .frame(height: 340)

                Form {
                    Section("隧道") {
                        HStack {
                            Text("状态")
                            Spacer()
                            Text(statusText)
                                .foregroundStyle(tunnel.status == .connected ? .green : .secondary)
                        }
                        Button(tunnel.status == .connected ? "断开隧道" : "连接隧道") {
                            tunnel.status == .connected ? tunnel.stop() : tunnel.start()
                        }
                        Button(paired ? "已配对（重新配对）" : "配对设备") { showPairing = true }
                        Button("自检") { showDiag = true }
                    }

                    Section("选点结果") {
                        if let g = tapped, let w = injectPoint {
                            coordRow("地图上点的", g, color: .secondary)
                            coordRow("注入用的", w, color: .green)
                            HStack {
                                Text("坐标偏移")
                                Spacer()
                                Text(offsetMeters < 1
                                     ? "无（境外或已对齐）"
                                     : String(format: "%.0f 米（已自动换算）", offsetMeters))
                                    .foregroundStyle(offsetMeters < 1 ? .secondary : .orange)
                            }
                            .font(.footnote)
                        } else {
                            Text("还没选点").font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    Section("操作") {
                        Button("注入到手机") { inject() }
                            .disabled(injectPoint == nil || tunnel.status != .connected || busy)
                        Button("恢复真实定位") { clearSim() }
                            .disabled(tunnel.status != .connected || busy)
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("定位隧道")
            .onAppear {
                tunnel.load()
                paired = FileManager.default.fileExists(atPath: Bridge.pairingPath)
            }
            .sheet(isPresented: $showDiag) { DiagView(tunnel: tunnel) }
            .sheet(isPresented: $showPairing, onDismiss: {
                paired = FileManager.default.fileExists(atPath: Bridge.pairingPath)
            }) { PairingView() }
        }
    }

    // MARK: - 地图（可点选）

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let p = tapped {
                    Marker("目标", coordinate: p).tint(.green)
                }
                if let w = injectPoint {
                    Annotation("注入点", coordinate: w) {
                        Circle().fill(.blue.opacity(0.45))
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { screenPoint in
                // iOS 17 起：把屏幕点换算成地图坐标
                if let coord = proxy.convert(screenPoint, from: .local) {
                    pick(coord)
                }
            }
        }
    }

    /// 选点：把地图坐标（中国区为 GCJ-02）转成 WGS-84 作为注入值
    private func pick(_ mapCoord: CLLocationCoordinate2D) {
        tapped = mapCoord

        let wgs = CoordTransform.gcj2wgs(mapCoord.latitude, mapCoord.longitude)
        injectPoint = wgs

        offsetMeters = CoordTransform.distance(mapCoord, wgs)
        message = offsetMeters < 1
            ? "境外，无需换算"
            : String(format: "已自动换算：地图坐标与注入坐标相差 %.0f 米", offsetMeters)
    }

    private func coordRow(_ title: String, _ c: CLLocationCoordinate2D, color: Color) -> some View {
        HStack {
            Text(title).font(.footnote)
            Spacer()
            Text(String(format: "%.7f, %.7f", c.latitude, c.longitude))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private var statusText: String {
        switch tunnel.status {
        case .connected:    return "已连接"
        case .connecting:   return "连接中…"
        case .disconnected: return "未连接"
        case .invalid:      return "未配置"
        default:            return "状态 \(tunnel.status.rawValue)"
        }
    }

    // MARK: - 注入

    private func inject() {
        guard let p = injectPoint else { return }
        busy = true
        message = "正在注入…"
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = Bridge.simulate(lat: p.latitude, lng: p.longitude)
            DispatchQueue.main.async {
                busy = false
                message = rc == 0
                    ? String(format: "已注入 %.7f, %.7f", p.latitude, p.longitude)
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
