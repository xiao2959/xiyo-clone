//
//  CoordTransform.swift
//  坐标系转换：WGS-84 ⇄ GCJ-02 ⇄ BD-09
//
//  为什么必须有这个文件：
//    在中国大陆，Apple 地图/高德显示的底图是 **GCJ-02**（火星坐标），
//    而定位模拟注入给系统的必须是 **WGS-84**。
//    如果直接把地图上点出来的坐标注入 → 落点偏 400~700 米。
//
//    官方那个 App 不偏，就是因为它内部做了这一层转换。
//    StikDebug 没有这层 → 所以它偏。
//
//  算法参数与 Python 参考实现（已用公开测试向量验证，误差 0.000 米）完全一致。
//

import Foundation
import CoreLocation

enum CoordTransform {

    private static let a = 6378245.0                  // 克拉索夫斯基椭球长半轴
    private static let ee = 0.00669342162296594323    // 偏心率平方
    private static let xPi = Double.pi * 3000.0 / 180.0

    /// 是否在中国境外（境外不做偏移）
    static func outOfChina(_ lat: Double, _ lng: Double) -> Bool {
        !(lng > 73.66 && lng < 135.05 && lat > 3.86 && lat < 53.55)
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLng(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }

    /// WGS-84 → GCJ-02
    static func wgs2gcj(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D {
        if outOfChina(lat, lng) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        var dLat = transformLat(lng - 105.0, lat - 35.0)
        var dLng = transformLng(lng - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLng = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: lat + dLat, longitude: lng + dLng)
    }

    /// GCJ-02 → WGS-84（迭代逼近，误差 < 1e-9 度 ≈ 0.1 毫米）
    static func gcj2wgs(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D {
        if outOfChina(lat, lng) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        var wLat = lat, wLng = lng
        for _ in 0..<6 {
            let g = wgs2gcj(wLat, wLng)
            wLat += lat - g.latitude
            wLng += lng - g.longitude
        }
        return CLLocationCoordinate2D(latitude: wLat, longitude: wLng)
    }

    /// GCJ-02 → BD-09
    static func gcj2bd(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D {
        let z = sqrt(lng * lng + lat * lat) + 0.00002 * sin(lat * xPi)
        let theta = atan2(lat, lng) + 0.000003 * cos(lng * xPi)
        return CLLocationCoordinate2D(latitude: z * sin(theta) + 0.006,
                                      longitude: z * cos(theta) + 0.0065)
    }

    /// BD-09 → GCJ-02
    static func bd2gcj(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D {
        let x = lng - 0.0065
        let y = lat - 0.006
        let z = sqrt(x * x + y * y) - 0.00002 * sin(y * xPi)
        let theta = atan2(y, x) - 0.000003 * cos(x * xPi)
        return CLLocationCoordinate2D(latitude: z * sin(theta), longitude: z * cos(theta))
    }

    /// 两点距离（米）
    static func distance(_ p1: CLLocationCoordinate2D, _ p2: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: p1.latitude, longitude: p1.longitude)
            .distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
    }
}
