import Foundation
import SwiftUI
import Combine
import CoreLocation
import MapKit

/// 朝向来源：罗盘（手机指向）或移动方向（GPS 航迹）
enum HeadingSource {
    case compass
    case course
}

/// 全局状态机：定位 → 相机 → 路线 → 导航进度，全部收敛在这里
final class NavModel: ObservableObject {

    // MARK: - 定位数据

    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var accuracy: CLLocationAccuracy = -1
    @Published var speed: CLLocationSpeed = -1
    @Published var altitude: CLLocationDistance = 0
    @Published var course: CLLocationDirection = -1
    @Published var heading: CLLocationDirection = -1
    @Published var updatedAt: Date?
    @Published var errorMessage: String?

    // MARK: - 相机

    @Published var following = true
    @Published var cameraHeading: CLLocationDirection = 0
    @Published var zoomDistance: CLLocationDistance = 900
    @Published var pitch: CGFloat = 40
    @Published var headingSource: HeadingSource = .compass
    /// 请求地图缩放到整条路线（MapCanvas 监听该计数）
    @Published var fitRequest = 0

    // MARK: - 路线

    @Published var startCoordinate: CLLocationCoordinate2D?
    @Published var endCoordinate: CLLocationCoordinate2D?
    @Published var startName: String = "我的位置"
    @Published var endName: String = ""
    @Published var options: [RouteOption] = []
    @Published var selectedIndex = 0
    @Published var planning = false
    @Published var routeError: String?
    /// 路线变化计数，MapCanvas 据此重建 overlay
    @Published var routeRevision = 0

    // MARK: - 导航

    @Published var navigating = false
    @Published var stepIndex = 0
    @Published var stepRemaining: CLLocationDistance = 0
    @Published var remainingDistance: CLLocationDistance = 0
    @Published var remainingTime: TimeInterval = 0
    @Published var arrived = false

    // MARK: - 轨迹

    @Published var trail: [CLLocationCoordinate2D] = []

    // MARK: - 内部

    let locator = LocationEngine()
    private let router = RouteEngine()
    private let geocoder = CLGeocoder()

    private var lastTrailCoordinate: CLLocationCoordinate2D?
    private var lastTrailTime = Date.distantPast
    private var smoothedHeading: Double = 0
    private var smoothInitialized = false
    private var lastHeadingPublish = Date.distantPast
    private var planWorkItem: DispatchWorkItem?

    var selectedOption: RouteOption? {
        options.indices.contains(selectedIndex) ? options[selectedIndex] : nil
    }

    var currentStep: RouteStep? {
        guard let option = selectedOption, option.steps.indices.contains(stepIndex) else { return nil }
        return option.steps[stepIndex]
    }

    // MARK: - 生命周期

    init() {
        locator.onLocation = { [weak self] location in
            self?.consume(location)
        }
        locator.onHeading = { [weak self] degrees in
            self?.consumeHeading(degrees)
        }
        locator.onAuthorization = { [weak self] status in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.authorization = status
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    self.locator.start()
                    self.startName = "我的位置"
                }
            }
        }
        locator.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.errorMessage = message }
        }
        authorization = locator.authorization
    }

    func requestPermission() {
        locator.requestAuthorization()
        locator.start()
    }

    // MARK: - 位置消费

    private func consume(_ location: CLLocation) {
        DispatchQueue.main.async {
            self.coordinate = location.coordinate
            self.accuracy = location.horizontalAccuracy
            self.speed = location.speed
            self.altitude = location.altitude
            self.course = location.course
            self.updatedAt = location.timestamp

            self.appendTrail(location.coordinate)
            self.refreshCameraHeading(location)
            if self.navigating { self.tickNavigation(location) }
        }
    }

    /// 罗盘只更新读数：相机角度统一在位置回调里推进，
    /// 避免 10Hz 的罗盘抖动把相机动画反复打断。
    /// 读数本身也做 5Hz 节流，减少 SwiftUI 全量重绘。
    private func consumeHeading(_ degrees: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastHeadingPublish) > 0.2 else { return }
        lastHeadingPublish = now
        DispatchQueue.main.async {
            self.heading = degrees
        }
    }

    private func refreshCameraHeading(_ location: CLLocation) {
        guard following else { return }

        let target: Double
        switch headingSource {
        case .compass:
            if heading >= 0 {
                target = heading
            } else if location.course >= 0 {
                target = location.course
            } else {
                target = smoothedHeading
            }
        case .course:
            if location.course >= 0 && location.speed > 0.8 {
                target = location.course
            } else if heading >= 0 {
                target = heading
            } else {
                target = smoothedHeading
            }
        }

        applyHeadingTarget(target)
    }

    private func applyHeadingTarget(_ target: Double) {
        if !smoothInitialized {
            smoothedHeading = target
            smoothInitialized = true
        } else {
            smoothedHeading = Geo.lerpAngle(smoothedHeading, target, factor: 0.60)
        }
        cameraHeading = smoothedHeading
    }

    // MARK: - 轨迹

    private func appendTrail(_ coord: CLLocationCoordinate2D) {
        guard let last = lastTrailCoordinate else {
            lastTrailCoordinate = coord
            lastTrailTime = Date()
            trail = [coord]
            return
        }
        let moved = Geo.distance(last, coord)
        let elapsed = Date().timeIntervalSince(lastTrailTime)
        guard moved >= 8 || elapsed >= 12 else { return }

        lastTrailCoordinate = coord
        lastTrailTime = Date()
        trail.append(coord)
        if trail.count > 4000 {
            trail.removeFirst(trail.count - 4000)
        }
    }

    func clearTrail() {
        trail.removeAll()
        lastTrailCoordinate = nil
    }

    // MARK: - 相机指令

    func resetView() {
        following = true
        headingSource = .compass
        zoomDistance = 900
        pitch = 40
        smoothInitialized = false
    }

    func centerOnUser() {
        following = true
        if !navigating {
            zoomDistance = 700
            pitch = 40
        }
    }

    func rotate(by delta: Double) {
        following = false
        cameraHeading = (cameraHeading + delta).truncatingRemainder(dividingBy: 360)
    }

    func fitRoute() {
        fitRequest += 1
    }

    // MARK: - 路线规划

    func setDestination(_ coordinate: CLLocationCoordinate2D, name: String? = nil) {
        endCoordinate = coordinate
        endName = name ?? String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
        schedulePlan()
        reverseGeocode(coordinate)
    }

    func setStart(_ coordinate: CLLocationCoordinate2D, name: String) {
        startCoordinate = coordinate
        startName = name
        schedulePlan()
    }

    func useCurrentAsStart() {
        startCoordinate = nil
        startName = "我的位置"
        schedulePlan()
    }

    func clearDestination() {
        planWorkItem?.cancel()
        endCoordinate = nil
        endName = ""
        options = []
        routeRevision += 1
        routeError = nil
        navigating = false
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        geocoder.cancelGeocode()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { [weak self] places, _ in
            guard let self = self, let place = places?.first else { return }
            DispatchQueue.main.async {
                let parts = [place.name, place.thoroughfare, place.subLocality, place.locality]
                if let name = parts.compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                    self.endName = name
                }
            }
        }
    }

    func schedulePlan(delay: TimeInterval = 0.45) {
        planWorkItem?.cancel()
        guard endCoordinate != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.planRoute() }
        planWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func planRoute() {
        guard let destination = endCoordinate else {
            routeError = "请先选择终点"
            return
        }
        guard let origin = startCoordinate ?? coordinate else {
            routeError = RouteError.noLocation.localizedDescription
            return
        }

        planning = true
        routeError = nil
        router.plan(from: origin, to: destination) { [weak self] result in
            guard let self = self else { return }
            self.planning = false
            switch result {
            case .success(let options):
                self.options = options
                self.selectedIndex = 0
                self.stepIndex = 0
                self.routeRevision += 1
                // 规划完先看全程；点「回到位置」再恢复跟随
                if self.navigating == false {
                    self.following = false
                }
                self.fitRoute()
            case .failure(let error):
                self.options = []
                self.routeRevision += 1
                self.routeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func select(route index: Int) {
        guard options.indices.contains(index) else { return }
        selectedIndex = index
        stepIndex = 0
        routeRevision += 1
        if navigating, let coord = coordinate, let option = selectedOption {
            remainingDistance = option.remainingLength(from: coord)
        }
    }

    // MARK: - 导航

    func startNavigation() {
        guard selectedOption != nil else { return }
        navigating = true
        arrived = false
        following = true
        headingSource = .compass
        zoomDistance = 420
        pitch = 55
        stepIndex = 0
        if let coord = coordinate, let option = selectedOption {
            remainingDistance = option.remainingLength(from: coord)
            remainingTime = option.expectedTravelTime
            stepRemaining = option.distanceToStepEnd(from: coord, stepIndex: 0)
        }
        locator.start()
    }

    func stopNavigation() {
        navigating = false
        arrived = false
        following = true
        headingSource = .compass
        zoomDistance = 1100
        pitch = 35
    }

    private func tickNavigation(_ location: CLLocation) {
        guard let option = selectedOption else { return }

        let index = option.advancedStepIndex(from: stepIndex, coordinate: location.coordinate)
        stepIndex = index
        stepRemaining = option.distanceToStepEnd(from: location.coordinate, stepIndex: index)
        remainingDistance = option.remainingLength(from: location.coordinate)

        if option.distance > 0 {
            let ratio = min(max(remainingDistance / option.distance, 0), 1.2)
            remainingTime = option.expectedTravelTime * ratio
        }

        if remainingDistance < 25 {
            navigating = false
            arrived = true
            zoomDistance = 950
            pitch = 35
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.arrived = false
            }
        }
    }
}
