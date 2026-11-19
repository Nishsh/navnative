import SwiftUI
import MapKit
import CoreLocation

struct RootView: View {
    @EnvironmentObject private var model: NavModel
    @ObservedObject private var settings = SettingsStore.shared

    @State private var showSearch = false
    @State private var searchTarget: SearchTarget = .destination
    @State private var showStatus = true
    @State private var showPOI = false
    @State private var showTrips = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            MapCanvas(model: model)
                .ignoresSafeArea()

            if model.following {
                centerMarker
            }

            VStack(spacing: 10) {
                if model.navigating {
                    NavTopBar()
                } else {
                    topBar
                }

                Spacer(minLength: 0)

                if model.navigating {
                    HStack(alignment: .bottom, spacing: 10) {
                        SpeedBadge()
                        NavBottomBar()
                    }
                } else {
                    bottomArea
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)

            if model.arrived {
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                        Text("已到达 \(model.arrivedName)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.success)
                    )
                    .shadow(color: Theme.success.opacity(0.45), radius: 16, x: 0, y: 8)
                    .padding(.bottom, 150)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showSearch) {
            SearchPanel(initialTarget: searchTarget)
                .environmentObject(model)
        }
        .sheet(isPresented: $showPOI) {
            POISheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showTrips) {
            TripsSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(model)
        }
        .alert("提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            model.requestPermission()
        }
    }

    // MARK: - 车标

    private var centerMarker: some View {
        ZStack {
            // 精度差时外圈变黄，给出「位置可能不准」的视觉反馈
            Circle()
                .stroke(
                    Theme.qualityColor(model.quality).opacity(0.55),
                    lineWidth: model.quality.rawValue >= FixQuality.good.rawValue ? 0 : 3
                )
                .frame(width: 62, height: 62)

            Circle()
                .fill(Theme.primary)
                .frame(width: 46, height: 46)
                .shadow(color: Theme.primary.opacity(0.5), radius: 14, x: 0, y: 4)
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: 46, height: 46)
            Image(systemName: "location.north.fill")
                .font(.system(size: 21, weight: .heavy))
                .foregroundColor(.white)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 顶部

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                searchField

                circleButton(icon: "arrow.up.arrow.down", tint: Theme.subInk, size: 44) {
                    model.swapEndpoints()
                }
            }

            if !model.waypoints.isEmpty {
                waypointChips
            }

            if !model.options.isEmpty {
                routeSelector
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Button(action: {
                searchTarget = .destination
                showSearch = true
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.subInk)

                    VStack(alignment: .leading, spacing: 2) {
                        if model.endName.isEmpty {
                            Text("搜索目的地")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(Theme.subInk)
                        } else {
                            Text(model.destinationLabel)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.ink)
                                .lineLimit(1)
                            Text(model.startName)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.faint)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !model.planning && !model.endName.isEmpty {
                Button(action: { model.clearDestination() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard(padding: 12)
    }

    private var waypointChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { pair in
                    HStack(spacing: 5) {
                        Text("经\(pair.offset + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.warning))
                        Text(pair.element.name)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.ink)
                            .lineLimit(1)
                        Button(action: { model.removeWaypoint(pair.element.id) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.faint)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Theme.cardFill.opacity(0.94))
                    )
                }

                Button(action: {
                    searchTarget = .waypoint
                    showSearch = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text("途经点")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(Theme.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.cardFill.opacity(0.94)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 1)
        }
    }

    private var routeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.options) { option in
                    Button(action: { model.select(route: option.id) }) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(option.id == model.selectedIndex ? .white : Theme.ink)
                            Text("\(Fmt.distance(option.distance)) · \(Fmt.duration(option.expectedTravelTime))")
                                .font(.system(size: 10))
                                .foregroundColor(option.id == model.selectedIndex ? .white.opacity(0.9) : Theme.subInk)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .chipBackground(active: option.id == model.selectedIndex)
                        .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - 底部

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if model.planning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在计算路线…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.subInk)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassCard(padding: 0)
            } else if let error = model.routeError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassCard(padding: 0)
            }

            if model.tripActive && !model.navigating {
                tripPill
            }

            if showStatus {
                StatusCard()
            }

            HStack(spacing: 8) {
                circleButton(icon: "info.circle", tint: showStatus ? Theme.primary : Theme.subInk, size: 46) {
                    withAnimation(.easeInOut(duration: 0.18)) { showStatus.toggle() }
                }
                circleButton(icon: "location.fill", tint: Theme.ink, size: 46) {
                    model.centerOnUser()
                }
                circleButton(icon: "mappin.and.ellipse", tint: Theme.ink, size: 46) {
                    showPOI = true
                }
                circleButton(icon: "clock.arrow.circlepath", tint: Theme.ink, size: 46) {
                    showTrips = true
                }
                circleButton(icon: "gearshape.fill", tint: Theme.ink, size: 46) {
                    showSettings = true
                }
            }

            if model.selectedOption != nil {
                primaryButton(title: "开始导航", icon: "location.north.line.fill") {
                    model.startNavigation()
                }
            } else {
                primaryButton(title: "选择目的地", icon: "magnifyingglass") {
                    searchTarget = .destination
                    showSearch = true
                }
            }
        }
    }

    private var tripPill: some View {
        Button(action: { model.toggleTrip() }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.danger)
                    .frame(width: 7, height: 7)
                Text("记录中")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.ink)
                Text(Fmt.distance(model.tripDistance))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(Theme.subInk)
                Text(Fmt.duration(model.tripElapsed))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(Theme.subInk)
                Spacer(minLength: 0)
                Text("结束")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.danger)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCard(padding: 0)
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.primary)
            )
            .shadow(color: Theme.primary.opacity(0.35), radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    private func circleButton(icon: String, tint: Color, size: CGFloat = 48, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size > 46 ? 17 : 16, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(Theme.cardFill.opacity(0.95))
                )
                .overlay(
                    Circle().strokeBorder(Theme.cardStroke.opacity(0.5), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView().environmentObject(NavModel())
    }
}
