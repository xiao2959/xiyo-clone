//
//  LicenseView.swift
//  「授权」页 —— 对齐官方版的授权详情布局
//
//  官方界面元素（截图可见）：
//    已激活 / 所有功能已解锁 / 剩余 28 天 / 刷新状态
//    授权详情：状态|类型 / 过期|剩余
//    检查授权 / 清除授权
//

import SwiftUI

struct LicenseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var license: LicenseManager

    @State private var input: String = ""
    @State private var showClearConfirm: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: license.isUsable
                              ? "checkmark.shield.fill"
                              : "lock.shield.fill")
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
                }

                Section("授权详情") {
                    row("状态", license.state.text, highlight: license.isUsable)
                    row("类型", license.editionText)
                    row("过期", license.expireText)
                    row("剩余", license.remainingText)
                }

                if license.isUsable == false {
                    Section("输入卡密激活") {
                        TextField("粘贴授权码，例如 XYO-…", text: $input)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled(true)
                            .font(.system(.body, design: .monospaced))

                        Button {
                            Task {
                                if await license.activateRemote(input) {
                                    input = ""
                                }
                            }
                        } label: {
                            Text("激活").fontWeight(.semibold)
                        }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    Button {
                        Task { await license.syncRemote() }
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清除授权", systemImage: "trash")
                    }
                }

                if license.lastMessage.isEmpty == false {
                    Section {
                        Text(license.lastMessage)
                            .font(.footnote)
                            .foregroundStyle(license.isUsable ? Color.green : Color.orange)
                    }
                }

                Section("说明") {
                    Text("卡密由发卡面板生成，激活时绑定本机设备。"
                         + "到期后功能自动锁定，需要重新购买卡密。")
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
            .alert("确定要清除所有授权信息吗？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) { license.clear() }
            } message: {
                Text("清除后需要重新激活。")
            }
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
