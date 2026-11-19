import SwiftUI
import MapKit
import CoreLocation

/// 搜索面板要落到哪个位置
enum SearchTarget: String, CaseIterable, Identifiable {
    case destination
    case waypoint
    case start

    var id: String { rawValue }

    var title: String {
        switch self {
        case .destination: return "终点"
        case .waypoint: return "途经点"
        case .start: return "起点"
        }
    }

    var dotColor: Color {
        switch self {
        case .destination: return Theme.danger
        case .waypoint: return Theme.warning
        case .start: return Theme.success
        }
    }
}

struct SearchPanel: View {
    var initialTarget: SearchTarget = .destination

    @EnvironmentObject private var model: NavModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = PlaceCompleter()
    @ObservedObject private var favorites = FavoritesStore.shared

    @State private var target: SearchTarget = .destination
    @State private var text = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    init(initialTarget: SearchTarget = .destination) {
        self.initialTarget = initialTarget
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 6) {
                ForEach(SearchTarget.allCases) { item in
                    Button(action: {
                        target = item
                        focused = true
                    }) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(item.dotColor)
                                .frame(width: 7, height: 7)
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(target == item ? .white : Theme.subInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(target == item ? Theme.primary : Theme.inset)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            inputRow
                .padding(.horizontal, 16)
                .padding(.top, 10)

            Divider().padding(.top, 12)

            resultsList

            Spacer(minLength: 0)
        }
        .background(Theme.canvas)
        .onAppear {
            target = initialTarget
            switch initialTarget {
            case .destination:
                text = model.endName
            case .waypoint:
                text = ""
            case .start:
                text = model.startCoordinate == nil ? "" : model.startName
            }
            if let coordinate = model.coordinate {
                completer.updateRegion(around: coordinate)
            }
            if !text.isEmpty {
                completer.query(text)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focused = true
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("搜索地点")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.ink)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.faint)
            }
            Spacer()
            if busy {
                ProgressView().padding(.trailing, 6)
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
        .padding(.bottom, 12)
    }

    private var hint: String {
        switch target {
        case .destination: return "将作为导航终点"
        case .waypoint: return "途经点最多 8 个"
        case .start: return "默认从当前位置出发"
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(target.dotColor)
                .frame(width: 9, height: 9)

            TextField("输入地名、地址或关键字", text: $text)
                .font(.system(size: 15))
                .foregroundColor(Theme.ink)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($focused)
                .onChange(of: text) { newValue in
                    completer.query(newValue)
                }

            if !text.isEmpty {
                Button(action: {
                    text = ""
                    completer.query("")
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    focused ? Theme.primary.opacity(0.55) : Theme.hairline,
                    lineWidth: 1
                )
        )
    }

    // MARK: - 结果

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    shortcuts
                } else {
                    ForEach(Array(completer.results.enumerated()), id: \.offset) { pair in
                        Button(action: { pick(pair.element) }) {
                            row(
                                symbol: "mappin.circle.fill",
                                title: pair.element.title,
                                subtitle: pair.element.subtitle
                            )
                        }
                        .buttonStyle(.plain)

                        if pair.offset < completer.results.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }

                    if completer.results.isEmpty {
                        emptyState
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var shortcuts: some View {
        VStack(spacing: 0) {
            Button(action: { useCurrentLocation() }) {
                row(
                    symbol: "location.fill",
                    title: currentActionTitle,
                    subtitle: model.coordinate == nil ? "等待定位…" : Fmt.coordinate(model.coordinate!)
                )
            }
            .buttonStyle(.plain)

            if target == .destination {
                Divider().padding(.leading, 48)
                Button(action: { model.swapEndpoints(); dismiss() }) {
                    row(symbol: "arrow.up.arrow.down", title: "交换起终点", subtitle: "当前终点作为起点")
                }
                .buttonStyle(.plain)
            }

            if target == .destination && model.coordinate != nil {
                Divider().padding(.leading, 48)
                Button(action: {
                    model.saveCurrentAsFavorite()
                    dismiss()
                }) {
                    row(symbol: "star.fill", title: "把当前位置存入收藏", subtitle: "下次可一键设为终点")
                }
                .buttonStyle(.plain)
            }

            if !favorites.items.isEmpty {
                HStack {
                    Text("收藏地点")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.faint)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 6)

                ForEach(favorites.items) { favorite in
                    HStack(spacing: 0) {
                        Button(action: { apply(coordinate: favorite.coordinate, name: favorite.name) }) {
                            row(symbol: "star.circle.fill", title: favorite.name, subtitle: Fmt.coordinate(favorite.coordinate))
                        }
                        .buttonStyle(.plain)

                        Button(action: { favorites.remove(favorite) }) {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.faint)
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                    }
                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    private var currentActionTitle: String {
        switch target {
        case .destination: return "使用当前位置作为终点"
        case .waypoint: return "把当前位置设为途经点"
        case .start: return "从当前位置出发"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundColor(Theme.faint.opacity(0.7))
            Text(completer.querying ? "搜索中…" : "没有匹配结果，换个关键词试试")
                .font(.system(size: 12))
                .foregroundColor(Theme.faint)
            Text("也可以在地图上长按直接选点")
                .font(.system(size: 11))
                .foregroundColor(Theme.faint.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }

    private func row(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundColor(Theme.primary.opacity(0.85))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - 动作

    private func pick(_ completion: MKLocalSearchCompletion) {
        busy = true
        completer.resolve(completion) { item in
            busy = false
            guard let item = item else { return }
            apply(coordinate: item.placemark.coordinate, name: item.name ?? completion.title)
        }
    }

    private func apply(coordinate: CLLocationCoordinate2D, name: String) {
        switch target {
        case .destination:
            model.setDestination(coordinate, name: name)
        case .waypoint:
            model.addWaypoint(coordinate, name: name)
        case .start:
            model.setStart(coordinate, name: name)
        }
        dismiss()
    }

    private func useCurrentLocation() {
        guard let coordinate = model.coordinate else { return }
        switch target {
        case .destination:
            model.setDestination(coordinate, name: "我的位置")
        case .waypoint:
            model.addWaypoint(coordinate, name: "我的位置")
        case .start:
            model.useCurrentAsStart()
        }
        dismiss()
    }
}

/// MKLocalSearchCompleter 包装：搜索补全 + 结果解析
final class PlaceCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {

    @Published var results: [MKLocalSearchCompletion] = []
    @Published private(set) var querying = false

    private let completer = MKLocalSearchCompleter()
    private var search: MKLocalSearch?
    private var pendingQuery: String?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 34.0, longitude: 108.0),
            span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40)
        )
    }

    func updateRegion(around coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 60000,
            longitudinalMeters: 60000
        )
    }

    func query(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingQuery = trimmed
        guard !trimmed.isEmpty else {
            results = []
            querying = false
            return
        }
        querying = true
        completer.queryFragment = trimmed
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        querying = false
        results = Array(completer.results.prefix(20))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        querying = false
        results = []
    }

    func resolve(_ completion: MKLocalSearchCompletion, done: @escaping (MKMapItem?) -> Void) {
        search?.cancel()
        let request = MKLocalSearch.Request(completion: completion)
        let localSearch = MKLocalSearch(request: request)
        search = localSearch
        localSearch.start { response, _ in
            DispatchQueue.main.async {
                done(response?.mapItems.first)
            }
        }
    }
}
