//
//  ContentView.swift
//  主界面：地图点选 → 自动换算 → 注入
//
//  ⚠️ 这个文件刻意写得"平铺直叙"，避免复杂 ViewBuilder 表达式。
//     原因：swift-frontend 在复杂 SwiftUI 表达式上会崩（Failed frontend command，
//     日志里只有 warning 没有 error）。瘦身后可稳定编译。
//
//  和 StikDebug 的本质区别：地图点出来的坐标是 GCJ-02，
//  注入前必须转成 WGS-84，否则偏 400~700 米。
//

import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()

    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.7069, longitude: 119.1618),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))

    @State private var picked: CLLocationCoordinate2D?
    @State private var wgsPoint: CLLocationCoordinate2D?
    @State private var note: String = "在地图上点一下选位置"
    @State private var showPair: Bool = false
    @State private var showDiag: Bool = false
    @State private var busy: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapArea
                    .frame(height: 320)
                infoList
            }
            .navigationTitle("定位隧道")
            .onAppear { tunnel.load() }
            .sheet(isPresented: $showPair) { PairingView() }
            .sheet(isPresented: $showDiag) { DiagView(tunnel: tunnel) }
        }
    }

    // MARK: - 地图

    private var mapArea: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let p = picked {
                    Marker("目标", coordinate: p)
                }
            }
            .onTapGesture(coordinateSpace: .local) { loc in
                if let c = proxy.convert(loc, from: .local) {
                    applyPick(c)
                }
            }
        }
    }

    // MARK: - 下方信息

    private var infoList: some View {
        List {
            Section("隧道") {
                row("状态", tunnelText)
                Button(tunnel.status == .connected ? "断开隧道" : "连接隧道") {
                    toggleTunnel()
                }
                Button("配对设备") { showPair = true }
                Button("自检") { showDiag = true }
            }

            Section("选点") {
                row("地图坐标", pickedText)
                row("注入坐标", wgsText)
                row("说明", note)
            }

            Section("操作") {
                Button("注入到手机") { inject() }
                    .disabled(busy)
                Button("恢复真实定位") { clearSim() }
                    .disabled(busy)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 状态文本

    private var tunnelText: String {
        switch tunnel.status {
        case .connected:    return "已连接"
        case .connecting:   return "连接中"
        case .disconnected: return "未连接"
        case .invalid:      return "未配置"
        default:            return "其他"
        }
    }

    private var pickedText: String {
        guard let p = picked else { return "未选" }
        return format(p)
    }

    private var wgsText: String {
        guard let w = wgsPoint else { return "未选" }
        return format(w)
    }

    private func format(_ c: CLLocationCoordinate2D) -> String {
        let la = String(format: "%.7f", c.latitude)
        let lo = String(format: "%.7f", c.longitude)
        return la + ", " + lo
    }

    // MARK: - 动作

    private func applyPick(_ c: CLLocationCoordinate2D) {
        picked = c
        let w = CoordTransform.gcj2wgs(c.latitude, c.longitude)
        wgsPoint = w
        let d = CoordTransform.distance(c, w)
        if d < 1 {
            note = "境外，无需换算"
        } else {
            note = "已换算，偏移 " + String(format: "%.0f", d) + " 米"
        }
    }

    private func toggleTunnel() {
        if tunnel.status == .connected {
            tunnel.stop()
        } else {
            tunnel.start()
        }
    }

    private func inject() {
        guard let w = wgsPoint else {
            note = "请先在地图上选点"
            return
        }
        busy = true
        note = "注入中…"
        let lat = w.latitude
        let lng = w.longitude
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = Bridge.simulate(lat: lat, lng: lng)
            DispatchQueue.main.async {
                busy = false
                if rc == 0 {
                    note = "已注入"
                } else if rc == -1 {
                    note = "注入失败(-1 配对文件不可用)"
                } else if rc == -2 {
                    note = "注入失败(-2 连不上 10.7.0.1)"
                } else {
                    note = "注入失败(" + String(rc) + ")"
                }
            }
        }
    }

    private func clearSim() {
        busy = true
        note = "恢复中…"
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = Bridge.clear()
            DispatchQueue.main.async {
                busy = false
                note = (rc == 0) ? "已恢复真实定位" : ("恢复失败(" + String(rc) + ")")
            }
        }
    }
}
