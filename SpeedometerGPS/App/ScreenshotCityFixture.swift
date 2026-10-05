#if DEBUG
import CoreLocation
import Foundation
import MapKit

/// Campaign-only data, loaded once. Shipping behavior never depends on fixtures.
struct ScreenshotCityFixture: Decodable {
    struct Point: Decodable {
        let latitude: Double
        let longitude: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }
    let storeLocale: String
    let uiLocale: String
    let city: String
    let cityLabel: String
    let points: [Point]
    let distanceMeters: Double
    let attribution: String
    let fixMapURL: URL

    static let current: ScreenshotCityFixture? = {
        let args = ProcessInfo.processInfo.arguments
        let prefix = "--ui-city-fixture="
        guard let argument = args.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let name = String(argument.dropFirst(prefix.count))
        precondition(name == (name as NSString).lastPathComponent, "Fixture must be inside Documents")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: documents.appendingPathComponent(name)))
            precondition(fixture.points.count >= 5 && fixture.points.count <= 5_000)
            precondition(fixture.points.allSatisfy { CLLocationCoordinate2DIsValid($0.coordinate) })
            precondition(args.contains("--ui-locale=\(fixture.uiLocale)"), "Campaign fixture locale mismatch")
            let screen = args.first(where: { $0.hasPrefix("--ui-screen=") }).map { String($0.dropFirst("--ui-screen=".count)) } ?? ""
            let ready = ["city": fixture.city, "storeLocale": fixture.storeLocale, "uiLocale": fixture.uiLocale, "screen": screen]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("campaign-city-ready.json")
            try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]).write(to: url, options: .atomic)
            return fixture
        } catch {
            preconditionFailure("Requested city fixture could not load: \(error)")
        }
    }()

    // Cache geometry once, rather than rebuilding a coordinate array in body.
    static let coordinates = current?.points.map(\.coordinate)
    static let region: MKCoordinateRegion? = coordinates.map { points in
        let latitudes = points.map(\.latitude), longitudes = points.map(\.longitude)
        let south = latitudes.min()!, north = latitudes.max()!
        let west = longitudes.min()!, east = longitudes.max()!
        return MKCoordinateRegion(center: .init(latitude: (south+north)/2, longitude: (west+east)/2),
                                  span: .init(latitudeDelta: max(0.012, (north-south)*1.5),
                                              longitudeDelta: max(0.012, (east-west)*1.5)))
    }

    var referenceRoutes: [ReferenceRoute] {
        let vertices = points.map { ReferenceRoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        return [
            .init(id: UUID(uuidString: "4EAEC599-4B55-4DB7-B115-231476528850")!, name: cityLabel,
                  sourceFileName: "\(storeLocale)-city.gpx", segments: [vertices]),
            .init(id: UUID(uuidString: "E14FE010-A11B-40F8-84E0-B1455A879CA7")!, name: "\(cityLabel) · 2",
                  sourceFileName: "\(storeLocale)-city-2.gpx", segments: [Array(vertices.reversed())])
        ]
    }

    var trackPoints: [TrackPoint] {
        let end = Date(timeIntervalSince1970: 1_790_064_000)
        var elapsed: TimeInterval = 0
        let duration = distanceMeters / 6
        return points.enumerated().map { index, point in
            if index > 0 {
                let previous = points[index-1]
                elapsed += CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) / 6
            }
            return TrackPoint(latitude: point.latitude, longitude: point.longitude, altitude: 20,
                              metersPerSecond: index == points.count-1 ? 24 / 3.6 : 6,
                              timestamp: end.addingTimeInterval(elapsed-duration))
        }
    }
}
#endif
