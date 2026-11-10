//
//  ResultSheet.swift
//  注入结果确认（从 StikDebug 返回时弹出）
//
//  为什么要这个：StikDebug 的确认框是英文的（Simulate Location? / Clear Location?），
//  而且它不会把"注入成功还是失败"回传给我们。
//  所以让用户回到本 App 时一键标记，之后主界面常驻显示中文结果。
//

import SwiftUI

struct ResultSheet: View {
    @Environment(\.dismiss) private var dismiss

    let coord: String
    let onResult: (Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("模拟成功了吗？")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("刚才发送的目标")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(coord)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)

                Text("看一眼手机地图上的蓝点：\n在目标位置就是成功，回真实位置或没动就是失败。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    onResult(true)
                    dismiss()
                } label: {
                    Text("✅ 模拟成功")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(Color.green.opacity(0.18))
                        .foregroundStyle(.green)
                        .cornerRadius(14)
                }

                Button {
                    onResult(false)
                    dismiss()
                } label: {
                    Text("❌ 没成功")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(Color.red.opacity(0.14))
                        .foregroundStyle(.red)
                        .cornerRadius(14)
                }

                Spacer()
            }
            .padding(22)
            .navigationTitle("注入结果")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后") { dismiss() }
                }
            }
        }
    }
}
