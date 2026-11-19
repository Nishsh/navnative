import SwiftUI
import CoreLocation

// MARK: - 定位诊断卡

struct StatusCard: View {
    @EnvironmentObject private var model: NavModel

    private var statusColor: Color {
        switch model.authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            return Theme.qualityColor(model.quality)
        case .denied, .restricted:
            return Theme.danger
        default:
            return Theme.faint
        }
    }

    private var statusText: String {
        switch model.authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            if model.coordinate == nil { return "正在搜索卫星…" }
            return "定位\(model.quality.shortTitle)"
        case .denied, .restricted:
            return "定位权限未开启"
        default:
            return "等待授权"
        }
    }

    private var motionText: String {
        if model.coordinate == nil { return "无数据" }
        if model.isStationary { return "静止" }
        return "移动中"
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
                Text("·")
                    .foregroundColor(Theme.faint)
                Text(motionText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.subInk)
                Spacer(minLength: 0)
                Text(Fmt.clock(model.updatedAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.faint)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                metric("速度", Fmt.speedValue(model.speed), Fmt.speedUnit)
                metric("海拔", Fmt.altitude(model.altitude), Fmt.altitudeUnit)
                metric("航向", Fmt.bearing(model.heading >= 0 ? model.heading : model.course), "")
                metric("精度", model.accuracy > 0 ? String(format: "±%.0f", model.accuracy) : "--", "m")
            }

            if let coordinate = model.coordinate {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.faint)
                    Text(Fmt.coordinate(coordinate))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.faint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Text("滤除 \(model.filteredCount)")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.faint)
                }
            }

            if model.quality == .poor || model.quality == .unknown {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.warning)
                    Text("信号弱：尽量到开阔处，或稍等几秒让卫星收敛")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.subInk)
                    Spacer(minLength: 0)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundColor(Theme.faint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.inset)
        )
    }
}

// MARK: - 导航顶部：转向指引

struct NavTopBar: View {
    @EnvironmentObject private var model: NavModel

    private var large: Bool { SettingsStore.shared.largeHUD }

    private var instruction: String {
        guard let step = model.currentStep else { return "沿路线前行" }
        return step.instruction
    }

    private var distanceText: String {
        model.stepRemaining > 0 ? Fmt.distanceTight(model.stepRemaining) : ""
    }

    private var nextText: String {
        guard let next = model.nextStep, !next.instruction.isEmpty else { return "" }
        return "然后 \(InstructionText.actionOnly(next.instruction))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: large ? 16 : 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.primary)
                        .frame(width: large ? 66 : 54, height: large ? 66 : 54)
                    Image(systemName: model.currentStep?.maneuverSymbol ?? "arrow.up")
                        .font(.system(size: large ? 30 : 25, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(distanceText)
                        .font(.system(size: large ? 30 : 22, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.ink)
                    Text(instruction)
                        .font(.system(size: large ? 16 : 13, weight: .medium))
                        .foregroundColor(Theme.subInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !nextText.isEmpty {
                        Text(nextText)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.faint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if model.offRoute {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                            .font(.system(size: 18))
                        Text("偏航")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(Theme.danger)
                }
            }
            .glassCard(padding: large ? 14 : 12)

            if model.speedAlert {
                HStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 13, weight: .bold))
                    Text("超速 \(String(format: "%.0f", model.overspeedAmount)) km/h")
                        .font(.system(size: 13, weight: .bold))
                    Spacer(minLength: 0)
                    Text("限速 \(String(format: "%.0f", SettingsStore.shared.speedLimit))")
                        .font(.system(size: 11))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.danger)
                )
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - 导航底部：剩余信息

struct NavBottomBar: View {
    @EnvironmentObject private var model: NavModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                infoBlock("剩余", Fmt.distance(model.remainingDistance))
                divider
                infoBlock("预计", Fmt.duration(model.remainingTime))
                divider
                infoBlock("到达", Fmt.arrival(model.remainingTime))
            }

            if !model.voiceCaption.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: settings.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.primary)
                    Text(model.voiceCaption)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.subInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                Button(action: { model.stopNavigation() }) {
                    Text("结束导航")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Theme.cardFill.opacity(0.95))
                        )
                }
                .buttonStyle(.plain)

                iconButton("arrow.up.left.and.arrow.down.right") {
                    model.fitRoute()
                }

                iconButton(settings.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                    settings.voiceEnabled.toggle()
                    if !settings.voiceEnabled { model.voice.stop() }
                }
            }
        }
        .glassCard(padding: 12)
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.ink)
                .frame(width: 46)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Theme.cardFill.opacity(0.95))
                )
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
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

// MARK: - 速度徽标

struct SpeedBadge: View {
    @EnvironmentObject private var model: NavModel

    private var speedValue: String { Fmt.speedValue(model.speed) }

    private var tint: Color {
        if model.speedAlert { return Theme.danger }
        if Fmt.speedNumber(model.speed) > SettingsStore.shared.speedLimit { return Theme.warning }
        return Theme.ink
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(speedValue)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundColor(tint)
                .minimumScaleFactor(0.6)
            Text(Fmt.speedUnit)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Theme.faint)
        }
        .frame(width: 58, height: 58)
        .background(
            Circle().fill(Theme.cardFill.opacity(0.94))
        )
        .overlay(
            Circle().strokeBorder(model.speedAlert ? Theme.danger : Theme.cardStroke.opacity(0.6), lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
    }
}
