import SwiftUI
import CoreLocation

/// 底部实时数据卡（自由浏览模式）
struct StatusCard: View {
    @EnvironmentObject private var model: NavModel

    private var statusColor: Color {
        switch model.authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            return model.accuracy > 0 && model.accuracy < 60 ? Theme.success : Color.orange
        case .denied, .restricted:
            return Theme.danger
        default:
            return Theme.faint
        }
    }

    private var statusText: String {
        switch model.authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            if model.coordinate == nil { return "正在定位…" }
            return model.accuracy > 60 ? "定位精度较低" : "定位正常"
        case .denied, .restricted:
            return "定位权限未开启"
        default:
            return "等待授权"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.ink)
                Spacer(minLength: 0)
                Text(Fmt.clock(model.updatedAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.faint)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                metric("速度", Fmt.speed(model.speed), "km/h")
                metric("海拔", Fmt.altitude(model.altitude), "m")
                metric("航向", Fmt.bearing(model.heading >= 0 ? model.heading : model.course), "°")
                metric("精度", model.accuracy > 0 ? String(format: "%.0f", model.accuracy) : "--", "m")
            }

            if let coordinate = model.coordinate {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.faint)
                    Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.faint)
                    Spacer(minLength: 0)
                    Text("\(model.trail.count) 点")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.faint)
                }
            }
        }
        .glassCard(padding: 12)
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Theme.faint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.ink)
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.035))
        )
    }
}

// MARK: - 导航顶部：转向指引

struct NavTopBar: View {
    @EnvironmentObject private var model: NavModel

    private var instruction: String {
        guard let step = model.currentStep else { return "沿路线前行" }
        return step.instruction
    }

    private var distanceText: String {
        model.stepRemaining > 0 ? Fmt.distance(model.stepRemaining) : ""
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.primary)
                    .frame(width: 52, height: 52)
                Image(systemName: model.currentStep?.maneuverSymbol ?? "arrow.up")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(distanceText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.ink)
                Text(instruction)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.subInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .glassCard(padding: 12)
    }
}

// MARK: - 导航底部：剩余信息

struct NavBottomBar: View {
    @EnvironmentObject private var model: NavModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                infoBlock("剩余", Fmt.distance(model.remainingDistance))
                divider
                infoBlock("预计", Fmt.duration(model.remainingTime))
                divider
                infoBlock("车速", "\(Fmt.speed(model.speed)) km/h")
            }

            HStack(spacing: 10) {
                Button(action: { model.stopNavigation() }) {
                    Text("结束导航")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.95))
                        )
                }
                .buttonStyle(.plain)

                Button(action: { model.fitRoute() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.ink)
                        .frame(width: 50)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.95))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard(padding: 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(width: 1, height: 26)
    }

    private func infoBlock(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Theme.faint)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
