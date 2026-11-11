//
//  TunnelBridge.swift
//  Rust 静态库（idevice, MIT）的 Swift 封装
//
//  链路：rppairing → TLS-PSK/CDTunnel → 用户态 TCP → RSD → CoreDevice 注入
//  不需要 utun / NetworkExtension，所以没有 .appex，也就不需要通配符证书。
//
//  底层是阻塞的 C 函数，这里统一丢到后台队列，用 async 返回。
//

import Foundation

enum TunnelBridge {

    /// 返回码（与 Rust ffi_tunnel::rc 一致）
    enum Code: Int32 {
        case ok = 0
        case noTunnel = -1
        case openFailed = -2
        case noService = -3
        case connectFailed = -4
        case actionFailed = -5
        case badPairing = -6
        case badArg = -7

        var text: String {
            switch self {
            case .ok:            return "成功"
            case .noTunnel:      return "隧道未建立"
            case .openFailed:    return "建隧道失败"
            case .noService:     return "设备没有 locationservice"
            case .connectFailed: return "连接服务失败"
            case .actionFailed:  return "注入动作全部失败"
            case .badPairing:    return "配对文件有问题"
            case .badArg:        return "参数非法"
            }
        }
    }

    struct Result {
        let code: Int32
        let message: String
        var ok: Bool { code == Int32(Code.ok.rawValue) }
        var codeText: String { Code(rawValue: code)?.text ?? "未知(\(code))" }
    }

    private static let queue = DispatchQueue(label: "com.lab.xiyoclone.tunnel",
                                            qos: .userInitiated)

    private static func call(_ body: @escaping () -> Result) async -> Result {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: body()) }
        }
    }

    /// 读 C 侧写回的字符串
    private static func readBuffer(_ buf: [CChar]) -> String {
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - 建立隧道

    /// - Parameters:
    ///   - host: 设备地址，本机通常是 "127.0.0.1"
    ///   - rpPort: `_remotepairing._tcp` 端口；0 = 自动探测
    ///   - pairingPath: rppairing 配对文件路径
    static func open(host: String = "127.0.0.1",
                     rpPort: Int32 = 0,
                     pairingPath: String) async -> Result {
        await call {
            var buf = [CChar](repeating: 0, count: 4096)
            let code = host.withCString { h in
                pairingPath.withCString { p in
                    tunnel_open(h, rpPort, p, &buf, Int32(buf.count))
                }
            }
            return Result(code: code, message: readBuffer(buf))
        }
    }

    // MARK: - 注入

    static func inject(lat: Double, lon: Double) async -> Result {
        await call {
            var buf = [CChar](repeating: 0, count: 4096)
            let code = tunnel_inject(lat, lon, &buf, Int32(buf.count))
            return Result(code: code, message: readBuffer(buf))
        }
    }

    /// DVT 通路注入（iOS 27 实际可用的路径）
    static func injectDVT(lat: Double, lon: Double) async -> Result {
        await call {
            var buf = [CChar](repeating: 0, count: 4096)
            let code = tunnel_inject_dvt(lat, lon, &buf, Int32(buf.count))
            return Result(code: code, message: readBuffer(buf))
        }
    }

    static func clearDVT() async -> Result {
        await call {
            var buf = [CChar](repeating: 0, count: 1024)
            let code = tunnel_clear_dvt(&buf, Int32(buf.count))
            return Result(code: code, message: readBuffer(buf))
        }
    }

    static func clear() async -> Result {
        await call {
            var buf = [CChar](repeating: 0, count: 2048)
            let code = tunnel_clear(&buf, Int32(buf.count))
            return Result(code: code, message: readBuffer(buf))
        }
    }

    // MARK: - 诊断

    static func services() async -> String {
        await call {
            var buf = [CChar](repeating: 0, count: 16384)
            _ = tunnel_services(&buf, Int32(buf.count))
            return Result(code: 0, message: readBuffer(buf))
        }.message
    }

    static func diag() async -> String {
        await call {
            var buf = [CChar](repeating: 0, count: 4096)
            _ = tunnel_diag(&buf, Int32(buf.count))
            return Result(code: 0, message: readBuffer(buf))
        }.message
    }

    /// 探测 remotepairing 端口；返回 nil 表示没找到
    static func probePort(host: String = "127.0.0.1") async -> UInt16? {
        let p = await call {
            let v = host.withCString { tunnel_probe_port($0) }
            return Result(code: v, message: "")
        }.code
        return p > 0 ? UInt16(p) : nil
    }

    static func close() async {
        _ = await call {
            _ = tunnel_close()
            return Result(code: 0, message: "")
        }
    }
}
