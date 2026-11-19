import SwiftUI
import MapKit
import CoreLocation

struct SearchPanel: View {
    @EnvironmentObject private var model: NavModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = PlaceCompleter()

    @State private var endText = ""
    @State private var startText = ""
    @State private var busy = false
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case start
        case end
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 10) {
                fieldRow(dotColor: Theme.success, placeholder: "起点（默认当前位置）", text: $startText, field: .start)
                fieldRow(dotColor: Theme.danger, placeholder: "终点", text: $endText, field: .end)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            Divider().padding(.top, 14)

            resultsList

            Spacer(minLength: 0)
        }
        .background(Color(red: 0.97, green: 0.97, blue: 0.99))
        .onAppear {
            endText = model.endName
            if model.startCoordinate != nil { startText = model.startName }
            if !model.endName.isEmpty { completer.query(model.endName) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focused = .end
            }
        }
    }

    private var header: some View {
        HStack {
            Text("规划路线")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.ink)
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

    private func fieldRow(
        dotColor: Color,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)

            TextField(placeholder, text: text)
                .font(.system(size: 15))
                .foregroundColor(Theme.ink)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($focused, equals: field)
                .onChange(of: text.wrappedValue) { newValue in
                    guard focused == field else { return }
                    completer.query(newValue)
                }

            if field == .start {
                Button("当前位置") {
                    model.useCurrentAsStart()
                    dismiss()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    focused == field ? Theme.primary.opacity(0.55) : Color.black.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(completer.results.enumerated()), id: \.offset) { pair in
                    Button(action: { pick(pair.element) }) {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(Theme.primary.opacity(0.85))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(pair.element.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.ink)
                                    .lineLimit(1)
                                if !pair.element.subtitle.isEmpty {
                                    Text(pair.element.subtitle)
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
                    .buttonStyle(.plain)

                    if pair.offset < completer.results.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }

                if completer.results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 30))
                            .foregroundColor(Theme.faint.opacity(0.7))
                        Text("输入地名或地址搜索，也可以长按地图选点")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.faint)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 42)
                    .padding(.horizontal, 24)
                }
            }
            .padding(.top, 8)
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) {
        busy = true
        let target = focused ?? .end
        completer.resolve(completion) { item in
            busy = false
            guard let item = item else { return }
            let name = item.name ?? completion.title
            if target == .start {
                model.setStart(item.placemark.coordinate, name: name)
            } else {
                model.setDestination(item.placemark.coordinate, name: name)
            }
            dismiss()
        }
    }
}

/// MKLocalSearchCompleter 包装：搜索补全 + 结果解析
final class PlaceCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()
    private var search: MKLocalSearch?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 34.0, longitude: 108.0),
            span: MKCoordinateSpan(latitudeDelta: 45, longitudeDelta: 55)
        )
    }

    func query(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = Array(completer.results.prefix(16))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
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
