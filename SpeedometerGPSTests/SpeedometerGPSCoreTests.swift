import CoreLocation
import MapKit
import MapLibre
import StoreKitTest
import SwiftUI
import UIKit
import XCTest
@testable import SpeedometerGPS

final class SpeedometerGPSCoreTests: XCTestCase {
    func testOfflineTileTemplateValidationRetainsXYZAndRejectsInvalidEndpoints() throws {
        let template = "https://tiles.openfreemap.org/planet/20260927_080001_pt/{z}/{x}/{y}.pbf"
        XCTAssertTrue(OSMMapStyle.isHTTPSMapTileTemplate(template))
        for invalid in ["http://example.com/{z}/{x}/{y}.pbf", "https:relative/{z}", "https://example.com/{unknown}", "not-a-url"] {
            XCTAssertFalse(OSMMapStyle.isHTTPSMapTileTemplate(invalid), invalid)
        }
        let style = Data(#"{"version":8,"sources":{"openmaptiles":{"url":"https://tiles.openfreemap.org/planet"}},"layers":[]}"#.utf8)
        let tileJSON = try JSONSerialization.data(withJSONObject: ["tiles": [template]])
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: OSMMapStyle.frozen(style, tileJSON: tileJSON)) as? [String: Any])
        let sources = try XCTUnwrap(output["sources"] as? [String: [String: Any]])
        XCTAssertEqual(sources["openmaptiles"]?["tiles"] as? [String], [template])
    }


    func testOfflineRegionCatalogHasCountriesProvincesAndOriginalShapes() throws {
        let regions = try OfflineRegionCatalog.load()
        let countries = regions.filter { $0.parentID == nil }
        XCTAssertEqual(countries.count, 258)
        XCTAssertEqual(regions.count - countries.count, 4596)
        let ids = Set(regions.map(\.id))
        XCTAssertEqual(ids.count, regions.count)
        XCTAssertTrue(regions.allSatisfy { $0.parentID == nil || ids.contains($0.parentID!) })
        for id in ["country.MCO", "country.RUS", "country.FJI", "province.1159315991"] {
            let region = try XCTUnwrap(regions.first { $0.id == id })
            let data = try region.shapeData()
            let shape = try MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
            XCTAssertNotNil(shape)
            let geometry = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue(["Polygon", "MultiPolygon"].contains(geometry["type"] as? String ?? ""))
            if id == "country.RUS" { XCTAssertEqual(geometry["type"] as? String, "MultiPolygon") }
        }
        let monaco = try XCTUnwrap(countries.first { $0.id == "country.MCO" })
        XCTAssertEqual(monaco.localizedName(locale: Locale(identifier: "ru")), "Монако")
        let islands = try XCTUnwrap(countries.first { $0.id == "country.CSI" })
        XCTAssertNotEqual(islands.localizedName(locale: Locale(identifier: "en")), "Australia")
        let minskCity = try XCTUnwrap(regions.first { $0.subdivisionCode == "BY-HM" })
        XCTAssertEqual(minskCity.localizedName(locale: Locale(identifier: "en")), "City of Minsk")
    }

    func testOfflineMetadataKeepsOldDownloadsAndNamedRegionIdentity() throws {
        let old = Data(#"{"id":"82A232D3-35D4-4B8F-AEA2-C2DECD4A35AA","name":"Existing map","languageID":"ru","south":53.89,"west":27.55,"north":53.91,"east":27.58}"#.utf8)
        let legacy = try JSONDecoder().decode(DownloadedMapMetadata.self, from: old)
        XCTAssertNil(legacy.regionID)
        XCTAssertNil(legacy.frozenStyleURL)
        XCTAssertEqual(legacy.name, "Existing map")
        let named = DownloadedMapMetadata(name: "Monaco", languageID: "ru", bounds: legacy.bounds, regionID: "country.MCO", styleVersion: 1)
        let restored = try JSONDecoder().decode(DownloadedMapMetadata.self, from: JSONEncoder().encode(named))
        XCTAssertEqual(restored, named)
        XCTAssertEqual(restored.regionID, "country.MCO")
        XCTAssertEqual(restored.frozenStyleURL, named.frozenStyleURL)
        let styleURL = try XCTUnwrap(Bundle.main.url(forResource: "OSMLiberty", withExtension: "json"))
        let first = Data(#"{"tiles":["https://tiles.openfreemap.org/planet/old/{z}/{x}/{y}.pbf"],"maxzoom":14}"#.utf8)
        let next = Data(#"{"tiles":["https://tiles.openfreemap.org/planet/new/{z}/{x}/{y}.pbf"],"maxzoom":14}"#.utf8)
        let original = try OSMMapStyle.frozen(Data(contentsOf: styleURL), tileJSON: first)
        let newer = try OSMMapStyle.frozen(Data(contentsOf: styleURL), tileJSON: next)
        XCTAssertNotEqual(original, newer)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let source = try XCTUnwrap((json["sources"] as? [String: [String: Any]])?["openmaptiles"])
        XCTAssertNil(source["url"])
        XCTAssertEqual(source["tiles"] as? [String], ["https://tiles.openfreemap.org/planet/old/{z}/{x}/{y}.pbf"])
        XCTAssertThrowsError(try OSMMapStyle.frozen(Data(contentsOf: styleURL), tileJSON: Data("{}".utf8)))
    }


    @MainActor
    func testMapProviderDefaultsPersistUpgradeAndReset() {
        let suite = "MapProvider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("mph", forKey: "speed_unit")
        defaults.set(false, forKey: "follow_location_on_map")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.mapProvider, .openStreetMap)
        settings.mapProvider = .apple
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.mapProvider, .apple)
        XCTAssertFalse(restored.followLocationOnMap, "Selecting a map must retain other preferences")
        restored.reset()
        XCTAssertEqual(AppSettings(defaults: defaults).mapProvider, .openStreetMap)
        defaults.set("future-removed-provider", forKey: "map_provider")
        XCTAssertEqual(AppSettings(defaults: defaults).mapProvider, .openStreetMap)
    }

    @MainActor
    func testDistanceLabelSizeDefaultsPersistResetAndRejectInvalidValues() {
        let suite = "DistanceLabels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.distanceLabelSize, .two)
        for size in RouteDistanceLabelSize.allCases {
            settings.distanceLabelSize = size
            XCTAssertEqual(AppSettings(defaults: defaults).distanceLabelSize, size)
        }
        settings.distanceLabelSize = .one
        settings.reset()
        XCTAssertEqual(AppSettings(defaults: defaults).distanceLabelSize, .two)
        defaults.set(99, forKey: "route_distance_label_size")
        XCTAssertEqual(AppSettings(defaults: defaults).distanceLabelSize, .two)
    }

    @MainActor
    func testDistanceLabelSizesPreserveNativeAnchorAndCacheArtwork() throws {
        let marker = ReferenceRouteMarker(kind: .distance, meters: 15_000, latitude: 54, longitude: 27)
        var cache = ReferenceMarkerPresentationCache()
        let view = LegacyReferenceMarkerAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.center = CGPoint(x: 123, y: 456)
        for size in RouteDistanceLabelSize.allCases {
            XCTAssertTrue(cache.prepare(markers: [marker], size: size))
            let presentation = try XCTUnwrap(cache.byID[marker.id])
            XCTAssertEqual(presentation.fontSize, CGFloat(size.rawValue) * 10)
            let image = try XCTUnwrap(presentation.numberImage)
            for _ in 0..<100 {
                XCTAssertFalse(cache.prepare(markers: [marker], size: size))
                XCTAssertTrue(cache.byID[marker.id]?.numberImage === image)
            }
            view.configure(presentation, showsLabel: true, heading: 45)
            XCTAssertEqual(view.center, CGPoint(x: 123, y: 456))
            XCTAssertEqual(view.coordinateAnchor.y + view.centerOffset.y, view.bounds.midY, accuracy: 0.01)
            XCTAssertEqual(view.subviews.first?.frame, view.bounds)
            XCTAssertGreaterThanOrEqual(view.bounds.height, image.size.height + 12)
        }
        let endpoint = ReferenceRouteMarker(kind: .start, meters: 0, latitude: 54, longitude: 27)
        XCTAssertEqual(ReferenceMarkerPresentation(marker: endpoint, size: .one).labelWidth,
                       ReferenceMarkerPresentation(marker: endpoint, size: .three).labelWidth)
    }

    func testLargerDistanceLabelsDeclutterUsingTheirActualBounds() {
        let markers = [10, 15].enumerated().map { index, km in
            ReferenceRouteMarker(kind: .distance, meters: Double(km) * 1_000, latitude: Double(index), longitude: 27)
        }
        var cache = ReferenceMarkerPresentationCache()
        cache.prepare(markers: markers, size: .one)
        let small = ReferenceMarkerLabelLayout.visibleIDs(presentations: cache.ordered, size: CGSize(width: 375, height: 500)) {
            CGPoint(x: 100 + $0.latitude * 45, y: 200)
        }
        cache.prepare(markers: markers, size: .three)
        let large = ReferenceMarkerLabelLayout.visibleIDs(presentations: cache.ordered, size: CGSize(width: 375, height: 500)) {
            CGPoint(x: 100 + $0.latitude * 45, y: 200)
        }
        XCTAssertEqual(small.count, 2)
        XCTAssertEqual(large.count, 1)
        XCTAssertEqual(cache.ordered.count, 2, "Decluttering hides text, never removes a route tick")
    }

    func testOSMUsesVectorRendererAtEverySupportedVersion() {
        for version in [15, 16, 17, 18, 26] {
            XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: version, mapProvider: .openStreetMap), .osmVector)
        }
        XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: 26, mapProvider: .apple), .modernSwiftUI)
        XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: 26, sourcePointCount: 25_200, mapProvider: .apple), .legacyUIKit)
    }

    @MainActor
    func testVectorMapRetainsCompletedSourcesMarkersAndCameraOnAppend() async throws {
        let map = MLNMapView(frame: .init(x: 0, y: 0, width: 375, height: 600), styleURL: try OSMMapStyle.url(languageID: "en-US", permitsNetwork: false))
        let coordinator = VectorRouteMapSurface.Coordinator()
        map.delegate = coordinator
        for _ in 0..<100 {
            if map.style != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let style = try XCTUnwrap(map.style)
        let points = [CLLocationCoordinate2D(latitude: 54, longitude: 27), CLLocationCoordinate2D(latitude: 54.01, longitude: 27.01)]
        let completed = RouteDrawingGroup(id: "0", segments: [points])
        var snapshot = RouteMapSnapshot(routeSegments: [], referenceSegments: [], eventMarkers: [], markerOffsets: [:], currentCoordinate: points[1], currentCourse: 20, currentState: .recording, theme: .lime, recordedDrawingGroups: [completed])
        coordinator.snapshot = snapshot; coordinator.render(in: map)
        let source = try XCTUnwrap(style.source(withIdentifier: "spiderroute-recorded-0"))
        let marker = try XCTUnwrap(map.annotations?.first)
        map.setCamera(MLNMapCamera(lookingAtCenter: points[1], acrossDistance: 1_800, pitch: 30, heading: 45), animated: false)
        let before = map.camera.copy() as! MLNMapCamera
        snapshot.recordedDrawingGroups = [completed, .init(id: "1", segments: [[points[1], .init(latitude: 54.02, longitude: 27.02)]])]
        coordinator.snapshot = snapshot; coordinator.render(in: map)
        XCTAssertTrue(style.source(withIdentifier: "spiderroute-recorded-0") === source)
        XCTAssertTrue((map.annotations?.first as AnyObject?) === (marker as AnyObject))
        XCTAssertNotNil(style.source(withIdentifier: "spiderroute-recorded-1"))
        XCTAssertEqual(map.camera.centerCoordinate.latitude, before.centerCoordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(map.camera.heading, before.heading, accuracy: 0.01)
        XCTAssertEqual(map.camera.pitch, before.pitch, accuracy: 0.01)
        let reference = ReferenceRouteMarker(kind: .distance, meters: 15_000, latitude: 54.015, longitude: 27.015)
        snapshot.referenceMarkers = [reference]
        var retained: MLNAnnotation?
        for size in RouteDistanceLabelSize.allCases {
            snapshot.distanceLabelSize = size
            coordinator.snapshot = snapshot; coordinator.render(in: map)
            let annotation = try XCTUnwrap(map.annotations?.first { $0.coordinate.latitude == reference.latitude && $0.coordinate.longitude == reference.longitude })
            if let retained { XCTAssertTrue((annotation as AnyObject) === (retained as AnyObject)) }
            retained = annotation
            let view = try XCTUnwrap(coordinator.mapView(map, viewFor: annotation))
            let presentation = ReferenceMarkerPresentation(marker: reference, size: size)
            XCTAssertEqual(view.bounds.height, presentation.canvasHeight)
            XCTAssertEqual(view.centerOffset.dy + view.bounds.height / 2, 4, accuracy: 0.01)
            XCTAssertEqual(annotation.coordinate.latitude, reference.latitude)
            XCTAssertTrue(style.source(withIdentifier: "spiderroute-recorded-0") === source)
            XCTAssertEqual(map.camera.heading, before.heading, accuracy: 0.01)
        }
        map.delegate = nil
    }

    @MainActor
    func testMapLanguagePersistsSeparatelyFromAppAndDownloadLanguage() throws {
        let suite = "MapLanguage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en-US", forKey: "app_language_preference")
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.mapLanguageID)
        settings.mapLanguageID = "ru"
        XCTAssertEqual(AppSettings(defaults: defaults).mapLanguageID, "ru")
        XCTAssertEqual(defaults.string(forKey: "app_language_preference"), "en-US")
        let metadata = DownloadedMapMetadata(name: "Minsk", languageID: "ru", bounds: .init(sw: .init(latitude: 53.89, longitude: 27.55), ne: .init(latitude: 53.91, longitude: 27.58)))
        let restored = try JSONDecoder().decode(DownloadedMapMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(restored, metadata)
        XCTAssertEqual(restored.languageID, "ru")
        settings.mapLanguageID = "de"
        XCTAssertEqual(restored.languageID, "ru")
        settings.reset(); XCTAssertNil(settings.mapLanguageID)
    }

    func testLocalizedOSMStyleChangesNamesAndPreservesRoadNumbers() throws {
        let data = Data(#"{"version":8,"sources":{},"layers":[{"id":"city","layout":{"text-field":["get","name"]}},{"id":"shield","layout":{"text-field":["get","ref"]}}]}"#.utf8)
        let localized = try JSONSerialization.jsonObject(with: OSMMapStyle.localized(data, languageID: "ru")) as! [String: Any]
        let layers = localized["layers"] as! [[String: Any]]
        let name = (layers[0]["layout"] as! [String: Any])["text-field"] as! [Any]
        XCTAssertEqual(name[0] as? String, "coalesce")
        XCTAssertEqual(name[1] as? [String], ["get", "name:ru"])
        XCTAssertEqual(name.last as? [String], ["get", "name"])
        XCTAssertEqual((layers[1]["layout"] as! [String: Any])["text-field"] as? [String], ["get", "ref"])
        XCTAssertEqual(OSMMapStyle.languageCode("en-GB"), "en")
        XCTAssertEqual(OSMMapStyle.languageCode("zh-Hant"), "zh-Hant")
        let small = MLNCoordinateBounds(sw: .init(latitude: 53.89, longitude: 27.55), ne: .init(latitude: 53.91, longitude: 27.58))
        XCTAssertLessThan(OSMMapStyle.estimatedTileCount(small), 2_500)
        let world = MLNCoordinateBounds(sw: .init(latitude: -80, longitude: -180), ne: .init(latitude: 80, longitude: 180))
        XCTAssertGreaterThan(OSMMapStyle.estimatedTileCount(world), 2_500)
    }

    func testGuideMarkersUseDetailZoomHysteresis() {
        XCTAssertFalse(RouteGuideMapVisibility.showsDetails(distance: 100_000, wasVisible: true))
        XCTAssertFalse(RouteGuideMapVisibility.showsDetails(distance: 4_500, wasVisible: false))
        XCTAssertTrue(RouteGuideMapVisibility.showsDetails(distance: 4_500, wasVisible: true))
        XCTAssertTrue(RouteGuideMapVisibility.showsDetails(distance: 1_200, wasVisible: false))
        XCTAssertFalse(RouteGuideMapVisibility.showsDetails(distance: .nan, wasVisible: true))
        XCTAssertFalse(RouteGuideMapVisibility.showsDetails(distance: 0, wasVisible: false))
    }

    @MainActor
    func testMarkerLayoutPublicationDoesNotRetainMapProjection() {
        let state = ReferenceMarkerLayoutState()
        let marker = ReferenceRouteMarker(kind: .start, meters: 0, latitude: 54, longitude: 30)
        var projectionIsValid = true
        var calls = 0
        let prepared = state.prepare(markers: [marker], heading: 35) { _ in
            XCTAssertTrue(projectionIsValid)
            calls += 1
            return CGPoint(x: 120, y: 120)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(state.labeledIDs.isEmpty, "Preparing coordinates must not publish during a map callback")
        projectionIsValid = false
        XCTAssertTrue(state.apply(prepared))
        XCTAssertEqual(state.labeledIDs, ["start"])
        XCTAssertEqual(state.heading, 35)
        XCTAssertEqual(calls, 1, "Deferred publication cannot call the expired map projection")
        XCTAssertTrue(state.update(markers: [], heading: 35) { _ in XCTFail("No markers to project"); return nil })
        XCTAssertTrue(state.labeledIDs.isEmpty)
    }

    @MainActor
    func testLegacyMarkerHostingKeepsTheTickAtTheMapKitAnchor() throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 375, height: 500))
        let coordinator = LegacyRouteMapSurface.Coordinator(onCameraChanged: { _,_,_ in }, onCameraSettled: { _,_,_ in })
        let markers = [
            ReferenceRouteMarker(kind: .distance, meters: 10_000, latitude: 53.96090536842297, longitude: 27.570619038826706),
            ReferenceRouteMarker(kind: .start, meters: 0, latitude: 53.922379, longitude: 27.624129, horizontalOffset: -28),
            ReferenceRouteMarker(kind: .finish, meters: 85_750, latitude: 54.301871, longitude: 26.835857, horizontalOffset: 28)
        ]
        let snapshot = RouteMapSnapshot(routeSegments: [], referenceSegments: [], eventMarkers: [], markerOffsets: [:],
            currentCoordinate: nil, currentCourse: 0, currentState: .idle, theme: .amber, referenceMarkers: markers)
        coordinator.render(snapshot, in: map)
        for annotation in map.annotations {
            let view = try XCTUnwrap(coordinator.mapView(map, viewFor: annotation))
            let host = try XCTUnwrap(view.subviews.first)
            view.layoutIfNeeded(); host.layoutIfNeeded()
            XCTAssertEqual(host.frame, view.bounds, "Autoresizing must not double the hosted marker size")
            XCTAssertEqual(view.center, .zero, "Sizing must preserve the center owned by MapKit")
            let native = try XCTUnwrap(view as? LegacyReferenceMarkerAnnotationView)
            let tick = host.convert(native.coordinateAnchor, to: view)
            XCTAssertLessThan(tick.y + 3.5, host.bounds.maxY, "The complete rotated tick must fit inside its drawing canvas")
            XCTAssertEqual(tick.x, view.bounds.midX, accuracy: 0.01)
            XCTAssertEqual(tick.y + view.centerOffset.y, view.bounds.midY, accuracy: 0.01,
                           "The tick's tip must project onto the annotation coordinate")
        }
    }

    func testMarkerPanReusesLocalizedPresentationAndInvalidatesOnRouteOrLocaleChanges() {
        var markers: [ReferenceRouteMarker] = []
        for index in 0...41 {
            let kind: ReferenceRouteMarker.Kind = index == 0 ? .start : (index == 41 ? .finish : .distance)
            markers.append(ReferenceRouteMarker(kind: kind, meters: Double(index) * 5_000,
                latitude: 54 + Double(index) * 0.03, longitude: 30))
        }
        var cache = ReferenceMarkerPresentationCache()
        XCTAssertTrue(cache.prepare(markers: markers, localeID: "en-US"))
        let original = cache.ordered.map(\.distanceLabel)
        let started = CACurrentMediaTime()
        for frame in 0..<600 {
            XCTAssertFalse(cache.prepare(markers: markers, localeID: "en-US"), "A pan must never rebuild formatted labels")
            let visible = ReferenceMarkerLabelLayout.visibleIDs(presentations: cache.ordered,
                size: CGSize(width: 414, height: 600)) {
                CGPoint(x: 150 + sin(Double(frame) / 30) * 90, y: ($0.latitude - 54) * 800)
            }
            XCTAssertTrue(visible.contains("start"))
        }
        print("MARKER_PAN 600 frames, 42 markers, cached layout seconds=\(CACurrentMediaTime() - started)")
        XCTAssertEqual(cache.ordered.map(\.distanceLabel), original)
        XCTAssertTrue(cache.prepare(markers: markers, localeID: "ru-RU"), "Language changes must invalidate cached labels")
        let reversed = ReferenceRouteMarker.make(points: markers.reversed().map {
            ReferenceRoutePoint(latitude: $0.latitude, longitude: $0.longitude)
        })
        XCTAssertTrue(cache.prepare(markers: reversed, localeID: "ru-RU"))
        XCTAssertEqual(cache.byID["start"]?.marker.latitude, markers.last?.latitude)
        XCTAssertTrue(cache.prepare(markers: [], localeID: "ru-RU"))
        XCTAssertTrue(cache.byID.isEmpty)
    }

    @MainActor
    func testNativeReferenceViewCanBeReusedWithoutMovingCoordinateOrKeepingOldLabel() {
        let view = LegacyReferenceMarkerAnnotationView(annotation: nil, reuseIdentifier: "reference-distance")
        for (kind, meters, offset) in [(ReferenceRouteMarker.Kind.start, 0.0, -28.0), (.finish, 201_710.0, 28.0), (.distance, 105_000.0, 0.0)] {
            let marker = ReferenceRouteMarker(kind: kind, meters: meters, latitude: 54, longitude: 30, horizontalOffset: offset)
            let presentation = ReferenceMarkerPresentation(marker: marker)
            view.center = CGPoint(x: 123, y: 456)
            view.configure(presentation, showsLabel: true, heading: 45)
            XCTAssertEqual(view.center, CGPoint(x: 123, y: 456))
            XCTAssertEqual(view.coordinateAnchor.y + view.centerOffset.y, view.bounds.midY)
            XCTAssertEqual(view.accessibilityLabel, presentation.accessibilityLabel)
            XCTAssertEqual(view.subviews.count, 1)
            XCTAssertEqual(view.subviews.first?.frame, view.bounds)
            view.prepareForReuse()
        }
    }

    @MainActor
    func testRecordedEventHostingKeepsTheBadgeCanvasAtItsCoordinate() throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 375, height: 260))
        let coordinator = LegacyRouteMapSurface.Coordinator(onCameraChanged: { _,_,_ in }, onCameraSettled: { _,_,_ in })
        let events = [RouteEventKind.start, .finish, .pause, .resume].enumerated().map { index, kind in
            RouteEventMarker(id: "event-\(index)", kind: kind,
                coordinate: CLLocationCoordinate2D(latitude: 53.9 + Double(index) * 0.01, longitude: 27.55))
        }
        let snapshot = RouteMapSnapshot(routeSegments: [events.map(\.coordinate)], referenceSegments: [],
            eventMarkers: events, markerOffsets: RouteEventMarkers.visualOffsets(for: events),
            currentCoordinate: nil, currentCourse: 0, currentState: .idle, theme: .amber)
        coordinator.render(snapshot, in: map)
        for annotation in map.annotations {
            let view = try XCTUnwrap(coordinator.mapView(map, viewFor: annotation))
            let host = try XCTUnwrap(view.subviews.first)
            view.layoutIfNeeded(); host.layoutIfNeeded()
            XCTAssertEqual(view.bounds.size, CGSize(width: 70, height: 70))
            XCTAssertEqual(host.frame, view.bounds)
            XCTAssertEqual(view.center, .zero, "Resizing must not move MapKit's coordinate anchor")
            XCTAssertEqual(view.centerOffset, .zero)
            let badgeAnchor = host.convert(CGPoint(x: 35, y: 35), to: view)
            XCTAssertEqual(badgeAnchor.x, view.bounds.midX, accuracy: 0.01)
            XCTAssertEqual(badgeAnchor.y, view.bounds.midY, accuracy: 0.01)
        }
    }

    func testReferenceMarkerLabelsDeclutterButKeepEndpointsAndRevealOnZoom() {
        var markers: [ReferenceRouteMarker] = []
        for index in 0...20 {
            let kind: ReferenceRouteMarker.Kind = index == 0 ? .start : (index == 20 ? .finish : .distance)
            markers.append(ReferenceRouteMarker(kind: kind, meters: Double(index) * 5_000,
                                                latitude: 0, longitude: Double(index)))
        }
        let size = CGSize(width: 375, height: 450)
        let overview = ReferenceMarkerLabelLayout.visibleIDs(markers: markers, size: size) {
            CGPoint(x: 25 + $0.longitude * 16, y: 200)
        }
        XCTAssertTrue(overview.contains("start"))
        XCTAssertTrue(overview.contains("finish"))
        XCTAssertLessThan(overview.count, markers.count)
        XCTAssertGreaterThan(overview.count, 2)
        let zoomed = ReferenceMarkerLabelLayout.visibleIDs(markers: Array(markers.prefix(4)), size: size) {
            CGPoint(x: 25 + $0.longitude * 85, y: 200)
        }
        XCTAssertEqual(zoomed, Set(markers.prefix(4).map(\.id)))
        XCTAssertEqual(markers.count, 21, "Label layout must not remove 5 km tick geometry")
    }

    func testKilometerTicksAreProtectedEndpointsOfTheRenderedLineInBothDirections() {
        // A sparse road exposes independent line generalization: marker coordinates
        // inside an MKPolyline may be skipped by its zoom-dependent renderer.
        let points: [ReferenceRoutePoint] = [.init(latitude: 54, longitude: 30),
            .init(latitude: 54.1, longitude: 30.2), .init(latitude: 55, longitude: 30.4)]
        let route = ReferenceRoute(id: UUID(), name: "Sparse road", sourceFileName: "road.gpx", segments: [points])
        let display = ReferenceRouteDisplay(route: route)
        let ends = display.segments.flatMap { [$0.first!, $0.last!] }
        for marker in display.forwardMarkers + display.reverseMarkers {
            XCTAssertTrue(ends.contains { abs($0.latitude - marker.latitude) < 1e-10 && abs($0.longitude - marker.longitude) < 1e-10 },
                          "\(marker.id) must be an exact polyline endpoint at every zoom")
        }
        XCTAssertEqual(route.segments, [points], "Pinning display geometry must never modify source points")
        XCTAssertEqual(display.distance, route.distance)
    }

    func testReferenceKilometerMarkersUseOriginalDistanceAndBothEndpoints() {
        let points = [ReferenceRoutePoint(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.77)]
        let markers = ReferenceRouteMarker.make(points: points)
        XCTAssertEqual(markers.first?.kind, .start)
        XCTAssertEqual(markers.last?.kind, .finish)
        XCTAssertEqual(markers.filter { $0.kind == .distance }.map(\.meters), Array(stride(from: 5_000.0, through: 85_000, by: 5_000)))
        for marker in markers where marker.kind == .distance {
            XCTAssertEqual(CLLocation(latitude: 0, longitude: 0).distance(from: CLLocation(latitude: marker.latitude, longitude: marker.longitude)), marker.meters, accuracy: 1)
        }
        XCTAssertEqual(markers.last?.longitude, points.last?.longitude)
        let reverse = ReferenceRouteMarker.make(points: Array(points.reversed()))
        XCTAssertEqual(reverse.first?.longitude, points.last?.longitude)
        XCTAssertEqual(reverse.last?.longitude, points.first?.longitude)
        XCTAssertGreaterThan(reverse[1].longitude, markers[1].longitude)
    }

    func testReferenceMarkersHandleShortRoutesLoopsDuplicatesAndDateLine() {
        let short: [ReferenceRoutePoint] = [.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.01)]
        XCTAssertEqual(ReferenceRouteMarker.make(points: short).map(\.kind), [.start, .finish])
        let loop = ReferenceRouteMarker.make(points: short + [short[0]])
        XCTAssertEqual(loop.first?.coordinate.latitude, loop.last?.coordinate.latitude)
        XCTAssertEqual(loop.first?.coordinate.longitude, loop.last?.coordinate.longitude)
        XCTAssertLessThan(loop.first!.horizontalOffset, 0)
        XCTAssertGreaterThan(loop.last!.horizontalOffset, 0)
        let acrossDateLine = ReferenceRouteMarker.make(points: [.init(latitude: 0, longitude: 179.8), .init(latitude: 0, longitude: -179.8)])
        XCTAssertEqual(acrossDateLine.filter { $0.kind == .distance }.count, 8)
        XCTAssertTrue(acrossDateLine.allSatisfy { abs($0.longitude) > 179 })
    }

    @MainActor
    func testReferenceMarkerPreferencesPersistAndDoNotChangeImportedGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        let data = Data("<gpx><trk><trkseg><trkpt lat=\"0\" lon=\"0\"/><trkpt lat=\"0\" lon=\"0.77\"/></trkseg></trk></gpx>".utf8)
        let route = try store.importRoute(data: data, fileName: "ride.gpx")
        XCTAssertTrue(store.showsDistanceMarkers)
        let original = store.display(for: route).segments
        store.reverseDirection(of: route)
        store.showsDistanceMarkers = false
        XCTAssertEqual(store.markers(for: route).map(\.kind), [.start, .finish])
        XCTAssertEqual(store.markers(for: route).first?.longitude, 0.77)
        let reloaded = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        XCTAssertTrue(reloaded.isReversed(route))
        XCTAssertFalse(reloaded.showsDistanceMarkers)
        XCTAssertEqual(reloaded.route?.segments, route.segments)
        XCTAssertEqual(reloaded.display(for: route).segments.flatMap { $0.map(\.longitude) }, original.flatMap { $0.map(\.longitude) })
        reloaded.delete(route.id)
        let empty = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        XCTAssertTrue(empty.routes.isEmpty)
        XCTAssertTrue(empty.reversedRouteIDs.isEmpty)
        XCTAssertFalse(empty.showsDistanceMarkers, "The user's default survives an empty library")
    }

    @MainActor
    func testReferenceMarkersMigrateOldLibraryAndExcludeDisconnectedSegments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = ReferenceRoute(id: UUID(), name: "Split", sourceFileName: "split.gpx", segments: [
            [.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.1)],
            [.init(latitude: 0, longitude: 1), .init(latitude: 0, longitude: 1.1)]
        ])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(route))
        let old = try JSONSerialization.data(withJSONObject: ["version": 2, "routes": [encoded], "selectedRouteID": route.id.uuidString, "isVisible": true])
        try old.write(to: directory.appendingPathComponent("reference-route.json"))
        let store = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        XCTAssertTrue(store.showsDistanceMarkers)
        XCTAssertEqual(store.route, route)
        XCTAssertTrue(store.markers(for: route).isEmpty)
        store.reverseDirection(of: route)
        XCTAssertFalse(store.isReversed(route))
        XCTAssertFalse(route.supportsDistanceMarkers)
    }

    @MainActor
    func testLongImportedRouteRetainsOverlayWhileRecordingGrows() {
        let reference = (0..<20_000).map { index in
            CLLocationCoordinate2D(latitude: 53.9 + Double(index) * 0.00001,
                                   longitude: 27.55 + sin(Double(index) / 500) * 0.02)
        }
        var recorded = Array(reference.prefix(7_200))
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 414, height: 500))
        let coordinator = LegacyRouteMapSurface.Coordinator(onCameraChanged: { _, _, _ in }, onCameraSettled: { _, _, _ in })
        func snapshot() -> RouteMapSnapshot {
            RouteMapSnapshot(routeSegments: [recorded], referenceSegments: [reference],
                eventMarkers: [], markerOffsets: [:], currentCoordinate: recorded.last,
                currentCourse: 0, currentState: .recording, theme: .amber)
        }
        coordinator.render(snapshot(), in: map)
        let importedOverlay = map.overlays.first!
        let currentAnnotation = map.annotations.first!
        let start = CFAbsoluteTimeGetCurrent()
        for index in 7_200..<7_220 {
            recorded.append(reference[index])
            coordinator.render(snapshot(), in: map)
        }
        print("LONG_ROUTE_20_UPDATES_SECONDS=\(CFAbsoluteTimeGetCurrent() - start)")
        XCTAssertTrue(map.overlays.contains { $0 === importedOverlay }, "Recording must not tear down the imported GPX overlay")
        XCTAssertTrue(map.annotations.contains { $0 === currentAnnotation }, "Location marker identity must survive updates")
    }

    @MainActor
    func testCompletedRecordedChunksAndReferenceSurviveNewGPSPoints() {
        let map = MKMapView()
        let coordinator = LegacyRouteMapSurface.Coordinator(onCameraChanged: { _, _, _ in }, onCameraSettled: { _, _, _ in })
        var path = RouteDisplayPath()
        for index in 0..<7_200 {
            path.append(.init(latitude: 53.9 + Double(index) * 0.00001, longitude: 27.55))
        }
        let reference = RouteDisplayPath.chunks(for: (0..<20_000).map {
            CLLocationCoordinate2D(latitude: 53.9 + Double($0) * 0.00001, longitude: 27.55)
        })
        func snapshot() -> RouteMapSnapshot {
            RouteMapSnapshot(routeSegments: path.segments, referenceSegments: reference, eventMarkers: [], markerOffsets: [:], currentCoordinate: path.segments.last?.last, currentCourse: 0, currentState: .recording, theme: .amber)
        }
        coordinator.render(snapshot(), in: map)
        let stable = map.overlays.dropLast().map { ObjectIdentifier($0) }
        path.append(.init(latitude: 53.972, longitude: 27.55002))
        coordinator.render(snapshot(), in: map)
        XCTAssertEqual(map.overlays.dropLast().map { ObjectIdentifier($0) }, stable)
        let all = map.overlays.map { ObjectIdentifier($0) }
        coordinator.render(snapshot(), in: map)
        XCTAssertEqual(map.overlays.map { ObjectIdentifier($0) }, all)
        let start = CFAbsoluteTimeGetCurrent()
        for index in 7_201..<7_221 {
            path.append(.init(latitude: 53.9 + Double(index) * 0.00001, longitude: 27.55))
            coordinator.render(snapshot(), in: map)
        }
        print("LONG_ROUTE_CACHED_20_UPDATES_SECONDS=\(CFAbsoluteTimeGetCurrent() - start)")
    }

    func testBackgroundCheckpointWritesFlushInOrderAndCannotResurrectAfterClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActiveTripCheckpointStore(applicationSupportURL: directory)
        let writer = ActiveTripCheckpointWriter(store: store)
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<30 {
            writer.save(ActiveTripCheckpoint(state: .recording, startedAt: start, points: [], elapsed: Double(index), savedAt: start.addingTimeInterval(Double(index))), synchronously: false)
        }
        writer.flush()
        XCTAssertEqual(store.load()?.elapsed, 29)
        writer.save(ActiveTripCheckpoint(state: .recording, startedAt: start, points: [], elapsed: 30, savedAt: start), synchronously: false)
        writer.clear()
        writer.flush()
        XCTAssertNil(store.load())
    }

    func testDisplaySimplificationPreservesEndpointsCornersAndSegmentBreaks() {
        let raw = (0..<10_000).map { index in
            CLLocationCoordinate2D(latitude: 53.9 + Double(index) * 0.000001, longitude: 27.55)
        }
        let chunks = RouteDisplayPath.chunks(for: raw)
        XCTAssertLessThan(chunks.flatMap { $0 }.count, 100)
        XCTAssertEqual(chunks.first?.first?.latitude, raw.first?.latitude)
        XCTAssertEqual(chunks.last?.last?.latitude, raw.last?.latitude)
        for (left, right) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(left.last?.latitude, right.first?.latitude)
        }
        let corner = [raw[0], CLLocationCoordinate2D(latitude: 53.9, longitude: 27.56), raw.last!]
        XCTAssertEqual(RouteDisplayPath.simplify(corner).count, 3)
        var path = RouteDisplayPath()
        for coordinate in raw { path.append(coordinate) }
        let previousEnd = path.segments.last!.last!
        path.append(.init(latitude: 54, longitude: 28), beginsNewSegment: true)
        path.append(.init(latitude: 54.001, longitude: 28))
        XCTAssertEqual(path.segments.dropLast().last?.last?.latitude, previousEnd.latitude)
        XCTAssertEqual(path.segments.last?.first?.latitude, 54)
        XCTAssertEqual(path.segments.last?.count, 2)
    }

    @MainActor
    func testImportedRouteDisplayCacheAvoidsRepeatedFullDistanceCalculation() throws {
        let points = (0..<20_000).map { index in
            ReferenceRoutePoint(latitude: 53.9 + Double(index) * 0.000001,
                                longitude: 27.55 + sin(Double(index) / 500) * 0.002)
        }
        let route = ReferenceRoute(id: UUID(), name: "Long ride", sourceFileName: "long.gpx", segments: [points])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        let first = store.display(for: route)
        XCTAssertLessThan(first.segments.flatMap { $0 }.count, points.count / 10)
        for _ in 0..<60 { XCTAssertEqual(store.display(for: route).distance, route.distance) }
        XCTAssertEqual(store.displayPreparationCount, 1, "Repeated map updates must reuse prepared geometry")

    }

    func testSuppliedRecordingDisplayAndExportPreserveAllPoints() async throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("performance-trip.json")),
              let referenceData = try? Data(contentsOf: directory.appendingPathComponent("performance-reference.gpx")) else {
            throw XCTSkip("Install a private GPX fixture with scripts/test-long-route.sh")
        }
        let trip = try JSONDecoder().decode(TripRecord.self, from: data)
        let reference = try ReferenceRouteImporter.decode(data: referenceData, fileName: "performance-reference.gpx")
        let display = ReferenceRouteDisplay(route: reference)
        XCTAssertEqual(reference.pointCount, trip.points.count)
        XCTAssertLessThanOrEqual(display.segments.flatMap { $0 }.count,
            reference.pointCount + display.segments.count + display.forwardMarkers.count + display.reverseMarkers.count)
        for format in RouteExportFormat.allCases {
            let document = try await RouteExporter.prepare(trip: trip, format: format)
            let exported = try ReferenceRouteImporter.decode(data: document.data, fileName: "recording.\(format.filenameExtension)")
            XCTAssertEqual(exported.pointCount, trip.points.count)
            XCTAssertEqual(exported.segments.count, trip.segments.count)
            XCTAssertEqual(exported.coordinates.first!.latitude, trip.points.first!.latitude, accuracy: 0.0000001)
            XCTAssertEqual(exported.coordinates.last!.longitude, trip.points.last!.longitude, accuracy: 0.0000001)
        }
        print("SUPPLIED_ROUTE original=\(reference.pointCount) displayed=\(display.segments.flatMap { $0 }.count) chunks=\(display.segments.count) exported_all_formats=true")
    }

    func testAsyncExportPreservesEveryPointAndSegment() async throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let points: [TrackPoint] = (0..<7_200).map { index -> TrackPoint in
            let latitude = 53.9 + Double(index) * 0.000001
            return TrackPoint(latitude: latitude, longitude: 27.55,
                       altitude: Double(index), metersPerSecond: 6, timestamp: date.addingTimeInterval(Double(index)),
                       beginsNewSegment: index == 3_600)
        }
        let trip = TripRecord(id: UUID(), startedAt: date, endedAt: date.addingTimeInterval(7_200), points: points, activity: "activity_cycling")
        for format in RouteExportFormat.allCases {
            let document = try await RouteExporter.prepare(trip: trip, format: format)
            let imported = try ReferenceRouteImporter.decode(data: document.data, fileName: "long.\(format.filenameExtension)")
            XCTAssertEqual(imported.pointCount, 7_200)
            XCTAssertEqual(imported.segments.count, 2)
        }
    }

    func testFollowCameraNeverFeedsDelayedAnimationZoomBackIntoCommands() {
        let center = CLLocationCoordinate2D(latitude: 53.9, longitude: 27.5)
        let intended = RouteCameraState(center: center, distance: 60_000, heading: 0, pitch: 0)
        let stale = RouteCameraState(center: center, distance: 160_000, heading: 0, pitch: 0)
        let user = RouteCameraState(center: center, distance: 20_000, heading: 20, pitch: 25)
        let command = RouteMapCameraCommand(target: .camera(intended))
        XCTAssertEqual(RouteMapCameraPolicy.followCamera(userCamera: nil, command: command, observedCamera: stale), intended)
        XCTAssertEqual(RouteMapCameraPolicy.followCamera(userCamera: user, command: command, observedCamera: stale), user)
    }

    func testMapRejectsUninitializedCameraTelemetry() {
        let center = CLLocationCoordinate2D(latitude: 53.9, longitude: 27.5)
        XCTAssertTrue(RouteCameraState(center: center, distance: 1_000, heading: 0, pitch: 0).isUsable)
        XCTAssertFalse(RouteCameraState(center: center, distance: .nan, heading: 0, pitch: 0).isUsable)
        XCTAssertFalse(RouteCameraState(center: center, distance: 0, heading: 0, pitch: 0).isUsable)
        XCTAssertFalse(RouteCameraState(center: .init(latitude: .nan, longitude: 0), distance: 1_000, heading: 0, pitch: 0).isUsable)
    }

    func testHUDRotationCyclesThroughLandscapePortraitAndOppositeLandscape() {
        XCTAssertEqual(HUDOrientationMode.allCases, [.landscapeRight, .portrait, .landscapeLeft])
        XCTAssertEqual(HUDOrientationMode.landscapeRight.next, .portrait)
        XCTAssertEqual(HUDOrientationMode.portrait.next, .landscapeLeft)
        XCTAssertEqual(HUDOrientationMode.landscapeLeft.next, .landscapeRight)
        XCTAssertEqual(HUDOrientationMode.landscapeRight.interfaceMask, .landscapeRight)
        XCTAssertEqual(HUDOrientationMode.portrait.interfaceMask, .portrait)
        XCTAssertEqual(HUDOrientationMode.landscapeLeft.interfaceMask, .landscapeLeft)
    }

    func testHUDViewportKeepsOneTwoAndThreeDigitSpeedsInsidePhoneBounds() {
        for viewport in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
            let layout = HUDViewportLayout(viewport: viewport)
            XCTAssertGreaterThan(layout.numberWidth, 0)
            XCTAssertGreaterThan(layout.numberHeight, 0)
            XCTAssertLessThanOrEqual(layout.numberWidth, viewport.width - 40)
            XCTAssertLessThanOrEqual(layout.numberHeight, viewport.height * 0.54)

            for digits in 1...3 {
                let intrinsicWidth = CGFloat(digits) * 0.58 + CGFloat(digits - 1) * 0.075
                let renderedHeight = min(layout.numberHeight, layout.numberWidth / intrinsicWidth)
                let renderedWidth = intrinsicWidth * renderedHeight
                XCTAssertLessThanOrEqual(renderedWidth, layout.numberWidth + 0.001)
                XCTAssertLessThanOrEqual(renderedHeight, layout.numberHeight + 0.001)
            }
        }
    }

    func testHUDColorCycleKeepsGreenDefaultAndReturnsAfterThreeChoices() {
        XCTAssertEqual(HUDColorStyle.allCases, [.green, .amber, .cyan])
        XCTAssertEqual(HUDColorStyle.green.next, .amber)
        XCTAssertEqual(HUDColorStyle.amber.next, .cyan)
        XCTAssertEqual(HUDColorStyle.cyan.next, .green)
    }

    @MainActor
    func testHUDOptInDefaultsOffPersistsAndResetsWithoutLegacyAutoEnable() {
        let suite = "HUDOptIn.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["hud", "speed", "map", "trips"], forKey: "bottom_navigation_order")
        defaults.set("cyan", forKey: "hud_color_style")
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hudEnabled)
        XCTAssertEqual(settings.hudColorStyle, .cyan)
        settings.hudEnabled = true
        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.hudEnabled)
        XCTAssertEqual(restored.bottomNavigationOrder, [.map, .speed, .trips])
        restored.hudEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).hudEnabled)
        restored.hudEnabled = true
        restored.reset()
        XCTAssertFalse(AppSettings(defaults: defaults).hudEnabled)
        XCTAssertEqual(AppSettings(defaults: defaults).hudColorStyle, .green)
    }

    func testScreenWakePolicyPreventsSleepOnlyWhileTheAppIsActive() {
        XCTAssertTrue(ScreenWakePolicy.shouldDisableIdleTimer(for: .active))
        XCTAssertFalse(ScreenWakePolicy.shouldDisableIdleTimer(for: .inactive))
        XCTAssertFalse(ScreenWakePolicy.shouldDisableIdleTimer(for: .background))
    }

    @MainActor
    func testBottomNavigationOrderPersistsAndRepairsStoredValues() {
        let suiteName = "SpeedometerGPSTests.BottomNavigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["trips", "speed", "trips", "future-item"], forKey: "bottom_navigation_order")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.bottomNavigationOrder, [.trips, .speed, .map])

        settings.moveBottomNavigation(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(settings.bottomNavigationOrder, [.speed, .map, .trips])
        XCTAssertEqual(AppSettings(defaults: defaults).bottomNavigationOrder, [.speed, .map, .trips])

        settings.reset()
        XCTAssertEqual(AppSettings(defaults: defaults).bottomNavigationOrder, BottomNavigationItem.defaultOrder)
    }

    @MainActor
    func testConfiguredFirstBottomNavigationItemControlsLaunchPresentation() {
        let trips = MainShellView.initialNavigationState(
            order: [.trips, .map, .speed],
            isEntitled: false,
            startsWithPaywall: false
        )
        XCTAssertEqual(trips.tab, .trips)
        XCTAssertFalse(trips.showsPaywall)

        let fresh = MainShellView.initialNavigationState(order: [], isEntitled: false, startsWithPaywall: false)
        XCTAssertEqual(fresh.tab, .map)
        XCTAssertFalse(fresh.showsPaywall)
        let welcome = MainShellView.initialNavigationState(order: [], isEntitled: false, startsWithPaywall: true)
        XCTAssertTrue(welcome.showsPaywall)
    }

    @MainActor
    func testSpiderRouteMigratesLegacyTabOrderWithoutResettingRidePreferences() {
        let suite = "SpiderRouteMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["speed", "map", "trips", "hud"], forKey: "bottom_navigation_order")
        defaults.set(88, forKey: "maximum_speed")
        defaults.set("coral", forKey: "speed_theme")
        defaults.set(false, forKey: "sync_icloud")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.bottomNavigationOrder, [.map, .speed, .trips])
        XCTAssertEqual(settings.maximumSpeed, 88)
        XCTAssertEqual(settings.theme, .coral)
        XCTAssertFalse(settings.syncWithICloud)
        defaults.set(["hud", "trips", "map", "speed"], forKey: "bottom_navigation_order")
        XCTAssertEqual(AppSettings(defaults: defaults).bottomNavigationOrder, [.map, .speed, .trips])
        defaults.removeObject(forKey: "bottom_navigation_order")
        defaults.removeObject(forKey: "maximum_speed")
        defaults.removeObject(forKey: "speed_theme")
        let fresh = AppSettings(defaults: defaults)
        XCTAssertEqual(fresh.maximumSpeed, 60)
        XCTAssertEqual(fresh.theme, .lime)
    }

    func testLiveMapDoesNotAutoFitAfterUserZoomInAnyTripState() {
        for state in [TripState.recording, .paused, .idle] {
            XCTAssertFalse(
                RouteMapCameraPolicy.shouldAutomaticallyFit(
                    hasCoordinates: true,
                    userHasAdjustedCamera: true,
                    positionIsUserControlled: true,
                    tripState: state
                )
            )
        }
        XCTAssertTrue(
            RouteMapCameraPolicy.shouldAutomaticallyFit(
                hasCoordinates: true,
                userHasAdjustedCamera: false,
                positionIsUserControlled: false,
                tripState: .recording
            )
        )
    }

    func testLegacyMapRetainsCurrentLocationAnnotationAcrossLocationUpdates() {
        let currentLocation = LegacyMapAnnotationKey.currentLocation
        let unchangedEvent = LegacyMapAnnotationKey.event("start-1")
        let removedEvent = LegacyMapAnnotationKey.event("pause-1")
        let addedEvent = LegacyMapAnnotationKey.event("resume-1")
        let plan = LegacyMapAnnotationReconciliation.make(
            existing: [currentLocation, unchangedEvent, removedEvent],
            desired: [currentLocation, unchangedEvent, addedEvent]
        )

        XCTAssertEqual(plan.retained, [currentLocation, unchangedEvent])
        XCTAssertEqual(plan.added, [addedEvent])
        XCTAssertEqual(plan.removed, [removedEvent])
    }

    @MainActor
    func testFollowLocationSettingPersistsAndResetRestoresIt() {
        let suiteName = "SpeedometerGPSTests.FollowLocation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.followLocationOnMap)
        settings.followLocationOnMap = false
        XCTAssertFalse(AppSettings(defaults: defaults).followLocationOnMap)
        settings.reset()
        XCTAssertTrue(AppSettings(defaults: defaults).followLocationOnMap)
    }

    func testFollowLocationLooksAheadWithoutChangingTheRiderCoordinateSource() {
        let rider = CLLocationCoordinate2D(latitude: 53.9000, longitude: 27.5600)
        let north = RouteMapCameraPolicy.followCenter(location: rider, direction: 0, cameraDistance: 1_000)
        XCTAssertGreaterThan(north.latitude, rider.latitude)
        XCTAssertEqual(north.longitude, rider.longitude, accuracy: 0.000_01)
        let lookAheadMeters = CLLocation(latitude: rider.latitude, longitude: rider.longitude)
            .distance(from: CLLocation(latitude: north.latitude, longitude: north.longitude))
        XCTAssertEqual(lookAheadMeters, 160, accuracy: 1)

        let noDirection = RouteMapCameraPolicy.followCenter(location: rider, direction: nil, cameraDistance: 1_000)
        XCTAssertEqual(noDirection.latitude, rider.latitude, accuracy: 0.000_001)
        XCTAssertEqual(noDirection.longitude, rider.longitude, accuracy: 0.000_001)
        XCTAssertEqual(RouteMapCameraPolicy.followAnimationDuration, 0.9)

        let chosenCamera = RouteCameraState(
            center: CLLocationCoordinate2D(latitude: 1, longitude: 1),
            distance: 1_250,
            heading: 73,
            pitch: 42
        )
        let followed = RouteMapCameraPolicy.followedCamera(
            preserving: chosenCamera,
            location: rider,
            direction: 90
        )
        XCTAssertEqual(followed.distance, chosenCamera.distance)
        XCTAssertEqual(followed.heading, chosenCamera.heading)
        XCTAssertEqual(followed.pitch, chosenCamera.pitch)
        XCTAssertGreaterThan(followed.center.longitude, rider.longitude)
    }

    func testFollowLocationWaitsForUserCameraGestureToSettle() {
        let gestureChange = Date(timeIntervalSinceReferenceDate: 10_000)

        XCTAssertTrue(
            RouteMapCameraPolicy.shouldApplyAutomaticFollow(
                lastUserCameraChange: nil,
                now: gestureChange
            )
        )
        XCTAssertFalse(
            RouteMapCameraPolicy.shouldApplyAutomaticFollow(
                lastUserCameraChange: gestureChange,
                now: gestureChange.addingTimeInterval(0.5)
            )
        )
        XCTAssertTrue(
            RouteMapCameraPolicy.shouldApplyAutomaticFollow(
                lastUserCameraChange: gestureChange,
                now: gestureChange.addingTimeInterval(RouteMapCameraPolicy.userInteractionSettlingInterval)
            )
        )
    }

    func testLocationProviderSelectionKeepsLegacyAndModernPathsSeparate() {
        XCTAssertEqual(LocationProviderSelector.kind(forMajorVersion: 15), .legacyManager)
        XCTAssertEqual(LocationProviderSelector.kind(forMajorVersion: 16), .legacyManager)
        XCTAssertEqual(LocationProviderSelector.kind(forMajorVersion: 17), .modernLiveUpdates)
        XCTAssertEqual(LocationProviderSelector.kind(forMajorVersion: 26), .modernLiveUpdates)
    }

    func testLocationTrackingLifecycleOnlyEnablesBackgroundWorkForActiveTrips() {
        let idle = LocationTrackingPolicy.legacyConfiguration(isTripActive: false)
        XCTAssertEqual(idle.desiredAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(idle.distanceFilter, 10)
        XCTAssertTrue(idle.pausesAutomatically)
        XCTAssertFalse(idle.allowsBackgroundUpdates)
        XCTAssertFalse(idle.showsBackgroundIndicator)
        XCTAssertFalse(LocationTrackingPolicy.needsModernBackgroundActivity(isTripActive: false))

        let recording = LocationTrackingPolicy.legacyConfiguration(isTripActive: true)
        XCTAssertEqual(recording.desiredAccuracy, kCLLocationAccuracyBestForNavigation)
        XCTAssertEqual(recording.distanceFilter, kCLDistanceFilterNone)
        XCTAssertFalse(recording.pausesAutomatically)
        XCTAssertTrue(recording.allowsBackgroundUpdates)
        XCTAssertTrue(recording.showsBackgroundIndicator)
        XCTAssertTrue(LocationTrackingPolicy.needsModernBackgroundActivity(isTripActive: true))
    }

    func testMapAndOfferCodeCompatibilityStrategies() {
        XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: 15), .legacyUIKit)
        XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: 16), .legacyUIKit)
        XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: 17), .modernSwiftUI)
        XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: 27, contentCount: 1000), .legacyUIKit)
        XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: 27, sourcePointCount: 4_999), .modernSwiftUI)
        XCTAssertEqual(RouteMapRendererSelector.kind(forMajorVersion: 27, sourcePointCount: 5_000), .legacyUIKit)
        let continuity = RouteMapRendererContinuity()
        let original = RouteMapCameraCommand(target: .region(RouteMapGeometry.fallbackRegion))
        XCTAssertEqual(continuity.command(kind: .modernSwiftUI, requested: original), original)
        let camera = RouteCameraState(center: .init(latitude: 50, longitude: 8), distance: 1400, heading: 45, pitch: 20)
        continuity.camera = camera
        let restored = continuity.command(kind: .legacyUIKit, requested: original)
        XCTAssertEqual(restored.target, .camera(camera))
        XCTAssertTrue(restored.overridesUserCamera)
        XCTAssertEqual(continuity.command(kind: .legacyUIKit, requested: original), restored)
        let requested = RouteMapCameraCommand(target: .region(RouteMapGeometry.fallbackRegion))
        XCTAssertEqual(continuity.command(kind: .legacyUIKit, requested: requested), requested)
        let selection = RouteMapCameraCommand(target: .region(RouteMapGeometry.fallbackRegion))
        XCTAssertEqual(continuity.command(kind: .modernSwiftUI, requested: selection), selection,
                       "A new route's fit must win when selection also changes renderer")
        XCTAssertEqual(continuity.command(kind: .modernSwiftUI, requested: selection), selection)
        XCTAssertEqual(OfferCodePresenterSelector.kind(forMajorVersion: 15), .legacyPaymentQueue)
        XCTAssertEqual(OfferCodePresenterSelector.kind(forMajorVersion: 16), .modernAppStore)
    }

    func testPlatformSymbolFallsBackWhenPreferredSymbolIsUnavailable() {
        XCTAssertEqual(
            PlatformSymbol.name("speedometer.gps.symbol.that.does.not.exist", fallback: "location"),
            "location"
        )
        XCTAssertEqual(PlatformSymbol.name("speedometer.gps.symbol.that.does.not.exist"), "questionmark.circle")
    }

    func testReferenceRouteDirectionUsesTheNearestSegmentAndTravelDirection() {
        let route = [[
            CLLocationCoordinate2D(latitude: 53.9000, longitude: 27.5600),
            CLLocationCoordinate2D(latitude: 53.9010, longitude: 27.5600),
            CLLocationCoordinate2D(latitude: 53.9020, longitude: 27.5610)
        ]]
        let forward = RouteMapGeometry.heading(
            along: route,
            nearestTo: CLLocationCoordinate2D(latitude: 53.9004, longitude: 27.5600),
            preferredDirection: 5
        )
        let reverse = RouteMapGeometry.heading(
            along: route,
            nearestTo: CLLocationCoordinate2D(latitude: 53.9004, longitude: 27.5600),
            preferredDirection: 185
        )
        XCTAssertEqual(forward ?? -1, 0, accuracy: 1)
        XCTAssertEqual(reverse ?? -1, 180, accuracy: 1)
    }

    @MainActor
    func testDeletingOneTripPersistsWithoutRemovingOtherTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 10_000)
        let first = TripRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(60), points: [], activity: "activity_cycling")
        let second = TripRecord(id: UUID(), startedAt: start.addingTimeInterval(120), endedAt: start.addingTimeInterval(180), points: [], activity: "activity_automotive")
        let store = RouteArchiveStore(localDocumentsURL: directory, cloudContainerIdentifier: nil, loadInBackground: false)
        store.add(first, syncWithICloud: false)
        store.add(second, syncWithICloud: false)

        store.delete(first, syncWithICloud: false)

        XCTAssertEqual(store.trips, [second])
        store.flushPersistence()
        XCTAssertEqual(RouteArchiveStore(localDocumentsURL: directory, cloudContainerIdentifier: nil, loadInBackground: false).trips, [second])
    }

#if DEBUG
    @MainActor
    func testDebugAccessModeTogglesAndPersistsPaidAndFreeStates() {
        let suiteName = "SpeedometerGPSTests.DebugAccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SubscriptionStore(observeTransactions: false, debugDefaults: defaults)
        XCTAssertFalse(store.debugPaidModeEnabled)

        store.toggleDebugAccessMode()
        XCTAssertTrue(store.isEntitled)
        XCTAssertTrue(SubscriptionStore(observeTransactions: false, debugDefaults: defaults).isEntitled)

        store.toggleDebugAccessMode()
        XCTAssertFalse(store.isEntitled)
        XCTAssertFalse(SubscriptionStore(observeTransactions: false, debugDefaults: defaults).isEntitled)

        store.toggleDebugAccessMode()
        store.resetDebugFreeMode()
        XCTAssertFalse(store.isEntitled)
    }
#endif

    @MainActor
    func testColdStoreKitPurchaseCreatesExactlyOneEntitlement() async throws {
        let configurationURL = try XCTUnwrap(
            Bundle(for: SpeedometerGPSCoreTests.self)
                .url(forResource: "Configuration", withExtension: "storekit")
        )
        let session = try SKTestSession(contentsOf: configurationURL)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let suiteName = "SpeedometerGPSTests.StoreKit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SubscriptionStore(observeTransactions: false, debugDefaults: defaults)
        XCTAssertTrue(store.canStartPurchase)
        let purchased = await store.purchase()
        XCTAssertTrue(purchased)

        let transactions = session.allTransactions()
        XCTAssertEqual(transactions.filter { $0.productIdentifier == SubscriptionStore.yearlyProductID }.count, 1)
        XCTAssertTrue(store.isEntitled)
    }

    @MainActor
    func testLifetimeColdPurchaseRestoresPermanentAccess() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Configuration", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let suite = "SpeedometerGPSTests.Lifetime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SubscriptionStore(observeTransactions: false, debugDefaults: defaults)
        let purchased = await store.purchase(plan: .lifetime)
        XCTAssertTrue(purchased)
        XCTAssertTrue(store.isEntitled)
        XCTAssertEqual(session.allTransactions().count, 1)
        XCTAssertEqual(session.allTransactions().first?.productIdentifier, SubscriptionStore.lifetimeProductID)
        let restored = SubscriptionStore(observeTransactions: false, debugDefaults: defaults)
        await restored.refreshEntitlement()
        XCTAssertTrue(restored.isEntitled)
        let duplicate = await store.purchase(plan: .lifetime)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(session.allTransactions().count, 1)
    }

    func testAccessPlanCatalogKeepsAnnualAndLifetimeDistinct() {
        XCTAssertEqual(AccessPlan.yearly.fallbackPrice, "$9.99")
        XCTAssertEqual(AccessPlan.lifetime.fallbackPrice, "$19.99")
        XCTAssertEqual(AccessPlan.yearly.productType, .autoRenewable)
        XCTAssertEqual(AccessPlan.lifetime.productType, .nonConsumable)
        XCTAssertEqual(AccessPlan.yearly.actionKey, "paywall_subscribe")
        XCTAssertEqual(AccessPlan.lifetime.actionKey, "paywall_buy_lifetime")
    }

    @MainActor
    func testOfferCodeRedemptionOwnsTheCustomerFlowAndRecoversFromFailure() async {
        let suiteName = "SpeedometerGPSTests.OfferCodes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SubscriptionStore(observeTransactions: false, debugDefaults: defaults)
        var presentations = 0

        let unchanged = await store.redeemOfferCode {
            presentations += 1
        }
        XCTAssertEqual(unchanged, .unchanged)
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(store.activity, .idle)

        struct PresentationFailure: Error {}
        let failed = await store.redeemOfferCode {
            presentations += 1
            throw PresentationFailure()
        }
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(presentations, 2)
        XCTAssertEqual(store.activity, .idle)
        XCTAssertTrue(PurchasePolicy.blocksConflictingActions(.redeemingOfferCode))
        XCTAssertFalse(PurchasePolicy.canStart(entitled: false, activity: .redeemingOfferCode))
    }

    func testSpeedConversionsRoundTrip() {
        for unit in SpeedUnit.allCases {
            let converted = unit.value(fromMetersPerSecond: 27.5)
            XCTAssertEqual(unit.metersPerSecond(from: converted), 27.5, accuracy: 0.000_1)
        }
    }

    func testTripMetricsUseRecordedPoints() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            TrackPoint(latitude: 53.9000, longitude: 27.5600, altitude: 210, metersPerSecond: 10, timestamp: start),
            TrackPoint(latitude: 53.9010, longitude: 27.5610, altitude: 211, metersPerSecond: 20, timestamp: start.addingTimeInterval(60))
        ]
        let trip = TripRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(60), points: points, activity: "activity_automotive")
        XCTAssertGreaterThan(trip.distance, 100)
        XCTAssertEqual(trip.duration, 60)
        XCTAssertEqual(trip.topSpeed, 20)
        XCTAssertEqual(trip.averageSpeed, 15)
    }

    func testLanguageContractContainsFiftySelectorsAndNormalizesAliases() {
        XCTAssertEqual(AppLanguage.all.count, 50)
        XCTAssertEqual(AppLanguage.normalized("en"), "en-US")
        XCTAssertEqual(AppLanguage.normalized("es"), "es-ES")
        XCTAssertEqual(AppLanguage.normalized("iw"), "he")
        XCTAssertEqual(AppLanguage.normalized("nb-NO"), "no")
        XCTAssertEqual(AppLanguage.normalized("zh-TW"), "zh-Hant")
    }

    func testLoaderTimingAndReduceMotionState() {
        XCTAssertEqual(WelcomeStoryTiming.loaderDuration, 1.5)
        XCTAssertEqual(WelcomeStoryTiming.loadingProgress(at: 0, reducedMotion: true), 1)
        XCTAssertEqual(WelcomeStoryTiming.loadingProgress(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(WelcomeStoryTiming.loadingProgress(at: 1.5), 1, accuracy: 0.001)
        XCTAssertLessThan(WelcomeStoryTiming.loadingProgress(at: 0.5), WelcomeStoryTiming.loadingProgress(at: 1.0))
    }

    func testWelcomeRouteMarkerAndSpeedShareOneSlowTimeline() {
        let start = WelcomeStoryTiming.routeSnapshot(at: 0)
        let midpoint = WelcomeStoryTiming.routeSnapshot(at: WelcomeStoryTiming.routeTravelDuration / 2)
        let finish = WelcomeStoryTiming.routeSnapshot(at: WelcomeStoryTiming.routeTravelDuration)
        let reduced = WelcomeStoryTiming.routeSnapshot(at: 0, reducedMotion: true)

        XCTAssertEqual(start.progress, 0, accuracy: 0.001)
        XCTAssertEqual(start.speed, 18, accuracy: 0.001)
        XCTAssertEqual(midpoint.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(midpoint.speed, 27, accuracy: 0.001)
        XCTAssertEqual(finish.progress, 1, accuracy: 0.001)
        XCTAssertEqual(reduced.progress, 1, accuracy: 0.001)
        XCTAssertEqual(reduced.speed, 0, accuracy: 0.001)
        XCTAssertEqual(WelcomeStoryTiming.routeTravelDuration, 5.0)
        XCTAssertEqual(WelcomeStoryTiming.routeLoopDuration, 6.0)

        let size = CGSize(width: 320, height: 300)
        XCTAssertEqual(WelcomeRouteGeometry.point(at: 0, in: size).x, 32.288, accuracy: 0.001)
        XCTAssertEqual(WelcomeRouteGeometry.point(at: 0, in: size).y, 151.83, accuracy: 0.001)
        XCTAssertEqual(WelcomeRouteGeometry.point(at: 1, in: size).x, 288, accuracy: 0.001)
        XCTAssertEqual(WelcomeRouteGeometry.point(at: 1, in: size).y, 54.15, accuracy: 0.001)
        XCTAssertTrue(WelcomeRouteGeometry.heading(at: 0.5, in: size).isFinite)

        let headings = stride(from: 0.0, through: 1.0, by: 0.005)
            .map { WelcomeRouteGeometry.heading(at: $0, in: size) }
        for pair in zip(headings, headings.dropFirst()) {
            let wrappedDelta = atan2(sin(pair.1 - pair.0), cos(pair.1 - pair.0))
            XCTAssertLessThan(abs(wrappedDelta), 0.20)
        }
    }

    func testWelcomeDisplaySwipesFromNumberToGaugeBeforeRides() {
        XCTAssertEqual(WelcomeFlowPage.route.rawValue, 0)
        XCTAssertEqual(WelcomeFlowPage.display.rawValue, 1)
        XCTAssertEqual(WelcomeFlowPage.rides.rawValue, 2)

        let number = WelcomeStoryTiming.displaySnapshot(at: 0)
        let gauge = WelcomeStoryTiming.displaySnapshot(at: 3)
        let returnedNumber = WelcomeStoryTiming.displaySnapshot(at: 5.5)
        let reduced = WelcomeStoryTiming.displaySnapshot(at: 0, reducedMotion: true)

        XCTAssertEqual(number.pageOffset, 0, accuracy: 0.001)
        XCTAssertEqual(gauge.pageOffset, 1, accuracy: 0.001)
        XCTAssertEqual(returnedNumber.pageOffset, 2, accuracy: 0.001)
        XCTAssertEqual(reduced.speed, 24, accuracy: 0.001)
        XCTAssertEqual(WelcomeStoryTiming.displayLoopDuration, 6.6)
    }

    func testSpeedometerNeedleMatchesTheDisplayedScale() {
        XCTAssertEqual(SpeedometerGaugeGeometry.needleAngle(speed: 0, maximum: 140), 135, accuracy: 0.001)
        XCTAssertEqual(SpeedometerGaugeGeometry.needleAngle(speed: 70, maximum: 140), 270, accuracy: 0.001)
        XCTAssertEqual(SpeedometerGaugeGeometry.needleAngle(speed: 140, maximum: 140), 405, accuracy: 0.001)
        XCTAssertEqual(SpeedometerGaugeGeometry.needleAngle(speed: 200, maximum: 140), 405, accuracy: 0.001)
    }

    func testSpeedDashboardUsesBoundedGaugeSizesAcrossPhonesAndPads() {
        let mini = SpeedDashboardLayout(viewport: CGSize(width: 320, height: 568))
        let phone = SpeedDashboardLayout(viewport: CGSize(width: 393, height: 690))
        let pad = SpeedDashboardLayout(viewport: CGSize(width: 680, height: 900))
        let widePad = SpeedDashboardLayout(viewport: CGSize(width: 1024, height: 1200))

        XCTAssertTrue(mini.compact)
        XCTAssertEqual(mini.gaugeDiameter, 284)
        XCTAssertEqual(phone.gaugeDiameter, 330)
        XCTAssertEqual(pad.gaugeDiameter, 330)
        XCTAssertEqual(widePad.gaugeDiameter, 440)
        XCTAssertLessThanOrEqual(mini.gaugeDiameter, 320 - 36)
        XCTAssertEqual(mini.speedDisplayHeight, 326)
        XCTAssertEqual(phone.speedDisplayHeight, 378)
        XCTAssertEqual(widePad.speedDisplayHeight, 500)
    }

    @MainActor
    func testStandaloneDigitalUsesAppearanceSpecificPersistedDefaults() {
        let suiteName = "SpeedometerGPSTests.DisplayColors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        var red: CGFloat = -1
        var green: CGFloat = -1
        var blue: CGFloat = -1
        var alpha: CGFloat = -1
        XCTAssertTrue(UIColor(settings.speedNumberColor(for: .light)).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 0, accuracy: 0.001)
        XCTAssertEqual(green, 0, accuracy: 0.001)
        XCTAssertEqual(blue, 0, accuracy: 0.001)
        XCTAssertEqual(alpha, 1, accuracy: 0.001)

        let dark = UIColor(settings.speedNumberColor(for: .dark))
        let expectedDark = UIColor(AppPalette.digitalGreen)
        XCTAssertEqual(dark.cgColor.components, expectedDark.cgColor.components)
        XCTAssertEqual(UIColor(settings.speedNumberInactiveColor(for: .light)).cgColor.alpha, 0.022, accuracy: 0.001)
        XCTAssertNil(settings.speedNumberOutlineColor(for: .light))
        XCTAssertNil(settings.speedNumberOutlineColor(for: .dark))

        settings.lightSpeedNumberColor = DisplayColor(red: 0.2, green: 0.3, blue: 0.4)
        settings.darkSpeedNumberColor = DisplayColor(red: 0.9, green: 0.8, blue: 0.7)
        settings.lightSpeedOutlineEnabled = true
        settings.darkSpeedOutlineEnabled = true
        settings.lightSpeedOutlineColor = DisplayColor(red: 1, green: 0, blue: 0)
        settings.darkSpeedOutlineColor = DisplayColor(red: 0, green: 0, blue: 1)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.lightSpeedNumberColor, settings.lightSpeedNumberColor)
        XCTAssertEqual(reloaded.darkSpeedNumberColor, settings.darkSpeedNumberColor)
        XCTAssertEqual(reloaded.lightSpeedOutlineColor, settings.lightSpeedOutlineColor)
        XCTAssertEqual(reloaded.darkSpeedOutlineColor, settings.darkSpeedOutlineColor)
        XCTAssertNotNil(reloaded.speedNumberOutlineColor(for: .light))
        XCTAssertNotNil(reloaded.speedNumberOutlineColor(for: .dark))
    }

    @MainActor
    func testResetSpeedColorsRestoresOnlyAppearanceSpecificDefaults() {
        let suiteName = "SpeedometerGPSTests.ResetDisplayColors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        settings.unit = .milesPerHour
        settings.speedAlertEnabled = true
        settings.lightSpeedNumberColor = DisplayColor(red: 0.2, green: 0.3, blue: 0.4)
        settings.darkSpeedNumberColor = DisplayColor(red: 0.9, green: 0.8, blue: 0.7)
        settings.lightSpeedOutlineEnabled = true
        settings.darkSpeedOutlineEnabled = true
        settings.lightSpeedOutlineColor = DisplayColor(red: 1, green: 0, blue: 0)
        settings.darkSpeedOutlineColor = DisplayColor(red: 0, green: 0, blue: 1)

        settings.resetSpeedColors()

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.lightSpeedNumberColor, .black)
        XCTAssertEqual(reloaded.darkSpeedNumberColor, .digitalGreen)
        XCTAssertFalse(reloaded.lightSpeedOutlineEnabled)
        XCTAssertFalse(reloaded.darkSpeedOutlineEnabled)
        XCTAssertEqual(reloaded.lightSpeedOutlineColor, .white)
        XCTAssertEqual(reloaded.darkSpeedOutlineColor, .black)
        XCTAssertEqual(reloaded.unit, .milesPerHour)
        XCTAssertTrue(reloaded.speedAlertEnabled)
    }

    func testGPSQualityMapsAccuracyToCellularSignalLevels() {
        XCTAssertEqual(GPSQuality.signalLevel(horizontalAccuracy: -1), 0)
        XCTAssertEqual(GPSQuality.signalLevel(horizontalAccuracy: 8), 4)
        XCTAssertEqual(GPSQuality.signalLevel(horizontalAccuracy: 25), 3)
        XCTAssertEqual(GPSQuality.signalLevel(horizontalAccuracy: 50), 2)
        XCTAssertEqual(GPSQuality.signalLevel(horizontalAccuracy: 120), 1)
    }

    func testGPSSignalBarsUseUpwardOpticalAlignment() {
        XCTAssertEqual(GPSNetworkSignalGeometry.opticalVerticalOffset, -2)
    }

    func testLiveMapCameraFitsTheWholeRecordedRoute() {
        let coordinates = RouteMapView.mockRoute
        let region = RouteMapGeometry.region(fitting: coordinates)

        for coordinate in coordinates {
            XCTAssertLessThanOrEqual(abs(coordinate.latitude - region.center.latitude), region.span.latitudeDelta / 2)
            XCTAssertLessThanOrEqual(abs(coordinate.longitude - region.center.longitude), region.span.longitudeDelta / 2)
        }
        XCTAssertGreaterThan(RouteMapGeometry.heading(for: coordinates), 0)
        XCTAssertLessThan(RouteMapGeometry.heading(for: coordinates), 360)
    }

    func testSpeedAlertSoundsOnCrossingRepeatsAndUsesHysteresis() {
        let start = Date(timeIntervalSince1970: 10_000)
        let limit = 30.0
        var evaluator = SpeedAlertEvaluator()

        XCTAssertFalse(evaluator.shouldPlayAlert(speedMetersPerSecond: 29, limitMetersPerSecond: limit, isEnabled: true, now: start))
        XCTAssertTrue(evaluator.shouldPlayAlert(speedMetersPerSecond: 30, limitMetersPerSecond: limit, isEnabled: true, now: start))
        XCTAssertFalse(evaluator.shouldPlayAlert(speedMetersPerSecond: 34, limitMetersPerSecond: limit, isEnabled: true, now: start.addingTimeInterval(14)))
        XCTAssertTrue(evaluator.shouldPlayAlert(speedMetersPerSecond: 34, limitMetersPerSecond: limit, isEnabled: true, now: start.addingTimeInterval(15)))

        XCTAssertFalse(evaluator.shouldPlayAlert(speedMetersPerSecond: 29.5, limitMetersPerSecond: limit, isEnabled: true, now: start.addingTimeInterval(16)))
        XCTAssertTrue(evaluator.isAboveLimit)
        XCTAssertFalse(evaluator.shouldPlayAlert(speedMetersPerSecond: 28.5, limitMetersPerSecond: limit, isEnabled: true, now: start.addingTimeInterval(17)))
        XCTAssertFalse(evaluator.isAboveLimit)
        XCTAssertTrue(evaluator.shouldPlayAlert(speedMetersPerSecond: 31, limitMetersPerSecond: limit, isEnabled: true, now: start.addingTimeInterval(18)))

        XCTAssertFalse(evaluator.shouldPlayAlert(speedMetersPerSecond: 31, limitMetersPerSecond: limit, isEnabled: false, now: start.addingTimeInterval(19)))
        XCTAssertFalse(evaluator.isAboveLimit)
    }

    func testRouteExporterProducesGPXKMLGeoJSONAndCSV() throws {
        let trip = exportFixture

        let gpx = try XCTUnwrap(String(data: RouteExporter.data(for: trip, format: .gpx), encoding: .utf8))
        XCTAssertTrue(gpx.contains("<gpx version=\"1.1\""))
        XCTAssertTrue(gpx.contains("<trkpt lat=\"53.9000000\" lon=\"27.5600000\">"))
        XCTAssertTrue(gpx.contains("<speedometer:speed unit=\"m/s\">10.000</speedometer:speed>"))
        // Namespace identity stays stable; the consumer-facing link points to the app.
        XCTAssertTrue(gpx.contains("xmlns:speedometer=\"https://yumcut.com/mobile/speedometer-gps\""))
        XCTAssertTrue(gpx.contains("<link href=\"https://apps.apple.com/app/id6801154513\"><text>SpiderRoute</text><type>text/html</type></link>"))
        XCTAssertLessThan(try XCTUnwrap(gpx.range(of: "<link ")?.lowerBound),
                          try XCTUnwrap(gpx.range(of: "<time>")?.lowerBound), "GPX metadata links precede time in the schema")

        let kml = try XCTUnwrap(String(data: RouteExporter.data(for: trip, format: .kml), encoding: .utf8))
        XCTAssertTrue(kml.contains("<MultiGeometry>"))
        XCTAssertTrue(kml.contains("<LineString>"))
        XCTAssertTrue(kml.contains("27.5600000,53.9000000,210.00"))
        XCTAssertTrue(kml.contains("<Data name=\"applicationURL\"><value>https://apps.apple.com/app/id6801154513</value></Data>"))

        let geoJSONData = try RouteExporter.data(for: trip, format: .geoJSON)
        let geoJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: geoJSONData) as? [String: Any])
        XCTAssertEqual(geoJSON["type"] as? String, "FeatureCollection")
        let features = try XCTUnwrap(geoJSON["features"] as? [[String: Any]])
        XCTAssertEqual(features.count, 1)
        let properties = try XCTUnwrap(features.first?["properties"] as? [String: Any])
        XCTAssertEqual(properties["applicationURL"] as? String, "https://apps.apple.com/app/id6801154513")

        let csv = try XCTUnwrap(String(data: RouteExporter.data(for: trip, format: .csv), encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix("segment,timestamp,latitude,longitude,altitude_m,speed_m_s,activity,elapsed_s,"))
        XCTAssertEqual(csv.split(separator: "\n").count, 3)
        XCTAssertFalse(csv.contains("https://"), "CSV keeps its existing tabular contract without metadata rows")

        for format in RouteExportFormat.allCases {
            XCTAssertTrue(RouteExporter.filename(for: trip, format: format).hasSuffix(".\(format.filenameExtension)"))
            XCTAssertFalse(try RouteExporter.data(for: trip, format: format).isEmpty)
            let imported = try ReferenceRouteImporter.decode(data: RouteExporter.data(for: trip, format: format),
                                                             fileName: "route.\(format.filenameExtension)")
            XCTAssertEqual(imported.pointCount, trip.points.count)
            if format != .csv {
                XCTAssertEqual(imported.name, "SpiderRoute Ride 2024-08-11T11:40:00.000Z")
            }
        }
    }

    func testReferenceRouteImporterPreservesGPXSegmentsAndName() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>Weekend road</name>
            <trkseg>
              <trkpt lat="53.9000" lon="27.5600" />
              <trkpt lat="53.9100" lon="27.5700" />
            </trkseg>
            <trkseg>
              <trkpt lat="53.9200" lon="27.5800" />
              <trkpt lat="53.9300" lon="27.5900" />
            </trkseg>
          </trk>
        </gpx>
        """.utf8)

        let route = try ReferenceRouteImporter.decode(data: data, fileName: "weekend.gpx")

        XCTAssertEqual(route.name, "Weekend road")
        XCTAssertEqual(route.segments.count, 2)
        XCTAssertEqual(route.pointCount, 4)
        XCTAssertEqual(route.segments[1][0].latitude, 53.92, accuracy: 0.000_001)
        XCTAssertGreaterThan(route.distance, 2_000)
    }

    func testReferenceRouteImporterAcceptsGeoJSONMultiLineString() throws {
        let data = Data("""
        {
          "type": "FeatureCollection",
          "features": [{
            "type": "Feature",
            "properties": {"name": "Forest road"},
            "geometry": {
              "type": "MultiLineString",
              "coordinates": [
                [[27.56, 53.90], [27.57, 53.91]],
                [[27.58, 53.92], [27.59, 53.93]]
              ]
            }
          }]
        }
        """.utf8)

        let route = try ReferenceRouteImporter.decode(data: data, fileName: "forest.geojson")

        XCTAssertEqual(route.name, "Forest road")
        XCTAssertEqual(route.segments.map(\.count), [2, 2])
        XCTAssertEqual(route.segments[0][0].longitude, 27.56, accuracy: 0.000_001)
    }

    func testReferenceRouteImporterAcceptsKMLAndCSVSegments() throws {
        let kml = Data("""
        <kml><Document><name>Lake road</name><Placemark><MultiGeometry>
          <LineString><coordinates>27.56,53.90,0 27.57,53.91,0</coordinates></LineString>
          <LineString><coordinates>27.58,53.92,0 27.59,53.93,0</coordinates></LineString>
        </MultiGeometry></Placemark></Document></kml>
        """.utf8)
        let kmlRoute = try ReferenceRouteImporter.decode(data: kml, fileName: "lake.kml")
        XCTAssertEqual(kmlRoute.name, "Lake road")
        XCTAssertEqual(kmlRoute.segments.map(\.count), [2, 2])

        let csv = Data("""
        segment,latitude,longitude,title
        1,53.90,27.56,"Start, Minsk"
        1,53.91,27.57,Middle
        2,53.92,27.58,Resume
        2,53.93,27.59,Finish
        """.utf8)
        let csvRoute = try ReferenceRouteImporter.decode(data: csv, fileName: "weekend.csv")
        XCTAssertEqual(csvRoute.name, "weekend")
        XCTAssertEqual(csvRoute.segments.map(\.count), [2, 2])
    }

    func testReferenceRouteImporterRecognizesEveryShareableExtension() {
        for fileName in ["route.gpx", "route.KML", "route.geojson", "route.json", "route.csv"] {
            XCTAssertTrue(ReferenceRouteImporter.supports(fileName: fileName), fileName)
        }
        XCTAssertFalse(ReferenceRouteImporter.supports(fileName: "route.txt"))
        XCTAssertFalse(ReferenceRouteImporter.supports(fileName: "route"))
    }

    @MainActor
    func testIncomingReferenceRouteRequiresConfirmationBeforeImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedURL = directory.appendingPathComponent("shared.gpx")
        try Data("""
        <gpx version="1.1"><trk><name>Shared road</name><trkseg>
          <trkpt lat="53.90" lon="27.56"/><trkpt lat="53.91" lon="27.57"/>
        </trkseg></trk></gpx>
        """.utf8).write(to: sharedURL)

        let store = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        let coordinator = IncomingReferenceRouteCoordinator(processArguments: [])
        XCTAssertTrue(coordinator.receive(sharedURL))
        XCTAssertEqual(coordinator.currentURL, sharedURL)
        XCTAssertEqual(coordinator.currentName, "Shared road")
        XCTAssertTrue(store.routes.isEmpty, "Receiving a URL must not import before confirmation")

        coordinator.cancelCurrent()
        XCTAssertNil(coordinator.currentURL)
        XCTAssertTrue(store.routes.isEmpty, "Cancel must preserve the route library")

        XCTAssertTrue(coordinator.receive(sharedURL))
        coordinator.currentName = "  Edited shared road  "
        let imported = try coordinator.importCurrent(into: store)
        XCTAssertEqual(imported.name, "Edited shared road")
        XCTAssertEqual(store.routes, [imported])
        XCTAssertEqual(store.selectedRouteID, imported.id)
        XCTAssertTrue(store.isVisible)
        XCTAssertNil(coordinator.currentURL)
        XCTAssertFalse(coordinator.receive(directory.appendingPathComponent("unsupported.txt")))
    }

    @MainActor
    func testReferenceRouteRenamePersistsWithoutChangingGeometryOrSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("""
        <gpx version="1.1"><trk><name>Original road</name><trkseg>
          <trkpt lat="53.90" lon="27.56"/><trkpt lat="53.91" lon="27.57"/>
        </trkseg></trk></gpx>
        """.utf8)

        let store = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        let route = try store.importRoute(data: data, fileName: "original.gpx")
        XCTAssertFalse(store.rename(route.id, to: "   "))
        XCTAssertTrue(store.rename(route.id, to: "  Commute road  "))

        let reloaded = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        XCTAssertEqual(reloaded.route?.name, "Commute road")
        XCTAssertEqual(reloaded.route?.segments, route.segments)
        XCTAssertEqual(reloaded.route?.sourceFileName, "original.gpx")
        XCTAssertEqual(reloaded.selectedRouteID, route.id)
        XCTAssertTrue(reloaded.isVisible)
    }

    @MainActor
    func testReferenceRouteStorePersistsLibrarySelectionAndVisibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("""
        <gpx version="1.1"><trk><name>Saved road</name><trkseg>
          <trkpt lat="53.90" lon="27.56"/><trkpt lat="53.91" lon="27.57"/>
        </trkseg></trk></gpx>
        """.utf8)

        let store = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        let first = try store.importRoute(data: data, fileName: "saved.gpx")
        let second = try store.importRoute(data: data, fileName: "alternate.gpx")
        store.select(first.id)
        store.isVisible = false

        let reloaded = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        XCTAssertEqual(reloaded.routes.count, 2)
        XCTAssertEqual(reloaded.route?.name, "Saved road")
        XCTAssertEqual(reloaded.route?.pointCount, 2)
        XCTAssertEqual(reloaded.selectedRouteID, first.id)
        XCTAssertFalse(reloaded.isVisible)

        reloaded.delete(first.id)
        XCTAssertEqual(reloaded.routes.map(\.id), [second.id])
        XCTAssertEqual(reloaded.selectedRouteID, second.id)
    }

    @MainActor
    func testReferenceRouteStoreMigratesLegacySingleRouteWithoutBundledSeed() throws {
        struct LegacyState: Codable {
            let route: ReferenceRoute
            let isVisible: Bool
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyRoute = ReferenceRoute(
            id: UUID(),
            name: "Computer import",
            sourceFileName: "computer.gpx",
            segments: [[.init(latitude: 53.90, longitude: 27.56), .init(latitude: 53.91, longitude: 27.57)]]
        )
        try JSONEncoder().encode(LegacyState(route: legacyRoute, isVisible: true))
            .write(to: directory.appendingPathComponent("reference-route.json"))

        let migrated = ReferenceRouteStore(applicationSupportURL: directory, processArguments: [])
        XCTAssertEqual(migrated.routes, [legacyRoute])
        XCTAssertEqual(migrated.selectedRouteID, legacyRoute.id)
        XCTAssertTrue(migrated.isVisible)
    }

    func testRouteExporterPreservesRecoveredSegmentBoundaries() throws {
        let start = Date(timeIntervalSince1970: 1_723_376_400)
        let trip = TripRecord(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(180),
            points: [
                TrackPoint(latitude: 53.900, longitude: 27.560, altitude: 210, metersPerSecond: 10, timestamp: start),
                TrackPoint(latitude: 53.901, longitude: 27.561, altitude: 211, metersPerSecond: 11, timestamp: start.addingTimeInterval(60)),
                TrackPoint(latitude: 54.100, longitude: 27.800, altitude: 220, metersPerSecond: 12, timestamp: start.addingTimeInterval(120), beginsNewSegment: true),
                TrackPoint(latitude: 54.101, longitude: 27.801, altitude: 221, metersPerSecond: 13, timestamp: start.addingTimeInterval(180))
            ],
            activity: "activity_automotive",
            recordedDuration: 120
        )

        XCTAssertEqual(trip.segments.count, 2)
        let expectedDistance = CLLocation(latitude: 53.901, longitude: 27.561).distance(from: CLLocation(latitude: 53.900, longitude: 27.560))
            + CLLocation(latitude: 54.101, longitude: 27.801).distance(from: CLLocation(latitude: 54.100, longitude: 27.800))
        XCTAssertEqual(trip.distance, expectedDistance, accuracy: 0.01)

        let gpx = try XCTUnwrap(String(data: RouteExporter.data(for: trip, format: .gpx), encoding: .utf8))
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count - 1, 2)
        let kml = try XCTUnwrap(String(data: RouteExporter.data(for: trip, format: .kml), encoding: .utf8))
        XCTAssertEqual(kml.components(separatedBy: "<LineString>").count - 1, 2)
        let geoJSON = try JSONSerialization.jsonObject(with: RouteExporter.data(for: trip, format: .geoJSON)) as? [String: Any]
        let features = try XCTUnwrap(geoJSON?["features"] as? [[String: Any]])
        let geometry = try XCTUnwrap(features.first?["geometry"] as? [String: Any])
        XCTAssertEqual((geometry["coordinates"] as? [Any])?.count, 2)
        let csv = try XCTUnwrap(String(data: RouteExporter.data(for: trip, format: .csv), encoding: .utf8))
        XCTAssertTrue(csv.contains("\n1,"))
        XCTAssertTrue(csv.contains("\n2,"))
    }

    @MainActor
    func testSpeedAlertSettingsPersistInCanonicalMetersPerSecond() {
        let suiteName = "SpeedometerGPSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.speedAlertEnabled)
        XCTAssertEqual(settings.speedNumberStyle, .digital)
        XCTAssertEqual(settings.speedDashboardStyle, .number)
        XCTAssertEqual(settings.lightSpeedNumberColor, .black)
        XCTAssertEqual(settings.darkSpeedNumberColor, .digitalGreen)
        XCTAssertFalse(settings.lightSpeedOutlineEnabled)
        XCTAssertFalse(settings.darkSpeedOutlineEnabled)
        let initialAppearance = settings.appearance
        XCTAssertEqual(settings.speedAlertLimitMetersPerSecond, 25 / 3.6, accuracy: 0.001)

        settings.speedAlertEnabled = true
        settings.speedNumberStyle = .modern
        settings.speedDashboardStyle = .gauge
        settings.appearance = initialAppearance.toggled
        settings.lightSpeedNumberColor = DisplayColor(red: 0.12, green: 0.34, blue: 0.56)
        settings.darkSpeedNumberColor = DisplayColor(red: 0.65, green: 0.43, blue: 0.21)
        settings.lightSpeedOutlineEnabled = true
        settings.darkSpeedOutlineEnabled = true
        settings.speedAlertLimitMetersPerSecond = 88 / 2.236_936
        settings.unit = .milesPerHour

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.speedAlertEnabled)
        XCTAssertEqual(reloaded.speedNumberStyle, .modern)
        XCTAssertEqual(reloaded.speedDashboardStyle, .gauge)
        XCTAssertEqual(reloaded.appearance, initialAppearance.toggled)
        XCTAssertEqual(reloaded.lightSpeedNumberColor, settings.lightSpeedNumberColor)
        XCTAssertEqual(reloaded.darkSpeedNumberColor, settings.darkSpeedNumberColor)
        XCTAssertTrue(reloaded.lightSpeedOutlineEnabled)
        XCTAssertTrue(reloaded.darkSpeedOutlineEnabled)
        XCTAssertEqual(reloaded.unit, .milesPerHour)
        XCTAssertEqual(reloaded.speedAlertLimitMetersPerSecond, 88 / 2.236_936, accuracy: 0.001)

        reloaded.reset()
        XCTAssertEqual(reloaded.appearance, initialAppearance)
        XCTAssertEqual(reloaded.lightSpeedNumberColor, .black)
        XCTAssertEqual(reloaded.darkSpeedNumberColor, .digitalGreen)
        XCTAssertFalse(reloaded.lightSpeedOutlineEnabled)
        XCTAssertFalse(reloaded.darkSpeedOutlineEnabled)
    }

    func testPurchaseLoadingDoesNotBlockFirstTap() {
        XCTAssertTrue(PurchasePolicy.canStart(entitled: false, activity: .idle))
        XCTAssertTrue(PurchasePolicy.canStart(entitled: false, activity: .loadingProduct))
        XCTAssertFalse(PurchasePolicy.canStart(entitled: false, activity: .purchasing))
        XCTAssertFalse(PurchasePolicy.blocksConflictingActions(.loadingProduct))
        XCTAssertTrue(PurchasePolicy.blocksConflictingActions(.pending))
        XCTAssertTrue(PurchasePolicy.blocksConflictingActions(.restoring))
    }

    private var exportFixture: TripRecord {
        let start = Date(timeIntervalSince1970: 1_723_376_400)
        return TripRecord(
            id: UUID(uuidString: "A1C9B7D0-7328-41AE-A32D-0DAE51A8C739")!,
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            points: [
                TrackPoint(latitude: 53.9, longitude: 27.56, altitude: 210, metersPerSecond: 10, timestamp: start),
                TrackPoint(latitude: 53.901, longitude: 27.561, altitude: 211, metersPerSecond: 20, timestamp: start.addingTimeInterval(60))
            ],
            activity: "activity_automotive"
        )
    }
}

@MainActor
final class TripRecorderTests: XCTestCase {
    func testRouteEventMarkersDescribeNoOneAndMultiplePauses() {
        let start = Date(timeIntervalSince1970: 8_000)
        var points = [TrackPoint]()
        for index in 0..<6 {
            let latitude = 53.9 + Double(index) * 0.001
            let longitude = 27.56 + Double(index) * 0.001
            points.append(TrackPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: 210,
                metersPerSecond: 12,
                timestamp: start.addingTimeInterval(Double(index) * 10),
                beginsNewSegment: index == 2 || index == 4
            ))
        }

        XCTAssertEqual(RouteEventMarkers.make(points: Array(points[0...1]), isFinished: true).map(\.kind), [.start, .finish])
        XCTAssertEqual(RouteEventMarkers.make(points: Array(points[0...3]), isFinished: true).map(\.kind), [.start, .pause, .resume, .finish])
        XCTAssertEqual(
            RouteEventMarkers.make(points: points, isFinished: true).map(\.kind),
            [.start, .pause, .resume, .pause, .resume, .finish]
        )
    }

    func testNearbyRouteEventMarkersReceiveDistinctVisualOffsets() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 53.9, longitude: 27.56)
        let markers = [
            RouteEventMarker(id: "pause", kind: .pause, coordinate: coordinate),
            RouteEventMarker(id: "resume", kind: .resume, coordinate: .init(latitude: 53.90001, longitude: 27.56001)),
            RouteEventMarker(id: "finish", kind: .finish, coordinate: .init(latitude: 53.90002, longitude: 27.56002))
        ]

        let offsets = RouteEventMarkers.visualOffsets(for: markers)
        XCTAssertEqual(offsets.count, 3)
        XCTAssertEqual(Set(offsets.values.map { "\($0.width),\($0.height)" }).count, 3)
        XCTAssertTrue(offsets.values.allSatisfy { $0 != .zero })
    }

    func testResumeStartsANewSegmentWithoutBridgingThePausedGap() throws {
        let recorder = makeRecorder()
        let start = Date(timeIntervalSince1970: 9_000)
        recorder.start(now: start)
        recorder.add(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 53.9000, longitude: 27.5600),
            altitude: 210,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 12,
            timestamp: start.addingTimeInterval(10)
        ))

        recorder.togglePause(now: start.addingTimeInterval(20))
        recorder.togglePause(now: start.addingTimeInterval(120))
        recorder.add(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 54.1000, longitude: 27.8000),
            altitude: 220,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 14,
            timestamp: start.addingTimeInterval(130)
        ))

        let record = try XCTUnwrap(recorder.finish(activity: "activity_automotive", now: start.addingTimeInterval(140)))
        XCTAssertEqual(record.segments.count, 2)
        XCTAssertTrue(record.points[1].beginsNewSegment)
        XCTAssertEqual(record.distance, 0, accuracy: 0.001)
    }

    func testStartingWithAnExistingTimestampImmediatelyShowsElapsedTime() {
        let recorder = makeRecorder()
        recorder.start(now: Date().addingTimeInterval(-143))
        XCTAssertGreaterThanOrEqual(recorder.elapsed, 142)
        XCTAssertLessThan(recorder.elapsed, 145)
    }

    func testCancellationAndFinishBoundaries() {
        let recorder = makeRecorder()
        XCTAssertNil(recorder.finish(activity: "activity_unknown"))
        let start = Date(timeIntervalSince1970: 10_000)
        recorder.start(now: start)
        recorder.togglePause(now: start.addingTimeInterval(10))
        XCTAssertEqual(recorder.state, .paused)
        recorder.togglePause(now: start.addingTimeInterval(20))
        XCTAssertEqual(recorder.state, .recording)
        let record = recorder.finish(activity: "activity_walking", now: start.addingTimeInterval(30))
        XCTAssertEqual(record?.duration, 20)
        XCTAssertEqual(recorder.state, .idle)
    }

    func testActiveTripCheckpointSurvivesRelaunchAndContinuesWithoutCountingTheGap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActiveTripCheckpointStore(applicationSupportURL: directory)
        let start = Date(timeIntervalSince1970: 20_000)

        let recorder = TripRecorder(checkpointStore: store, loadRecoveryInBackground: false)
        recorder.start(now: start)
        recorder.add(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 53.9, longitude: 27.56),
            altitude: 210,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 12,
            timestamp: start.addingTimeInterval(30)
        ))
        recorder.checkpointForLifecycle(now: start.addingTimeInterval(60))
        recorder.flushCheckpoints()

        let relaunched = TripRecorder(checkpointStore: store, loadRecoveryInBackground: false)
        XCTAssertEqual(relaunched.pendingRecovery?.points.count, 1)
        XCTAssertEqual(try XCTUnwrap(relaunched.pendingRecovery).elapsed, 60, accuracy: 0.001)
        relaunched.continueRecoveredTrip(now: start.addingTimeInterval(600))
        relaunched.add(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 54.1, longitude: 27.8),
            altitude: 220,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 14,
            timestamp: start.addingTimeInterval(630)
        ))
        let record = relaunched.finish(activity: "activity_automotive", now: start.addingTimeInterval(660))

        let finished = try XCTUnwrap(record)
        XCTAssertEqual(finished.duration, 120, accuracy: 0.001)
        XCTAssertEqual(finished.segments.count, 2)
        XCTAssertTrue(finished.points[1].beginsNewSegment)
        XCTAssertEqual(finished.distance, 0, accuracy: 0.001)
        XCTAssertNil(store.load())
    }

    func testDiscardingRecoveredTripClearsOnlyTheActiveCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActiveTripCheckpointStore(applicationSupportURL: directory)
        let start = Date(timeIntervalSince1970: 30_000)
        try store.save(ActiveTripCheckpoint(
            state: .recording,
            startedAt: start,
            points: [],
            elapsed: 45,
            savedAt: start.addingTimeInterval(45)
        ))

        let recorder = TripRecorder(checkpointStore: store, loadRecoveryInBackground: false)
        XCTAssertTrue(recorder.needsRecoveryDecision)
        recorder.discardRecoveredTrip()

        XCTAssertEqual(recorder.state, .idle)
        XCTAssertFalse(recorder.needsRecoveryDecision)
        XCTAssertNil(store.load())
    }

    func testPausedCheckpointRecoversPausedUntilTheUserResumes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActiveTripCheckpointStore(applicationSupportURL: directory)
        let start = Date(timeIntervalSince1970: 40_000)
        try store.save(ActiveTripCheckpoint(
            state: .paused,
            startedAt: start,
            points: [
                TrackPoint(latitude: 53.9, longitude: 27.56, altitude: 210, metersPerSecond: 10, timestamp: start.addingTimeInterval(60))
            ],
            elapsed: 90,
            savedAt: start.addingTimeInterval(90)
        ))

        let recorder = TripRecorder(checkpointStore: store, loadRecoveryInBackground: false)
        recorder.continueRecoveredTrip(now: start.addingTimeInterval(900))
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertEqual(recorder.elapsed, 90, accuracy: 0.001)
        recorder.togglePause(now: start.addingTimeInterval(930))
        recorder.add(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 54.1, longitude: 27.8),
            altitude: 220,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 12,
            timestamp: start.addingTimeInterval(945)
        ))
        let record = recorder.finish(activity: "activity_cycling", now: start.addingTimeInterval(960))
        let finished = try XCTUnwrap(record)
        XCTAssertEqual(finished.duration, 120, accuracy: 0.001)
        XCTAssertEqual(finished.segments.count, 2)
    }

    private func makeRecorder() -> TripRecorder {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return TripRecorder(checkpointStore: ActiveTripCheckpointStore(applicationSupportURL: directory), loadRecoveryInBackground: false)
    }
}
