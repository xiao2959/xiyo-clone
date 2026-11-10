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
    ///
    /// ⚠️ 之前用 title+", "+subtitle 拼成自然语言查询，会把结果带偏
    ///    （例如搜"潍坊学院"却落到别的区）。
    ///    改用 MKLocalSearch.Request(completion:) —— 苹果官方的"补全→精确定位"接口，
    ///    拿到的是这一条补全对应的坐标，不会串。
    func resolve(_ c: MKLocalSearchCompletion, done: @escaping (CLLocationCoordinate2D?) -> Void) {
        let req: MKLocalSearch.Request
        if #available(iOS 17.0, *) {
            // iOS 17 起支持直接用补全构造 Request（本项目最低 17.0，恒走这里）
            req = MKLocalSearch.Request(completion: c)
        } else {
            req = MKLocalSearch.Request()
            req.naturalLanguageQuery = c.title
        }
        // 用补全自带的 region 结果更稳，不强行指定全国大区
        MKLocalSearch(request: req).start { response, error in
            DispatchQueue.main.async {
                if let item = response?.mapItems.first {
                    done(item.placemark.coordinate)
                } else {
                    done(nil)
                }
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
