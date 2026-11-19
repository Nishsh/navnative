import SwiftUI
import UIKit
import CoreLocation

/// 视觉主题（v9）：明暗自适应。所有语义色都是 dynamic color，
/// 切换配色只需要在根视图设置 preferredColorScheme。
enum Theme {

    // MARK: - 品牌色（不随明暗变化）

    static let primary = Color(red: 0.310, green: 0.275, blue: 0.898)     // #4F46E5
    static let primaryDark = Color(red: 0.263, green: 0.220, blue: 0.792) // #4338CA
    static let accent = Color(red: 0.000, green: 0.510, blue: 0.980)      // #0082FA
    static let success = Color(red: 0.063, green: 0.725, blue: 0.506)     // #10B981
    static let warning = Color(red: 0.960, green: 0.620, blue: 0.043)     // #F59E0B
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)      // #EF4444

    // MARK: - 语义色（明暗自适应）

    static let ink = dynamic(light: 0x1F2937, dark: 0xF3F4F6)
    static let subInk = dynamic(light: 0x6B7280, dark: 0xA8AEB8)
    static let faint = dynamic(light: 0x9CA3AF, dark: 0x7C8290)

    static let canvas = dynamic(light: 0xF2F3F8, dark: 0x0E1014)
    static let cardFill = dynamic(light: 0xFFFFFF, dark: 0x1B1E24)
    static let cardStroke = dynamic(light: 0xFFFFFF, dark: 0x34383F)
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)
    static let inset = dynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.05)

    static let radius: CGFloat = 16

    // MARK: - 定位质量配色

    static func qualityColor(_ quality: FixQuality) -> Color {
        switch quality {
        case .excellent: return success
        case .good: return Color(red: 0.20, green: 0.72, blue: 0.40)
        case .fair: return warning
        case .poor: return danger
        case .unknown: return faint
        }
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

/// 半透明卡片背景（明暗通用）
struct GlassCard: ViewModifier {
    var padding: CGFloat = 14
    var strong: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.cardFill.opacity(strong ? 0.98 : 0.86))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.cardStroke.opacity(0.55), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 8)
    }
}

extension View {
    func glassCard(padding: CGFloat = 14) -> some View {
        modifier(GlassCard(padding: padding))
    }

    /// 小尺寸浮层按钮背景
    func chipBackground(active: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? Theme.primary : Theme.cardFill.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Color.clear : Theme.cardStroke.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - 数字格式化（带单位系统）

enum Fmt {

    private static var units: UnitSystem { SettingsStore.shared.units }

    /// 距离：米/公里 或 英尺/英里
    static func distance(_ meters: CLLocationDistance) -> String {
        guard meters.isFinite, meters >= 0 else { return "--" }
        if units == .imperial {
            let feet = meters * 3.28084
            if feet < 1000 { return String(format: "%.0f ft", feet) }
            return String(format: "%.1f mi", feet / 5280)
        }
        if meters < 1000 { return String(format: "%.0f m", meters) }
        if meters < 10000 { return String(format: "%.2f km", meters / 1000) }
        return String(format: "%.1f km", meters / 1000)
    }

    /// 紧凑距离：用于转向卡（不带空格）
    static func distanceTight(_ meters: CLLocationDistance) -> String {
        guard meters.isFinite, meters >= 0 else { return "--" }
        if units == .imperial {
            let feet = meters * 3.28084
            if feet < 1000 { return String(format: "%.0f ft", feet) }
            return String(format: "%.1f mi", feet / 5280)
        }
        if meters < 1000 { return String(format: "%.0f m", meters) }
        return String(format: "%.1f km", meters / 1000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        let m = total / 60
        if m < 60 { return "\(m) 分钟" }
        let h = m / 60
        if h >= 24 { return "\(h / 24) 天 \(h % 24) 时" }
        return "\(h) 小时 \(m % 60) 分"
    }

    /// ETA：几时几分到达
    static func arrival(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 86400 else { return "--:--" }
        let date = Date().addingTimeInterval(seconds)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// 速度数值（按单位系统换算）
    static func speedValue(_ mps: CLLocationSpeed) -> String {
        guard mps.isFinite, mps >= 0 else { return "--" }
        let value = units == .imperial ? mps * 2.23694 : mps * 3.6
        return String(format: "%.0f", value)
    }

    /// 速度小数值
    static func speedDecimal(_ mps: CLLocationSpeed) -> String {
        guard mps.isFinite, mps >= 0 else { return "--" }
        let value = units == .imperial ? mps * 2.23694 : mps * 3.6
        return String(format: "%.1f", value)
    }

    static var speedUnit: String { units == .imperial ? "mph" : "km/h" }

    /// m/s → 当前单位下的数值
    static func speedNumber(_ mps: CLLocationSpeed) -> Double {
        guard mps.isFinite, mps >= 0 else { return 0 }
        return units == .imperial ? mps * 2.23694 : mps * 3.6
    }

    static func altitude(_ meters: CLLocationDistance) -> String {
        guard meters.isFinite else { return "--" }
        if units == .imperial {
            return String(format: "%.0f", meters * 3.28084)
        }
        return String(format: "%.0f", meters)
    }

    static var altitudeUnit: String { units == .imperial ? "ft" : "m" }

    static func bearing(_ deg: CLLocationDirection) -> String {
        guard deg.isFinite, deg >= 0 else { return "--" }
        let names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let index = Int((deg + 22.5) / 45) % 8
        return "\(names[index]) \(Int(deg))°"
    }

    static func clock(_ date: Date?) -> String {
        guard let date = date else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func dayTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    static func coordinate(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }
}
