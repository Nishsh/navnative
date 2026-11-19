import Foundation
import MapKit
import CoreLocation

// MARK: - 地理工具

enum Geo {
    static let metersPerDegreeLat: Double = 111_320

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb)
    }

    /// 角度差归一化到 (-180, 180]
    static func angleDelta(_ from: Double, _ to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// 角度插值：走最短弧，避免 359° → 1° 时反向转一圈
    static func lerpAngle(_ from: Double, _ to: Double, factor: Double) -> Double {
        let f = min(max(factor, 0), 1)
        var result = from + angleDelta(from, to) * f
        result = result.truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }

    /// 方位角（真北 0°，顺时针）
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * Double.pi / 180
        let lat2 = b.latitude * Double.pi / 180
        let dLon = (b.longitude - a.longitude) * Double.pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var deg = atan2(y, x) * 180 / Double.pi
        if deg < 0 { deg += 360 }
        return deg
    }

    /// 点到线段的距离（等距圆柱投影，短距离内误差可忽略）
    static func distanceToSegment(_ p: CLLocationCoordinate2D,
                                  _ a: CLLocationCoordinate2D,
                                  _ b: CLLocationCoordinate2D) -> Double {
        let latRef = a.latitude * Double.pi / 180
        let kx = cos(latRef) * metersPerDegreeLat
        let ky = metersPerDegreeLat

        func project(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            ((c.longitude - a.longitude) * kx, (c.latitude - a.latitude) * ky)
        }

        let (px, py) = project(p)
        let (bx, by) = project(b)
        let length2 = bx * bx + by * by
        if length2 < 0.0001 {
            return sqrt(px * px + py * py)
        }
        var t = (px * bx + py * by) / length2
        t = min(max(t, 0), 1)
        let dx = px - bx * t
        let dy = py - by * t
        return sqrt(dx * dx + dy * dy)
    }
}

extension MKPolyline {
    var allCoordinates: [CLLocationCoordinate2D] {
        let count = pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    var lastCoordinate: CLLocationCoordinate2D? {
        allCoordinates.last
    }
}

// MARK: - 路线模型

struct RouteStep {
    let instruction: String
    let distance: CLLocationDistance
    /// 该 step 的终点坐标
    let endCoordinate: CLLocationCoordinate2D?
    let polyline: MKPolyline

    /// 转向方向，用于顶部箭头图标
    var maneuverSymbol: String {
        let text = instruction
        if text.contains("到达") || text.contains("抵达") { return "flag.checkered" }
        if text.contains("掉头") { return "arrow.uturn.left" }
        if text.contains("环岛") || text.contains("转盘") { return "arrow.triangle.turn.up.right.circle.fill" }
        if text.contains("右转") || text.contains("向右") || text.contains("靠右") { return "arrow.turn.up.right" }
        if text.contains("左转") || text.contains("向左") || text.contains("靠左") { return "arrow.turn.up.left" }
        if text.contains("出口") || text.contains("匝道") { return "arrow.up.right" }
        if text.contains("高速") { return "arrow.up" }
        return "arrow.up"
    }

    /// 播报用的短句（去掉括号里的路名等冗余）
    var spokenText: String {
        InstructionText.clean(instruction)
    }
}

/// 指令文案处理
enum InstructionText {

    /// MKRoute 的中文指令里常带「在XX路向左转」，播报时保留但压缩长度
    static func clean(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "\n", with: " ")
        value = value.replacingOccurrences(of: "  ", with: " ")
        if value.count > 40 {
            value = String(value.prefix(40))
        }
        return value
    }

    /// 只保留动作部分（用于「然后」）
    static func actionOnly(_ text: String) -> String {
        for keyword in ["向左转", "向右转", "掉头", "靠左", "靠右", "直行", "到达目的地", "到达"] {
            if text.contains(keyword) { return keyword }
        }
        return clean(text)
    }
}

struct RouteOption: Identifiable {
    let id: Int
    let title: String
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let polyline: MKPolyline
    let steps: [RouteStep]
    /// 原始 MKRoute（多途经点拼接时没有单一 route，为 nil）
    let route: MKRoute?
    /// 途经点数量
    let waypointCount: Int

    /// 沿折线计算到终点的剩余里程
    func remainingLength(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let pts = polyline.allCoordinates
        guard pts.count > 1 else { return 0 }

        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, p) in pts.enumerated() {
            let d = Geo.distance(p, coordinate)
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            }
        }

        var total = Geo.distance(coordinate, pts[bestIndex])
        var i = bestIndex
        while i < pts.count - 1 {
            total += Geo.distance(pts[i], pts[i + 1])
            i += 1
        }
        return total
    }

    /// 到路线的最短距离（偏航检测用）
    func distanceToPolyline(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let pts = polyline.allCoordinates
        guard pts.count > 1 else {
            return pts.first.map { Geo.distance($0, coordinate) } ?? .greatestFiniteMagnitude
        }
        var best = Double.greatestFiniteMagnitude
        var i = 0
        while i < pts.count - 1 {
            let d = Geo.distanceToSegment(coordinate, pts[i], pts[i + 1])
            if d < best { best = d }
            i += 1
        }
        return best
    }

    /// 前方 N 米内是否有转向（语音提示用）
    func upcomingTurn(from coordinate: CLLocationCoordinate2D, stepIndex: Int) -> (distance: Double, step: RouteStep)? {
        guard steps.indices.contains(stepIndex) else { return nil }
        let step = steps[stepIndex]
        let remaining = distanceToStepEnd(from: coordinate, stepIndex: stepIndex)
        return (remaining, step)
    }

    /// 当前位置对应的 step 序号（只在 [current, current+2] 内前进，避免折返跳步）
    func advancedStepIndex(from current: Int, coordinate: CLLocationCoordinate2D) -> Int {
        guard !steps.isEmpty else { return 0 }

        // 防御：current 可能来自旧路线，先夹到合法区间，避免构造非法 Range 崩溃
        let safeCurrent = min(max(current, 0), steps.count - 1)
        let upper = min(steps.count - 1, safeCurrent + 2)

        var best = safeCurrent
        var bestDistance = Double.greatestFiniteMagnitude
        for i in safeCurrent...upper {
            let pts = steps[i].polyline.allCoordinates
            for p in pts {
                let d = Geo.distance(p, coordinate)
                if d < bestDistance {
                    bestDistance = d
                    best = i
                }
            }
        }
        return best
    }

    /// 当前 step 剩余距离（到该 step 终点）
    func distanceToStepEnd(from coordinate: CLLocationCoordinate2D, stepIndex: Int) -> CLLocationDistance {
        guard steps.indices.contains(stepIndex) else { return 0 }
        let pts = steps[stepIndex].polyline.allCoordinates
        guard !pts.isEmpty else { return 0 }

        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, p) in pts.enumerated() {
            let d = Geo.distance(p, coordinate)
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            }
        }

        var total = Geo.distance(coordinate, pts[bestIndex])
        var i = bestIndex
        while i < pts.count - 1 {
            total += Geo.distance(pts[i], pts[i + 1])
            i += 1
        }
        return total
    }
}

enum RouteError: LocalizedError {
    case empty
    case noLocation
    case tooFar
    case legFailed(Int)

    var errorDescription: String? {
        switch self {
        case .empty: return "没有找到可用路线，换个终点再试"
        case .noLocation: return "还没有定位结果，请等待定位成功"
        case .tooFar: return "目的地太远，超出单次规划距离"
        case .legFailed(let index): return "第 \(index) 段路线规划失败"
        }
    }
}

// MARK: - 路线偏好

struct RoutePreferences {
    var transport: MKDirectionsTransportType = .automobile
    var avoidHighways = false
    var avoidTolls = false
    var wantsAlternatives = true

    static func fromSettings() -> RoutePreferences {
        let settings = SettingsStore.shared
        var prefs = RoutePreferences()
        prefs.transport = settings.travelMode == .walking ? .walking : .automobile
        prefs.avoidHighways = settings.avoidHighways
        prefs.avoidTolls = settings.avoidTolls
        prefs.wantsAlternatives = settings.travelMode != .walking
        return prefs
    }
}

// MARK: - 路线规划

final class RouteEngine {

    private var activeCalcs: [MKDirections] = []

    /// 规划（支持途经点，v5）
    func plan(from origin: CLLocationCoordinate2D,
              to destination: CLLocationCoordinate2D,
              via waypoints: [CLLocationCoordinate2D] = [],
              preferences: RoutePreferences = RoutePreferences(),
              completion: @escaping (Result<[RouteOption], Error>) -> Void) {

        cancel()

        var points: [CLLocationCoordinate2D] = [origin]
        points.append(contentsOf: waypoints)
        points.append(destination)

        var pairs: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        var i = 0
        while i < points.count - 1 {
            pairs.append((points[i], points[i + 1]))
            i += 1
        }
        guard !pairs.isEmpty else {
            completion(.failure(RouteError.noLocation))
            return
        }

        // 无途经点：一次请求多方案
        if pairs.count == 1, preferences.wantsAlternatives {
            requestLeg(from: pairs[0].0,
                       to: pairs[0].1,
                       preferences: preferences,
                       alternatives: true) { result in
                switch result {
                case .success(let routes):
                    let options = routes.enumerated().map { pair -> RouteOption in
                        self.makeOption(route: pair.element,
                                        index: pair.offset,
                                        title: RouteEngine.title(for: pair.element, index: pair.offset, total: routes.count),
                                        waypointCount: 0)
                    }
                    completion(.success(options))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            return
        }

        // 有途经点：逐段请求后拼接
        collectLegs(pairs: pairs,
                    index: 0,
                    accumulated: [],
                    preferences: preferences) { result in
            switch result {
            case .success(let legs):
                guard let combined = self.combine(legs: legs, waypointCount: waypoints.count) else {
                    completion(.failure(RouteError.empty))
                    return
                }
                completion(.success([combined]))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        for calc in activeCalcs { calc.cancel() }
        activeCalcs.removeAll()
    }

    // MARK: - 单段请求

    private func requestLeg(from: CLLocationCoordinate2D,
                            to: CLLocationCoordinate2D,
                            preferences: RoutePreferences,
                            alternatives: Bool,
                            completion: @escaping (Result<[MKRoute], Error>) -> Void) {

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = preferences.transport
        request.requestsAlternateRoutes = alternatives

        if #available(iOS 16.0, *) {
            if preferences.avoidHighways { request.highwayPreference = .avoid }
            if preferences.avoidTolls { request.tollPreference = .avoid }
        }

        let calculator = MKDirections(request: request)
        activeCalcs.append(calculator)

        calculator.calculate { [weak self] response, error in
            DispatchQueue.main.async {
                self?.activeCalcs.removeAll { $0 === calculator }

                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let response = response, !response.routes.isEmpty else {
                    completion(.failure(RouteError.empty))
                    return
                }
                completion(.success(response.routes))
            }
        }
    }

    private func collectLegs(pairs: [(CLLocationCoordinate2D, CLLocationCoordinate2D)],
                             index: Int,
                             accumulated: [MKRoute],
                             preferences: RoutePreferences,
                             completion: @escaping (Result<[MKRoute], Error>) -> Void) {
        guard index < pairs.count else {
            completion(.success(accumulated))
            return
        }

        let pair = pairs[index]
        requestLeg(from: pair.0, to: pair.1, preferences: preferences, alternatives: false) { result in
            switch result {
            case .success(let routes):
                guard let route = routes.first else {
                    completion(.failure(RouteError.legFailed(index + 1)))
                    return
                }
                self.collectLegs(pairs: pairs,
                                 index: index + 1,
                                 accumulated: accumulated + [route],
                                 preferences: preferences,
                                 completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - 组装

    private func makeOption(route: MKRoute, index: Int, title: String, waypointCount: Int) -> RouteOption {
        let steps: [RouteStep] = route.steps.map { step in
            RouteStep(
                instruction: step.instructions.isEmpty ? "继续直行" : step.instructions,
                distance: step.distance,
                endCoordinate: step.polyline.lastCoordinate,
                polyline: step.polyline
            )
        }
        return RouteOption(
            id: index,
            title: title,
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            polyline: route.polyline,
            steps: steps,
            route: route,
            waypointCount: waypointCount
        )
    }

    private func combine(legs: [MKRoute], waypointCount: Int) -> RouteOption? {
        guard !legs.isEmpty else { return nil }

        var coordinates: [CLLocationCoordinate2D] = []
        var steps: [RouteStep] = []
        var distance: Double = 0
        var travelTime: Double = 0

        for leg in legs {
            let legPoints = leg.polyline.allCoordinates
            for point in legPoints {
                if let last = coordinates.last, Geo.distance(last, point) < 0.5 { continue }
                coordinates.append(point)
            }
            for step in leg.steps {
                steps.append(
                    RouteStep(
                        instruction: step.instructions.isEmpty ? "继续直行" : step.instructions,
                        distance: step.distance,
                        endCoordinate: step.polyline.lastCoordinate,
                        polyline: step.polyline
                    )
                )
            }
            distance += leg.distance
            travelTime += leg.expectedTravelTime
        }

        guard coordinates.count > 1 else { return nil }
        var coords = coordinates
        let line = MKPolyline(coordinates: &coords, count: coords.count)

        return RouteOption(
            id: 0,
            title: waypointCount > 0 ? "经 \(waypointCount) 个途经点" : "推荐路线",
            distance: distance,
            expectedTravelTime: travelTime,
            polyline: line,
            steps: steps,
            route: nil,
            waypointCount: waypointCount
        )
    }

    /// 路线命名：最短时间那条叫「推荐」，其余按序号
    private static func title(for route: MKRoute, index: Int, total: Int) -> String {
        if total <= 1 { return "推荐路线" }
        if index == 0 { return "推荐路线" }
        return "备选方案 \(index + 1)"
    }
}
