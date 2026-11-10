//
//  LocationSearch.swift
//  地点搜索（MKLocalSearchCompleter）+ 手动输入经纬度
//
//  为什么需要：地图能点选，但要找别的城市/地点只能靠手拖，很难找。
//  这个模块提供"搜地名 → 跳过去 → 自动放 pin"的能力。
//

import Foundation
import MapKit

// MARK: - 搜索模型

final class SearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {

    @Published var query: String = "" {
        didSet { completer.queryFragment = query }
    }
    @Published var results: [MKLocalSearchCompletion] = []
    @Published var errorText: String = ""

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // 地址 + POI + 通用查询都收，国内搜"XX学校/XX路"才出得来
        completer.resultTypes = [.address, .pointOfInterest, .query]
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.0, longitude: 108.0),
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40))
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = Array(completer.results.prefix(12))
        DispatchQueue.main.async {
            self.results = r
            self.errorText = ""
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.errorText = "搜索失败：" + error.localizedDescription
        }
    }

    /// 把搜索建议解析成真实坐标
    func resolve(_ c: MKLocalSearchCompletion, done: @escaping (CLLocationCoordinate2D?) -> Void) {
        let req = MKLocalSearch.Request()
        // 用自然语言查询，兼容所有 iOS 版本；带上 subtitle 提高命中率
        req.naturalLanguageQuery = c.subtitle.isEmpty ? c.title : (c.title + ", " + c.subtitle)
        req.region = completer.region
        MKLocalSearch(request: req).start { response, _ in
            DispatchQueue.main.async {
                done(response?.mapItems.first?.placemark.coordinate)
            }
        }
    }
}

// MARK: - 纯函数：解析 "36.7, 119.1" 这种输入（可单测）

enum CoordInput {
    /// 支持 "lat,lon" / "lat lon" / 中文逗号 / 全角逗号
    static func parse(_ s: String) -> CLLocationCoordinate2D? {
        let t = s
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
        let parts = t.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard parts.count >= 2,
              let la = Double(parts[0]),
              let lo = Double(parts[1]),
              la >= -90, la <= 90, lo >= -180, lo <= 180 else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }
}
