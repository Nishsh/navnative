import Foundation
import SwiftUI
import Combine
import CoreLocation

// MARK: - 枚举

enum UnitSystem: String, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }
    var title: String { self == .metric ? "公制（km / m）" : "英制（mi / ft）" }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "跟随系统"
        case .light: return "白天"
        case .dark: return "夜间"
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum TravelMode: String, CaseIterable, Identifiable {
    case automobile
    case walking

    var id: String { rawValue }
    var title: String { self == .automobile ? "驾车" : "步行" }
    var symbol: String { self == .automobile ? "car.fill" : "figure.walk" }
    var activity: CLActivityType { self == .automobile ? .automotiveNavigation : .fitness }
}

// MARK: - 设置存储

/// 全量偏好设置，UserDefaults 持久化（v9）
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // 语音
    @Published var voiceEnabled: Bool { didSet { save(voiceEnabled, "voiceEnabled") } }
    @Published var voiceVolume: Double { didSet { save(voiceVolume, "voiceVolume") } }
    @Published var voiceRate: Double { didSet { save(voiceRate, "voiceRate") } }

    // 显示
    @Published var themeMode: ThemeMode { didSet { save(themeMode.rawValue, "themeMode") } }
    @Published var units: UnitSystem { didSet { save(units.rawValue, "units") } }
    @Published var largeHUD: Bool { didSet { save(largeHUD, "largeHUD") } }
    @Published var showAccuracyCircle: Bool { didSet { save(showAccuracyCircle, "showAccuracyCircle") } }
    @Published var showTrail: Bool { didSet { save(showTrail, "showTrail") } }
    @Published var mapPitchEnabled: Bool { didSet { save(mapPitchEnabled, "mapPitchEnabled") } }

    // 导航
    @Published var travelMode: TravelMode { didSet { save(travelMode.rawValue, "travelMode") } }
    @Published var avoidHighways: Bool { didSet { save(avoidHighways, "avoidHighways") } }
    @Published var avoidTolls: Bool { didSet { save(avoidTolls, "avoidTolls") } }
    @Published var voiceAlertDistance: Double { didSet { save(voiceAlertDistance, "voiceAlertDistance") } }

    // 安全
    @Published var speedAlertEnabled: Bool { didSet { save(speedAlertEnabled, "speedAlertEnabled") } }
    @Published var speedLimit: Double { didSet { save(speedLimit, "speedLimit") } }
    @Published var speedTolerance: Double { didSet { save(speedTolerance, "speedTolerance") } }

    // 电源
    @Published var keepScreenOn: Bool { didSet { save(keepScreenOn, "keepScreenOn") } }
    @Published var backgroundLocation: Bool { didSet { save(backgroundLocation, "backgroundLocation") } }

    // 定位
    @Published var coordinateCorrection: Bool { didSet { save(coordinateCorrection, "coordinateCorrection") } }
    @Published var autoReroute: Bool { didSet { save(autoReroute, "autoReroute") } }

    private init() {
        voiceEnabled = defaults.object(forKey: "voiceEnabled") as? Bool ?? true
        voiceVolume = defaults.object(forKey: "voiceVolume") as? Double ?? 0.9
        voiceRate = defaults.object(forKey: "voiceRate") as? Double ?? 0.5

        themeMode = ThemeMode(rawValue: defaults.string(forKey: "themeMode") ?? "") ?? .auto
        units = UnitSystem(rawValue: defaults.string(forKey: "units") ?? "") ?? .metric
        largeHUD = defaults.object(forKey: "largeHUD") as? Bool ?? false
        showAccuracyCircle = defaults.object(forKey: "showAccuracyCircle") as? Bool ?? true
        showTrail = defaults.object(forKey: "showTrail") as? Bool ?? true
        mapPitchEnabled = defaults.object(forKey: "mapPitchEnabled") as? Bool ?? true

        travelMode = TravelMode(rawValue: defaults.string(forKey: "travelMode") ?? "") ?? .automobile
        avoidHighways = defaults.object(forKey: "avoidHighways") as? Bool ?? false
        avoidTolls = defaults.object(forKey: "avoidTolls") as? Bool ?? false
        voiceAlertDistance = defaults.object(forKey: "voiceAlertDistance") as? Double ?? 300

        speedAlertEnabled = defaults.object(forKey: "speedAlertEnabled") as? Bool ?? true
        speedLimit = defaults.object(forKey: "speedLimit") as? Double ?? 120
        speedTolerance = defaults.object(forKey: "speedTolerance") as? Double ?? 8

        keepScreenOn = defaults.object(forKey: "keepScreenOn") as? Bool ?? true
        backgroundLocation = defaults.object(forKey: "backgroundLocation") as? Bool ?? true

        coordinateCorrection = defaults.object(forKey: "coordinateCorrection") as? Bool ?? false
        autoReroute = defaults.object(forKey: "autoReroute") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// 恢复默认
    func resetToDefaults() {
        voiceEnabled = true
        voiceVolume = 0.9
        voiceRate = 0.5
        themeMode = .auto
        units = .metric
        largeHUD = false
        showAccuracyCircle = true
        showTrail = true
        mapPitchEnabled = true
        travelMode = .automobile
        avoidHighways = false
        avoidTolls = false
        voiceAlertDistance = 300
        speedAlertEnabled = true
        speedLimit = 120
        speedTolerance = 8
        keepScreenOn = true
        backgroundLocation = true
        coordinateCorrection = false
        autoReroute = true
    }
}
