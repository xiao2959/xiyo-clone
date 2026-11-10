//
//  ContentView.swift —— 一体化版（C 轮）
//
//  关键突破：StikDebug 3.2.2 支持深链直接注入坐标（从二进制中确认）：
//      stikdebug://simulate-location?lat=37.3349&lon=-122.0090
//      stikdebug://clear-location
//      stikdebug://stop-location
//
//  所以不需要用户手动开第二个 App、手动粘贴：
//      本 App 地图点选 → GCJ→WGS 换算 → 调深链 → StikDebug 收到坐标直接注入
//
//  用户视角：点地图 → 点「注入」→ 完成。
//

import SwiftUI
import MapKit
import UIKit

struct ContentView: View {
    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.7069, longitude: 119.1618),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))

    @State private var picked: CLLocationCoordinate2D?
    @State private var wgsPoint: CLLocationCoordinate2D?
    @State private var note: String = "在地图上点一下，选目标位置"
    @State private var status: String = ""
    @State private var stikInstalled: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapArea.frame(height: 320)
                infoList
            }
            .navigationTitle("定位注入")
            .onAppear { stikInstalled = checkStik() }
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
            .onTapGesture(coordinateSpace: .local) { location in
                if let c = proxy.convert(location, from: .local) {
                    applyPick(c)
                }
            }
        }
    }

    // MARK: - 信息

    private var infoList: some View {
        List {
            Section("选点") {
                row("地图坐标", pickedText)
                row("注入坐标", wgsText, highlight: true)
                row("说明", note)
            }

            Section {
                Button {
                    inject()
                } label: {
                    HStack {
                        Image(systemName: "location.fill")
                        Text("注入到手机").fontWeight(.semibold)
                    }
                }
                .disabled(wgsPoint == nil)

                Button {
                    sendClear()
                } label: {
                    Label("恢复真实定位", systemImage: "arrow.uturn.backward")
                }
            } footer: {
                if status.isEmpty == false {
                    Text(status).font(.footnote)
                }
            }

            if stikInstalled == false {
                Section("需要先装 StikDebug") {
                    Text("本 App 负责选点和换算，实际注入由 StikDebug 完成。")
                        .font(.footnote)
                    Text("安装：Safari 打开 http://103.119.2.243/apps/StikDebug-3.2.2.ipa ，用全能签签名安装。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("原理") {
                Text("国内地图用 GCJ-02，注入按 WGS-84 解释。"
                     + "直接把地图坐标注入会偏 400～700 米。"
                     + "本 App 先换算再通过 StikDebug 的深链接口注入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(highlight ? Color.green : Color.primary)
                .multilineTextAlignment(.trailing)
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
        String(format: "%.7f, %.7f", c.latitude, c.longitude)
    }

    // MARK: - 逻辑

    private func applyPick(_ c: CLLocationCoordinate2D) {
        picked = c
        let w = CoordTransform.gcj2wgs(c.latitude, c.longitude)
        wgsPoint = w
        let d = CoordTransform.distance(c, w)
        if d < 1 {
            note = "境外，无需换算（0 米）"
        } else {
            note = String(format: "已修正约 %.0f 米", d)
        }
        status = ""
    }

    private func checkStik() -> Bool {
        if let u = URL(string: "stikdebug://"), UIApplication.shared.canOpenURL(u) {
            return true
        }
        return false
    }

    /// 调 StikDebug 深链注入（坐标已是 WGS-84）
    private func inject() {
        guard let w = wgsPoint else { return }
        let lat = String(format: "%.7f", w.latitude)
        let lon = String(format: "%.7f", w.longitude)
        let s = DeepLink.simulate(lat: w.latitude, lon: w.longitude)
        guard DeepLink.validate(s), let u = URL(string: s) else {
            status = "URL 构造失败：" + s
            return
        }
        UIApplication.shared.open(u) { ok in
            DispatchQueue.main.async {
                if ok {
                    status = "已发送：" + lat + ", " + lon
                } else {
                    status = "打开 StikDebug 失败，请确认已安装"
                }
            }
        }
    }

    private func sendClear() {
        let cs = DeepLink.clear()
        guard let u = URL(string: cs) else { return }
        UIApplication.shared.open(u) { ok in
            DispatchQueue.main.async {
                status = ok ? "已请求恢复真实定位" : "打开 StikDebug 失败"
            }
        }
    }
}
