//
//  TCPRelay.swift
//  LocalVPNExtension
//
//  目的：把 App 发往 10.7.0.1:<port> 的 TCP 流量，接管并在用户态转发到 127.0.0.1:<port>。
//        （iOS 里用户态进程无法把包"投递"到本机回环，只能在 socket 层做代理，
//        所以必须自己终结 TCP：回 SYN-ACK、收数据、发回包、按序号对齐。）
//
//  这是骨架里最硬的一块。已实现：三次握手、数据转发、ACK、FIN/RST、校验和。
//  仍是 TODO：重传、乱序重组、窗口通告（对"一次请求-响应"够用，对长连接/大文件不够）。
//

import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.lab.xiyoclone.ext", category: "relay")

// MARK: - 工具：校验和 / 序列号

private func checksum(_ data: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i + 1 < data.count {
        sum &+= UInt32(data[i]) << 8 | UInt32(data[i + 1])
        i += 2
    }
    if i < data.count { sum &+= UInt32(data[i]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
    return UInt16(~sum & 0xFFFF)
}

private func seqLess(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
private func seqAdd(_ a: UInt32, _ n: Int) -> UInt32 { a &+ UInt32(n) }

// MARK: - TCP 段构造

struct TCPSegment {
    let srcPort: UInt16, dstPort: UInt16
    let seq: UInt32, ack: UInt32
    let flags: UInt8            // FIN=1 SYN=2 RST=4 PSH=8 ACK=16
    let window: UInt16
    let payload: [UInt8]

    static let FIN: UInt8 = 0x01
    static let SYN: UInt8 = 0x02
    static let RST: UInt8 = 0x04
    static let PSH: UInt8 = 0x08
    static let ACK: UInt8 = 0x10

    /// 必须显式写：本类型在主体里定义了 `init?(bytes:offset:)`，
    /// Swift 就不再自动合成 memberwise init，而 RelayConnection.send() 需要它。
    /// （这是真编译错误，不是风格问题）
    init(srcPort: UInt16, dstPort: UInt16, seq: UInt32, ack: UInt32,
         flags: UInt8, window: UInt16, payload: [UInt8]) {
        self.srcPort = srcPort
        self.dstPort = dstPort
        self.seq = seq
        self.ack = ack
        self.flags = flags
        self.window = window
        self.payload = payload
    }

    init?(bytes: [UInt8], offset: Int) {
        guard bytes.count >= offset + 20 else { return nil }
        let b = bytes
        let o = offset
        srcPort = UInt16(b[o]) << 8 | UInt16(b[o + 1])
        dstPort = UInt16(b[o + 2]) << 8 | UInt16(b[o + 3])
        seq     = UInt32(b[o + 4]) << 24 | UInt32(b[o + 5]) << 16 | UInt32(b[o + 6]) << 8 | UInt32(b[o + 7])
        ack     = UInt32(b[o + 8]) << 24 | UInt32(b[o + 9]) << 16 | UInt32(b[o + 10]) << 8 | UInt32(b[o + 11])
        let dataOffset = Int(b[o + 12] >> 4) * 4
        flags   = b[o + 13]
        window  = UInt16(b[o + 14]) << 8 | UInt16(b[o + 15])
        let payloadStart = o + max(dataOffset, 20)
        payload = payloadStart <= bytes.count ? Array(b[payloadStart...]) : []
    }
}

/// 构造一个完整的 IPv4 + TCP 包（从 10.7.0.1 发往 clientIP:clientPort）
func buildIPv4TCP(srcIP: [UInt8], dstIP: [UInt8],
                  segment s: TCPSegment) -> Data {
    let tcpLen = 20 + s.payload.count
    var tcp = [UInt8](repeating: 0, count: tcpLen)
    func put16(_ v: UInt16, _ at: Int) { tcp[at] = UInt8(v >> 8); tcp[at + 1] = UInt8(v & 0xFF) }
    func put32(_ v: UInt32, _ at: Int) {
        tcp[at] = UInt8((v >> 24) & 0xFF); tcp[at + 1] = UInt8((v >> 16) & 0xFF)
        tcp[at + 2] = UInt8((v >> 8) & 0xFF); tcp[at + 3] = UInt8(v & 0xFF)
    }
    put16(s.srcPort, 0); put16(s.dstPort, 2)
    put32(s.seq, 4); put32(s.ack, 8)
    tcp[12] = 5 << 4                      // data offset = 20 字节，无选项
    tcp[13] = s.flags
    put16(s.window, 14)
    tcp[16] = 0; tcp[17] = 0              // 校验和占位
    tcp[18] = 0; tcp[19] = 0
    if !s.payload.isEmpty {
        for (i, b) in s.payload.enumerated() { tcp[20 + i] = b }
    }

    // TCP 伪首部校验和
    var pseudo = [UInt8]()
    pseudo += srcIP; pseudo += dstIP
    pseudo += [0, 6]
    pseudo += [UInt8((tcpLen >> 8) & 0xFF), UInt8(tcpLen & 0xFF)]
    pseudo += tcp
    let csum = checksum(pseudo)
    tcp[16] = UInt8(csum >> 8); tcp[17] = UInt8(csum & 0xFF)

    // IPv4 头
    let totalLen = 20 + tcpLen
    var ip = [UInt8](repeating: 0, count: 20)
    ip[0] = 0x45
    ip[2] = UInt8((totalLen >> 8) & 0xFF); ip[3] = UInt8(totalLen & 0xFF)
    ip[8] = 64                            // TTL
    ip[9] = 6                             // TCP
    for i in 0..<4 { ip[12 + i] = srcIP[i]; ip[16 + i] = dstIP[i] }
    let ipSum = checksum(ip)
    ip[10] = UInt8(ipSum >> 8); ip[11] = UInt8(ipSum & 0xFF)

    return Data(ip + tcp)
}

// MARK: - 单条连接

private final class RelayConnection {
    enum State { case synReceived, established, closing, closed }

    let clientIP: [UInt8]
    let clientPort: UInt16
    let localPort: UInt16
    let flow: String

    var state: State = .synReceived
    var clientISN: UInt32 = 0            // 客户端初始序号
    var serverISN: UInt32               // 本端初始序号（随机）
    var clientNext: UInt32 = 0           // 期望收到的下一个客户端序号
    var serverNext: UInt32 = 0           // 本端已发出的下一个序号

    private var upstream: NWConnection?
    private let queue: DispatchQueue
    private let onReply: (Data) -> Void  // 把构造好的 IP 包交回 packetFlow

    init(clientIP: [UInt8], clientPort: UInt16, localPort: UInt16,
         queue: DispatchQueue, onReply: @escaping (Data) -> Void) {
        self.clientIP = clientIP
        self.clientPort = clientPort
        self.localPort = localPort
        self.flow = "\(clientIP.map(String.init).joined(separator: ".")):\(clientPort)->\(localPort)"
        self.serverISN = UInt32.random(in: 0...UInt32.max)
        self.serverNext = self.serverISN &+ 1
        self.queue = queue
        self.onReply = onReply
    }

    // 收到 SYN → 回 SYN-ACK，同时连 127.0.0.1:localPort
    func onSYN(seq: UInt32) {
        clientISN = seq
        clientNext = seq &+ 1
        send(flags: TCPSegment.SYN | TCPSegment.ACK, payload: [])

        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort) ?? 62078,
                                using: .tcp)
        upstream = conn
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.state = .established
                self.pump()
            case .failed(let e):
                log.error("\(self.flow) upstream failed: \(e.localizedDescription)")
                self.sendRST()
                self.state = .closed
            default: break
            }
        }
        conn.start(queue: queue)
    }

    // 客户端数据 → 转发给本机服务
    func onData(_ payload: [UInt8]) {
        guard !payload.isEmpty else { return }
        let len = payload.count
        if seqLess(clientNext, clientNext &+ UInt32(len)) { clientNext = clientNext &+ UInt32(len) }
        // 简单确认（TODO: 窗口与乱序）
        send(flags: TCPSegment.ACK, payload: [])

        upstream?.send(content: Data(payload), completion: .contentProcessed { [weak self] err in
            if let err { log.error("\(self?.flow ?? "") forward failed: \(err.localizedDescription)") }
        })
    }

    func onFIN() {
        clientNext = clientNext &+ 1
        send(flags: TCPSegment.FIN | TCPSegment.ACK, payload: [])
        upstream?.cancel()
        state = .closed
    }

    // 本机服务回数据 → 封装回给客户端
    private func pump() {
        guard state == .established else { return }
        upstream?.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.send(flags: TCPSegment.ACK | TCPSegment.PSH, payload: [UInt8](data))
            }
            if done || err != nil {
                self.send(flags: TCPSegment.FIN | TCPSegment.ACK, payload: [])
                self.state = .closed
                return
            }
            self.pump()
        }
    }

    private func send(flags: UInt8, payload: [UInt8]) {
        let seg = TCPSegment(srcPort: localPort, dstPort: clientPort,
                             seq: serverNext, ack: clientNext,
                             flags: flags, window: 65535, payload: payload)
        onReply(buildIPv4TCP(srcIP: [10, 7, 0, 1], dstIP: clientIP, segment: seg))
        if flags & (TCPSegment.SYN | TCPSegment.FIN) != 0 || !payload.isEmpty {
            serverNext = serverNext &+ UInt32(payload.count) &+ ((flags & TCPSegment.SYN != 0 || flags & TCPSegment.FIN != 0) ? 1 : 0)
        }
    }

    private func sendRST() {
        let seg = TCPSegment(srcPort: localPort, dstPort: clientPort,
                             seq: serverNext, ack: clientNext,
                             flags: TCPSegment.RST | TCPSegment.ACK, window: 0, payload: [])
        onReply(buildIPv4TCP(srcIP: [10, 7, 0, 1], dstIP: clientIP, segment: seg))
    }
}

// MARK: - 总调度

final class TCPRelay {
    private var conns: [String: RelayConnection] = [:]
    private let queue = DispatchQueue(label: "tunnel.tcprelay")
    private let onReply: (Data) -> Void

    init(onReply: @escaping (Data) -> Void) { self.onReply = onReply }

    /// 处理一个发往 10.7.0.1 的 TCP 包
    func handle(packet: Data) {
        let bytes = [UInt8](packet)
        guard bytes.count >= 20 else { return }
        let ihl = Int(bytes[0] & 0x0F) * 4
        guard bytes.count >= ihl + 20 else { return }

        let clientIP = Array(bytes[16..<20])
        guard let seg = TCPSegment(bytes: bytes, offset: ihl) else { return }

        let key = "\(clientIP.map(String.init).joined(separator: ".")):\(seg.srcPort)"
        if var c = conns[key] {
            if seg.flags & TCPSegment.SYN != 0 {
                c.onSYN(seq: seg.seq)
            } else if seg.flags & TCPSegment.FIN != 0 {
                c.onFIN()
                conns.removeValue(forKey: key)
            } else if !seg.payload.isEmpty {
                c.onData(seg.payload)
            }
            return
        }

        guard seg.flags & TCPSegment.SYN != 0 else {
            log.debug("drop non-SYN for unknown flow \(key)")
            return
        }
        let c = RelayConnection(clientIP: clientIP, clientPort: seg.srcPort,
                                localPort: seg.dstPort, queue: queue, onReply: onReply)
        conns[key] = c
        c.onSYN(seq: seg.seq)
    }

    func closeAll() {
        conns.removeAll()
    }
}
