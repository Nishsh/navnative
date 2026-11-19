import SwiftUI
import CoreLocation

/// 视觉主题：沿用 Web 版的靛蓝 + 磨砂玻璃卡片
enum Theme {
    static let primary = Color(red: 0.310, green: 0.275, blue: 0.898)   // #4F46E5
    static let primaryDark = Color(red: 0.263, green: 0.220, blue: 0.792) // #4338CA
    static let success = Color(red: 0.063, green: 0.725, blue: 0.506)   // #10B981
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)    // #EF4444
    static let ink = Color(red: 0.122, green: 0.161, blue: 0.216)       // #1F2937
    static let subInk = Color(red: 0.420, green: 0.447, blue: 0.502)    // #6B7280
    static let faint = Color(red: 0.612, green: 0.639, blue: 0.686)     // #9CA3AF

    static let radius: CGFloat = 16
}

/// 半透明卡片背景
struct GlassCard: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Color.white.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 8)
    }
}

extension View {
    func glassCard(padding: CGFloat = 14) -> some View {
        modifier(GlassCard(padding: padding))
    }
}

/// 数字格式化工具
enum Fmt {
    static func distance(_ meters: CLLocationDistance) -> String {
        guard meters.isFinite, meters >= 0 else { return "--" }
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
        return "\(h) 小时 \(m % 60) 分"
    }

    static func speed(_ mps: CLLocationSpeed) -> String {
        guard mps.isFinite, mps >= 0 else { return "--" }
        return String(format: "%.1f", mps * 3.6)
    }

    static func altitude(_ meters: CLLocationDistance) -> String {
        guard meters.isFinite else { return "--" }
        return String(format: "%.0f", meters)
    }

    static func bearing(_ deg: CLLocationDirection) -> String {
        guard deg.isFinite, deg >= 0 else { return "--" }
        return String(format: "%.0f°", deg)
    }

    static func clock(_ date: Date?) -> String {
        guard let date = date else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
