import Foundation
import CoreLocation

// MARK: - 定位质量

/// 定位质量等级（v2）
enum FixQuality: Int, Comparable {
    case unknown = 0
    case poor = 1
    case fair = 2
    case good = 3
    case excellent = 4

    static func < (lhs: FixQuality, rhs: FixQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .unknown: return "无定位"
        case .poor: return "信号差"
        case .fair: return "信号一般"
        case .good: return "信号良好"
        case .excellent: return "信号极佳"
        }
    }

    var shortTitle: String {
        switch self {
        case .unknown: return "—"
        case .poor: return "差"
        case .fair: return "一般"
        case .good: return "良好"
        case .excellent: return "极佳"
        }
    }

    /// 是否可用于导航（差于 fair 时不建议依赖）
    var usableForNavigation: Bool { self.rawValue >= FixQuality.fair.rawValue }

    static func from(accuracy: CLLocationAccuracy) -> FixQuality {
        guard accuracy > 0 else { return .unknown }
        if accuracy <= 8 { return .excellent }
        if accuracy <= 16 { return .good }
        if accuracy <= 40 { return .fair }
        if accuracy <= 150 { return .poor }
        return .unknown
    }
}

/// 融合后的定位结果
struct FusedFix {
    /// 平滑后的坐标（用于显示与导航）
    var coordinate: CLLocationCoordinate2D
    /// 原始坐标（用于诊断/记录）
    var rawCoordinate: CLLocationCoordinate2D
    var horizontalAccuracy: CLLocationAccuracy
    var verticalAccuracy: CLLocationAccuracy
    var altitude: CLLocationDistance
    /// 平滑后的速度 m/s
    var speed: CLLocationSpeed
    /// 平滑后的航向（-1 表示未知）
    var course: CLLocationDirection
    var timestamp: Date
    var quality: FixQuality
    /// 判定为静止（坐标被冻结）
    var isStationary: Bool
    /// 本次是否真的产生了位移
    var moved: Bool
}

// MARK: - 坐标系校正

/// WGS-84 ↔ GCJ-02 转换。
///
/// 说明：iOS 在中国大陆区域下，CoreLocation 返回的坐标已经与 MapKit 底图（高德数据）对齐，
/// 正常情况下**不需要**再做转换。这里提供开关，是给「坐标与道路明显偏移几百米」的场景兜底，
/// 例如设备地区设置为境外、或导入外部 GPS 轨迹时。
enum CoordinateFix {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323
    private static let pi = Double.pi

    static func outOfChina(lat: Double, lon: Double) -> Bool {
        !(lon > 73.66 && lon < 135.05 && lat > 3.86 && lat < 53.55)
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * pi) + 320.0 * sin(y * pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
        return ret
    }

    static func wgs2gcj(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if outOfChina(lat: coordinate.latitude, lon: coordinate.longitude) { return coordinate }
        let dLat = transformLat(coordinate.longitude - 105.0, coordinate.latitude - 35.0)
        let dLon = transformLon(coordinate.longitude - 105.0, coordinate.latitude - 35.0)
        let radLat = coordinate.latitude / 180.0 * pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        let dLatM = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi)
        let dLonM = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * pi)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + dLatM,
            longitude: coordinate.longitude + dLonM
        )
    }

    /// 迭代反解，误差 < 1cm
    static func gcj2wgs(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if outOfChina(lat: coordinate.latitude, lon: coordinate.longitude) { return coordinate }
        var current = coordinate
        for _ in 0..<4 {
            let shifted = wgs2gcj(current)
            current.latitude += coordinate.latitude - shifted.latitude
            current.longitude += coordinate.longitude - shifted.longitude
        }
        return current
    }

    /// GCJ-02 之间的两点距离与方位不受整体偏移影响，可直接复用 CLLocation 计算
    static func wrap(_ coordinate: CLLocationCoordinate2D,
                     altitude: Double = 0,
                     horizontalAccuracy: Double = -1,
                     course: Double = -1,
                     speed: Double = -1,
                     timestamp: Date) -> CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }
}

// MARK: - 定位融合器（v2 核心）

/// 把 CoreLocation 的原始点流变成可用的「稳定位置」。
///
/// 处理顺序：
/// 1. 丢弃无效点（精度为负、时间戳陈旧、乱序）
/// 2. 丢弃跳点（隐含速度超过 200km/h 的瞬移）
/// 3. 静止判定（低速度持续 2.5s）→ 冻结坐标，彻底消除原地抖动
/// 4. 按精度加权的一阶低通，精度越差平滑越重
/// 5. 速度/航向低通，并在航向不可信时用位移反推
final class LocationFuser {

    // 参数：集中在这里，方便调
    private struct Config {
        /// 允许的最大数据年龄（秒）
        var maxAge: TimeInterval = 8
        /// 首次定位允许的最大精度（米），冷启动放宽
        var firstAccuracyCap: CLLocationAccuracy = 500
        /// 稳定后允许的最大精度
        var accuracyCap: CLLocationAccuracy = 150
        /// 硬上限：超过直接丢弃
        var hardAccuracyCap: CLLocationAccuracy = 400
        /// 跳点判定：隐含速度阈值 m/s（55 ≈ 198km/h）
        var teleportSpeed: Double = 55
        /// 跳点判定的最小位移（米），避免小抖动误判
        var teleportMinDistance: Double = 60
        /// 静止判定速度阈值 m/s
        var stationarySpeed: Double = 0.8
        /// 静止判定持续时间
        var stationaryHold: TimeInterval = 2.5
        /// 长时间无有效点后允许降级接受的间隔
        var rescueAfter: TimeInterval = 12
    }

    private let config = Config()

    /// 每次产出有效点回调
    var onFix: ((FusedFix) -> Void)?
    /// 丢弃统计（调试用）
    private(set) var rejectedCount = 0
    private(set) var acceptedCount = 0
    private(set) var lastRejectReason: String?

    private var lastAccepted: CLLocation?
    private var lastAcceptedAt: Date?
    private var filtered: CLLocationCoordinate2D?
    private var filteredSpeed: Double = 0
    private var filteredCourse: Double = -1
    private var stationarySince: Date?
    private var isStationary = false
    private var lastFix: FusedFix?

    func reset() {
        lastAccepted = nil
        lastAcceptedAt = nil
        filtered = nil
        filteredSpeed = 0
        filteredCourse = -1
        stationarySince = nil
        isStationary = false
        lastFix = nil
        rejectedCount = 0
        acceptedCount = 0
        lastRejectReason = nil
    }

    // MARK: - 入口

    @discardableResult
    func ingest(_ location: CLLocation, now: Date = Date()) -> FusedFix? {
        let reason = validate(location, now: now)
        if let reason = reason {
            // 极端情况兜底：长时间没有任何点，宁可给一个粗位置也不要空地图
            let starved = lastAcceptedAt.map { now.timeIntervalSince($0) > config.rescueAfter } ?? true
            if !starved || location.horizontalAccuracy > config.firstAccuracyCap {
                rejectedCount += 1
                lastRejectReason = reason
                return nil
            }
        }

        let fix = buildFix(from: location, now: now)
        lastAccepted = location
        lastAcceptedAt = now
        acceptedCount += 1
        lastFix = fix
        onFix?(fix)
        return fix
    }

    // MARK: - 校验

    /// 返回 nil 表示可以接受，否则返回丢弃原因
    private func validate(_ location: CLLocation, now: Date) -> String? {
        guard location.horizontalAccuracy >= 0 else { return "精度无效" }

        let age = now.timeIntervalSince(location.timestamp)
        if age > config.maxAge { return "数据陈旧 \(Int(age))s" }
        if age < -5 { return "时间戳异常" }

        if let last = lastAccepted {
            // 乱序点
            if location.timestamp <= last.timestamp { return "时间戳重复" }

            let distance = location.distance(from: last)
            let dt = location.timestamp.timeIntervalSince(last.timestamp)

            // 跳点：短时间内出现不可能的大位移
            if dt > 0.1, dt < 8, distance > config.teleportMinDistance {
                let implied = distance / dt
                if implied > config.teleportSpeed { return "跳点 \(Int(distance))m/\(String(format: "%.1f", dt))s" }
            }

            // 精度过差的点：除非已经很久没有位置
            let cap = config.accuracyCap
            let starved = lastAcceptedAt.map { now.timeIntervalSince($0) > config.rescueAfter } ?? true
            if !starved, location.horizontalAccuracy > cap { return "精度过差 \(Int(location.horizontalAccuracy))m" }
        }

        if location.horizontalAccuracy > config.hardAccuracyCap { return "超出硬上限" }
        return nil
    }

    // MARK: - 融合

    private func buildFix(from location: CLLocation, now: Date) -> FusedFix {
        let accuracy = max(location.horizontalAccuracy, 1)
        let rawSpeed = location.speed >= 0 ? location.speed : 0

        // 1. 静止判定（带迟滞：进入 2.5s，退出即时）
        if rawSpeed < config.stationarySpeed {
            if stationarySince == nil { stationarySince = now }
        } else {
            stationarySince = nil
        }
        if let since = stationarySince, now.timeIntervalSince(since) > config.stationaryHold {
            isStationary = true
        } else if rawSpeed >= config.stationarySpeed * 1.5 {
            isStationary = false
        }

        // 2. 坐标平滑
        var output = location.coordinate
        var moved = false
        if let current = filtered {
            let distance = Geo.distance(current, location.coordinate)

            if isStationary {
                // 原地不动：只要位移没超出精度圈，就不挪车标
                if distance > max(8, accuracy * 1.2) {
                    output = interpolate(current, location.coordinate, 0.10)
                    moved = true
                } else {
                    output = current
                }
            } else {
                // 死区：小于阈值视为噪声
                let deadBand = max(1.8, min(accuracy * 0.45, 10))
                if distance < deadBand {
                    output = current
                } else {
                    let alpha = smoothingAlpha(distance: distance, accuracy: accuracy)
                    output = interpolate(current, location.coordinate, alpha)
                    moved = distance > 2 || alpha > 0.5
                }
            }
        } else {
            moved = true
        }

        // 3. 速度平滑
        var speed = filteredSpeed * 0.55 + rawSpeed * 0.45
        if isStationary { speed *= 0.55 }
        if speed < 0.25 { speed = 0 }
        filteredSpeed = speed

        // 4. 航向
        var course: Double = -1
        let courseAccuracy = location.courseAccuracy
        let courseUsable = location.course >= 0
            && speed > 1.2
            && (courseAccuracy < 0 || courseAccuracy < 60)

        if courseUsable {
            course = filteredCourse >= 0
                ? Geo.lerpAngle(filteredCourse, location.course, factor: 0.42)
                : location.course
        } else if moved, let current = filtered {
            let distance = Geo.distance(current, output)
            if distance > 3 {
                let bearing = Geo.bearing(from: current, to: output)
                course = filteredCourse >= 0 ? Geo.lerpAngle(filteredCourse, bearing, factor: 0.35) : bearing
            }
        }
        if course >= 0 { filteredCourse = course }

        filtered = output

        return FusedFix(
            coordinate: output,
            rawCoordinate: location.coordinate,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            altitude: location.altitude,
            speed: speed,
            course: course >= 0 ? course : filteredCourse,
            timestamp: location.timestamp,
            quality: FixQuality.from(accuracy: location.horizontalAccuracy),
            isStationary: isStationary,
            moved: moved
        )
    }

    private func smoothingAlpha(distance: Double, accuracy: CLLocationAccuracy) -> Double {
        // 位移明显大于精度时快速跟随，反之重压
        if distance > max(45, accuracy * 3) { return 0.85 }
        if accuracy <= 8 { return 0.50 }
        if accuracy <= 16 { return 0.38 }
        if accuracy <= 40 { return 0.24 }
        if accuracy <= 100 { return 0.14 }
        return 0.08
    }

    private func interpolate(_ from: CLLocationCoordinate2D,
                             _ to: CLLocationCoordinate2D,
                             _ t: Double) -> CLLocationCoordinate2D {
        let f = min(max(t, 0), 1)
        // 经度按纬度收敛，避免高纬度横向跳动
        let lat = from.latitude + (to.latitude - from.latitude) * f
        let lon = from.longitude + (to.longitude - from.longitude) * f
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
