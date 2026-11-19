import Foundation
import MapKit
import CoreLocation
import Combine

// MARK: - 周边分类（v6）

enum POICategory: String, CaseIterable, Identifiable {
    case fuel
    case charging
    case parking
    case food
    case cafe
    case convenience
    case supermarket
    case hospital
    case pharmacy
    case restroom
    case hotel
    case bank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fuel: return "加油站"
        case .charging: return "充电桩"
        case .parking: return "停车场"
        case .food: return "餐饮"
        case .cafe: return "咖啡"
        case .convenience: return "便利店"
        case .supermarket: return "超市"
        case .hospital: return "医院"
        case .pharmacy: return "药店"
        case .restroom: return "公共厕所"
        case .hotel: return "酒店"
        case .bank: return "银行"
        }
    }

    var symbol: String {
        switch self {
        case .fuel: return "fuelpump.fill"
        case .charging: return "bolt.car.fill"
        case .parking: return "parkingsign.circle.fill"
        case .food: return "fork.knife"
        case .cafe: return "cup.and.saucer.fill"
        case .convenience: return "bag.fill"
        case .supermarket: return "cart.fill"
        case .hospital: return "cross.case.fill"
        case .pharmacy: return "pills.fill"
        case .restroom: return "figure.dress.line.vertical.figure"
        case .hotel: return "bed.double.fill"
        case .bank: return "building.columns.fill"
        }
    }

    /// 给 MKLocalSearch 的自然语言查询词
    var query: String {
        switch self {
        case .fuel: return "加油站"
        case .charging: return "充电站"
        case .parking: return "停车场"
        case .food: return "餐厅"
        case .cafe: return "咖啡店"
        case .convenience: return "便利店"
        case .supermarket: return "超市"
        case .hospital: return "医院"
        case .pharmacy: return "药店"
        case .restroom: return "公共厕所"
        case .hotel: return "酒店"
        case .bank: return "银行"
        }
    }
}

struct POIItem: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    let distance: CLLocationDistance
    let category: POICategory
}

// MARK: - 搜索器

final class POISearcher: ObservableObject {

    @Published private(set) var results: [POIItem] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCategory: POICategory?

    private var search: MKLocalSearch?

    func search(category: POICategory,
                around center: CLLocationCoordinate2D,
                radius: CLLocationDistance = 3000) {
        search?.cancel()
        loading = true
        errorMessage = nil
        lastCategory = category
        results = []

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category.query
        request.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )
        request.resultTypes = [.pointOfInterest]

        let localSearch = MKLocalSearch(request: request)
        search = localSearch

        localSearch.start { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false

                if let error = error {
                    self.errorMessage = "搜索失败：\(error.localizedDescription)"
                    return
                }
                guard let response = response, !response.mapItems.isEmpty else {
                    self.errorMessage = "附近没有找到\(category.title)"
                    return
                }

                var items: [POIItem] = []
                for item in response.mapItems {
                    let coordinate = item.placemark.coordinate
                    let distance = Geo.distance(center, coordinate)
                    guard distance <= radius else { continue }
                    let name = item.name ?? item.placemark.name ?? category.title
                    let address = [item.placemark.thoroughfare, item.placemark.subLocality, item.placemark.locality]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    items.append(
                        POIItem(
                            name: name,
                            address: address,
                            coordinate: coordinate,
                            distance: distance,
                            category: category
                        )
                    )
                }

                items.sort { $0.distance < $1.distance }
                self.results = Array(items.prefix(30))
                if self.results.isEmpty {
                    self.errorMessage = "附近没有找到\(category.title)"
                }
            }
        }
    }

    func cancel() {
        search?.cancel()
        loading = false
    }
}
