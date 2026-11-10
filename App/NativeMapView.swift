//
//  NativeMapView.swift
//  用原生 MKMapView 替代 SwiftUI Map，解决"位置来回跳"
//
//  为什么换：
//    SwiftUI 的 Map(position: $camera) 是双向绑定。用户一拖地图，
//    MapKit 就回写 camera；代码里同时用 .region(...) 设置 → 互相覆盖 → 视觉跳动。
//
//  原生 MKMapView 的做法：
//    - 只有**主动跳转**（搜索/输入经纬度/回当前位置）才 setRegion
//    - 用户拖动不会写回 SwiftUI state，所以不会触发 updateUIView 里的 setRegion
//    - 点选用 UITapGestureRecognizer + convert，稳定且精确
//

import SwiftUI
import MapKit

struct NativeMapView: UIViewRepresentable {
    /// 主动跳转目标。只有它变化时才 setRegion（且做去重）
    let center: CLLocationCoordinate2D?
    /// 当前选中的点（红色 pin）
    let picked: CLLocationCoordinate2D?
    /// 点地图回调
    let onPick: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false   // 不显示蓝点，避免模拟定位后跟着抖
        map.isRotateEnabled = false
        map.isPitchEnabled = false

        // 初始视野：潍坊
        let initial = CLLocationCoordinate2D(latitude: 36.7069, longitude: 119.1618)
        map.setRegion(MKCoordinateRegion(
            center: initial,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)),
            animated: false)
        context.coordinator.lastCenter = initial

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // struct 会被重建，闭包要同步给常驻的 Coordinator
        context.coordinator.onPick = onPick

        // 只有主动跳转且与上次不同才动地图 —— 这是"不跳"的关键
        if let c = center, context.coordinator.shouldMove(to: c) {
            context.coordinator.lastCenter = c
            map.setRegion(MKCoordinateRegion(
                center: c,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)),
                animated: true)
        }

        // 更新红色 pin
        if let p = picked {
            if let ann = context.coordinator.annotation {
                ann.coordinate = p
            } else {
                let a = MKPointAnnotation()
                a.coordinate = p
                a.title = "目标"
                map.addAnnotation(a)
                context.coordinator.annotation = a
            }
        } else if let ann = context.coordinator.annotation {
            map.removeAnnotation(ann)
            context.coordinator.annotation = nil
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onPick: (CLLocationCoordinate2D) -> Void
        var lastCenter: CLLocationCoordinate2D?
        var annotation: MKPointAnnotation?

        init(onPick: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onPick = onPick
        }

        /// 阈值去重：坐标没实质变化就不 setRegion
        func shouldMove(to c: CLLocationCoordinate2D) -> Bool {
            guard let l = lastCenter else { return true }
            return abs(l.latitude - c.latitude) > 0.000001
                || abs(l.longitude - c.longitude) > 0.000001
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            let point = g.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            onPick(coord)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let id = "target"
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            v.annotation = annotation
            if let m = v as? MKMarkerAnnotationView {
                m.markerTintColor = .systemRed
                m.glyphText = "目标"
            }
            return v
        }
    }
}
