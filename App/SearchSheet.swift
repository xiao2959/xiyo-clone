//
//  SearchSheet.swift
//  地点搜索面板
//

import SwiftUI
import MapKit

struct SearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var search: SearchModel
    let onPick: (CLLocationCoordinate2D) -> Void

    @State private var busy: Bool = false
    @State private var err: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("例如：潍坊学院 / 北京西站 / 歌尔光电园", text: $search.query)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                }

                if err.isEmpty == false {
                    Section { Text(err).font(.footnote).foregroundStyle(.red) }
                }

                if busy {
                    Section { HStack { ProgressView(); Text("正在定位…") } }
                }

                Section("搜索结果") {
                    if search.results.isEmpty {
                        Text(search.query.isEmpty
                             ? "输入地名开始搜"
                             : (search.errorText.isEmpty ? "搜不到，换个关键词试试" : search.errorText))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(search.results, id: \.self) { item in
                        Button {
                            select(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.body)
                                if item.subtitle.isEmpty == false {
                                    Text(item.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("搜中国地名时建议带上市/区名，例如「潍坊 潍坊学院」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("搜地点")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func select(_ item: MKLocalSearchCompletion) {
        busy = true
        err = ""
        search.resolve(item) { c in
            DispatchQueue.main.async {
                busy = false
                if let c {
                    onPick(c)
                    dismiss()
                } else {
                    err = "这个结果没解析出坐标，换个关键词或直接用经纬度"
                }
            }
        }
    }
}
