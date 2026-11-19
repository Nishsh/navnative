import SwiftUI
import MapKit
import UIKit
import CoreLocation

// MARK: - 周边搜索面板（v6）

struct POISheet: View {
    @EnvironmentObject private var model: NavModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var searcher = POISearcher()
    @State private var category: POICategory = .fuel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("周边")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Theme.ink)
                    Text(model.coordinate == nil ? "等待定位…" : "以当前位置为中心 3 公里")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                }
                Spacer()
                if searcher.loading {
                    ProgressView()
                }
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.faint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(POICategory.allCases) { item in
                        Button(action: {
                            category = item
                            runSearch()
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(item.title)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(category == item ? .white : Theme.subInk)
                            .frame(width: 64, height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(category == item ? Theme.primary : Theme.inset)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            Divider().padding(.top, 10)

            if let error = searcher.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.faint)
                    .padding(.top, 30)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(searcher.results) { item in
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Image(systemName: item.category.symbol)
                                    .font(.system(size: 17))
                                    .foregroundColor(Theme.primary)
                                    .frame(width: 26)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(Theme.ink)
                                        .lineLimit(1)
                                    Text(item.address.isEmpty ? item.category.title : item.address)
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.faint)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                Text(Fmt.distance(item.distance))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(Theme.subInk)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                            HStack(spacing: 8) {
                                Button(action: {
                                    model.setDestination(item.coordinate, name: item.name)
                                    dismiss()
                                }) {
                                    Text("导航到这里")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Theme.primary))
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    model.addWaypoint(item.coordinate, name: item.name)
                                    dismiss()
                                }) {
                                    Text("加入途经点")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Theme.warning)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Theme.warning.opacity(0.12)))
                                }
                                .buttonStyle(.plain)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .padding(.top, 6)
                        }

                        Divider().padding(.leading, 54)
                    }
                }
                .padding(.top, 4)
            }
        }
        .background(Theme.canvas)
        .onAppear { runSearch() }
    }

    private func runSearch() {
        guard let center = model.coordinate else { return }
        searcher.search(category: category, around: center, radius: 3000)
    }
}

// MARK: - 行程面板（v4）

struct TripsSheet: View {
    @EnvironmentObject private var model: NavModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TripStore.shared
    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("行程记录")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Theme.ink)
                    Text("共 \(store.trips.count) 次 · 累计 \(Fmt.distance(store.totalDistance))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                }
                Spacer()
                Button(action: { model.toggleTrip() }) {
                    HStack(spacing: 4) {
                        Image(systemName: model.tripActive ? "stop.fill" : "record.circle")
                        Text(model.tripActive ? "结束" : "开始记录")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(model.tripActive ? Theme.danger : Theme.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.inset))
                }
                .buttonStyle(.plain)

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.faint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if store.trips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "map")
                        .font(.system(size: 34))
                        .foregroundColor(Theme.faint.opacity(0.7))
                    Text("还没有记录")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.subInk)
                    Text("开始导航会自动记录；\n也可以点右上角手动开始")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.trips) { record in
                            tripRow(record)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func tripRow(_ record: TripRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Fmt.dayTime(record.startedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.faint)
                Text(record.modeTitle)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.primary.opacity(0.12)))
                Spacer()
                Button(action: {
                    if let url = store.exportGPX(record) {
                        shareURL = url
                        showShare = true
                    }
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.subInk)
                }
                .buttonStyle(.plain)

                Button(action: { store.delete(record) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.faint)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                Text(record.startName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.faint)
                Text(record.endName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                stat(Fmt.distance(record.distance), "里程")
                stat(Fmt.duration(record.duration), "用时")
                stat("\(Fmt.speedValue(record.avgSpeed))", "均速 \(Fmt.speedUnit)")
                stat("\(Fmt.speedValue(record.maxSpeed))", "极速 \(Fmt.speedUnit)")
            }
        }
        .glassCard(padding: 12)
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(Theme.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 分享

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 设置面板（v9）

struct SettingsSheet: View {
    @EnvironmentObject private var model: NavModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showAbout = false

    var body: some View {
        NavigationView {
            List {
                Section(header: sectionHeader("语音播报")) {
                    Toggle("开启语音", isOn: $settings.voiceEnabled)
                    if settings.voiceEnabled {
                        HStack {
                            Text("音量")
                            Slider(value: $settings.voiceVolume, in: 0.2...1.0)
                            Text("\(Int(settings.voiceVolume * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("语速")
                            Slider(value: $settings.voiceRate, in: 0.35...0.62)
                            Text(String(format: "%.2f", settings.voiceRate))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Picker("提前播报", selection: $settings.voiceAlertDistance) {
                            Text("150 m").tag(150.0)
                            Text("300 m").tag(300.0)
                            Text("500 m").tag(500.0)
                            Text("800 m").tag(800.0)
                        }
                        Button("试听") {
                            model.voice.speak("前方三百米左转，请注意行车安全", priority: .normal, dedupWindow: 1)
                        }
                    }
                }

                Section(header: sectionHeader("显示")) {
                    Picker("主题", selection: $settings.themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    Picker("单位", selection: $settings.units) {
                        ForEach(UnitSystem.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                    Toggle("导航大字模式", isOn: $settings.largeHUD)
                    Toggle("显示精度圈", isOn: $settings.showAccuracyCircle)
                    Toggle("显示行驶轨迹", isOn: $settings.showTrail)
                    Toggle("地图 3D 倾斜", isOn: $settings.mapPitchEnabled)
                }

                Section(header: sectionHeader("路线偏好"), footer: Text("避开高速/收费需要 iOS 16 及以上，旧系统会自动忽略。")) {
                    Picker("出行方式", selection: $settings.travelMode) {
                        ForEach(TravelMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    Toggle("避开高速", isOn: $settings.avoidHighways)
                    Toggle("避开收费", isOn: $settings.avoidTolls)
                    Toggle("偏航自动重算", isOn: $settings.autoReroute)
                }

                Section(header: sectionHeader("安全提醒")) {
                    Toggle("超速提醒", isOn: $settings.speedAlertEnabled)
                    HStack {
                        Text("限速值")
                        Slider(value: $settings.speedLimit, in: 40...160, step: 5)
                        Text("\(Int(settings.speedLimit))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("容差")
                        Slider(value: $settings.speedTolerance, in: 0...30, step: 1)
                        Text("\(Int(settings.speedTolerance)) km/h")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: sectionHeader("定位与电源"), footer: Text("坐标校正常年关闭即可。只有发现车标与道路整体偏移数百米时才需要打开（系统地区为境外时常见）。")) {
                    Toggle("后台持续定位", isOn: $settings.backgroundLocation)
                    Toggle("导航时屏幕常亮", isOn: $settings.keepScreenOn)
                    Toggle("坐标偏移校正（WGS→GCJ）", isOn: $settings.coordinateCorrection)
                    HStack {
                        Text("定位精度")
                        Spacer()
                        Text(model.accuracy > 0 ? String(format: "±%.0f m", model.accuracy) : "--")
                            .foregroundColor(.secondary)
                        Text("· \(model.quality.title)")
                            .foregroundColor(Theme.qualityColor(model.quality))
                    }
                }

                Section(header: sectionHeader("关于")) {
                    Button("版本历史 v1 → v10") { showAbout = true }
                    Button("恢复默认设置") { settings.resetToDefaults() }
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(AppInfo.version)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        model.applySettingsChanges()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
            }
        }
        .onDisappear {
            model.applySettingsChanges()
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
    }
}

// MARK: - 版本历史（v10）

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("私人导航 Pro")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(Theme.ink)
                        Text(AppInfo.version)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.faint)
                        Text("纯原生 MapKit 导航，零第三方依赖、零 API Key")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.subInk)
                    }

                    ForEach(AppInfo.changelog, id: \.version) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(item.version)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.primary))
                                Text(item.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.ink)
                            }
                            ForEach(item.points, id: \.self) { point in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("·")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Theme.faint)
                                    Text(point)
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.subInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.inset)
                        )
                    }
                }
                .padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle("版本历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 版本信息

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "10.0"
        let build = info?["CFBundleVersion"] as? String ?? "100"
        return "v\(short) (\(build))"
    }

    struct ChangelogItem {
        let version: String
        let title: String
        let points: [String]
    }

    static let changelog: [ChangelogItem] = [
        ChangelogItem(version: "v1", title: "原生骨架", points: [
            "SwiftUI + MKMapView 包装，替换 WKWebView 方案",
            "MKDirections 规划、相机跟随、长按选点"
        ]),
        ChangelogItem(version: "v2", title: "定位质量管线", points: [
            "精度门限：丢弃 >150m 的粗定位与陈旧缓存点",
            "跳点剔除：隐含速度超 200km/h 的瞬移直接丢弃",
            "静止冻结：原地不动时坐标不再漂移",
            "按精度加权平滑，精度越差压得越重"
        ]),
        ChangelogItem(version: "v3", title: "语音播报", points: [
            "中文 TTS，转弯前分级播报（远/中/近）",
            "播报时自动压低音乐音量",
            "静音仍保留字幕提示"
        ]),
        ChangelogItem(version: "v4", title: "行程记录", points: [
            "自动记录里程、均速、极速、海拔升降",
            "行程本地持久化，可导出 GPX"
        ]),
        ChangelogItem(version: "v5", title: "多途经点", points: [
            "最多 8 个途经点，分段规划后拼接",
            "途经点可单独删除，地图上编号显示"
        ]),
        ChangelogItem(version: "v6", title: "周边搜索", points: [
            "12 类 POI：加油、充电、停车、餐饮等",
            "一键设为终点或加入途经点"
        ]),
        ChangelogItem(version: "v7", title: "路线偏好", points: [
            "避开高速 / 避开收费（iOS 16+）",
            "驾车 / 步行切换，多方案对比"
        ]),
        ChangelogItem(version: "v8", title: "安全与偏航", points: [
            "超速视觉+语音提醒，可调限速与容差",
            "急加速/急刹检测与驾驶评分",
            "偏离路线 6 秒自动重算"
        ]),
        ChangelogItem(version: "v9", title: "设置与主题", points: [
            "日夜主题、公制/英制单位",
            "语音、路线、电源偏好全量持久化"
        ]),
        ChangelogItem(version: "v10", title: "整合与打磨", points: [
            "导航大字模式、按车速自适应缩放",
            "收藏夹、版本历史、相机节流防抖",
            "全链路状态机收敛，崩溃点清零"
        ])
    ]
}
