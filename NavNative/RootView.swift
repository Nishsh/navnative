import SwiftUI
import MapKit
import CoreLocation

struct RootView: View {
    @EnvironmentObject private var model: NavModel
    @State private var showSearch = false
    @State private var showStatus = true

    var body: some View {
        ZStack {
            MapCanvas(model: model)
                .ignoresSafeArea()

            if model.following {
                centerMarker
            }

            VStack(spacing: 12) {
                if model.navigating {
                    NavTopBar()
                } else {
                    topBar
                }

                Spacer(minLength: 0)

                if model.navigating {
                    NavBottomBar()
                } else {
                    bottomArea
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)

            if model.arrived {
                VStack {
                    Spacer()
                    Text("已到达目的地附近")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(Theme.success)
                        )
                        .shadow(color: Theme.success.opacity(0.4), radius: 14, x: 0, y: 6)
                        .padding(.bottom, 120)
                }
                .allowsHitTesting(false)
            }
        }
        .background(Color(red: 0.95, green: 0.96, blue: 0.98))
        .sheet(isPresented: $showSearch) {
            SearchPanel()
                .environmentObject(model)
        }
        .alert("定位提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            model.requestPermission()
        }
    }

    // MARK: - 车标（跟随模式下固定屏幕中心，地图已按航向旋转）

    private var centerMarker: some View {
        ZStack {
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
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                searchField
                circleButton(
                    icon: model.following ? "location.fill" : "location",
                    tint: model.following ? Theme.primary : Theme.ink
                ) {
                    model.centerOnUser()
                }
            }

            if !model.options.isEmpty {
                routeSelector
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Button(action: { showSearch = true }) {
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
                            Text(model.endName)
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

    private var routeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.options) { option in
                    Button(action: { model.select(route: option.id) }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(option.id == model.selectedIndex ? .white : Theme.ink)
                            Text("\(Fmt.distance(option.distance)) · \(Fmt.duration(option.expectedTravelTime))")
                                .font(.system(size: 11))
                                .foregroundColor(option.id == model.selectedIndex ? .white.opacity(0.9) : Theme.subInk)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(option.id == model.selectedIndex ? Theme.primary : Color.white.opacity(0.92))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    // MARK: - 底部

    private var bottomArea: some View {
        VStack(spacing: 12) {
            if model.planning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在计算路线…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.subInk)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassCard(padding: 0)
            } else if let error = model.routeError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassCard(padding: 0)
            }

            if showStatus {
                StatusCard()
            }

            HStack(spacing: 10) {
                circleButton(icon: "info.circle", tint: showStatus ? Theme.primary : Theme.ink) {
                    showStatus.toggle()
                }
                circleButton(icon: "arrow.triangle.2.circlepath", tint: Theme.ink) {
                    model.resetView()
                }

                if model.selectedOption != nil {
                    Button(action: { model.startNavigation() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "location.north.line.fill")
                                .font(.system(size: 17, weight: .bold))
                            Text("开始导航")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Theme.primary)
                        )
                        .shadow(color: Theme.primary.opacity(0.35), radius: 14, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { showSearch = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 16, weight: .bold))
                            Text("选择目的地")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Theme.primary)
                        )
                        .shadow(color: Theme.primary.opacity(0.35), radius: 14, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func circleButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 48, height: 48)
                .background(
                    Circle().fill(Color.white.opacity(0.94))
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
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
