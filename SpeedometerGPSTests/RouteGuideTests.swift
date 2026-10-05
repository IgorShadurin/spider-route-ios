import XCTest
import UIKit
@testable import SpeedometerGPS

final class RouteGuideTests: XCTestCase {
    @MainActor
    func testMapDescriptorsKeepPhotoDataOutOfAnnotationsAndReuseArtwork() throws {
        let store = ReferenceRouteStore(applicationSupportURL: directory(), processArguments: [])
        let route = try store.importRoute(data: gpx, fileName: "route.gpx")
        let guide = try store.importGuide(data: photoGuide(for: route, photos: [photoDocument()]), for: route)
        let descriptor = try XCTUnwrap(store.visibleGuideMapPoints.first)
        XCTAssertEqual(descriptor, RouteGuideMapPoint(guide.points[0]))
        XCTAssertEqual(store.visibleGuidePoints.first?.photos?.count, 1, "Tap detail must retain original photo and source metadata")
        let traits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .light), UITraitCollection(displayScale: 2)])
        let first = RouteGuideMarkerImage.image(for: descriptor, details: false, traits: traits)
        for _ in 0..<1000 {
            XCTAssertTrue(RouteGuideMarkerImage.image(for: descriptor, details: false, traits: traits) === first)
        }
        XCTAssertFalse(RouteGuideMarkerImage.image(for: descriptor, details: true, traits: traits) === first)
        XCTAssertTrue(store.setGuideEnabled(false, for: route))
        XCTAssertTrue(store.visibleGuideMapPoints.isEmpty)
        XCTAssertTrue(store.setGuideEnabled(true, for: route))
        XCTAssertEqual(store.visibleGuideMapPoints.first, descriptor)
    }

    func testUnicodeSourceLinksArePortableToIOS15() {
        let url = RouteGuideImporter.sourceURL("https://ru.wikipedia.org/wiki/Днепр")
        XCTAssertEqual(url?.absoluteString, "https://ru.wikipedia.org/wiki/%D0%94%D0%BD%D0%B5%D0%BF%D1%80")
        XCTAssertEqual(RouteGuideImporter.sourceURL(url!.absoluteString), url)
        XCTAssertNil(RouteGuideImporter.sourceURL("https://example.org/a b"))
        XCTAssertNil(RouteGuideImporter.sourceURL("https://user:password@example.org/path"))
        XCTAssertNil(RouteGuideImporter.sourceURL("javascript:alert(1)"))
    }

    private let gpx = Data("<gpx><trk><trkseg><trkpt lat=\"53.9\" lon=\"30.3\"/><trkpt lat=\"54\" lon=\"30.4\"/></trkseg></trk></gpx>".utf8)

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func guideData(for route: ReferenceRoute, mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var document: [String: Any] = [
            "schemaVersion": 1, "title": "Места рядом", "language": "ru",
            "routeFingerprint": RouteGuideImporter.fingerprint(for: route),
            "points": [["id": "church", "title": "Церковь", "latitude": 53.95, "longitude": 30.35,
                        "category": "heritage", "summary": "Памятник архитектуры.",
                        "sources": [["title": "Реестр", "url": "https://example.org/place"]],
                        "distanceFromRouteMeters": 100, "distanceAlongRouteMeters": 200]]
        ]
        mutate(&document)
        return try JSONSerialization.data(withJSONObject: document)
    }

    private func photoDocument(data: Data? = nil) -> [String: Any] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return ["id": "photo", "title": "Вид памятника", "sourceURL": "https://example.org/photo",
                "author": "Автор", "license": "CC BY 4.0", "licenseURL": "https://creativecommons.org/licenses/by/4.0/",
                "imageURL": "https://example.org/photo.png", "data": (data ?? image.pngData()!).base64EncodedString()]
    }

    private func photoGuide(for route: ReferenceRoute, photos: [[String: Any]], version: Int = 2,
                            icon: String = "person") throws -> Data {
        try guideData(for: route) { document in
            document["schemaVersion"] = version
            var points = document["points"] as! [[String: Any]]
            points[0]["photos"] = photos
            points[0]["icon"] = icon
            document["points"] = points
        }
    }

    @MainActor
    func testPortablePhotoAndSemanticIconPersistWhileLegacyGuideRemainsValid() throws {
        let root = directory()
        let store = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        let route = try store.importRoute(data: gpx, fileName: "route.gpx")
        let legacy = try RouteGuideImporter.decode(data: guideData(for: route), for: route)
        XCTAssertNil(legacy.points[0].photos)
        XCTAssertNil(legacy.points[0].icon)
        let photo = photoDocument()
        let guide = try store.importGuide(data: photoGuide(for: route, photos: [photo]), for: route)
        XCTAssertEqual(guide.points[0].icon, .person)
        XCTAssertEqual(guide.points[0].photos?.first?.data.base64EncodedString(), photo["data"] as? String)
        let restored = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        XCTAssertEqual(restored.guide(for: route), guide)
        XCTAssertEqual(try RouteGuideImporter.decode(data: JSONEncoder().encode(guide), for: route), guide)
        for icon in RouteGuidePoint.Icon.allCases {
            XCTAssertNoThrow(try RouteGuideImporter.decode(data: photoGuide(for: route, photos: [], icon: icon.rawValue), for: route))
        }
    }

    @MainActor
    func testThousandKilometerGuideWithMaximumPlacesAndPhotoBudgetLoadsInBackground() async throws {
        let root = directory()
        let store = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        let fixture = try await Task.detached {
            let track = ThousandKilometerFixture.points()
            let route = ReferenceRoute(id: UUID(), name: "1,000 km fixture", sourceFileName: "long.geojson",
                segments: [track.map { ReferenceRoutePoint(latitude: $0.latitude, longitude: $0.longitude) }])
            let guide = RouteGuide(schemaVersion: 2, title: "Synthetic guide", language: "en",
                routeFingerprint: RouteGuideImporter.fingerprint(for: route), points: ThousandKilometerFixture.guidePoints(includePhotos: true))
            let photos = guide.points.flatMap { $0.photos ?? [] }
            XCTAssertEqual(photos.count, 120)
            let bytes = photos.reduce(0) { $0 + $1.data.count }
            XCTAssertGreaterThan(bytes, 23 * 1024 * 1024)
            XCTAssertLessThanOrEqual(bytes, RouteGuideImporter.maximumTotalPhotoBytes)
            XCTAssertEqual(guide.points.count, RouteGuideImporter.maximumPointCount)
            try RouteGuideImporter.validate(guide, for: route)
            return (route, guide, bytes)
        }.value
        // Import through the same async URL entry point used by Settings.
        let trip = TripRecord(id: UUID(), startedAt: Date(), endedAt: Date(), points: ThousandKilometerFixture.points(), activity: "activity_cycling")
        let input = root.appendingPathComponent("long.geojson")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await Task.detached { try RouteExporter.data(for: trip, format: .geoJSON).write(to: input) }.value
        let imported = try await store.importRouteInBackground(from: input)
        let guide = RouteGuide(schemaVersion: 2, title: fixture.1.title, language: "en",
            routeFingerprint: RouteGuideImporter.fingerprint(for: imported), points: fixture.1.points)
        let guideURL = root.appendingPathComponent("guide.json")
        try await Task.detached { try JSONEncoder().encode(guide).write(to: guideURL) }.value
        _ = try await store.importGuideInBackground(from: guideURL, for: imported)
        XCTAssertEqual(store.visibleGuideMapPoints.count, 1000)
        let persisted = root.appendingPathComponent("route-guides/\(imported.id.uuidString).json")
        let before = try Data(contentsOf: persisted)
        XCTAssertTrue(store.setGuideEnabled(false, for: imported))
        XCTAssertTrue(store.visibleGuideMapPoints.isEmpty)
        XCTAssertEqual(try Data(contentsOf: persisted), before, "Visibility must not rewrite photo bytes")
        let reloaded = ReferenceRouteStore(applicationSupportURL: root, processArguments: [], loadInBackground: true)
        XCTAssertTrue(reloaded.isLoading)
        await reloaded.waitForLoad()
        XCTAssertEqual(reloaded.guide(for: imported), guide)
        XCTAssertFalse(reloaded.isGuideEnabled(for: imported))
        XCTAssertTrue(reloaded.setGuideEnabled(true, for: imported))
        XCTAssertEqual(reloaded.visibleGuideMapPoints.count, 1000)
        print("THOUSAND_KM_GUIDE places=1000 photos=120 bytes=\(fixture.2) recovered=true")
    }

    func testMalformedAndOversizedMediaIsRejected() throws {
        let route = try ReferenceRouteImporter.decode(data: gpx, fileName: "route.gpx")
        let photo = photoDocument()
        let badFields: [(String, Any)] = [
            ("data", "not-base64!"), ("data", ""),
            ("data", Data("not an image".utf8).base64EncodedString()),
            // A valid single-frame GIF is still not an allowed portable photo format.
            ("data", "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"),
            ("data", Data(Data(base64Encoded: photo["data"] as! String)!.prefix(40)).base64EncodedString()),
            ("data", Data(repeating: 0, count: RouteGuideImporter.maximumPhotoBytes + 1).base64EncodedString()),
            ("sourceURL", "file:///tmp/image.png"), ("licenseURL", "https://name:password@example.org"),
            ("imageURL", "javascript:alert(1)"), ("author", " "), ("license", ""), ("title", String(repeating: "a", count: 301))
        ]
        for (key, value) in badFields {
            var invalid = photo
            invalid[key] = value
            XCTAssertThrowsError(try RouteGuideImporter.decode(data: photoGuide(for: route, photos: [invalid]), for: route), key)
        }
        XCTAssertThrowsError(try RouteGuideImporter.decode(data: photoGuide(for: route, photos: [photo], version: 1), for: route))
        XCTAssertThrowsError(try RouteGuideImporter.decode(data: photoGuide(for: route, photos: [photo], icon: "unknown"), for: route))
        XCTAssertThrowsError(try RouteGuideImporter.decode(data: photoGuide(for: route, photos: [photo, photo]), for: route))
        let tooMany = (0..<4).map { index -> [String: Any] in
            var value = photo; value["id"] = "photo-\(index)"; return value
        }
        XCTAssertThrowsError(try RouteGuideImporter.decode(data: photoGuide(for: route, photos: tooMany), for: route))
        // A tiny compressed PNG with huge declared geometry must fail before decoding pixels.
        var hugePNG = Data(base64Encoded: photo["data"] as! String)!
        hugePNG.replaceSubrange(16..<20, with: [0, 0, 0x20, 0])
        XCTAssertThrowsError(try RouteGuideImporter.decode(data: photoGuide(for: route, photos: [photoDocument(data: hugePNG)]), for: route))
        let many = try guideData(for: route) { document in
            document["schemaVersion"] = 2
            let point = (document["points"] as! [[String: Any]])[0]
            document["points"] = (0..<121).map { index -> [String: Any] in
                var value = point; value["id"] = "point-\(index)"; value["photos"] = [photo]; return value
            }
        }
        XCTAssertThrowsError(try RouteGuideImporter.decode(data: many, for: route))
    }

    func testFingerprintMatchesPythonReferenceAndRetainsSegmentBoundaries() throws {
        let route = try ReferenceRouteImporter.decode(data: gpx, fileName: "route.gpx")
        XCTAssertEqual(RouteGuideImporter.fingerprint(for: route),
                       "92ac15f1c17b86dfefd364537a2c5af0f79a807c6bc21a1e53923094983c5e61")
        let split = ReferenceRoute(id: route.id, name: route.name, sourceFileName: route.sourceFileName,
                                   segments: route.segments[0].map { [$0] })
        XCTAssertNotEqual(RouteGuideImporter.fingerprint(for: route), RouteGuideImporter.fingerprint(for: split))
    }

    func testImporterBoundsDistancesSourcesAndPointCount() throws {
        let route = try ReferenceRouteImporter.decode(data: gpx, fileName: "route.gpx")
        let badFields: [(String, Any)] = [
            ("distanceFromRouteMeters", -1), ("distanceAlongRouteMeters", -1),
            ("details", String(repeating: "я", count: 5_001)),
            ("sources", [[String: String]]()),
            ("sources", [["title": "Unsafe", "url": "https://user:secret@example.org"]]),
            ("sources", [["title": "Unsafe", "url": "file:///etc/passwd"]]),
            ("longitude", 181), ("summary", "  \n "), ("category", "unknown")
        ]
        for (key, value) in badFields {
            let data = try guideData(for: route) { document in
                var points = document["points"] as! [[String: Any]]
                points[0][key] = value
                document["points"] = points
            }
            XCTAssertThrowsError(try RouteGuideImporter.decode(data: data, for: route), key)
        }
        let many = try guideData(for: route) { document in
            let point = (document["points"] as! [[String: Any]])[0]
            document["points"] = (0...RouteGuideImporter.maximumPointCount).map { index in
                var unique = point
                unique["id"] = "point-\(index)"
                return unique
            }
        }
        XCTAssertThrowsError(try RouteGuideImporter.decode(data: many, for: route))
        let boundary = try guideData(for: route) { document in
            var points = document["points"] as! [[String: Any]]
            points[0]["summary"] = String(repeating: "я", count: 500)
            points[0]["details"] = String(repeating: "я", count: 5_000)
            document["points"] = points
        }
        XCTAssertNoThrow(try RouteGuideImporter.decode(data: boundary, for: route))
    }

    @MainActor
    func testCorruptSidecarDoesNotPreventLegacyRouteRestoration() throws {
        let root = directory()
        let store = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        let route = try store.importRoute(data: gpx, fileName: "route.gpx")
        _ = try store.importGuide(data: guideData(for: route), for: route)
        let sidecar = root.appendingPathComponent("route-guides/\(route.id.uuidString).json")
        try Data("{broken".utf8).write(to: sidecar, options: .atomic)
        let restored = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        XCTAssertEqual(restored.routes, [route])
        XCTAssertEqual(restored.route, route)
        XCTAssertTrue(restored.isVisible)
        XCTAssertNil(restored.guide(for: route))
        XCTAssertTrue(restored.visibleGuidePoints.isEmpty)
    }

    @MainActor
    func testOptionalGuidePersistsAndDisabledRestoresWithoutMapPoints() throws {
        let root = directory()
        let store = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        let route = try store.importRoute(data: gpx, fileName: "route.gpx")
        XCTAssertNil(store.guide(for: route))
        XCTAssertFalse(store.isGuideEnabled(for: route))
        XCTAssertTrue(store.visibleGuidePoints.isEmpty)
        let original = try store.importGuide(data: guideData(for: route), for: route)
        XCTAssertEqual(store.visibleGuidePoints, original.points)
        let restored = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        XCTAssertEqual(restored.guide(for: route), original)
        XCTAssertEqual(restored.visibleGuidePoints, original.points)
        XCTAssertTrue(restored.setGuideEnabled(false, for: route))
        let disabled = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        XCTAssertEqual(disabled.guide(for: route), original)
        XCTAssertFalse(disabled.isGuideEnabled(for: route))
        XCTAssertTrue(disabled.visibleGuidePoints.isEmpty)
        XCTAssertEqual(disabled.routes[0].segments, route.segments)
    }

    @MainActor
    func testInvalidReplacementRetainsPreviousGuideAndEnabledState() throws {
        let root = directory()
        let store = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        let route = try store.importRoute(data: gpx, fileName: "route.gpx")
        let original = try store.importGuide(data: guideData(for: route), for: route)
        XCTAssertTrue(store.setGuideEnabled(false, for: route))
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 99 },
            { $0["routeFingerprint"] = String(repeating: "0", count: 64) },
            { $0["points"] = [["id": "broken"]] },
            { value in
                var points = value["points"] as! [[String: Any]]
                points[0]["summary"] = String(repeating: "я", count: 501)
                value["points"] = points
            },
            { value in
                var points = value["points"] as! [[String: Any]]
                points[0]["latitude"] = 91
                value["points"] = points
            },
            { value in
                var points = value["points"] as! [[String: Any]]
                points[0]["sources"] = [["title": "Unsafe", "url": "javascript:alert(1)"]]
                value["points"] = points
            },
            { value in
                let points = value["points"] as! [[String: Any]]
                value["points"] = points + points
            }
        ]
        for mutate in mutations {
            XCTAssertThrowsError(try store.importGuide(data: guideData(for: route, mutate: mutate), for: route))
            XCTAssertEqual(store.guide(for: route), original)
            XCTAssertFalse(store.isGuideEnabled(for: route))
        }
        XCTAssertThrowsError(try store.importGuide(data: Data("{broken".utf8), for: route))
        XCTAssertThrowsError(try store.importGuide(data: Data(repeating: 0, count: RouteGuideImporter.maximumFileBytes + 1), for: route))
        let restored = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        XCTAssertEqual(restored.guide(for: route), original)
        XCTAssertFalse(restored.isGuideEnabled(for: route))
    }

    @MainActor
    func testSelectionVisibilityRenameReversalAndDeletionKeepGuidesIsolated() throws {
        let root = directory()
        let store = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        let first = try store.importRoute(data: gpx, fileName: "first.gpx")
        let guide = try store.importGuide(data: guideData(for: first), for: first)
        store.reverseDirection(of: first)
        XCTAssertTrue(store.rename(first.id, to: "Renamed"))
        XCTAssertEqual(store.guide(for: store.route!), guide)
        XCTAssertEqual(store.visibleGuidePoints, guide.points)
        let renamed = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        XCTAssertEqual(renamed.route?.name, "Renamed")
        XCTAssertTrue(renamed.isReversed(first))
        XCTAssertEqual(renamed.guide(for: first), guide)
        let second = try store.importRoute(data: gpx, fileName: "second.gpx")
        XCTAssertTrue(store.visibleGuidePoints.isEmpty)
        XCTAssertNil(store.guide(for: second))
        store.select(first.id)
        XCTAssertEqual(store.visibleGuidePoints, guide.points)
        store.isVisible = false
        XCTAssertTrue(store.visibleGuidePoints.isEmpty)
        store.isVisible = true
        XCTAssertEqual(store.visibleGuidePoints, guide.points)
        store.delete(first.id)
        XCTAssertTrue(store.visibleGuidePoints.isEmpty)
        XCTAssertNil(store.guide(for: first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("route-guides/\(first.id.uuidString).json").path))
        let restored = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        XCTAssertNil(restored.guide(for: first))
        XCTAssertEqual(restored.routes.map(\.id), [second.id])
        XCTAssertThrowsError(try store.importGuide(data: guideData(for: first), for: first))
    }

    @MainActor
    func testDifferentGeometryIsRejectedAndFailedDiskWriteDoesNotPublishReplacement() throws {
        let root = directory()
        let store = ReferenceRouteStore(applicationSupportURL: root, processArguments: [])
        let first = try store.importRoute(data: gpx, fileName: "first.gpx")
        let differentGPX = Data(String(decoding: gpx, as: UTF8.self).replacingOccurrences(of: "53.9", with: "53.8").utf8)
        let second = try store.importRoute(data: differentGPX, fileName: "second.gpx")
        let data = try guideData(for: first)
        XCTAssertThrowsError(try store.importGuide(data: data, for: second)) { error in
            XCTAssertEqual(error as? RouteGuideImportError, .routeMismatch)
        }
        let original = try store.importGuide(data: data, for: first)
        let guidesDirectory = root.appendingPathComponent("route-guides")
        try FileManager.default.removeItem(at: guidesDirectory)
        try Data("blocks-directory".utf8).write(to: guidesDirectory)
        XCTAssertThrowsError(try store.importGuide(data: guideData(for: first) { $0["title"] = "Replacement" }, for: first))
        XCTAssertEqual(store.guide(for: first), original)
        XCTAssertFalse(store.setGuideEnabled(false, for: first))
        XCTAssertTrue(store.isGuideEnabled(for: first))
    }
}
