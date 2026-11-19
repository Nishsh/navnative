import Foundation
import SwiftUI
import Combine
import CoreLocation
import MapKit
import UIKit

/// 朝向来源
enum HeadingSource: String, CaseIterable, Identifiable {
    case auto
    case compass
    case course

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .compass: return "罗盘"
        case .course: return "行进方向"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .compass: return "safari.fill"
        case .course: return "location.north.line.fill"
        }
    }
}

/// 途经点（v5）
struct Waypoint: Identifiable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
    var name: String
}

/// 全局状态机：定位 → 相机 → 路线 → 导航进度，全部收敛在这里
final class NavModel: ObservableObject {

    // MARK: - 依赖

    let settings = SettingsStore.shared
    let voice = VoiceGuidance()
    let safety = SafetyMonitor()
    private let locator = LocationEngine()
    private let router = RouteEngine()
    private let geocoder = CLGeocoder()
    private let tripRecorder = TripRecorder()
    private let tripStore = TripStore.shared
    let favorites = FavoritesStore.shared

    // MARK: - 定位数据

    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var rawCoordinate: CLLocationCoordinate2D?
    @Published var accuracy: CLLocationAccuracy = -1
    @Published var quality: FixQuality = .unknown
    @Published var speed: CLLocationSpeed = -1
    @Published var altitude: CLLocationDistance = 0
    @Published var course: CLLocationDirection = -1
    @Published var heading: CLLocationDirection = -1
    @Published var headingAccuracy: CLLocationDirection = -1
    @Published var updatedAt: Date?
    @Published var isStationary = false
    @Published var filteredCount = 0
    @Published var errorMessage: String?

    // MARK: - 相机

    @Published var following = true
    @Published var cameraHeading: CLLocationDirection = 0
    @Published var zoomDistance: CLLocationDistance = 900
    @Published var pitch: CGFloat = 40
    @Published var headingSource: HeadingSource = .auto
    /// 请求地图缩放到整条路线（MapCanvas 监听该计数）
    @Published var fitRequest = 0
    /// 3D 倾斜开关（跟随设置）
    @Published var tiltEnabled = true

    // MARK: - 路线

    @Published var startCoordinate: CLLocationCoordinate2D?
    @Published var endCoordinate: CLLocationCoordinate2D?
    @Published var startName: String = "我的位置"
    @Published var endName: String = ""
    @Published var waypoints: [Waypoint] = []
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
    @Published var arrivedName = ""
    @Published var offRoute = false
    @Published var nextInstruction: String = ""

    // MARK: - 语音字幕 / 安全

    @Published var voiceCaption: String = ""
    @Published var speedAlert = false
    @Published var overspeedAmount: Double = 0
    @Published var safetyScore: Double = 100

    // MARK: - 行程

    @Published var tripActive = false
    @Published var tripDistance: Double = 0
    @Published var tripMaxSpeed: Double = 0
    @Published var tripElapsed: TimeInterval = 0

    // MARK: - 轨迹

    @Published var trail: [CLLocationCoordinate2D] = []

    // MARK: - 内部

    private var lastTrailCoordinate: CLLocationCoordinate2D?
    private var lastTrailTime = Date.distantPast
    private var smoothedHeading: Double = 0
    private var smoothInitialized = false
    private var lastHeadingPublish = Date.distantPast
    private var planWorkItem: DispatchWorkItem?
    private var announcedThresholds: Set<String> = []
    private var lastRerouteAt: Date?
    private var offRouteSince: Date?
    private var lastTripRefresh = Date.distantPast

    var selectedOption: RouteOption? {
        options.indices.contains(selectedIndex) ? options[selectedIndex] : nil
    }

    var currentStep: RouteStep? {
        guard let option = selectedOption, option.steps.indices.contains(stepIndex) else { return nil }
        return option.steps[stepIndex]
    }

    var nextStep: RouteStep? {
        guard let option = selectedOption, option.steps.indices.contains(stepIndex + 1) else { return nil }
        return option.steps[stepIndex + 1]
    }

    var hasRoute: Bool { !options.isEmpty }

    var destinationLabel: String {
        if !waypoints.isEmpty {
            return "\(endName)（\(waypoints.count) 途经点）"
        }
        return endName
    }

    // MARK: - 生命周期

    init() {
        locator.backgroundEnabled = settings.backgroundLocation
        locator.coordinateCorrection = settings.coordinateCorrection
        locator.setActivity(settings.travelMode.activity)

        locator.onFix = { [weak self] fix in
            self?.consume(fix)
        }
        locator.onHeading = { [weak self] degrees, accuracy in
            self?.consumeHeading(degrees, accuracy: accuracy)
        }
        locator.onAuthorization = { [weak self] status in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.authorization = status
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    self.locator.start()
                    if self.startCoordinate == nil {
                        self.startName = "我的位置"
                    }
                }
            }
        }
        locator.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.errorMessage = message }
        }

        authorization = locator.authorization
        tiltEnabled = settings.mapPitchEnabled
        pitch = settings.mapPitchEnabled ? 40 : 0
        voiceCaption = voice.lastText
    }

    func requestPermission() {
        locator.requestAuthorization()
        locator.start()
    }

    /// 设置变化后同步到各子系统（v9）
    func applySettingsChanges() {
        locator.backgroundEnabled = settings.backgroundLocation
        locator.coordinateCorrection = settings.coordinateCorrection
        locator.setActivity(settings.travelMode.activity)
        tiltEnabled = settings.mapPitchEnabled
        if !navigating {
            pitch = settings.mapPitchEnabled ? 40 : 0
            zoomDistance = 900
        } else {
            pitch = settings.mapPitchEnabled ? 55 : 0
        }
        if hasRoute {
            schedulePlan(delay: 0.3)
        }
        updateIdleTimer()
    }

    // MARK: - 位置消费

    private func consume(_ fix: FusedFix) {
        DispatchQueue.main.async {
            self.coordinate = fix.coordinate
            self.rawCoordinate = fix.rawCoordinate
            self.accuracy = fix.horizontalAccuracy
            self.quality = fix.quality
            self.speed = fix.speed
            self.altitude = fix.altitude
            self.course = fix.course
            self.updatedAt = fix.timestamp
            self.isStationary = fix.isStationary
            self.filteredCount = self.locator.rejectedCount

            if self.settings.showTrail {
                self.appendTrail(fix)
            }
            self.refreshCameraHeading(fix)
            self.refreshZoom(fix)

            if self.navigating {
                self.tickNavigation(fix)
            }
            if self.tripActive {
                self.tripRecorder.ingest(fix)
                self.refreshTripSnapshot(force: false)
            }
        }
    }

    private func consumeHeading(_ degrees: Double, accuracy: CLLocationDirection) {
        let now = Date()
        guard now.timeIntervalSince(lastHeadingPublish) > 0.2 else { return }
        lastHeadingPublish = now
        DispatchQueue.main.async {
            self.heading = degrees
            self.headingAccuracy = accuracy
        }
    }

    private func refreshCameraHeading(_ fix: FusedFix) {
        guard following else { return }

        let compassOK = heading >= 0 && headingAccuracy >= 0 && headingAccuracy < 35
        let courseOK = fix.course >= 0 && fix.speed > 1.2

        let target: Double
        switch headingSource {
        case .compass:
            target = compassOK ? heading : (courseOK ? fix.course : smoothedHeading)
        case .course:
            target = courseOK ? fix.course : (compassOK ? heading : smoothedHeading)
        case .auto:
            // 行驶中优先用航迹（手机在支架上朝向未必与车头一致），慢速/静止用罗盘
            if fix.speed > 3.0, fix.course >= 0 {
                target = fix.course
            } else if compassOK {
                target = heading
            } else if fix.course >= 0 {
                target = fix.course
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
            // 0.35 比原来更稳，避免每个定位点都小幅摆一次相机
            smoothedHeading = Geo.lerpAngle(smoothedHeading, target, factor: 0.35)
        }
        cameraHeading = smoothedHeading
    }

    /// 导航中按车速自适应缩放（v10）
    private func refreshZoom(_ fix: FusedFix) {
        guard following else { return }
        let target: Double
        if navigating {
            if fix.speed > 30 { target = 1100 }
            else if fix.speed > 18 { target = 750 }
            else if fix.speed > 8 { target = 520 }
            else { target = 420 }
        } else {
            return
        }
        zoomDistance = zoomDistance + (target - zoomDistance) * 0.12
    }

    // MARK: - 轨迹

    private func appendTrail(_ fix: FusedFix) {
        guard let last = lastTrailCoordinate else {
            lastTrailCoordinate = fix.coordinate
            lastTrailTime = Date()
            trail = [fix.coordinate]
            return
        }
        let moved = Geo.distance(last, fix.coordinate)
        let elapsed = Date().timeIntervalSince(lastTrailTime)
        guard moved >= 8 || elapsed >= 12 else { return }

        lastTrailCoordinate = fix.coordinate
        lastTrailTime = Date()
        trail.append(fix.coordinate)
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
        headingSource = .auto
        zoomDistance = navigating ? 460 : 900
        pitch = settings.mapPitchEnabled ? (navigating ? 55 : 40) : 0
        smoothInitialized = false
    }

    func centerOnUser() {
        following = true
        smoothInitialized = false
        locator.requestOneShot()
        if !navigating {
            zoomDistance = 700
            pitch = settings.mapPitchEnabled ? 40 : 0
        }
    }

    func rotate(by delta: Double) {
        following = false
        cameraHeading = (cameraHeading + delta).truncatingRemainder(dividingBy: 360)
    }

    func fitRoute() {
        following = false
        fitRequest += 1
    }

    func setHeadingSource(_ source: HeadingSource) {
        headingSource = source
        smoothInitialized = false
    }

    // MARK: - 路线规划

    func setDestination(_ coordinate: CLLocationCoordinate2D, name: String? = nil) {
        endCoordinate = coordinate
        endName = name ?? String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
        schedulePlan()
        reverseGeocode(coordinate) { [weak self] resolved in
            guard let self = self else { return }
            if name == nil {
                self.endName = resolved
            }
        }
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
        router.cancel()
        endCoordinate = nil
        endName = ""
        waypoints.removeAll()
        options = []
        routeRevision += 1
        routeError = nil
        navigating = false
        announcedThresholds.removeAll()
    }

    /// 交换起终点
    func swapEndpoints() {
        guard let end = endCoordinate else { return }
        let oldStartCoordinate = startCoordinate ?? coordinate
        let oldStartName = startCoordinate == nil ? "我的位置" : startName
        startCoordinate = end
        startName = endName
        endCoordinate = oldStartCoordinate
        endName = oldStartName
        schedulePlan()
    }

    // MARK: - 途经点（v5）

    func addWaypoint(_ coordinate: CLLocationCoordinate2D, name: String) {
        guard waypoints.count < 8 else {
            routeError = "最多支持 8 个途经点"
            return
        }
        waypoints.append(Waypoint(coordinate: coordinate, name: name))
        schedulePlan()
    }

    func removeWaypoint(_ id: UUID) {
        waypoints.removeAll { $0.id == id }
        schedulePlan()
    }

    func clearWaypoints() {
        waypoints.removeAll()
        schedulePlan()
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D,
                                completion: @escaping (String) -> Void) {
        geocoder.cancelGeocode()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { places, _ in
            guard let place = places?.first else { return }
            let parts = [place.name, place.thoroughfare, place.subLocality, place.locality]
            let name = parts.compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "目的地"
            DispatchQueue.main.async { completion(name) }
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
        let prefs = RoutePreferences.fromSettings()

        router.plan(
            from: origin,
            to: destination,
            via: waypoints.map { $0.coordinate },
            preferences: prefs
        ) { [weak self] result in
            guard let self = self else { return }
            self.planning = false
            switch result {
            case .success(let options):
                self.options = options
                self.selectedIndex = 0
                self.stepIndex = 0
                self.routeRevision += 1
                self.announcedThresholds.removeAll()
                // 规划完先看全程；点「回到位置」再恢复跟随
                if !self.navigating {
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
        announcedThresholds.removeAll()
        if navigating, let coord = coordinate, let option = selectedOption {
            remainingDistance = option.remainingLength(from: coord)
        }
    }

    // MARK: - 收藏

    func saveCurrentAsFavorite(name: String? = nil) {
        guard let coordinate = coordinate else {
            errorMessage = "还没有定位结果"
            return
        }
        if let name = name, !name.isEmpty {
            favorites.add(name: name, coordinate: coordinate)
            return
        }
        reverseGeocode(coordinate) { [weak self] resolved in
            self?.favorites.add(name: resolved, coordinate: coordinate)
        }
    }

    // MARK: - 导航

    func startNavigation() {
        guard selectedOption != nil else { return }
        navigating = true
        arrived = false
        arrivedName = ""
        following = true
        headingSource = .auto
        smoothInitialized = false
        zoomDistance = 480
        pitch = settings.mapPitchEnabled ? 55 : 0
        stepIndex = 0
        announcedThresholds.removeAll()
        offRoute = false
        offRouteSince = nil

        if let coord = coordinate, let option = selectedOption {
            remainingDistance = option.remainingLength(from: coord)
            remainingTime = option.expectedTravelTime
            stepRemaining = option.distanceToStepEnd(from: coord, stepIndex: 0)
        }

        safety.reset()
        safetyScore = 100
        startTrip()

        voice.speak(
            "开始导航，全程 \(Fmt.distance(remainingDistance))，预计 \(Fmt.duration(remainingTime))",
            priority: .high,
            dedupWindow: 1
        )
        voiceCaption = voice.lastText
        updateIdleTimer()
        locator.start()
    }

    func stopNavigation() {
        navigating = false
        arrived = false
        following = true
        headingSource = .auto
        zoomDistance = 1100
        pitch = settings.mapPitchEnabled ? 35 : 0
        offRoute = false
        offRouteSince = nil
        finishTrip()
        voice.stop()
        updateIdleTimer()
    }

    private func tickNavigation(_ fix: FusedFix) {
        guard let option = selectedOption else { return }

        let index = option.advancedStepIndex(from: stepIndex, coordinate: fix.coordinate)
        if index != stepIndex {
            // 允许「跳格」但不回退：旧索引只增不减
            stepIndex = max(stepIndex, index)
        }
        stepRemaining = option.distanceToStepEnd(from: fix.coordinate, stepIndex: stepIndex)
        remainingDistance = option.remainingLength(from: fix.coordinate)
        nextInstruction = currentStep?.instruction ?? ""

        if option.distance > 0 {
            let ratio = min(max(remainingDistance / option.distance, 0), 1.2)
            remainingTime = option.expectedTravelTime * ratio
        }

        checkDeviation(fix, option: option)
        announceTurn(fix, option: option)
        checkSpeed(fix)

        if remainingDistance < 30 {
            finishArrival()
        }
    }

    /// 偏航检测与自动重算（v8）
    private func checkDeviation(_ fix: FusedFix, option: RouteOption) {
        let deviation = option.distanceToPolyline(from: fix.coordinate)
        offRoute = deviation > 55

        if offRoute {
            if offRouteSince == nil { offRouteSince = Date() }
            let sustained = offRouteSince.map { Date().timeIntervalSince($0) } ?? 0
            guard settings.autoReroute, sustained > 6 else { return }
            guard lastRerouteAt.map({ Date().timeIntervalSince($0) > 20 }) ?? true else { return }
            guard let destination = endCoordinate else { return }

            lastRerouteAt = Date()
            offRouteSince = nil
            voice.speak("已偏离路线，正在重新规划", priority: .high)
            voiceCaption = voice.lastText

            router.plan(
                from: fix.coordinate,
                to: destination,
                via: [],
                preferences: RoutePreferences.fromSettings()
            ) { [weak self] result in
                guard let self = self else { return }
                if case .success(let options) = result, let first = options.first {
                    self.options = [first]
                    self.selectedIndex = 0
                    self.stepIndex = 0
                    self.routeRevision += 1
                    self.announcedThresholds.removeAll()
                    self.remainingDistance = first.remainingLength(from: fix.coordinate)
                    self.voice.speak("路线已更新", priority: .normal)
                    self.voiceCaption = self.voice.lastText
                }
            }
        } else {
            offRouteSince = nil
        }
    }

    /// 分级转向播报（v3）
    private func announceTurn(_ fix: FusedFix, option: RouteOption) {
        guard let step = currentStep, stepRemaining > 0 else { return }

        let base = settings.voiceAlertDistance
        var thresholds: [Double] = [base, base * 0.5, 70]
        if fix.speed > 20 {
            thresholds = [base * 2, base, base * 0.45]
        } else if fix.speed < 6 {
            thresholds = [base * 0.6, 60, 25]
        }

        for threshold in thresholds {
            let key = "\(stepIndex)-\(Int(threshold))"
            if stepRemaining <= threshold && !announcedThresholds.contains(key) {
                announcedThresholds.insert(key)
                let action = step.spokenText
                let distanceText = Fmt.distanceTight(max(stepRemaining, 10))
                var text = "\(distanceText)后\(action)"
                if threshold == 25 || threshold <= 70 {
                    text = action
                }
                voice.speak(text, priority: .normal, dedupWindow: 6)
                voiceCaption = voice.lastText
                break
            }
        }
    }

    /// 超速（v8）
    private func checkSpeed(_ fix: FusedFix) {
        let event = safety.ingest(speed: fix.speed)
        safetyScore = safety.score
        speedAlert = safety.isOverspeed
        overspeedAmount = safety.overspeedAmount

        if event == .overspeed {
            voice.speak(
                "注意车速，已超过设定值",
                priority: .high,
                dedupWindow: 20
            )
            voiceCaption = voice.lastText
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        } else if event == .harshBraking {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func finishArrival() {
        navigating = false
        arrived = true
        arrivedName = endName
        zoomDistance = 950
        pitch = settings.mapPitchEnabled ? 35 : 0
        voice.speak("已到达目的地附近，导航结束", priority: .high, dedupWindow: 2)
        voiceCaption = voice.lastText
        finishTrip()
        updateIdleTimer()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.arrived = false
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = navigating && settings.keepScreenOn
    }

    // MARK: - 行程（v4）

    func startTrip() {
        guard !tripActive else { return }
        tripRecorder.start(at: coordinate, name: startCoordinate == nil ? "我的位置" : startName)
        tripRecorder.endName = endName
        tripActive = true
        tripDistance = 0
        tripMaxSpeed = 0
        tripElapsed = 0
        lastTripRefresh = .distantPast
    }

    func finishTrip() {
        guard tripActive else { return }
        tripActive = false
        if let record = tripRecorder.finish(endName: endName.isEmpty ? nil : endName) {
            tripStore.add(record)
        }
        tripDistance = 0
        tripMaxSpeed = 0
        tripElapsed = 0
    }

    func toggleTrip() {
        if tripActive {
            finishTrip()
        } else {
            startTrip()
        }
    }

    private func refreshTripSnapshot(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastTripRefresh) > 1 else { return }
        lastTripRefresh = now
        tripDistance = tripRecorder.distance
        tripMaxSpeed = tripRecorder.maxSpeed
        if let started = tripRecorder.startedAt {
            tripElapsed = now.timeIntervalSince(started)
        }
    }

    var trips: [TripRecord] { tripStore.trips }
}

extension NavModel {
    /// 把定位误差画成圆（MapCanvas 用）
    var accuracyRadius: CLLocationDistance? {
        guard settings.showAccuracyCircle, accuracy > 0, accuracy < 500 else { return nil }
        return accuracy
    }
}
