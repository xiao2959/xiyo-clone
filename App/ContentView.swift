//
//  ContentView.swift —— CDPro 主界面
//
//  布局对齐官方版：底部三个 Tab（首页 / 地图 / 验证）
//    首页：问候 + 三个状态灯 + 三个大按钮 + 功能列表
//    地图：搜索条 + 地图 + 模拟/清除/收藏
//    验证：授权状态与卡密
//
//  设计原则：一屏只做一件事，按钮大、字少、状态用颜色表达。
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

    // 共享状态
    @StateObject private var tunnel = TunnelModel()
    @StateObject private var license = LicenseManager()
    @StateObject private var mapState = MapState()
    @StateObject private var search = SearchModel()

    // 选点
    @State private var picked: CLLocationCoordinate2D?
    @State private var injectPoint: CLLocationCoordinate2D?
    @AppStorage("inject_mode") private var modeRaw: String = InjectMode.autoGCJ.rawValue

    // 界面
    @State private var showSearch = false
    @State private var showLicense = false
    @State private var showPairing = false
    @State private var showDiagnostics = false
    @State private var showCoordInput = false
    @State private var showDisclaimer = false
    @State private var showFavorites = false
    @State private var coordText = ""
    @State private var toast = ""

    // 模拟结果提示条
    @State private var bannerOK: Bool = true
    @State private var bannerText: String = ""
    @State private var bannerVisible: Bool = false

    private var mode: InjectMode { InjectMode(rawValue: modeRaw) ?? .autoGCJ }

    var body: some View {
        TabView {
            homeTab
                .tabItem { Label("首页", systemImage: "house.fill") }
            mapTab
                .tabItem { Label("地图", systemImage: "location.fill") }
            verifyTab
                .tabItem { Label("验证", systemImage: "checkmark.seal.fill") }
        }
        .tint(.blue)
        .task {
            // 启动时按设备号同步一次会员状态（网络不通就保留本地状态）
            _ = await license.syncRemote()
            tunnel.refresh()
            // 有配对文件就悄悄把隧道接上，用户不用管
            if tunnel.hasPairing && tunnel.tunnelReady == false {
                await tunnel.connect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            tunnel.refresh()
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(search: search) { c in jump(to: c) }
        }
        .sheet(isPresented: $showLicense) {
            LicenseView(license: license)
        }
        .sheet(isPresented: $showPairing) {
            PairingView().onDisappear { tunnel.refresh() }
        }
        .sheet(isPresented: $showDiagnostics) {
            DirectInjectView(target: injectPoint)
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesSheet { loc in jump(to: loc.coordinate) }
        }
        .sheet(isPresented: $showDisclaimer) {
            DisclaimerSheet()
        }
        .alert("输入经纬度", isPresented: $showCoordInput) {
            TextField("36.7069, 119.1618", text: $coordText)
                .keyboardType(.numbersAndPunctuation)
            Button("跳转") {
                if let c = CoordInput.parse(coordText) { jump(to: c) }
                else { toast = "格式不对，要：纬度, 经度" }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 首页

    private var homeTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    greetingCard
                    statusPills
                    actionTiles
                    menuCard
                    if let t = tunnel.lastInjected, t.isEmpty == false {
                        lastInjectCard(t)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("CDPro").font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLicense = true } label: {
                        Image(systemName: license.isUsable
                              ? "checkmark.shield.fill" : "lock.shield.fill")
                            .foregroundStyle(license.isUsable ? .green : .orange)
                    }
                }
            }
        }
    }

    private var greetingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greetingTitle)
                .font(.title3.bold())
            Text(greetingSub)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private var greetingTitle: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 6 { return "夜深了，注意休息" }
        if h < 12 { return "早上好" }
        if h < 14 { return "中午好" }
        if h < 18 { return "下午好" }
        return "晚上好"
    }

    private var greetingSub: String {
        if tunnel.tunnelReady { return "隧道已连接，可以直接模拟位置" }
        if tunnel.hasPairing { return "点「启动隧道」开始使用" }
        return "先导入配对文件，再启动隧道"
    }

    private var statusPills: some View {
        HStack(spacing: 10) {
            pill(title: "配对文件", on: tunnel.hasPairing)
            pill(title: "VPN", on: tunnel.vpnUp ?? tunnel.tunnelReady)
            pill(title: "隧道", on: tunnel.tunnelReady)
        }
    }

    private func pill(title: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }

    private var actionTiles: some View {
        HStack(spacing: 12) {
            tile(icon: "qrcode.viewfinder",
                 tint: .blue,
                 title: "导入配对",
                 subtitle: tunnel.hasPairing ? "已导入" : "未导入") {
                showPairing = true
            }
            tile(icon: "lock.open.fill",
                 tint: .teal,
                 title: "VPN",
                 subtitle: (tunnel.vpnUp ?? tunnel.tunnelReady) ? "已开启" : "未开启") {
                toast = "请打开 LocalDevVPN 并点「连接」"
            }
            tile(icon: "play.fill",
                 tint: .green,
                 title: tunnel.busy ? "连接中" : "启动隧道",
                 subtitle: tunnel.tunnelReady ? "已连接" : "未连接") {
                Task { await tunnel.connect() }
            }
        }
    }

    private func tile(icon: String,
                      tint: Color,
                      title: String,
                      subtitle: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(tint)
                    .frame(height: 30)
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var menuCard: some View {
        VStack(spacing: 0) {
            menuRow(icon: "doc.badge.gearshape", title: "生成配对文件", tint: .blue) {
                showPairing = true
            }
            Divider().padding(.leading, 52)
            menuRow(icon: "stethoscope", title: "诊断与日志", tint: .purple) {
                showDiagnostics = true
            }
            Divider().padding(.leading, 52)
            menuRow(icon: "doc.text.magnifyingglass", title: "免责声明", tint: .blue) {
                showDisclaimer = true
            }
            Divider().padding(.leading, 52)
            menuRow(icon: "power", title: "断开连接", tint: .red) {
                Task { await tunnel.disconnect() }
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func menuRow(icon: String,
                         title: String,
                         tint: Color,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                    .frame(width: 26)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lastInjectCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill")
                .foregroundStyle(tunnel.status.contains("成功") ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.status).font(.subheadline.weight(.medium))
                Text(text).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 地图页

    private var mapTab: some View {
        ZStack(alignment: .top) {
            NativeMapView(state: mapState, picked: picked) { c in
                applyPick(c)
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                searchBar
                Spacer()
                if let p = picked {
                    coordChip(p)
                }
                Text("长按地图选择位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                if bannerVisible {
                    resultBanner
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomButtons
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button { showSearch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("搜索地点...")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                coordText = ""
                showCoordInput = true
            } label: {
                Image(systemName: "number")
                    .font(.system(size: 17))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func coordChip(_ c: CLLocationCoordinate2D) -> some View {
        Text(String(format: "%.7f, %.7f", c.latitude, c.longitude))
            .font(.caption.monospaced())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
    }

    /// 模拟结果提示条：成功绿色、失败红色，3.5 秒自动消失
    private var resultBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: bannerOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 18))
            Text(bannerText)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(bannerOK ? Color.green : Color.red,
                    in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
        .onTapGesture {
            withAnimation { bannerVisible = false }
        }
    }

    private func showBanner(ok: Bool, text: String) {
        bannerOK = ok
        bannerText = text
        withAnimation(.spring(duration: 0.25)) { bannerVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation { bannerVisible = false }
        }
    }

    private var bottomButtons: some View {
        HStack(spacing: 10) {
            bigButton(title: "模拟",
                      icon: "location.fill",
                      tint: .purple,
                      enabled: picked != nil && license.isUsable) {
                simulate()
            }
            bigButton(title: "清除",
                      icon: "xmark",
                      tint: .red,
                      enabled: true) {
                Task {
                    await tunnel.clear()
                    showBanner(ok: true, text: "已清除，恢复真实定位")
                }
            }
            bigButton(title: "收藏",
                      icon: "star",
                      tint: .orange,
                      enabled: true) {
                if let p = picked {
                    Favorites.add(p)
                    showBanner(ok: true, text: "已收藏")
                } else {
                    showFavorites = true
                }
            }
        }
    }

    private func bigButton(title: String,
                           icon: String,
                           tint: Color,
                           enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(enabled ? tint : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(enabled == false)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: - 验证页

    private var verifyTab: some View {
        NavigationStack {
            List {
                Section("授权状态") {
                    HStack {
                        Text(license.state.text)
                            .fontWeight(.semibold)
                            .foregroundStyle(license.isUsable ? .green : .orange)
                        Spacer()
                        Text(license.editionText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if license.isUsable {
                        Text(license.remainingText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showLicense = true
                    } label: {
                        Label(license.isUsable ? "查看授权详情" : "输入卡密激活",
                              systemImage: "key.fill")
                    }
                }

                Section("连接") {
                    LabeledContent("配对文件", value: tunnel.hasPairing ? "已导入" : "未导入")
                    LabeledContent("VPN", value: (tunnel.vpnUp ?? tunnel.tunnelReady) ? "已开启" : "未开启")
                    LabeledContent("隧道", value: tunnel.tunnelReady ? "已连接" : "未连接")
                    LabeledContent("状态", value: tunnel.status)
                }

                Section("坐标模式") {
                    Picker("模式", selection: $modeRaw) {
                        ForEach(InjectMode.allCases) { m in
                            Text(m.rawValue).tag(m.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: modeRaw) { _ in
                        if let p = picked { applyPick(p) }
                    }
                    Text(mode.hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("关于") {
                    LabeledContent("版本", value: "1.1")
                    Button("免责声明") { showDisclaimer = true }
                }
            }
            .navigationTitle("验证")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 逻辑

    private func jump(to c: CLLocationCoordinate2D) {
        mapState.requestJump(to: c)
        applyPick(c)
        toast = "已跳到 " + String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    private func applyPick(_ c: CLLocationCoordinate2D) {
        picked = c
        let out: CLLocationCoordinate2D
        switch mode {
        case .autoGCJ: out = CoordTransform.gcj2wgs(c.latitude, c.longitude)
        case .raw:     out = c
        case .reverse: out = CoordTransform.wgs2gcj(c.latitude, c.longitude)
        }
        injectPoint = out
    }

    private func simulate() {
        guard let p = injectPoint else { return }
        guard license.isUsable else {
            showLicense = true
            return
        }
        Task {
            // 没隧道就先建，再注入
            if tunnel.tunnelReady == false {
                showBanner(ok: true, text: "正在建立隧道…")
                await tunnel.connect()
            }
            let ok = await tunnel.inject(lat: p.latitude, lon: p.longitude)
            if ok {
                let c = String(format: "%.7f, %.7f", p.latitude, p.longitude)
                showBanner(ok: true, text: "模拟成功\n" + c)
            } else {
                showBanner(ok: false, text: "模拟失败：" + tunnel.status)
            }
        }
    }
}

// MARK: - 收藏

enum Favorites {
    private static let key = "favorites_v1"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ c: CLLocationCoordinate2D) {
        var list = load()
        let s = String(format: "%.7f,%.7f", c.latitude, c.longitude)
        if list.contains(s) == false {
            list.insert(s, at: 0)
            if list.count > 50 { list.removeLast() }
            UserDefaults.standard.set(list, forKey: key)
        }
    }

    static func remove(at index: Int) {
        var list = load()
        guard index >= 0 && index < list.count else { return }
        list.remove(at: index)
        UserDefaults.standard.set(list, forKey: key)
    }
}

// MARK: - 收藏列表

struct FavoritesSheet: View {
    var onPick: (CLLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [String] = Favorites.load()

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("还没有收藏。在地图上选好点后点「收藏」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { idx, s in
                    Button {
                        if let c = CoordInput.parse(s) {
                            onPick(CLLocation(latitude: c.latitude, longitude: c.longitude))
                            dismiss()
                        }
                    } label: {
                        Text(s).font(.footnote.monospaced())
                    }
                }
                .onDelete { offsets in
                    for i in offsets { Favorites.remove(at: i) }
                    items = Favorites.load()
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 免责声明

struct DisclaimerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("免责声明").font(.title3.bold())
                    Text("""
                    1. 本 App 仅用于开发者调试、应用测试与个人学习。
                    2. 坐标模拟只影响本机位置显示，不上传、不篡改任何服务器数据。
                    3. 请勿用于考勤作弊、位置欺诈等违法或违反第三方服务条款的用途。
                    4. 使用本 App 产生的一切后果由使用者自行承担。
                    5. 本 App 不收集、不上传用户的真实位置与配对凭据。
                    """)
                    .font(.footnote)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
