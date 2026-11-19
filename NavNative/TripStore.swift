import Foundation
import Combine
import CoreLocation

// MARK: - 轨迹点

struct TripPoint: Codable {
    var lat: Double
    var lon: Double
    /// 相对行程起点的秒数
    var t: Double
    var alt: Double
    var speed: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - 行程记录

struct TripRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date
    var distance: Double          // 米
    var maxSpeed: Double          // m/s
    var avgSpeed: Double          // m/s
    var ascent: Double            // 米
    var descent: Double           // 米
    var startName: String
    var endName: String
    var modeTitle: String
    var points: [TripPoint]

    var duration: TimeInterval { max(endedAt.timeIntervalSince(startedAt), 0) }

    var polyline: [CLLocationCoordinate2D] { points.map { $0.coordinate } }
}

// MARK: - 录制器

/// 行程录制（v4）：里程、极速、均速、海拔升降
final class TripRecorder {

    private(set) var active = false
    private(set) var distance: Double = 0
    private(set) var maxSpeed: Double = 0
    private(set) var ascent: Double = 0
    private(set) var descent: Double = 0
    private(set) var startedAt: Date?
    private(set) var points: [TripPoint] = []

    var startName = "我的位置"
    var endName = ""

    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastAltitude: Double?
    private var lastRecordAt = Date.distantPast
    private var lastFixAt: Date?

    func start(at coordinate: CLLocationCoordinate2D?, name: String) {
        active = true
        distance = 0
        maxSpeed = 0
        ascent = 0
        descent = 0
        points.removeAll()
        startedAt = Date()
        startName = name
        endName = ""
        lastCoordinate = coordinate
        lastAltitude = nil
        lastRecordAt = .distantPast
        lastFixAt = nil

        if let coordinate = coordinate {
            points.append(TripPoint(lat: coordinate.latitude, lon: coordinate.longitude,
                                    t: 0, alt: 0, speed: 0))
        }
    }

    func ingest(_ fix: FusedFix) {
        guard active, let startedAt = startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        lastFixAt = Date()

        // 里程
        if let last = lastCoordinate {
            let d = Geo.distance(last, fix.coordinate)
            // 融合器已滤跳点，这里再守一道：单次位移超过 300m 不计
            if d > 1.5 && d < 300 {
                distance += d
            }
        }
        lastCoordinate = fix.coordinate

        // 极速
        if fix.speed.isFinite, fix.speed > maxSpeed, fix.speed < 90 {
            maxSpeed = fix.speed
        }

        // 海拔升降（3m 迟滞，避免气压噪声）
        if fix.altitude.isFinite, fix.altitude != 0 {
            if let lastAlt = lastAltitude {
                let diff = fix.altitude - lastAlt
                if abs(diff) > 3 {
                    if diff > 0 { ascent += diff } else { descent += -diff }
                    lastAltitude = fix.altitude
                }
            } else {
                lastAltitude = fix.altitude
            }
        }

        // 采样：位移 6m 或 5s
        let needsRecord: Bool
        if let lastPoint = points.last {
            let moved = Geo.distance(lastPoint.coordinate, fix.coordinate)
            needsRecord = moved > 6 || Date().timeIntervalSince(lastRecordAt) > 5
        } else {
            needsRecord = true
        }
        guard needsRecord else { return }

        lastRecordAt = Date()
        points.append(
            TripPoint(
                lat: fix.coordinate.latitude,
                lon: fix.coordinate.longitude,
                t: elapsed,
                alt: fix.altitude,
                speed: fix.speed
            )
        )
        if points.count > 30000 {
            points.removeFirst(points.count - 30000)
        }
    }

    /// 结束并产出记录；不足 20 米或不足 15 秒的行程直接丢弃
    func finish(endName: String? = nil) -> TripRecord? {
        guard active, let startedAt = startedAt else { return nil }
        active = false

        let ended = Date()
        let duration = ended.timeIntervalSince(startedAt)
        if let name = endName { self.endName = name }
        if self.endName.isEmpty { self.endName = "终点" }

        defer {
            points.removeAll()
            lastCoordinate = nil
            lastAltitude = nil
            self.startedAt = nil
        }

        guard distance > 20, duration > 15 else { return nil }

        return TripRecord(
            startedAt: startedAt,
            endedAt: ended,
            distance: distance,
            maxSpeed: maxSpeed,
            avgSpeed: duration > 0 ? distance / duration : 0,
            ascent: ascent,
            descent: descent,
            startName: startName,
            endName: self.endName,
            modeTitle: SettingsStore.shared.travelMode.title,
            points: points
        )
    }

    func cancel() {
        active = false
        points.removeAll()
        startedAt = nil
        lastCoordinate = nil
    }
}

// MARK: - 行程存储

final class TripStore: ObservableObject {

    static let shared = TripStore()

    @Published private(set) var trips: [TripRecord] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("trips.json")
    }()

    private init() {
        load()
    }

    func add(_ record: TripRecord) {
        trips.insert(record, at: 0)
        if trips.count > 200 { trips.removeLast(trips.count - 200) }
        persist()
    }

    func delete(_ record: TripRecord) {
        trips.removeAll { $0.id == record.id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where trips.indices.contains(index) {
            trips.remove(at: index)
        }
        persist()
    }

    func clear() {
        trips.removeAll()
        persist()
    }

    var totalDistance: Double { trips.reduce(0) { $0 + $1.distance } }
    var totalDuration: TimeInterval { trips.reduce(0) { $0 + $1.duration } }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([TripRecord].self, from: data) {
            trips = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(trips) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - GPX 导出

    func exportGPX(_ record: TripRecord) -> URL? {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="NavNative" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><name>\(escape(record.startName)) → \(escape(record.endName))</name>
        <time>\(iso(record.startedAt))</time></metadata>
        <trk><name>\(escape(record.startName)) → \(escape(record.endName))</name><type>\(escape(record.modeTitle))</type><trkseg>

        """
        for point in record.points {
            let time = iso(record.startedAt.addingTimeInterval(point.t))
            xml += """
            <trkpt lat="\(point.lat)" lon="\(point.lon)"><ele>\(String(format: "%.1f", point.alt))</ele><time>\(time)</time></trkpt>

            """
        }
        xml += "</trkseg></trk></gpx>"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "Trip-\(formatter.string(from: record.startedAt)).gpx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - 收藏夹

struct Favorite: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var createdAt: Date = Date()

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

final class FavoritesStore: ObservableObject {

    static let shared = FavoritesStore()

    @Published private(set) var items: [Favorite] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("favorites.json")
    }()

    private init() {
        load()
    }

    func add(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名地点" : trimmed
        // 同位置 30m 内视为重复
        if items.contains(where: { Geo.distance($0.coordinate, coordinate) < 30 }) { return }
        items.insert(Favorite(name: finalName, lat: coordinate.latitude, lon: coordinate.longitude), at: 0)
        if items.count > 100 { items.removeLast(items.count - 100) }
        persist()
    }

    func remove(_ favorite: Favorite) {
        items.removeAll { $0.id == favorite.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Favorite].self, from: data) {
            items = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
