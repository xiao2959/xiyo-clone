//
//  NetWatch.swift
//  监测当前是否走蜂窝网络
//
//  为什么要看这个：
//    官方版在蜂窝网络下会要求「先开启飞行模式」。
//    原因是——开着蜂窝时 iOS 还能拿到基站信息，
//    考勤 App 可以用基站/邻区反推你在别处，注入的位置就不成立。
//    开飞行模式后没有基站，注入的位置成为唯一来源。
//

import Foundation
import Network
import Combine

final class NetWatch: ObservableObject {

    @Published var onCellular: Bool = false
    @Published var hasNetwork: Bool = true
    @Published var interfaceText: String = "—"

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            var ifaces: [String] = []
            if path.usesInterfaceType(.wifi) { ifaces.append("WiFi") }
            if path.usesInterfaceType(.cellular) { ifaces.append("蜂窝") }
            if path.usesInterfaceType(.wiredEthernet) { ifaces.append("有线") }

            DispatchQueue.main.async {
                self?.hasNetwork = (path.status == .satisfied)
                self?.onCellular = path.usesInterfaceType(.cellular)
                self?.interfaceText = ifaces.isEmpty ? "无" : ifaces.joined(separator: " + ")
            }
        }
        monitor.start(queue: DispatchQueue(label: "cdpro.netwatch"))
    }

    deinit { monitor.cancel() }

    /// 需要提醒用户开飞行模式
    var shouldWarnAirplane: Bool { onCellular }
}
