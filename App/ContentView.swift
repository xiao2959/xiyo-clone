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
    case autoGCJ = "标准模式（自动换算 GCJ→WGS）"
    case raw     = "兼容模式（原样注入）"
    case reverse = "反向模式（WGS→GCJ）"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .autoGCJ: return "标准模式 · 适用于大部分设备（默认）"
        case .raw:     return "兼容模式 · 适用于偏移设备"
        case .reverse: return "反向模式 · 前两种都往反方向偏时用"
        }
    }

    /// 对应官方版的叫法，方便对照
    var officialName: String {
        switch self {
        case .autoGCJ: return "标准模式"
        case .raw:     return "兼容模式"
        case .reverse: return "反向模式"
        }
    }
}

struct ContentView: View {

    // 共享状态
    @StateObject private var tunnel = TunnelModel()
    @StateObject private var license = LicenseManager()
    @StateObject private var mapState = MapState()
    @StateObject private var search = SearchModel()
    @StateObject private var netWatch = NetWatch()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var insp = LocationInspector()
    @State private var showAirplaneWarn = false
    /// 微调步长（米）
    @AppStorage("nudge_meters") private var nudgeMeters: Double = 10

    // 选点
    @State private var picked: CLLocationCoordinate2D?
    @State private var injectPoint: CLLocationCoordinate2D?
    @AppStorage("inject_mode") private var modeRaw: String = InjectMode.autoGCJ.rawValue
    /// 平滑移动（避免瞬移导致「速度异常」判定）
    @AppStorage("smooth_move") private var smoothMove: Bool = false

    // 界面
    @State private var showSearch = false
    @State private var showLicense = false
    @State private var showPairing = false
    @State private var showDiagnostics = false
    @State private var showCoordInput = false
    @State private var showDisclaimer = false
    @State private var showFavorites = false
    @State private var showHistory = false
    @State private var showFavNamePrompt = false
    @State private var favName = ""
    @State private var favCoord: CLLocationCoordinate2D?
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
        .onChange(of: scenePhase) { _, phase in
            // 切到后台的瞬间再注一次，避免刚切过去时被系统回退到真实位置
            if phase == .background, let c = tunnel.lastCoord {
                Task { _ = await TunnelBridge.moveDVT(lat: c.0, lon: c.1) }
            }
        }
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
            // 回前台同步会员状态：面板里锁定/解绑/续费都能立刻生效
            Task { _ = await license.syncRemote() }
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
            FavoritesSheet { c in jump(to: c) }
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet { c in jump(to: c) }
        }
        .sheet(isPresented: $showDisclaimer) {
            DisclaimerSheet()
        }
        .alert("请先开启飞行模式", isPresented: $showAirplaneWarn) {
            Button("我去开启", role: .cancel) {
                showBanner(ok: true, text: "开好飞行模式后再点一次「模拟」")
            }
            Button("已开启，继续") {
                Task { await runInject() }
            }
            Button("不开直接模拟") {
                // 不强制：有些场景开不了飞行模式（比如需要接电话）
                Task { await runInject() }
            }
        } message: {
            Text("当前是蜂窝网络（\(netWatch.interfaceText)）。\n\n"
                 + "开着蜂窝时，考勤类 App 能拿到基站信息反推你的真实位置，"
                 + "注入的位置会被判为异常。\n\n"
                 + "做法：下拉控制中心 → 打开飞行模式 → 再点「设置」把 WiFi 打开"
                 + "（需要网时）→ 回来继续。")
        }
        .alert("给这个位置起个名字", isPresented: $showFavNamePrompt) {
            TextField("例如：家 / 公司 / 学校", text: $favName)
            Button("取消", role: .cancel) { favCoord = nil }
            Button("收藏") {
                if let c = favCoord {
                    Favorites.add(c, name: favName)
                    showBanner(ok: true, text: favName.isEmpty
                               ? "已收藏" : "已收藏：「\(favName)」")
                }
                favCoord = nil
            }
        } message: {
            if let c = favCoord {
                Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
            }
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
                 title: "LocalDevVPN",
                 subtitle: (tunnel.vpnUp ?? tunnel.tunnelReady) ? "已连接" : "未连接") {
                if (tunnel.vpnUp ?? tunnel.tunnelReady) {
                    showBanner(ok: true, text: "LocalDevVPN 已连接")
                } else {
                    // 打开图文教程（含港区 Apple ID 注册 + App Store 直达）
                    if let u = URL(string: "https://103-119-2-243.sslip.io/vpn/") {
                        UIApplication.shared.open(u)
                    }
                }
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
                if license.isUsable == false {
                    Button { showLicense = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill").font(.caption)
                            Text("未激活 · 点此输入卡密").font(.footnote.weight(.medium))
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.orange, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if tunnel.vpnUp == false {
                    Button {
                        if let u = URL(string: "https://103-119-2-243.sslip.io/vpn/") {
                            UIApplication.shared.open(u)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open.fill").font(.caption)
                            Text("LocalDevVPN 没连 · 点此安装/连接").font(.footnote.weight(.medium))
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.blue, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let p = picked {
                    coordChip(p)
                    nudgeBar()
                }
                Text("长按地图选择位置（或点右上角 # 输入经纬度）")
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

            // 右侧浮动：收藏 / 历史
            VStack(spacing: 12) {
                sideButton(icon: "star", label: "收藏", tint: .orange) {
                    showFavorites = true
                }
                sideButton(icon: "clock.arrow.circlepath", label: "历史", tint: .blue) {
                    showHistory = true
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 68)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func sideButton(icon: String, label: String,
                            tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 46, height: 46)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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

    /// 微调：四个方向按米数平移，解决「就差一点点」
    private func nudgeBar() -> some View {
        HStack(spacing: 6) {
            nudgeButton("chevron.left")  { nudge(dLat: 0, dLon: -1) }
            VStack(spacing: 2) {
                nudgeButton("chevron.up")   { nudge(dLat: 1, dLon: 0) }
                nudgeButton("chevron.down") { nudge(dLat: -1, dLon: 0) }
            }
            nudgeButton("chevron.right") { nudge(dLat: 0, dLon: 1) }

            Button {
                nudgeMeters = (nudgeMeters < 50) ? nudgeMeters * 5 : 5
            } label: {
                Text("\(Int(nudgeMeters))m")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 26)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func nudgeButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 30, height: 26)
        }
        .buttonStyle(.plain)
    }

    /// 按米数平移当前选点
    private func nudge(dLat: Double, dLon: Double) {
        guard let cur = picked else { return }
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = metersPerDegLat * cos(cur.latitude * .pi / 180)
        let new = CLLocationCoordinate2D(
            latitude: cur.latitude + dLat * nudgeMeters / metersPerDegLat,
            longitude: cur.longitude + dLon * nudgeMeters / max(metersPerDegLon, 1))
        applyPick(new)
        showBanner(ok: true, text: String(format: "已微调 ±%.0f 米", nudgeMeters))
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
                      enabled: picked != nil) {
                if license.isUsable == false {
                    showBanner(ok: false, text: "还没激活，先输入卡密")
                    showLicense = true
                    return
                }
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
                    favCoord = p
                    favName = ""
                    showFavNamePrompt = true
                    prefillFavoriteName(p)
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
                    LabeledContent("模拟保持",
                                   value: tunnel.lastCoord == nil ? "未启用" : "已开启（每 8 秒刷新）")
                    LabeledContent("状态", value: tunnel.status)
                }

                Section("定位诊断（看系统真实值）") {
                    Button(insp.running ? "停止监听" : "开始监听") {
                        insp.running ? insp.stop() : insp.start()
                    }
                    if insp.ts != nil {
                        LabeledContent("经纬度", value: String(format: "%.7f, %.7f", insp.lat, insp.lon))
                        LabeledContent("水平精度", value: String(format: "%.1f 米", insp.accuracy))
                        LabeledContent("时效", value: insp.ageText)
                        LabeledContent("速度", value: insp.speed < 0 ? "无" : String(format: "%.1f m/s", insp.speed))
                        LabeledContent("设备标记·软件模拟",
                                       value: insp.simulatedBySoftware == true ? "是 ⚠️"
                                              : (insp.simulatedBySoftware == false ? "否 ✅" : "系统未提供"))
                        LabeledContent("设备标记·外设提供",
                                       value: insp.producedByAccessory == true ? "是 ⚠️"
                                              : (insp.producedByAccessory == false ? "否 ✅" : "系统未提供"))
                        LabeledContent("VPN网卡",
                                       value: insp.hasTunnelInterface().0
                                              ? insp.hasTunnelInterface().1.joined(separator: ",")
                                              : "无")
                        LabeledContent("系统代理",
                                       value: insp.proxySettings().0
                                              ? insp.proxySettings().1 : "无")
                        Text(insp.verdict)
                            .font(.caption)
                            .foregroundStyle(insp.simulatedBySoftware == true || insp.producedByAccessory == true
                                             ? .orange : .green)
                    } else {
                        Text("点上面开始监听，就能看到系统当前认为你在哪、以及是否被标记为模拟。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("注入方式") {
                    Toggle(isOn: $smoothMove) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("平滑移动")
                            Text("分 20 步过去，不会一下子跳过去；能减少「速度异常」判定")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("部分考勤 App 会检测 iOS 的「软件模拟位置」标志，"
                         + "这个开关只能减少跳变痕迹，无法消除该标志。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
                    Text("对照官方：标准模式（适用大部分设备）/ 兼容模式（适用于偏移设备）。"
                         + "实测偏了就切一下，选对一次会记住。")
                        .font(.caption2)
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

    /// 把坐标反查成地址，作为收藏名字的默认值
    private func prefillFavoriteName(_ c: CLLocationCoordinate2D) {
        let geo = CLGeocoder()
        let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
        geo.reverseGeocodeLocation(loc) { marks, _ in
            guard let pm = marks?.first else { return }
            var parts: [String] = []
            if let n = pm.name, n.isEmpty == false { parts.append(n) }
            if let t = pm.thoroughfare, t.isEmpty == false, parts.contains(t) == false {
                parts.append(t)
            }
            if let l = pm.locality, l.isEmpty == false, parts.contains(l) == false {
                parts.append(l)
            }
            let name = parts.joined(separator: " · ")
            guard name.isEmpty == false else { return }
            DispatchQueue.main.async {
                if self.favName.isEmpty { self.favName = name }
            }
        }
    }

    private func simulate() {
        guard let p = injectPoint else {
            // 不能静默返回：用户看不到任何反应就会以为“没用”
            tunnel.status = "请先选一个位置"
            tunnel.append("未选点，已提示用户")
            showBanner(ok: false, text: "请先长按地图选一个位置\n或点右上角 # 输入经纬度")
            return
        }
        guard license.isUsable else {
            showLicense = true
            return
        }
        // 蜂窝网络下先提醒开飞行模式（这是官方版的做法，也是不被检测的关键）
        if netWatch.shouldWarnAirplane {
            tunnel.status = "待确认：是否开飞行模式"
            tunnel.append("检测到蜂窝网络，弹窗确认中")
            showAirplaneWarn = true
            return
        }

        Task { await runInject() }
    }

    /// 真正做注入（弹窗确认后也走这里）
    private func runInject() async {
        guard let p = injectPoint else {
            showBanner(ok: false, text: "请先长按地图选一个位置")
            return
        }

        // 注入前先跟服务器确认一次会员状态（锁定/解绑会立刻拦住）
        _ = await license.syncRemote()
        if license.isUsable == false {
            showBanner(ok: false, text: license.lastMessage.isEmpty
                       ? "会员已失效，请重新激活" : license.lastMessage)
            showLicense = true
            return
        }
        // 没隧道就先建，再注入
        if tunnel.tunnelReady == false {
            showBanner(ok: true, text: "正在建立隧道…")
            await tunnel.connect()
        }
        let ok = smoothMove
            ? await tunnel.injectSmooth(from: tunnel.lastCoord,
                                        lat: p.latitude, lon: p.longitude)
            : await tunnel.inject(lat: p.latitude, lon: p.longitude)
        if ok {
            // 注入成功后采一次系统定位真值，一并上传
            insp.start()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            tunnel.uploadInjectLog(tag: "成功", extra: insp.snapshotText())
            insp.stop()
        } else {
            tunnel.uploadInjectLog(tag: "失败")
        }
        if ok {
            History.add(lat: p.latitude, lon: p.longitude)
            // 开始保活：防止切后台后位置跳回
            tunnel.startKeepAlive()
            let c = String(format: "%.7f, %.7f", p.latitude, p.longitude)
            showBanner(ok: true, text: "模拟成功·已开启保活\n" + c)
        } else {
            showBanner(ok: false, text: "模拟失败：" + tunnel.status)
        }
    }
}

// MARK: - 收藏

struct FavoriteItem: Codable, Identifiable {
    var id: String { "\(lat),\(lon)" }
    let lat: Double
    let lon: Double
    var name: String
    let ts: TimeInterval

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    var coordText: String {
        String(format: "%.7f, %.7f", lat, lon)
    }
    var displayName: String {
        name.isEmpty ? coordText : name
    }
}

enum Favorites {
    private static let key = "favorites_v2"
    private static let legacyKey = "favorites_v1"

    static func load() -> [FavoriteItem] {
        let d = UserDefaults.standard
        if let data = d.data(forKey: key),
           let list = try? JSONDecoder().decode([FavoriteItem].self, from: data) {
            return list
        }
        // 迁移旧版只有经纬度的收藏
        if let old = d.stringArray(forKey: legacyKey), old.isEmpty == false {
            var list: [FavoriteItem] = []
            for s in old {
                if let c = CoordInput.parse(s) {
                    list.append(FavoriteItem(lat: c.latitude, lon: c.longitude,
                                             name: "", ts: Date().timeIntervalSince1970))
                }
            }
            save(list)
            d.removeObject(forKey: legacyKey)
            return list
        }
        return []
    }

    static func save(_ list: [FavoriteItem]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func add(_ c: CLLocationCoordinate2D, name: String) {
        var list = load()
        let item = FavoriteItem(lat: c.latitude, lon: c.longitude,
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                ts: Date().timeIntervalSince1970)
        if let i = list.firstIndex(where: { $0.id == item.id }) {
            list[i] = item                 // 同一个点直接更新名字
        } else {
            list.insert(item, at: 0)
            if list.count > 100 { list.removeLast() }
        }
        save(list)
    }

    static func rename(at index: Int, to name: String) {
        var list = load()
        guard index >= 0 && index < list.count else { return }
        list[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save(list)
    }

    static func remove(at index: Int) {
        var list = load()
        guard index >= 0 && index < list.count else { return }
        list.remove(at: index)
        save(list)
    }

    static func remove(id: String) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
    }
}


// MARK: - 历史记录

/// 一次模拟记录
struct HistoryItem: Codable, Identifiable {
    var id: String { "\(lat),\(lon),\(ts)" }
    let lat: Double
    let lon: Double
    let ts: TimeInterval
    var name: String = ""

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    var coordText: String {
        String(format: "%.7f, %.7f", lat, lon)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

enum History {
    private static let key = "history_v1"
    private static let maxCount = 100

    static func load() -> [HistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([HistoryItem].self, from: data)
        else { return [] }
        return list
    }

    static func add(lat: Double, lon: Double, name: String = "") {
        var list = load()
        // 同一个点一分钟内不重复记
        if let first = list.first,
           abs(first.lat - lat) < 0.0000005, abs(first.lon - lon) < 0.0000005,
           Date().timeIntervalSince1970 - first.ts < 60 {
            return
        }
        list.insert(HistoryItem(lat: lat, lon: lon,
                                ts: Date().timeIntervalSince1970, name: name),
                    at: 0)
        if list.count > maxCount { list.removeLast(list.count - maxCount) }
        save(list)
    }

    static func remove(at index: Int) {
        var list = load()
        guard index >= 0 && index < list.count else { return }
        list.remove(at: index)
        save(list)
    }

    static func clear() { save([]) }

    private static func save(_ list: [HistoryItem]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 历史列表

struct HistorySheet: View {
    var onPick: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [HistoryItem] = History.load()
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("还没有模拟记录。\n在地图上选好点、点「模拟」成功后会自动记录在这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    Button {
                        onPick(item.coordinate)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.coordText)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text(item.timeText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { History.remove(at: i) }
                    items = History.load()
                }
            }
            .navigationTitle("模拟历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if items.isEmpty == false {
                        Button("清空") { showClearConfirm = true }
                            .foregroundStyle(.red)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("清空所有模拟历史？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    History.clear()
                    items = []
                }
            }
        }
    }
}

// MARK: - 收藏列表

struct FavoritesSheet: View {
    var onPick: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [FavoriteItem] = Favorites.load()
    @State private var renaming: FavoriteItem?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("还没有收藏。\n在地图选好点后点「收藏」，可以给它起个名字。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    Button {
                        onPick(item.coordinate)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(item.coordText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            renaming = item
                            renameText = item.name
                        } label: {
                            Label("改名", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Favorites.remove(id: item.id)
                            items = Favorites.load()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("改个名字", isPresented: Binding(
                get: { renaming != nil },
                set: { if $0 == false { renaming = nil } }
            )) {
                TextField("例如：家 / 公司 / 学校", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let r = renaming,
                       let i = items.firstIndex(where: { $0.id == r.id }) {
                        Favorites.rename(at: i, to: renameText)
                        items = Favorites.load()
                    }
                    renaming = nil
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
