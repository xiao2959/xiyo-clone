//
//  CardAPI.swift
//  CDPro 的卡密接口
//
//  走的是用户原有的发卡系统（和「牛牛守护」「魔盒」等共用一套卡库）：
//    面板：https://xiaoios.icu/cards       （应用选「CDPro」发卡）
//    接口：POST /card/active   激活（卡密 + 设备号绑定）
//          POST /card/info     按设备号查会员
//
//  返回统一是 BaseEntity 结构：
//    {"ret":0, "result":…, "msg":"", "error":""}
//    ret = 0 成功；1 未激活/卡密不存在；2 已过期/已锁定/已停用
//
//  设备号：用 identifierForVendor 的 UUID，服务端认得带横线的 UUID 格式，
//  会把它记录在 bound_uuid 里；换 App 重装只要 vendor 不变就还是同一台。
//

import Foundation
import UIKit

enum CardAPI {

    /// 接口入口：首选香港中转（国内快，实测 0.05s），
    /// 失败自动回退直连域名。两个都不通时才判定没网。
    static let bases = [
        "https://card.103-119-2-243.sslip.io",   // 香港中转
        "https://xiaoios.icu",                   // 直连（备用）
    ]
    static var base: String { bases[0] }

    static var bundleId: String {
        Bundle.main.bundleIdentifier ?? "app.jackfruit3114.leopard8609"
    }

    static var versionName: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1"
    }

    /// 设备标识：优先 identifierForVendor，退化到本地持久 UUID
    static var deviceId: String {
        if let v = UIDevice.current.identifierForVendor?.uuidString, v.isEmpty == false {
            return v
        }
        let key = "cdpro_device_id"
        let d = UserDefaults.standard
        if let s = d.string(forKey: key), s.isEmpty == false { return s }
        let s = UUID().uuidString
        d.set(s, forKey: key)
        return s
    }

    struct Info {
        /// 0=有效 1=未激活/卡密不存在 2=已过期/已锁定/已作废 -1=网络或解析失败
        var ret: Int = -1
        /// 服务器是否真的回应了（用于区分「没网」和「服务器说没有」）
        var reachable: Bool = false
        var ok: Bool = false
        var permanent: Bool = false
        /// 到期毫秒；0 表示永久
        var endMs: Int64 = 0
        var message: String = ""
        var account: String = ""
        var summary: String = ""
        var periodDays: Int = 0
    }

    // MARK: - 对外

    /// 激活：把卡密绑到这台设备上
    static func activate(code: String, device: String = deviceId) async -> Info {
        var i = await post("/card/active", [
            "account": code,
            "imei": device,
            "packageName": bundleId,
            "versionName": versionName,
        ])
        if i.ok {
            // 激活成功后再查一次，拿到准确的到期时间
            let detail = await info(device: device)
            if detail.ok {
                i.endMs = detail.endMs
                i.permanent = detail.permanent
                i.account = detail.account
                i.summary = detail.summary
                i.periodDays = detail.periodDays
            }
        }
        return i
    }

    /// 查询：这台设备当前的会员状态
    static func info(device: String = deviceId) async -> Info {
        await post("/card/info", [
            "imei": device,
            "packageName": bundleId,
            "versionName": versionName,
        ])
    }

    // MARK: - 底层

    /// 依次尝试各个入口，哪个先应答就用哪个
    private static func post(_ path: String, _ body: [String: Any]) async -> Info {
        var last = Info(ok: false, message: "网络连接失败")
        for b in bases {
            let r = await postOnce(b, path, body)
            if r.reachable { return r }   // 服务器真的回了就算结果
            last = r
        }
        return last
    }

    private static func postOnce(_ host: String, _ path: String,
                                 _ body: [String: Any]) async -> Info {
        guard let url = URL(string: host + path) else {
            return Info(ok: false, message: "接口地址错误")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return Info(ok: false, message: "服务器返回异常")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return Info(ok: false, message: "返回内容无法解析")
            }
            return parse(obj)
        } catch {
            return Info(ok: false, message: "网络错误：" + error.localizedDescription)
        }
    }

    private static func parse(_ obj: [String: Any]) -> Info {
        var info = Info()
        let ret = (obj["ret"] as? NSNumber)?.intValue ?? -1
        info.ret = ret
        info.reachable = true
        info.message = (obj["msg"] as? String) ?? ""

        guard ret == 0 else {
            if info.message.isEmpty {
                info.message = (ret == 1) ? "卡密不存在或未激活" : "卡密已过期或被停用"
            }
            return info
        }

        info.ok = true
        if let r = obj["result"] as? [String: Any] {
            info.account = (r["account"] as? String) ?? ""
            info.summary = (r["summary"] as? String) ?? ""
            info.periodDays = (r["period"] as? NSNumber)?.intValue ?? 0
            let endMs = (r["endMs"] as? NSNumber)?.int64Value ?? 0
            // period 99999 视为永久（服务端约定）
            if info.periodDays >= 99999 {
                info.permanent = true
                info.endMs = 0
            } else {
                info.endMs = endMs
            }
            if info.message.isEmpty { info.message = "激活成功" }
        } else if let s = obj["result"] as? String {
            // /card/active 的 result 是签名串，不带到期时间
            _ = s
            info.message = info.message.isEmpty ? "激活成功" : info.message
        }
        return info
    }
}
