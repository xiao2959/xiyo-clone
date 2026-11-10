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
    /// 只有"主动跳转"才设置它；用户拖地图不会写回，所以不会来回跳
    @State private var jumpTarget: CLLocationCoordinate2D?

    @State private var picked: CLLocationCoordinate2D?
    @State private var injectPoint: CLLocationCoordinate2D?
    @State private var note: String = "在地图上点一下，选目标位置"
    @State private var status: String = ""
    @State private var stikInstalled: Bool = false
    @State private var showModeHelp: Bool = false

    // 找地方：搜索 / 手动输经纬度
    @StateObject private var search = SearchModel()
    @State private var showSearch: Bool = false
    @State private var coordText: String = ""
    @State private var showCoordInput: Bool = false
    @State private var locating: Bool = false
    private let locator = CLLocationManager()

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .onAppear { stikInstalled = checkStik() }
            .sheet(isPresented: $showSearch) {
                SearchSheet(search: search) { c in
                    jump(to: c)
                }
            }
            .alert("输入经纬度", isPresented: $showCoordInput) {
                TextField("36.7069, 119.1618", text: $coordText)
                Button("跳转") {
                    if let c = CoordInput.parse(coordText) { jump(to: c) }
                    else { status = "坐标格式不对，要：纬度, 经度" }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    /// 跳到指定坐标并直接把它设为目标（省得跳完还要再点一下地图）
    private func jump(to c: CLLocationCoordinate2D) {
        jumpTarget = c
        applyPick(c)
        status = "已跳到 " + format(c)
    }

    /// 回到当前真实位置
    private func goCurrent() {
        locator.requestWhenInUseAuthorization()
        guard let c = locator.location?.coordinate else {
            status = "还没拿到定位，稍等再点一次"
            return
        }
        // 回到当前位置只移动地图，不覆盖已选的目标点
        jumpTarget = c
        status = "已回到当前位置（目标点保留）"
    }

    // MARK: - 地图（原生 MKMapView，不来回跳）

    private var mapArea: some View {
        NativeMapView(center: jumpTarget, picked: picked) { c in
            applyPick(c)
        }
    }

    // MARK: - 信息

    private var infoList: some View {
        List {
            Section("找地方") {
                Button {
                    showSearch = true
                } label: {
                    Label("搜索地名 / 小区 / 学校", systemImage: "magnifyingglass")
                }
                Button {
                    coordText = ""
                    showCoordInput = true
                } label: {
                    Label("输入经纬度跳转", systemImage: "number")
                }
                Button {
                    goCurrent()
                } label: {
                    Label("回到当前位置", systemImage: "location")
                }
                Text("搜到后自动跳过去并放好目标点，不用手动拖地图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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
                    sendStopAll()
                } label: {
                    Label("停止所有模拟（防跳回）", systemImage: "stop.circle")
                }

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

            Section("换位置后 1~2 秒跳回旧点？") {
                Text("这是 StikDebug 里还留着「持续/路线模拟」会话，它会周期性重发旧坐标。"
                     + "本 App 现在每次注入前会先发 stop 指令停掉旧会话，再设新点。")
                    .font(.footnote)
                Text("如果仍然跳回：进 StikDebug → 找到 Route / 路线模拟 / 持续模拟，"
                     + "手动停止或清除队列；或先点本页「停止所有模拟（防跳回）」，再注入。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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

    /// 换位置原子流程：先停旧模拟会话 → 稍等 → 再设新坐标。
    ///
    /// 为什么要停：StikDebug 二进制里有 RouteSimulationPlan / Timer /
    /// LocationSimulationCommandQueue / stopLocationSimulation —— 说明它支持
    /// 持续/路线模拟。若之前的会话还在跑，会周期性重发旧坐标，
    /// 表现就是"新位置过去一两秒又被拉回去"。
    private func inject() {
        guard let p = injectPoint else { return }
        let lat = String(format: "%.7f", p.latitude)
        let lon = String(format: "%.7f", p.longitude)

        // 第 1 步：停掉可能存在的持续模拟
        if let stop = URL(string: DeepLink.stopSimulation()) {
            UIApplication.shared.open(stop)
        }

        // 第 2 步：给 StikDebug 一点时间处理 stop，再发新坐标
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let s = DeepLink.simulate(lat: p.latitude, lon: p.longitude)
            guard DeepLink.validate(s), let u = URL(string: s) else {
                self.status = "URL 构造失败：" + s
                return
            }
            UIApplication.shared.open(u) { ok in
                DispatchQueue.main.async {
                    self.status = ok
                        ? "已停止旧模拟并注入：" + lat + ", " + lon
                        : "打开 StikDebug 失败，请确认已安装"
                }
            }
        }
    }

    /// 彻底停止：只发 stop，不设新点（用来清掉后台持续模拟）
    private func sendStopAll() {
        guard let u = URL(string: DeepLink.stopSimulation()) else { return }
        UIApplication.shared.open(u) { ok in
            DispatchQueue.main.async {
                self.status = ok ? "已发送停止指令" : "打开 StikDebug 失败"
            }
        }
    }

    private func sendClear() {
        let cs = DeepLink.clear()
        guard let u = URL(string: cs) else { return }
        UIApplication.shared.open(u) { ok in
            DispatchQueue.main.async {
                self.status = ok ? "已请求恢复真实定位" : "打开 StikDebug 失败"
            }
        }
    }
}
