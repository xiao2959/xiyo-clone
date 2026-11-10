//
//  PacketTunnelProvider.swift
//  隧道扩展 —— 这是「一个 App 搞定」的关键零件
//
//  为什么必须有它：
//    iOS 上普通 App 无法创建 utun 虚拟网卡。要访问设备的 RSD 服务
//    （IPv6 地址，在 USB 接口上），必须由 NetworkExtension 扩展
//    建一个 packet-tunnel 并设置路由。
//
//  LocalDevVPN 干的就是这件事（573KB，全部内容就这一个类）。
//  我们自己实现，就不需要再装第二个 App。
//
//  数据流：
//    主 App 完成 rppairing + CDTunnel 握手，拿到
//      clientIPv6 / serverIPv6 / serverRsdPort
//    → 通过 NETunnelProviderProtocol.providerConfiguration 传给本扩展
//    → 本扩展建 utun，主 App 就能 connect 到 [serverIPv6]:serverRsdPort
//

import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "com.lab.xiyoclone.tunnel", category: "tunnel")

    override func startTunnel(options: [String: NSObject]?,
                             completionHandler: @escaping (Error?) -> Void) {
        os_log("startTunnel 进入", log: log, type: .info)

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let conf = proto.providerConfiguration else {
            completionHandler(tunnelError("缺少 providerConfiguration"))
            return
        }

        guard let clientV6 = conf["clientIPv6"] as? String, !clientV6.isEmpty else {
            completionHandler(tunnelError("缺少 clientIPv6"))
            return
        }
        guard let serverV6 = conf["serverIPv6"] as? String, !serverV6.isEmpty else {
            completionHandler(tunnelError("缺少 serverIPv6"))
            return
        }
        let mtu = (conf["mtu"] as? NSNumber)?.intValue ?? 1400
        let prefix = (conf["prefix"] as? NSNumber)?.intValue ?? 64
        os_log("client=%{public}@ server=%{public}@ mtu=%d",
               log: log, type: .info, clientV6, serverV6, mtu)

        // 用 server 作为 tunnelRemoteAddress（iOS 要求非空）
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverV6)

        let ipv6 = NEIPv6Settings(addresses: [clientV6],
                                  networkPrefixLengths: [NSNumber(value: prefix)])
        // 把整个 IPv6 默认路由指进隧道，这样到 serverV6 的流量才会走这里
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        if mtu > 0 {
            settings.mtu = NSNumber(value: mtu)
        }

        // 给个内网 DNS，避免影响正常上网
        let dns = NEDNSSettings(servers: ["1.1.1.1"])
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                os_log("setTunnelNetworkSettings 失败: %{public}@",
                       log: self.log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            os_log("隧道建立完成", log: self.log, type: .info)
            completionHandler(nil)
            self.startPacketForwarding()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        os_log("stopTunnel reason=%d", log: log, type: .info, reason.rawValue)
        completionHandler()
    }

    /// 把 utun 上的包原样交回系统。
    ///
    /// 注意：这里不是真正的「转发代理」，因为目标地址是设备在 USB 侧的
    /// IPv6 地址，内核会自己把它丢到 utun 上；我们只要把读到的包
    /// 再写回去（writePackets）保证链路活着即可。
    private func startPacketForwarding() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            if packets.isEmpty == false {
                self.packetFlow.writePackets(packets, withProtocols: packets.map { _ in NSNumber(value: AF_INET6) })
            }
            self.startPacketForwarding()
        }
    }

    private func tunnelError(_ msg: String) -> NSError {
        NSError(domain: "com.lab.xiyoclone.tunnel",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
