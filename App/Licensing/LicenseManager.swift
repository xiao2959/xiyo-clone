//
//  LicenseManager.swift
//  授权状态机（对齐官方版）
//
//  官方状态（从二进制挖出的原词）：
//    未激活 / 请先输入卡密完成激活
//    已激活 / 所有功能已解锁
//    试用版 / 正式版
//    授权已过期，请重新激活
//    长期有效
//    检查未通过，请稍后重试
//
//  存储：UserDefaults（官方也用本地存储 + 「清除授权」）
//

import Foundation
import Combine

/// 授权状态
enum LicenseState: String {
    case unactivated   // 未激活
    case active        // 已激活
    case expired       // 已过期

    var text: String {
        switch self {
        case .unactivated: return "未激活"
        case .active:      return "已激活"
        case .expired:     return "已过期"
        }
    }
}

final class LicenseManager: ObservableObject {

    @Published private(set) var state: LicenseState = .unactivated
    @Published private(set) var code: String = ""
    /// 到期时间戳（秒）。0 = 长期有效
    @Published private(set) var expireEpoch: Int64 = 0
    @Published private(set) var lastMessage: String = ""
    /// 这张卡是不是「在线激活」来的（走发卡系统）
    @Published private(set) var remoteBound: Bool = false
    /// 在线卡是否永久
    @Published private(set) var permanentCard: Bool = false

    private let kCode = "xiyo_license_code"
    private let kExpire = "xiyo_license_expire"
    private let kRemote = "cdpro_license_remote"
    private let kPermanent = "cdpro_license_permanent"

    init() {
        load()
        refresh()
    }

    // MARK: - 对外

    var isUsable: Bool {
        return state == .active
    }

    /// 是否长期有效
    var isPermanent: Bool {
        return expireEpoch == 0 && state == .active
    }

    /// 版本类型文案（官方："试用版"/"正式版"）
    var editionText: String {
        guard state == .active else { return "未解锁" }
        if isPermanent { return "正式版·长期" }
        // 剩余不足 7 天显示试用版（和官方 isTrial 语义一致）
        let remaining = expireEpoch - Int64(Date().timeIntervalSince1970)
        return remaining < 7 * 86400 ? "试用版" : "正式版"
    }

    /// 剩余时长文案
    var remainingText: String {
        switch state {
        case .unactivated: return "—"
        case .expired:     return "已过期，请重新激活"
        case .active:      return License.remainingText(fromExpireEpoch: expireEpoch)
        }
    }

    /// 到期时间显示
    var expireText: String {
        if state == .unactivated { return "—" }
        return License.dateText(fromEpoch: expireEpoch)
    }

    // MARK: - 在线卡密（走发卡系统，和牛牛守护共用卡库）

    /// 在线激活：调 /card/active 把卡密绑到本机
    ///
    /// 服务端返回 ret=0 才算成功；成功后立刻查一次 /card/info 拿到准确到期时间。
    @discardableResult
    func activateRemote(_ input: String) async -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            lastMessage = "请输入卡密"
            return false
        }
        lastMessage = "正在验证…"
        let r = await CardAPI.activate(code: trimmed)
        if r.ok {
            await MainActor.run {
                self.code = trimmed
                self.remoteBound = true
                self.permanentCard = r.permanent
                self.expireEpoch = r.permanent ? 0 : (r.endMs / 1000)
                self.save()
                self.refresh()
                self.lastMessage = "激活成功" + (r.summary.isEmpty ? "" : "·" + r.summary)
            }
            return true
        }
        await MainActor.run {
            self.lastMessage = r.message.isEmpty ? "激活失败" : r.message
        }
        return false
    }

    /// 在线同步：按设备号查会员状态（启动时 / 回前台 / 注入前调）
    ///
    /// 规则（和发卡面板严格对齐）：
    ///   ret=0  → 有效，更新到期时间（续费立刻生效）
    ///   ret=1  → 服务器说这台设备没有卡（被解绑）→ 立即锁
    ///   ret=2  → 已过期 / 已锁定 / 已作废 → 立即锁
    ///   ret=-1 → 网络或解析失败 → 保留本地状态，不误锁
    @discardableResult
    func syncRemote() async -> Bool {
        let r = await CardAPI.info()

        // 没连上服务器：离线容忍，保留本地判断
        if r.reachable == false {
            return state == .active
        }

        if r.ret == 0 {
            await MainActor.run {
                self.remoteBound = true
                self.permanentCard = r.permanent
                self.expireEpoch = r.permanent ? 0 : (r.endMs / 1000)
                if self.code.isEmpty { self.code = r.account }
                self.save()
                self.refresh()
                if self.lastMessage.isEmpty { self.lastMessage = "" }
            }
            return state == .active
        }

        // 服务器明确说「没有有效会员」——立刻按服务器执行
        await MainActor.run {
            self.remoteBound = true
            self.expireEpoch = 0
            self.state = (r.ret == 1) ? .unactivated : .expired
            self.lastMessage = r.message.isEmpty
                ? (r.ret == 1 ? "这台设备已解绑，请重新激活" : "会员失效，请重新购买")
                : r.message
            self.save()
        }
        return false
    }

    /// 激活
    @discardableResult
    func activate(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            lastMessage = "请输入授权码"
            return false
        }
        guard let exp = License.decode(trimmed) else {
            lastMessage = "授权码无效"
            return false
        }
        // 已过期的码直接拒绝
        if exp != 0 && exp <= Int64(Date().timeIntervalSince1970) {
            lastMessage = "该授权码已过期"
            return false
        }
        code = trimmed
        expireEpoch = exp
        save()
        refresh()
        lastMessage = "激活成功"
        return true
    }

    /// 重新检查（对应官方「检查授权」/「刷新状态」）
    ///
    /// ⚠️ 关键：在线卡密（如 63Q4-8GPH-Y59A-WK4Y）不是本地那套 XYO 格式，
    ///    绝不能再拿去 License.decode()，否则必然解不开、状态会被打回「未激活」，
    ///    表现就是"点了激活没反应"。
    @discardableResult
    func refresh() -> Bool {
        // 在线激活的卡：按服务器给的到期时间判断
        if remoteBound {
            if permanentCard {
                state = .active
                return true
            }
            let now = Int64(Date().timeIntervalSince1970)
            state = (expireEpoch > now) ? .active : .expired
            return state == .active
        }

        // 旧的本地卡：沿用原来的离线校验
        guard code.isEmpty == false else {
            state = .unactivated
            return false
        }
        guard let exp = License.decode(code) else {
            state = .unactivated
            return false
        }
        expireEpoch = exp
        if exp == 0 {
            state = .active
            return true
        }
        let now = Int64(Date().timeIntervalSince1970)
        state = (exp > now) ? .active : .expired
        return state == .active
    }

    /// 清除授权（对应官方「清除授权」）
    func clear() {
        code = ""
        expireEpoch = 0
        state = .unactivated
        lastMessage = "已清除授权"
        remoteBound = false
        permanentCard = false
        let d = UserDefaults.standard
        d.removeObject(forKey: kCode)
        d.removeObject(forKey: kExpire)
        d.removeObject(forKey: kRemote)
        d.removeObject(forKey: kPermanent)
    }

    // MARK: - 存储

    private func save() {
        let d = UserDefaults.standard
        d.set(code, forKey: kCode)
        d.set(expireEpoch, forKey: kExpire)
        d.set(remoteBound, forKey: kRemote)
        d.set(permanentCard, forKey: kPermanent)
    }

    private func load() {
        let d = UserDefaults.standard
        if let c = d.string(forKey: kCode) { code = c }
        expireEpoch = Int64(d.double(forKey: kExpire))
        remoteBound = d.bool(forKey: kRemote)
        permanentCard = d.bool(forKey: kPermanent)
    }
}
