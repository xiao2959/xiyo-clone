//
//  MapState.swift
//  地图视野持久化 —— 这是「地图来回跳」的真正修复
//
//  根因：初始视野写死在 makeUIView 里。SwiftUI 只要重建 NativeMapView
//        （弹窗关闭、状态变化、List 刷新都可能触发），就会重跑 makeUIView，
//        视野被拉回初始点 → 用户看到"跳"。
//
//  修复：视野存在这个对象里（比 View 活得久），
//        makeUIView 时从它恢复，regionDidChange 时写回它。
//        这样无论 View 被重建多少次，地图都停在用户离开时的位置。
//

import Foundation
import MapKit

final class MapState: ObservableObject {

    /// 当前视野中心（nil = 还没动过，用默认值）
    private(set) var center: CLLocationCoordinate2D?
    /// 当前缩放
    private(set) var span: MKCoordinateSpan = MKCoordinateSpan(
        latitudeDelta: 0.02, longitudeDelta: 0.02)

    /// 一次性跳转请求（搜索/输经纬度/回当前位置时设置）
    /// NativeMapView 消费后置 nil，避免重复跳
    var pendingJump: CLLocationCoordinate2D?

    /// 已消费的跳转，用于去重
    private(set) var lastJump: CLLocationCoordinate2D?

    /// 默认视野（潍坊）
    static let fallback = CLLocationCoordinate2D(latitude: 36.7069, longitude: 119.1618)

    /// 地图自己报告视野变化时调用（用户拖动/缩放后）
    func record(center c: CLLocationCoordinate2D, span s: MKCoordinateSpan) {
        center = c
        span = s
    }

    /// 请求跳到某点
    func requestJump(to c: CLLocationCoordinate2D) {
        pendingJump = c
    }

    /// 取出待处理跳转（取一次就清空）
    func takeJump() -> CLLocationCoordinate2D? {
        guard let c = pendingJump else { return nil }
        pendingJump = nil
        lastJump = c
        return c
    }

    /// 恢复用的中心点：优先用户最后的视野
    func restoreCenter() -> CLLocationCoordinate2D {
        return center ?? MapState.fallback
    }

    func restoreSpan() -> MKCoordinateSpan {
        return span
    }
}
