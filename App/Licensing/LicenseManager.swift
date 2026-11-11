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

    private let kCode = "xiyo_license_code"
    private let kExpire = "xiyo_license_expire"

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

    /// 在线同步：按设备号查会员状态（启动时/刷新时调）
    @discardableResult
    func syncRemote() async -> Bool {
        let r = await CardAPI.info()
        if r.ok {
            await MainActor.run {
                self.expireEpoch = r.permanent ? 0 : (r.endMs / 1000)
                if self.code.isEmpty { self.code = r.account }
                self.save()
                self.refresh()
            }
            return state == .active
        }
        // 网络不通时保留本地状态，不要误锁
        return state == .active
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
    @discardableResult
    func refresh() -> Bool {
        guard code.isEmpty == false else {
            state = .unactivated
            return false
        }
        guard let exp = License.decode(code) else {
            // 存储被破坏
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
        let d = UserDefaults.standard
        d.removeObject(forKey: kCode)
        d.removeObject(forKey: kExpire)
    }

    // MARK: - 存储

    private func save() {
        let d = UserDefaults.standard
        d.set(code, forKey: kCode)
        d.set(expireEpoch, forKey: kExpire)
    }

    private func load() {
        let d = UserDefaults.standard
        if let c = d.string(forKey: kCode) { code = c }
        expireEpoch = Int64(d.double(forKey: kExpire))
    }
}
