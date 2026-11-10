//
//  License.swift
//  授权码编解码 —— 对齐官方版的「卡密 + 到期时间」模型
//
//  官方版状态：未激活 / 试用版 / 正式版 / 已过期 / 长期有效
//  官方版字段：remainDays / remainHours / expireTime / isTrial
//
//  授权码格式（离线自校验，每张卡唯一）：
//    XYO-<base36 到期时间戳>-<8位序列号>-<16位大写hex 签名>
//    特例：XYO-LONG-TERM = 长期有效
//
//  签名：SHA256("XiYO" + expBase36 + "-" + serial + SECRET)[:8字节] → 大写 hex
//  ⚠️ 必须与 tools/make_license.py 完全一致（已交叉验证）。
//

import Foundation
import CryptoKit

enum License {

    /// 内嵌密钥（可改）。必须与 make_license.py 的 SECRET 一致。
    static let secret = "XiYO2026-v2-secretKey-9f2c7e4a1b8"

    // MARK: - 生成（App 内一般不用，留给自测）

    static func encode(expireEpoch: Int64, serial: String) -> String? {
        if expireEpoch == 0 { return "XYO-LONG-TERM" }
        let exp = String(expireEpoch, radix: 36).uppercased()
        let ser = serial.uppercased()
        let sig = signature(exp: exp, serial: ser)
        return "XYO-" + exp + "-" + ser + "-" + sig
    }

    // MARK: - 解析

    /// 解析授权码，返回到期时间戳（秒）。0 = 长期有效；非法返回 nil
    static func decode(_ code: String) -> Int64? {
        let c = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if c == "XYO-LONG-TERM" { return 0 }

        let parts = c.split(separator: "-").map(String.init)
        guard parts.count >= 4 && parts[0] == "XYO" else { return nil }

        let exp = parts[1]
        let serial = parts[2]
        guard let e = Int64(exp, radix: 36) else { return nil }

        let expected = signature(exp: exp, serial: serial)
        guard expected == parts[parts.count - 1] else { return nil }
        return e
    }

    /// 取序列号（用于显示/发卡核对）
    static func serial(of code: String) -> String? {
        let c = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if c == "XYO-LONG-TERM" { return "LONG" }
        let parts = c.split(separator: "-").map(String.init)
        guard parts.count >= 4 else { return nil }
        return parts[2]
    }

    // MARK: - 内部

    private static func signature(exp: String, serial: String) -> String {
        let msg = "XiYO" + exp + "-" + serial + secret
        let h = SHA256.hash(data: Data(msg.utf8))
        return h.prefix(8).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - 文案

    static func remainingText(fromExpireEpoch expireEpoch: Int64) -> String {
        if expireEpoch == 0 { return "长期有效" }
        let now = Date().timeIntervalSince1970
        let remaining = TimeInterval(expireEpoch) - now
        if remaining <= 0 { return "已过期" }

        let days = Int(remaining / 86400)
        let hours = Int((remaining.truncatingRemainder(dividingBy: 86400)) / 3600)
        if days > 0 {
            return "剩余 " + String(days) + " 天 " + String(hours) + " 小时"
        }
        let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
        return "剩余 " + String(hours) + " 小时 " + String(minutes) + " 分钟"
    }

    static func dateText(fromEpoch expireEpoch: Int64) -> String {
        if expireEpoch == 0 { return "长期有效" }
        let d = Date(timeIntervalSince1970: TimeInterval(expireEpoch))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
