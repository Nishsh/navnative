import SwiftUI
import MapKit
import UIKit
import CoreLocation

/// 原生地图画布：MKMapView 包装，负责相机跟随、路线/轨迹绘制、精度圈、长按选点
struct MapCanvas: UIViewRepresentable {
    @ObservedObject var model: NavModel

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .standard
        map.showsBuildings = true
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = true
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.pointOfInterestFilter = .includingAll
        // iOS 13+ 自动跟随系统深浅色
        map.overrideUserInterfaceStyle = .unspecified

        // 定位到来前的占位视野（不写死上海，用全国视野避免"地图跳到别处"的错觉）
        let fallback = CLLocationCoordinate2D(latitude: 34.0, longitude: 108.0)
        let camera = MKMapCamera(lookingAtCenter: fallback, fromDistance: 4_200_000, pitch: 0, heading: 0)
        map.setCamera(camera, animated: false)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        longPress.delegate = context.coordinator
        map.addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)

        context.coordinator.map = map
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncAppearance(on: mapView)
        context.coordinator.syncPins(on: mapView)
        context.coordinator.syncRoute(on: mapView)
        context.coordinator.syncTrail(on: mapView)
        context.coordinator.syncAccuracy(on: mapView)
        context.coordinator.syncFit(on: mapView)
        context.coordinator.syncCamera(on: mapView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        var parent: MapCanvas
        weak var map: MKMapView?

        private var appliedRouteRevision = -1
        private var appliedTrailCount = -1
        private var appliedTrailEnabled = true
        private var appliedFitRequest = -1

        private var lastCenter: CLLocationCoordinate2D?
        private var lastHeading: Double = .infinity
        private var lastDistance: Double = -1
        private var lastPitch: CGFloat = -1
        private var lastCameraAt = Date.distantPast
        private var forceCameraUpdate = true

        private var routeOverlay: MKPolyline?
        private var trailOverlay: MKPolyline?
        private var accuracyOverlay: MKCircle?
        private var accuracyRadiusApplied: Double = -1
        private var accuracyCenterApplied: CLLocationCoordinate2D?

        private var startPin: MKPointAnnotation?
        private var endPin: MKPointAnnotation?
        private var waypointPins: [UUID: MKPointAnnotation] = [:]

        init(parent: MapCanvas) {
            self.parent = parent
            super.init()
        }

        // MARK: 标注

        func syncPins(on mapView: MKMapView) {
            let model = parent.model

            if let coordinate = model.startCoordinate {
                if let pin = startPin {
                    pin.coordinate = coordinate
                } else {
                    let pin = MKPointAnnotation()
                    pin.coordinate = coordinate
                    pin.title = "起点"
                    mapView.addAnnotation(pin)
                    startPin = pin
                }
            } else if let pin = startPin {
                mapView.removeAnnotation(pin)
                startPin = nil
            }

            if let coordinate = model.endCoordinate {
                if let pin = endPin {
                    pin.coordinate = coordinate
                } else {
                    let pin = MKPointAnnotation()
                    pin.coordinate = coordinate
                    pin.title = "终点"
                    mapView.addAnnotation(pin)
                    endPin = pin
                }
            } else if let pin = endPin {
                mapView.removeAnnotation(pin)
                endPin = nil
            }

            // 途经点（v5）
            var seen = Set<UUID>()
            for (index, waypoint) in model.waypoints.enumerated() {
                seen.insert(waypoint.id)
                if let pin = waypointPins[waypoint.id] {
                    pin.coordinate = waypoint.coordinate
                    pin.title = "途经点\(index + 1)"
                } else {
                    let pin = MKPointAnnotation()
                    pin.coordinate = waypoint.coordinate
                    pin.title = "途经点\(index + 1)"
                    mapView.addAnnotation(pin)
                    waypointPins[waypoint.id] = pin
                }
            }
            for (id, pin) in waypointPins where !seen.contains(id) {
                mapView.removeAnnotation(pin)
                waypointPins.removeValue(forKey: id)
            }
        }

        // MARK: 路线

        func syncRoute(on mapView: MKMapView) {
            let model = parent.model
            guard appliedRouteRevision != model.routeRevision else { return }
            appliedRouteRevision = model.routeRevision

            if let old = routeOverlay {
                mapView.removeOverlay(old)
                routeOverlay = nil
            }

            guard let option = model.selectedOption else { return }
            routeOverlay = option.polyline
            mapView.addOverlay(option.polyline, level: .aboveRoads)
        }

        // MARK: 轨迹

        func syncTrail(on mapView: MKMapView) {
            let model = parent.model
            let enabled = SettingsStore.shared.showTrail
            guard appliedTrailCount != model.trail.count || appliedTrailEnabled != enabled else { return }
            appliedTrailCount = model.trail.count
            appliedTrailEnabled = enabled

            if let old = trailOverlay {
                mapView.removeOverlay(old)
                trailOverlay = nil
            }
            guard enabled, model.trail.count > 1 else { return }

            var coordinates = model.trail
            let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            trailOverlay = line
            mapView.addOverlay(line, level: .aboveRoads)
        }

        // MARK: 精度圈（v2）

        func syncAccuracy(on mapView: MKMapView) {
            let model = parent.model

            guard let radius = model.accuracyRadius, let center = model.coordinate else {
                if let old = accuracyOverlay {
                    mapView.removeOverlay(old)
                    accuracyOverlay = nil
                    accuracyRadiusApplied = -1
                }
                return
            }

            let centerMoved: Bool
            if let applied = accuracyCenterApplied {
                centerMoved = Geo.distance(applied, center) > 3
            } else {
                centerMoved = true
            }
            let radiusChanged = abs(radius - accuracyRadiusApplied) > max(2, radius * 0.12)
            guard centerMoved || radiusChanged else { return }

            if let old = accuracyOverlay {
                mapView.removeOverlay(old)
            }
            let circle = MKCircle(center: center, radius: radius)
            mapView.addOverlay(circle, level: .aboveRoads)
            accuracyOverlay = circle
            accuracyRadiusApplied = radius
            accuracyCenterApplied = center
        }

        // MARK: 视野适配

        func syncFit(on mapView: MKMapView) {
            let model = parent.model
            guard appliedFitRequest != model.fitRequest else { return }
            guard let option = model.selectedOption else {
                appliedFitRequest = model.fitRequest
                return
            }
            appliedFitRequest = model.fitRequest

            let padding = UIEdgeInsets(top: 150, left: 48, bottom: 300, right: 48)
            mapView.setVisibleMapRect(option.polyline.boundingMapRect, edgePadding: padding, animated: true)
            lastCenter = nil
        }

        // MARK: 相机跟随

        func syncCamera(on mapView: MKMapView) {
            let model = parent.model

            guard model.following, let coordinate = model.coordinate else {
                forceCameraUpdate = true
                return
            }

            // 节流：相机动画 0.3s 内不重复打断
            let elapsed = Date().timeIntervalSince(lastCameraAt)
            let moved = lastCenter.map { Geo.distance($0, coordinate) > 2.5 } ?? true
            let headingChanged = lastHeading.isInfinite
                || abs(Geo.angleDelta(lastHeading, model.cameraHeading)) > 1.2
            let distanceChanged = abs(lastDistance - model.zoomDistance) > 25
            let pitchChanged = abs(lastPitch - model.pitch) > 2.0

            guard forceCameraUpdate || ((moved || headingChanged || distanceChanged || pitchChanged) && elapsed > 0.3) else {
                return
            }

            // 精度差的时候别跟着抖动坐标狂奔
            let target = coordinate
            let camera = MKMapCamera(
                lookingAtCenter: target,
                fromDistance: model.zoomDistance,
                pitch: model.pitch,
                heading: model.cameraHeading
            )
            mapView.setCamera(camera, animated: true)

            forceCameraUpdate = false
            lastCameraAt = Date()
            lastCenter = target
            lastHeading = model.cameraHeading
            lastDistance = model.zoomDistance
            lastPitch = model.pitch
        }

        // MARK: 外观

        func syncAppearance(on mapView: MKMapView) {
            let model = parent.model
            // 跟随时用车标替代系统蓝点，避免两个标记重叠
            let showsUser = !model.following
            if mapView.showsUserLocation != showsUser {
                mapView.showsUserLocation = showsUser
            }
            // 导航时用低饱和底图，突出路线
            let type: MKMapType = model.navigating ? .mutedStandard : .standard
            if mapView.mapType != type {
                mapView.mapType = type
            }
            if !mapView.showsBuildings {
                mapView.showsBuildings = true
            }
            if mapView.isPitchEnabled != model.tiltEnabled {
                mapView.isPitchEnabled = model.tiltEnabled
            }
        }

        // MARK: 手势

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.model.following = false
            parent.model.setDestination(coordinate)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began, parent.model.following {
                parent.model.following = false
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began, parent.model.following {
                parent.model.following = false
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.10)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.35)
                renderer.lineWidth = 1
                return renderer
            }

            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round

            if let route = routeOverlay, route === line {
                renderer.strokeColor = UIColor(red: 0.00, green: 0.42, blue: 0.98, alpha: 0.95)
                renderer.lineWidth = 7
            } else if let trail = trailOverlay, trail === line {
                renderer.strokeColor = UIColor(red: 0.31, green: 0.28, blue: 0.90, alpha: 0.45)
                renderer.lineWidth = 4
            } else {
                renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.5)
                renderer.lineWidth = 3
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation else { return nil }

            let identifier = "nav-pin"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            if view == nil {
                view = MKMarkerAnnotationView(annotation: point, reuseIdentifier: identifier)
                view?.canShowCallout = false
                view?.animatesWhenAdded = true
                view?.displayPriority = .required
            }
            view?.annotation = point

            let title = point.title ?? ""
            if title.hasPrefix("途经点") {
                view?.markerTintColor = UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
                let number = title.replacingOccurrences(of: "途经点", with: "")
                view?.glyphText = number.isEmpty ? "•" : number
                view?.glyphImage = nil
            } else if title == "起点" {
                view?.markerTintColor = UIColor(red: 0.06, green: 0.72, blue: 0.51, alpha: 1)
                view?.glyphImage = UIImage(systemName: "circle.fill")
                view?.glyphText = nil
            } else {
                view?.markerTintColor = UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1)
                view?.glyphImage = UIImage(systemName: "flag.fill")
                view?.glyphText = nil
            }
            return view
        }
    }
}
