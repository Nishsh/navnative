import SwiftUI
import MapKit
import UIKit
import CoreLocation

/// 原生地图画布：MKMapView 包装，负责相机跟随、路线/轨迹绘制、长按选点
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

        // 定位到来前的占位视野
        let fallback = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let camera = MKMapCamera(lookingAtCenter: fallback, fromDistance: 30000, heading: 0, pitch: 0)
        map.setCamera(camera, animated: false)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.55
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
        context.coordinator.syncPins(on: mapView)
        context.coordinator.syncRoute(on: mapView)
        context.coordinator.syncTrail(on: mapView)
        context.coordinator.syncFit(on: mapView)
        context.coordinator.syncCamera(on: mapView)
        context.coordinator.syncAppearance(on: mapView)
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
        private var appliedFitRequest = -1

        private var lastCenter: CLLocationCoordinate2D?
        private var lastHeading: Double = .infinity
        private var lastDistance: Double = -1
        private var lastPitch: CGFloat = -1
        private var forceCameraUpdate = true

        private var routeOverlay: MKPolyline?
        private var trailOverlay: MKPolyline?
        private var startPin: MKPointAnnotation?
        private var endPin: MKPointAnnotation?

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
            guard appliedTrailCount != model.trail.count else { return }
            appliedTrailCount = model.trail.count

            if let old = trailOverlay {
                mapView.removeOverlay(old)
                trailOverlay = nil
            }
            guard model.trail.count > 1 else { return }

            var coordinates = model.trail
            let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            trailOverlay = line
            mapView.addOverlay(line, level: .aboveRoads)
        }

        // MARK: 视野适配

        func syncFit(on mapView: MKMapView) {
            let model = parent.model
            guard appliedFitRequest != model.fitRequest, appliedFitRequest >= 0 || model.fitRequest > 0 else { return }
            guard let option = model.selectedOption else { return }
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

            let moved = lastCenter == nil || Geo.distance(lastCenter!, coordinate) > 1.0
            let headingChanged = lastHeading.isInfinite
                || abs(Geo.angleDelta(lastHeading, model.cameraHeading)) > 0.8
            let distanceChanged = abs(lastDistance - model.zoomDistance) > 10
            let pitchChanged = abs(lastPitch - model.pitch) > 1.0

            guard moved || headingChanged || distanceChanged || pitchChanged || forceCameraUpdate else { return }
            forceCameraUpdate = false

            let camera = MKMapCamera(
                lookingAtCenter: coordinate,
                fromDistance: model.zoomDistance,
                heading: model.cameraHeading,
                pitch: model.pitch
            )
            mapView.setCamera(camera, animated: true)

            lastCenter = coordinate
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
            let type: MKMapType = model.navigating ? .mutedStandard : .standard
            if mapView.mapType != type {
                mapView.mapType = type
            }
            if !mapView.showsBuildings {
                mapView.showsBuildings = true
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
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round

            if let route = routeOverlay, route === line {
                renderer.strokeColor = UIColor(red: 0.00, green: 0.42, blue: 0.98, alpha: 0.95)
                renderer.lineWidth = 7
            } else {
                renderer.strokeColor = UIColor(red: 0.31, green: 0.28, blue: 0.90, alpha: 0.55)
                renderer.lineWidth = 4
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
            }
            view?.annotation = point

            if point.title == "起点" {
                view?.markerTintColor = UIColor(red: 0.06, green: 0.72, blue: 0.51, alpha: 1)
                view?.glyphImage = UIImage(systemName: "circle.fill")
            } else {
                view?.markerTintColor = UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1)
                view?.glyphImage = UIImage(systemName: "flag.fill")
            }
            return view
        }
    }
}
