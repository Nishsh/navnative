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
        if text.contains("右转") || text.contains("向右") { return "arrow.turn.up.right" }
        if text.contains("左转") || text.contains("向左") { return "arrow.turn.up.left" }
        if text.contains("环岛") || text.contains("转盘") { return "arrow.triangle.turn.up.right.circle" }
        if text.contains("掉头") { return "arrow.uturn.left" }
        if text.contains("到达") || text.contains("抵达") { return "flag.checkered" }
        if text.contains("高速") || text.contains("出口") { return "arrow.up.right" }
        return "arrow.up"
    }
}

struct RouteOption: Identifiable {
    let id: Int
    let title: String
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let polyline: MKPolyline
    let steps: [RouteStep]
    /// 原始 MKRoute，拿它算 step 级进度
    let route: MKRoute

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
        guard let last = pts.last else { return 0 }

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
        _ = last
        return total
    }
}

enum RouteError: LocalizedError {
    case empty
    case noLocation

    var errorDescription: String? {
        switch self {
        case .empty: return "没有找到可用路线，换个终点再试"
        case .noLocation: return "还没有定位结果，请等待定位成功"
        }
    }
}

// MARK: - 路线规划

final class RouteEngine {
    private var directions: MKDirections?

    func plan(from: CLLocationCoordinate2D,
              to: CLLocationCoordinate2D,
              transport: MKDirectionsTransportType = .automobile,
              completion: @escaping (Result<[RouteOption], Error>) -> Void) {

        directions?.cancel()

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = transport
        request.requestsAlternateRoutes = true

        let calculator = MKDirections(request: request)
        directions = calculator

        calculator.calculate { response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let response = response, !response.routes.isEmpty else {
                    completion(.failure(RouteError.empty))
                    return
                }

                let options: [RouteOption] = response.routes.enumerated().map { pair -> RouteOption in
                    let index = pair.offset
                    let route = pair.element
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
                        title: RouteEngine.title(for: route, index: index, total: response.routes.count),
                        distance: route.distance,
                        expectedTravelTime: route.expectedTravelTime,
                        polyline: route.polyline,
                        steps: steps,
                        route: route
                    )
                }
                completion(.success(options))
            }
        }
    }

    func cancel() {
        directions?.cancel()
        directions = nil
    }

    /// 路线命名：最短时间那条叫「推荐」，其余按序号
    private static func title(for route: MKRoute, index: Int, total: Int) -> String {
        if total <= 1 { return "推荐路线" }
        if index == 0 { return "推荐路线" }
        return "备选方案 \(index + 1)"
    }
}
