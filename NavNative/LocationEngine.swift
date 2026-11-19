import Foundation
import CoreLocation

/// CoreLocation 采集器：位置 / 罗盘 / 速度 / 海拔。
///
/// 只用回调把数据抛给 NavModel，自身不持有 UI 状态，
/// 避免 SwiftUI 嵌套 ObservableObject 不转发 objectWillChange 的坑。
final class LocationEngine: NSObject, CLLocationManagerDelegate {

    /// 位置更新（约 1Hz）
    var onLocation: ((CLLocation) -> Void)?
    /// 罗盘更新，参数为「真北优先、退回磁北」的角度
    var onHeading: ((CLLocationDirection) -> Void)?
    /// 权限变化
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    /// 采集错误（文案）
    var onFailure: ((String) -> Void)?

    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var running = false

    override init() {
        super.init()
        manager.delegate = self
        // 导航级精度：车速与航向才够准
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 1
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
        authorization = manager.authorizationStatus
    }

    // MARK: - 控制

    func requestAuthorization() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
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
            onFailure?("定位权限被拒绝，请到 设置 → 隐私与安全性 → 定位服务 中允许「私人导航」")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 过滤掉明显失效的缓存点
        guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
        onLocation?(latest)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard degrees >= 0 else { return }
        onHeading?(degrees)
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
