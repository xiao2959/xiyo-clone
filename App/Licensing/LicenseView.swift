//
//  LicenseView.swift
//  「授权」页
//
//  卡密走发卡系统（xiaoios.icu）：激活时绑定本机设备号。
//
//  ⚠️ 之前的问题：提示文字（成功/失败原因）放在列表最底部，
//     点「激活」后什么都看不到，误以为"没反应"。
//     现在成功/失败/网络错误都直接顶在最上面，按钮也有「激活中…」状态。
//

import SwiftUI

struct LicenseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var license: LicenseManager

    @State private var input: String = ""
    @State private var showClearConfirm: Bool = false
    @State private var busy: Bool = false

    /// 本次操作的反馈（比 lastMessage 更醒目，操作完立即显示在顶部）
    @State private var feedback: String = ""
    @State private var feedbackOK: Bool = true

    private var trimmed: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                // ---------- 顶部：状态 + 本次反馈 ----------
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: license.isUsable
                              ? "checkmark.shield.fill" : "lock.shield.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(license.isUsable ? Color.green : Color.orange)

                        Text(license.state.text)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(license.isUsable ? Color.green : Color.orange)

                        Text(license.isUsable ? "所有功能已解锁" : "请先输入卡密完成激活")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if license.isUsable {
                            Text(license.remainingText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)

                    if feedback.isEmpty == false {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: feedbackOK
                                  ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(feedbackOK ? Color.green : Color.red)
                            Text(feedback)
                                .font(.footnote)
                                .foregroundStyle(feedbackOK ? Color.green : Color.red)
                        }
                    }
                }

                // ---------- 输入卡密 ----------
                if license.isUsable == false {
                    Section("输入卡密激活") {
                        TextField("粘贴卡密，例如 63Q4-8GPH-Y59A-WK4Y", text: $input)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled(true)
                            .font(.system(.body, design: .monospaced))

                        Button {
                            activate()
                        } label: {
                            HStack(spacing: 8) {
                                if busy {
                                    ProgressView().scaleEffect(0.85)
                                }
                                Text(busy ? "激活中…" : "激活")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(busy || trimmed.isEmpty)
                    }
                }

                // ---------- 详情 ----------
                Section("授权详情") {
                    row("状态", license.state.text, highlight: license.isUsable)
                    row("类型", license.editionText)
                    row("过期", license.expireText)
                    row("剩余", license.remainingText)
                }

                Section {
                    Button {
                        Task { await sync() }
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().scaleEffect(0.85) }
                            Label(busy ? "同步中…" : "刷新状态", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(busy)

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清除本地授权", systemImage: "trash")
                    }
                }

                Section("说明") {
                    Text("卡密由发卡面板生成，激活时绑定本机设备。"
                         + "到期后功能自动锁定，需要重新购买卡密。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("换手机需要在面板里解绑，否则会提示「已绑定其他设备」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("授权")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("确定要清除本地授权信息吗？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    license.clear()
                    feedback = "已清除本地授权，服务器上的绑定仍然保留"
                    feedbackOK = true
                }
            } message: {
                Text("清除后需要重新输入卡密激活。")
            }
            .onAppear {
                // 进页面先同步一次真实状态
                Task { await sync(silent: true) }
            }
        }
    }

    // MARK: - 动作

    private func activate() {
        guard busy == false else { return }
        busy = true
        feedback = "正在验证卡密…"
        feedbackOK = true
        Task {
            let ok = await license.activateRemote(trimmed)
            busy = false
            if ok {
                feedback = "激活成功 · " + license.remainingText
                feedbackOK = true
                input = ""
            } else {
                feedback = license.lastMessage.isEmpty ? "激活失败" : license.lastMessage
                feedbackOK = false
            }
        }
    }

    private func sync(silent: Bool = false) async {
        guard busy == false else { return }
        busy = true
        if silent == false { feedback = "正在同步…" }
        let ok = await license.syncRemote()
        busy = false
        if silent { return }
        if ok {
            feedback = "已同步 · " + license.remainingText
            feedbackOK = true
        } else {
            feedback = "未查到有效会员（这台设备还没激活）"
            feedbackOK = false
        }
    }

    private func row(_ t: String, _ v: String, highlight: Bool = false) -> some View {
        HStack {
            Text(t).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(highlight ? Color.green : Color.primary)
        }
    }
}
