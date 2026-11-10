//
//  NativeMapView.swift
//  原生 MKMapView + 视野持久化
//
//  关键修复（对比上一版）：
//    旧：makeUIView 里写死初始 region → View 一重建就跳回原点
//    新：视野从 MapState 恢复，用户拖动写回 MapState，
//        只有"主动跳转"才 setRegion。这样重建多少次都不跳。
//
//  交互对齐官方版：长按选点（官方 24 处 LongPress），单击也保留。
//

import SwiftUI
import MapKit

struct NativeMapView: UIViewRepresentable {
    @ObservedObject var state: MapState
    let picked: CLLocationCoordinate2D?
    let onPick: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, onPick: onPick)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isZoomEnabled = true
        map.isScrollEnabled = true

        // ★ 从 state 恢复视野（不是写死初始值）
        let center = state.restoreCenter()
        let span = state.restoreSpan()
        map.setRegion(MKCoordinateRegion(center: center, span: span), animated: false)
        context.coordinator.lastAppliedCenter = center

        // 长按选点（官方方式）
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 10
        map.addGestureRecognizer(longPress)

        // 单击也接，但让位给长按
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.require(toFail: longPress)
        map.addGestureRecognizer(tap)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onPick = onPick

        // 只有"请求跳转"才动地图，且只动一次
        if let target = state.takeJump() {
            context.coordinator.lastAppliedCenter = target
            map.setRegion(MKCoordinateRegion(
                center: target,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)),
                animated: true)
        }

        // pin 更新（不碰视野）
        context.coordinator.syncAnnotation(on: map, to: picked)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        let state: MapState
        var onPick: (CLLocationCoordinate2D) -> Void
        var lastAppliedCenter: CLLocationCoordinate2D?
        var annotation: MKPointAnnotation?
        /// 抑制标记：setRegion 触发的 regionDidChange 不要写回 state
        var suppressRecord = false

        init(state: MapState, onPick: @escaping (CLLocationCoordinate2D) -> Void) {
            self.state = state
            self.onPick = onPick
        }

        // 用户拖动/缩放后记录视野
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard suppressRecord == false else { return }
            state.record(center: mapView.region.center, span: mapView.region.span)
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard let map = g.view as? MKMapView, g.state == .began else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            onPick(coord)
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView, g.state == .ended else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            onPick(coord)
        }

        func syncAnnotation(on map: MKMapView, to coord: CLLocationCoordinate2D?) {
            guard let c = coord else {
                if let a = annotation { map.removeAnnotation(a); annotation = nil }
                return
            }
            if let a = annotation {
                // 只在真的变了才动，避免抖动
                if abs(a.coordinate.latitude - c.latitude) > 1e-9
                    || abs(a.coordinate.longitude - c.longitude) > 1e-9 {
                    a.coordinate = c
                }
            } else {
                let a = MKPointAnnotation()
                a.coordinate = c
                a.title = "目标"
                map.addAnnotation(a)
                annotation = a
            }
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
                m.animatesWhenAdded = false
            }
            return v
        }
    }
}
