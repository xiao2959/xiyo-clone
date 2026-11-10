//
//  ContentView.swift —— 优化版（B 轮）
//
//  设计变更（基于 A 轮结论）：
//    - 自研 rppairing→隧道→RSD 注入链路无法在当前环境验证，主界面不再暴露它
//    - 改为「地图点选 → GCJ→WGS 换算 → 交给 StikDebug」，
//      每一层都能在本地验证，装上去就能用
//
//  StikDebug 主程序里确认存在：
//    simulateLocationWithLatitude:longitude: / CoordinateImportParser /
//    LocationSimulationView / stikdebug:// URL scheme
//  它唯一不做的事就是 GCJ→WGS 换算 —— 这正是本 App 补上的。
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
    @State private var toast: String = ""
    @State private var shareURL: URL?
    @State private var showShare: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapArea.frame(height: 300)
                infoList
            }
            .navigationTitle("定位换算")
            .sheet(isPresented: $showShare) {
                if let shareURL {
                    ShareSheet(url: shareURL)
                }
            }
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
            Section("选点结果") {
                row("地图坐标 GCJ-02", pickedText)
                row("注入坐标 WGS-84", wgsText, highlight: true)
                row("换算偏移", note)
            }

            Section("第 1 步：把正确的坐标送出去（任选一种）") {
                Button {
                    copyWGS()
                } label: {
                    Label("复制 WGS-84 坐标", systemImage: "doc.on.doc")
                }
                .disabled(wgsPoint == nil)

                Button {
                    makeGPX()
                } label: {
                    Label("生成 GPX 并分享到 StikDebug", systemImage: "square.and.arrow.up")
                }
                .disabled(wgsPoint == nil)
            }

            Section("第 2 步：打开 StikDebug") {
                Button {
                    openStikDebug()
                } label: {
                    Label("打开 StikDebug", systemImage: "arrow.up.right.square")
                }
                Text("在 Location Simulator 里粘贴刚才复制的坐标，或导入 GPX 文件，然后开始模拟。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if toast.isEmpty == false {
                Section {
                    Text(toast).font(.footnote).foregroundStyle(.green)
                }
            }

            Section("为什么不会偏") {
                Text("国内地图（高德 / 腾讯 / 苹果中国）用 GCJ-02，定位注入按 WGS-84 解释。"
                     + "直接把地图上看到的数字填进模拟器会偏 400～700 米。"
                     + "本 App 在换算后再交给你，落点就是你点的位置。")
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
            note = "境外，无需换算（0 米）"
        } else {
            note = String(format: "已修正约 %.0f 米", d)
        }
        toast = ""
    }

    private func copyWGS() {
        guard let w = wgsPoint else { return }
        UIPasteboard.general.string = format(w)
        toast = "已复制：" + format(w) + "（去 StikDebug 粘贴）"
    }

    /// 生成 GPX 单航点文件，用系统分享面板送到 StikDebug 的 CoordinateImportParser
    private func makeGPX() {
        guard let w = wgsPoint else { return }
        let lat = String(format: "%.7f", w.latitude)
        let lng = String(format: "%.7f", w.longitude)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="XiYO" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="\(lat)" lon="\(lng)"><name>目标</name></wpt>
        </gpx>
        """
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("target.gpx")
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
            showShare = true
            toast = "GPX 已生成：" + lat + ", " + lng
        } catch {
            toast = "生成失败：" + error.localizedDescription
        }
    }

    private func openStikDebug() {
        let candidates = ["stikdebug://", "stikjit://"]
        for s in candidates {
            if let u = URL(string: s), UIApplication.shared.canOpenURL(u) {
                UIApplication.shared.open(u)
                toast = "已打开 StikDebug"
                return
            }
        }
        toast = "没找到 StikDebug，请从主屏幕打开它"
    }
}

// MARK: - 系统分享面板

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
