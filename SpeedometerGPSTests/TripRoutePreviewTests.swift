import UIKit
import XCTest
@testable import SpeedometerGPS

final class TripRoutePreviewTests: XCTestCase {
    private func point(_ lat: Double, _ lon: Double, gap: Bool = false) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, altitude: 0, metersPerSecond: 3,
                   timestamp: Date(timeIntervalSince1970: 1_000), beginsNewSegment: gap)
    }
    private func trip(_ points: [TrackPoint], id: UUID = UUID()) -> TripRecord {
        TripRecord(id: id, startedAt: Date(timeIntervalSince1970: 1_000),
                   endedAt: Date(timeIntervalSince1970: 2_000), points: points, activity: "activity_cycling")
    }

    func testGeometryFitsAndPreservesOrientationEndpointsAndGaps() throws {
        let points = [point(53, 27), point(54, 28), point(53, 29, gap: true), point(55, 30)]
        let vertices = try XCTUnwrap(TripPreviewGeometry.make(points: points))
        XCTAssertEqual(vertices.count, 4)
        XCTAssertEqual(vertices.map(\.beginsSegment), [true, false, true, false])
        XCTAssertLessThan(vertices[0].point.x, vertices[3].point.x)
        XCTAssertGreaterThan(vertices[0].point.y, vertices[3].point.y)
        for vertex in vertices {
            XCTAssertTrue((9.99...86.01).contains(vertex.point.x))
            XCTAssertTrue((9.99...62.01).contains(vertex.point.y))
        }
    }

    func testDatelineUsesNearbyLongitudesAndPolarCoordinatesStayFinite() throws {
        let wrapped = try XCTUnwrap(TripPreviewGeometry.make(points: [point(10, 179), point(11, -180), point(10, -179)]))
        let ordinary = try XCTUnwrap(TripPreviewGeometry.make(points: [point(10, -1), point(11, 0), point(10, 1)]))
        for (a, b) in zip(wrapped, ordinary) {
            XCTAssertEqual(a.point.x, b.point.x, accuracy: 0.00001)
            XCTAssertEqual(a.point.y, b.point.y, accuracy: 0.00001)
        }
        let polar = try XCTUnwrap(TripPreviewGeometry.make(points: [point(90, 0), point(-90, 1)]))
        XCTAssertTrue(polar.allSatisfy { $0.point.x.isFinite && $0.point.y.isFinite })
    }

    func testEmptyStationaryAndInvalidCoordinatesNeverInventConnectingLines() throws {
        XCTAssertEqual(TripPreviewGeometry.make(points: []), [])
        XCTAssertEqual(TripPreviewGeometry.make(points: [point(.nan, 0)]), [])
        let stationary = try XCTUnwrap(TripPreviewGeometry.make(points: [point(53, 27), point(53, 27)]))
        XCTAssertEqual(stationary.first?.point, CGPoint(x: 48, y: 36))
        let invalid = try XCTUnwrap(TripPreviewGeometry.make(points: [point(53, 27), point(100, 27), point(54, 28)]))
        XCTAssertEqual(invalid.map(\.beginsSegment), [true, true])
    }

    func testLongRouteArtworkIsBoundedAndSkippedPauseStillBreaksPath() throws {
        var points: [TrackPoint] = []
        for index in 0..<180_000 {
            let latitude = 53.0 + Double(index) / 200_000.0
            let longitude = 27.0 + sin(Double(index) / 2000.0) / 10.0
            points.append(point(latitude, longitude, gap: index == 117 || index == 90_001))
        }
        let began = CFAbsoluteTimeGetCurrent()
        let vertices = try XCTUnwrap(TripPreviewGeometry.make(points: points))
        print("180k thumbnail geometry seconds: \(CFAbsoluteTimeGetCurrent() - began)")
        XCTAssertLessThanOrEqual(vertices.count, TripPreviewGeometry.sampleBudget + 6)
        XCTAssertGreaterThanOrEqual(vertices.filter { $0.beginsSegment }.count, 3)
        XCTAssertTrue(vertices.first!.beginsSegment)
        var checks = 0
        let cancelled = TripPreviewGeometry.make(points: points, cancelled: { checks += 1; return checks == 3 })
        XCTAssertNil(cancelled)
        XCTAssertEqual(checks, 3)
    }

    func testOldArchivesRegenerateAndSameIDReplacementCannotReuseStaleImage() async throws {
        let original = trip([point(53, 27), point(54, 28), point(53, 29)])
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["previewIdentity"])
        let restored = try JSONDecoder().decode(TripRecord.self, from: data)
        XCTAssertEqual(original, restored)
        XCTAssertNotEqual(original.previewIdentity, restored.previewIdentity)
        let cache = TripRoutePreviewCache()
        let first = await cache.image(identity: original.previewIdentity, points: original.points)
        XCTAssertNotNil(first)
        let reused = await cache.image(identity: original.previewIdentity, points: original.points)
        XCTAssertTrue(first === reused)
        cache.removeAll()
        XCTAssertNil(cache.cached(original.previewIdentity))
        let regenerated = await cache.image(identity: restored.previewIdentity, points: restored.points)
        XCTAssertEqual(first?.pngData(), regenerated?.pngData())
        let replacement = trip([point(53, 27), point(53, 28), point(53, 29)], id: original.id)
        let changed = await cache.image(identity: replacement.previewIdentity, points: replacement.points)
        XCTAssertNotEqual(regenerated?.pngData(), changed?.pngData())
        XCTAssertEqual(changed?.cgImage?.width, 288)
        XCTAssertEqual(changed?.cgImage?.height, 216)
    }

    func testConcurrentRequestsForSameRideReuseArtwork() async {
        let cache = TripRoutePreviewCache()
        let ride = trip([point(53, 27), point(54, 28), point(53, 29)])
        let images = await withTaskGroup(of: UIImage?.self, returning: [UIImage].self) { group in
            for _ in 0..<24 {
                group.addTask { await cache.image(identity: ride.previewIdentity, points: ride.points) }
            }
            var images: [UIImage] = []
            for await image in group { if let image { images.append(image) } }
            return images
        }
        XCTAssertEqual(images.count, 24)
        XCTAssertTrue(images.allSatisfy { $0 === images.first })
    }

    func testCancelledRequestCanRegenerateOnNextAppearance() async {
        let cache = TripRoutePreviewCache()
        let ride = trip([point(53, 27), point(54, 28)])
        let request = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await cache.image(identity: ride.previewIdentity, points: ride.points)
        }
        request.cancel()
        let cancelled = await request.value
        XCTAssertNil(cancelled)
        let next = await cache.image(identity: ride.previewIdentity, points: ride.points)
        XCTAssertNotNil(next)
    }
}
