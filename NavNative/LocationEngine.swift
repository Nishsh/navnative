import Foundation
import CoreLocation
import UIKit

/// 定位采集器（v2）：CoreLocation 原始流 → LocationFuser → 稳定位置。
///
/// 只通过回调把数据抛给 NavModel，自身不持有 UI 状态。
final class LocationEngine: NSObject, CLLocationManagerDelegate {

    /// 融合后的位置
    var onFix: ((FusedFix) -> Void)?
    /// 罗盘更新：(角度, 精度)
    var onHeading: ((CLLocationDirection, CLLocationDirection) -> Void)?
    /// 权限变化
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    /// 采集错误（文案）
    var onFailure: ((String) -> Void)?

    private let manager = CLLocationManager()
    private let fuser = LocationFuser()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var running = false

    /// 被融合器丢弃的原始点数（诊断用）
    var rejectedCount: Int { fuser.rejectedCount }
    /// 被接受的点数
    var acceptedCount: Int { fuser.acceptedCount }
    /// 最近一次丢弃原因
    var lastRejectReason: String? { fuser.lastRejectReason }
    /// 是否允许后台定位（需要 Info.plist 的 location 后台模式）
    var backgroundEnabled = true
    /// 是否开启坐标偏移校正（默认关闭，系统已对齐底图）
    var coordinateCorrection = false

    private var lastHeadingPublish = Date.distantPast
    private var activity: CLActivityType = .otherNavigation

    override init() {
        super.init()
        manager.delegate = self
        // 精度：Best 已足够；BestForNavigation 会持续开传感器，静止时反而更抖、更耗电
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // 过滤阈值从 1m 提到 3m：1m 会把静止抖动全部放进来
        manager.distanceFilter = 3
        manager.headingFilter = 3
        manager.headingOrientation = .portrait
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = activity
        if #available(iOS 14.0, *) {
            manager.showsBackgroundLocationIndicator = true
        }
        authorization = manager.authorizationStatus

        fuser.onFix = { [weak self] fix in
            guard let self = self else { return }
            if self.coordinateCorrection {
                var corrected = fix
                corrected.coordinate = CoordinateFix.wgs2gcj(fix.coordinate)
                corrected.rawCoordinate = CoordinateFix.wgs2gcj(fix.rawCoordinate)
                self.onFix?(corrected)
            } else {
                self.onFix?(fix)
            }
        }
    }

    // MARK: - 控制

    func requestAuthorization() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func setActivity(_ type: CLActivityType) {
        activity = type
        manager.activityType = type
        // 步行/骑行时降低滤波强度，automotive 会把慢速移动吃掉
        manager.desiredAccuracy = type == .automotiveNavigation ? kCLLocationAccuracyBest : kCLLocationAccuracyBest
    }

    func start() {
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.pausesLocationUpdatesAutomatically = false
            // 后台：whenInUse 也可用，但必须在 Info.plist 声明 location 后台模式
            if backgroundEnabled && supportsBackground {
                manager.allowsBackgroundLocationUpdates = true
            }
            if !running {
                fuser.reset()
            }
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
            running = true
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        running = false
    }

    /// 省电：静止且不在导航时切到低功耗采样
    func setLowPower(_ low: Bool) {
        manager.desiredAccuracy = low ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
        manager.distanceFilter = low ? 10 : 3
    }

    /// 强制触发一次高精度定位（用于「回到我的位置」时刷新）
    func requestOneShot() {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        manager.requestLocation()
    }

    private var supportsBackground: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("location")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        onAuthorization?(authorization)

        switch authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
            running = true
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            running = false
            onFailure?("定位权限被拒绝，请到 设置 → 隐私与安全性 → 定位服务 中允许「私人导航 Pro」")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 一次性可能给多个点，按时间顺序全部喂给融合器，观察者只拿最后一次结果
        for location in locations {
            fuser.ingest(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let now = Date()
        guard now.timeIntervalSince(lastHeadingPublish) > 0.15 else { return }
        lastHeadingPublish = now

        guard newHeading.headingAccuracy >= 0 else { return }
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard degrees >= 0 else { return }
        onHeading?(degrees, newHeading.headingAccuracy)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let clError = error as? CLError else {
            onFailure?(error.localizedDescription)
            return
        }
        switch clError.code {
        case .denied:
            onFailure?("定位权限被拒绝")
        case .locationUnknown:
            // 瞬时失败，忽略，等下一次
            break
        default:
            onFailure?(clError.localizedDescription)
        }
    }
}
