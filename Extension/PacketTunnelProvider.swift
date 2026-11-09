//
//  PacketTunnelProvider.swift
//  LocalVPNExtension
//
//  职责只有三件：
//   1. 起"本地 VPN"：只接管 10.7.0.0/24，其余流量直连（分流）
//   2. 把发往 10.7.0.1 的 TCP 包交给 TCPRelay，由它代理到 127.0.0.1
//   3. 给 App 提供控制通道（handleAppMessage）
//
//  对应拆包证据：NSExtensionPointIdentifier=packet-tunnel，startNAT，10.7.0.0/10.7.0.1
//

import NetworkExtension
import Network
import os.log

private let log = Logger(subsystem: "com.lab.xiyoclone.ext", category: "tunnel")

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let gateway = "10.7.0.1"
    private let net = "10.7.0.0"
    private let mask = "255.255.255.0"
    private let queue = DispatchQueue(label: "tunnel.io")

    private lazy var relay = TCPRelay { [weak self] reply in
        self?.packetFlow.writePackets([reply], withProtocols: [NSNumber(value: AF_INET)])
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: gateway)

        let ipv4 = NEIPv4Settings(addresses: [gateway], subnetMasks: [mask])
        // 只接管 10.7.0.0/24；其余流量 iOS 会自动直连（这就是分流）
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: net, subnetMask: mask)]
        settings.ipv4Settings = ipv4
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                log.error("setTunnelNetworkSettings: \(error.localizedDescription)")
                completionHandler(error); return
            }
            log.info("tunnel up, gateway=\(self.gateway)")
            self.readLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        relay.closeAll()
        log.info("tunnel down: \(reason.rawValue)")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let text = String(data: messageData, encoding: .utf8) else { completionHandler?(nil); return }
        switch text {
        case "ping": completionHandler?("pong".data(using: .utf8))
        case "stats":
            completionHandler?("{\"ok\":true}".data(using: .utf8))
        default: completionHandler?(nil)
        }
    }

    // MARK: - 收包循环

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            for (i, p) in packets.enumerated() {
                let proto = protocols[i].int32Value
                let bytes = [UInt8](p)
                guard bytes.count >= 20, bytes[0] >> 4 == 4 else { continue }
                let dstIsGateway = bytes[16] == 10 && bytes[17] == 7 && bytes[18] == 0 && bytes[19] == 1
                guard dstIsGateway else { continue }

                switch proto {
                case AF_INET:
                    if bytes[9] == 6 {           // TCP
                        self.relay.handle(packet: p)
                    } else if bytes[9] == 17 {   // UDP（TODO：RSD 某些通道可能走 UDP，先记录）
                        log.debug("UDP to gateway, port \(bytes[22] << 8 | bytes[23]) ignored")
                    }
                default: continue
                }
            }
            self.readLoop()
        }
    }
}
