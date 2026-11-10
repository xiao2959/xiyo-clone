//
//  ContentView.swift —— 一键注入 + 坐标模式校准（D 轮）
//
//  用户反馈：注入后仍偏几百米。
//  原因待定：苹果地图在中国区可能是 GCJ-02 也可能是 WGS-84，
//            StikDebug 深链不换算、直接把 lat/lon 传给注入接口。
//            两种可能方向相反，猜错就反向偏 ~500 米。
//
//  解决：给用户三个模式，一次测准并记住选择。
//    ① 自动换算 GCJ→WGS（默认）
//    ② 原样注入（MapKit 若已是 WGS 就选这个）
//    ③ 反向换算 WGS→GCJ
//
//  用户视角：地图点选 → 点「注入」→ 完成；偏了就切一下模式。
//

import SwiftUI
import MapKit
import UIKit

/// 注入坐标的模式。选对一次，以后一直对。
enum InjectMode: String, CaseIterable, Identifiable {
    case autoGCJ = "自动换算 GCJ→WGS"
    case raw     = "原样注入（不换算）"
    case reverse = "反向换算 WGS→GCJ"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .autoGCJ: return "地图点是 GCJ-02 时用（默认）"
        case .raw:     return "地图点本来就是 WGS-84 时用"
        case .reverse: return "前两种都往反方向偏时用"
        }
    }
}

struct ContentView: View {
    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.7069, longitude: 119.1618),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))

    @State private var picked: CLLocationCoordinate2D?
    @State private var injectPoint: CLLocationCoordinate2D?
    @State private var note: String = "在地图上点一下，选目标位置"
    @State private var status: String = ""
    @State private var stikInstalled: Bool = false
    @State private var showModeHelp: Bool = false

    @AppStorage("inject_mode") private var modeRaw: String = InjectMode.autoGCJ.rawValue

    private var mode: InjectMode {
        InjectMode(rawValue: modeRaw) ?? .autoGCJ
    }

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
                row("实际注入", injectText, highlight: true)
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
                .disabled(injectPoint == nil)

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

            Section("坐标模式（偏了就换一个试试）") {
                Picker("坐标模式", selection: $modeRaw) {
                    ForEach(InjectMode.allCases) { m in
                        Text(m.rawValue).tag(m.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: modeRaw) { _ in
                    if let p = picked { applyPick(p) }
                }

                Text(mode.hint).font(.footnote).foregroundStyle(.secondary)

                Button("怎么选？点我看一句话说明") {
                    showModeHelp.toggle()
                }
                .font(.footnote)

                if showModeHelp {
                    Text("点一个明显地标 → 注入 → 看手机地图蓝点。\n"
                         + "蓝点在目标西边/南边约 500 米 → 切「原样注入」。\n"
                         + "蓝点往反方向偏 → 切「反向换算」。\n"
                         + "选对一次会自动记住，以后不用再改。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
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
                Text("StikDebug 的深链接口不换算坐标，收到什么就注入什么。"
                     + "国内地图与 GPS 坐标系不同，差 400～700 米。"
                     + "本 App 负责把坐标转成不偏的那个值。")
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

    private var injectText: String {
        guard let p = injectPoint else { return "未选" }
        return format(p)
    }

    private func format(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.7f, %.7f", c.latitude, c.longitude)
    }

    // MARK: - 逻辑

    private func applyPick(_ c: CLLocationCoordinate2D) {
        picked = c
        let out: CLLocationCoordinate2D
        switch mode {
        case .autoGCJ:
            out = CoordTransform.gcj2wgs(c.latitude, c.longitude)
        case .raw:
            out = c
        case .reverse:
            out = CoordTransform.wgs2gcj(c.latitude, c.longitude)
        }
        injectPoint = out
        let d = CoordTransform.distance(c, out)
        if d < 1 {
            note = "原样注入（偏移 0 米）"
        } else {
            note = String(format: "%@，偏移 %.0f 米", mode.rawValue, d)
        }
        status = ""
    }

    private func checkStik() -> Bool {
        guard let u = URL(string: "stikdebug://") else { return false }
        return UIApplication.shared.canOpenURL(u)
    }

    private func inject() {
        guard let p = injectPoint else { return }
        let lat = String(format: "%.7f", p.latitude)
        let lon = String(format: "%.7f", p.longitude)
        let s = DeepLink.simulate(lat: p.latitude, lon: p.longitude)
        guard DeepLink.validate(s), let u = URL(string: s) else {
            status = "URL 构造失败：" + s
            return
        }
        UIApplication.shared.open(u) { ok in
            DispatchQueue.main.async {
                status = ok
                    ? "已发送：" + lat + ", " + lon
                    : "打开 StikDebug 失败，请确认已安装"
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
