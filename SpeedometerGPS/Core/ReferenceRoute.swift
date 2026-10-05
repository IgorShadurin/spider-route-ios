#if DEBUG
import UIKit
#endif
import CoreLocation
import Foundation
import MapKit

struct ReferenceRoutePoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

struct ReferenceRoute: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let sourceFileName: String
    let segments: [[ReferenceRoutePoint]]

    let pointCount: Int
    let distance: CLLocationDistance
    private enum CodingKeys: String, CodingKey { case id, name, sourceFileName, segments }
    init(id: UUID, name: String, sourceFileName: String, segments: [[ReferenceRoutePoint]]) {
        self.id = id; self.name = name; self.sourceFileName = sourceFileName; self.segments = segments
        pointCount = segments.reduce(0) { $0 + $1.count }
        distance = Self.measure(segments)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
            sourceFileName: try c.decode(String.self, forKey: .sourceFileName),
            segments: try c.decode([[ReferenceRoutePoint]].self, forKey: .segments))
    }
    var supportsDistanceMarkers: Bool { segments.count == 1 && segments[0].count >= 2 }

    var coordinates: [CLLocationCoordinate2D] {
        segments.flatMap { $0.map(\.coordinate) }
    }

    private static func measure(_ segments: [[ReferenceRoutePoint]]) -> CLLocationDistance {
        segments.reduce(0) { total, segment in
            total + zip(segment, segment.dropFirst()).reduce(0) { subtotal, pair in
                let first = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                let second = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
                return subtotal + second.distance(from: first)
            }
        }
    }
}

enum ReferenceRouteImportError: Error, Equatable {
    case unsupportedFormat
    case invalidRoute
}

enum ReferenceRouteImporter {
    static let supportedFileExtensions: Set<String> = ["gpx", "kml", "geojson", "json", "csv"]

    static func supports(fileName: String) -> Bool {
        supportedFileExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    }

    static func decode(data: Data, fileName: String) throws -> ReferenceRoute {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let fallbackName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let decoded: (name: String?, segments: [[ReferenceRoutePoint]])

        switch fileExtension {
        case "gpx": decoded = try decodeGPX(data)
        case "kml": decoded = try decodeKML(data)
        case "geojson", "json": decoded = try decodeGeoJSON(data)
        case "csv": decoded = try decodeCSV(data)
        default: throw ReferenceRouteImportError.unsupportedFormat
        }

        let segments = decoded.segments
            .map { $0.filter(\.isValid) }
            .filter { $0.count >= 2 }
        guard !segments.isEmpty else { throw ReferenceRouteImportError.invalidRoute }

        let cleanedName = decoded.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReferenceRoute(
            id: UUID(),
            name: cleanedName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            sourceFileName: fileName,
            segments: segments
        )
    }

    private static func decodeGPX(_ data: Data) throws -> (String?, [[ReferenceRoutePoint]]) {
        let delegate = GPXRouteParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ReferenceRouteImportError.invalidRoute }
        return (delegate.routeName, delegate.segments)
    }

    private static func decodeKML(_ data: Data) throws -> (String?, [[ReferenceRoutePoint]]) {
        let delegate = KMLRouteParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ReferenceRouteImportError.invalidRoute }
        return (delegate.routeName, delegate.segments)
    }

    private static func decodeGeoJSON(_ data: Data) throws -> (String?, [[ReferenceRoutePoint]]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReferenceRouteImportError.invalidRoute
        }
        var routeName = root["name"] as? String
        var segments = [[ReferenceRoutePoint]]()

        func appendGeometry(_ geometry: [String: Any]) {
            switch geometry["type"] as? String {
            case "LineString":
                if let coordinates = geometry["coordinates"] as? [[Any]] {
                    segments.append(points(from: coordinates))
                }
            case "MultiLineString":
                if let lines = geometry["coordinates"] as? [[[Any]]] {
                    segments.append(contentsOf: lines.map(points(from:)))
                }
            default: break
            }
        }

        switch root["type"] as? String {
        case "FeatureCollection":
            for feature in root["features"] as? [[String: Any]] ?? [] {
                if routeName == nil, let properties = feature["properties"] as? [String: Any] {
                    routeName = properties["name"] as? String ?? properties["title"] as? String
                }
                if let geometry = feature["geometry"] as? [String: Any] { appendGeometry(geometry) }
            }
        case "Feature":
            if let properties = root["properties"] as? [String: Any] {
                routeName = routeName ?? properties["name"] as? String ?? properties["title"] as? String
            }
            if let geometry = root["geometry"] as? [String: Any] { appendGeometry(geometry) }
        case "LineString", "MultiLineString": appendGeometry(root)
        default: throw ReferenceRouteImportError.invalidRoute
        }
        return (routeName, segments)
    }

    private static func decodeCSV(_ data: Data) throws -> (String?, [[ReferenceRoutePoint]]) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReferenceRouteImportError.invalidRoute
        }
        let rows = parseCSV(text)
        guard let header = rows.first?.map({ $0.lowercased() }), rows.count > 1,
              let latitudeIndex = header.firstIndex(where: { $0 == "latitude" || $0 == "lat" }),
              let longitudeIndex = header.firstIndex(where: { $0 == "longitude" || $0 == "lon" || $0 == "lng" }) else {
            throw ReferenceRouteImportError.invalidRoute
        }
        let segmentIndex = header.firstIndex(where: { $0 == "segment" || $0 == "segment_id" })
        var segmentOrder = [String]()
        var grouped = [String: [ReferenceRoutePoint]]()

        for row in rows.dropFirst() {
            guard latitudeIndex < row.count, longitudeIndex < row.count,
                  let latitude = Double(row[latitudeIndex]),
                  let longitude = Double(row[longitudeIndex]) else { continue }
            let key = segmentIndex.flatMap { $0 < row.count ? row[$0] : nil } ?? "1"
            if grouped[key] == nil { segmentOrder.append(key) }
            grouped[key, default: []].append(.init(latitude: latitude, longitude: longitude))
        }
        return (nil, segmentOrder.compactMap { grouped[$0] })
    }

    private static func points(from coordinates: [[Any]]) -> [ReferenceRoutePoint] {
        coordinates.compactMap { pair in
            guard pair.count >= 2,
                  let longitude = number(pair[0]),
                  let latitude = number(pair[1]) else { return nil }
            return ReferenceRoutePoint(latitude: latitude, longitude: longitude)
        }
    }

    private static func number(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows = [[String]]()
        var row = [String]()
        var field = ""
        var insideQuotes = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if insideQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    insideQuotes.toggle()
                }
            } else if character == ",", !insideQuotes {
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else if (character == "\n" || character == "\r"), !insideQuotes {
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index += 1
        }
        row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}

@MainActor
final class IncomingReferenceRouteCoordinator: ObservableObject {
    @Published private(set) var pendingURLs: [URL] = []
    @Published var currentName = ""

    var currentURL: URL? { pendingURLs.first }

    init(
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) {
#if DEBUG
        guard processArguments.contains("--ui-screen=reference-route.import-confirmation") else { return }
        let previewURL = fileManager.temporaryDirectory
            .appendingPathComponent("shared-weekend-route.gpx")
        let previewData = Data(Self.previewGPX.utf8)
        if (try? previewData.write(to: previewURL, options: .atomic)) != nil {
            pendingURLs = [previewURL]
            currentName = suggestedName(for: previewURL)
        }
#endif
    }

    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard url.isFileURL, ReferenceRouteImporter.supports(fileName: url.lastPathComponent) else {
            return false
        }
        guard !pendingURLs.contains(url) else { return true }
        let startsNewConfirmation = pendingURLs.isEmpty
        pendingURLs.append(url)
        if startsNewConfirmation { currentName = suggestedName(for: url) }
        return true
    }

    func cancelCurrent() {
        guard !pendingURLs.isEmpty else { return }
        pendingURLs.removeFirst()
        currentName = pendingURLs.first.map { suggestedName(for: $0) } ?? ""
    }

    @discardableResult
    func importCurrent(into store: ReferenceRouteStore) throws -> ReferenceRoute {
        guard let currentURL else { throw ReferenceRouteImportError.invalidRoute }
        defer { cancelCurrent() }
        return try store.importRoute(from: currentURL, nameOverride: currentName)
    }

    @discardableResult
    func importCurrentInBackground(into store: ReferenceRouteStore) async throws -> ReferenceRoute {
        guard let currentURL else { throw ReferenceRouteImportError.invalidRoute }
        let name = currentName
        defer { cancelCurrent() }
        return try await store.importRouteInBackground(from: currentURL, nameOverride: name)
    }

    private func suggestedName(for url: URL) -> String {
        let fallback = url.deletingPathExtension().lastPathComponent
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let route = try? ReferenceRouteImporter.decode(data: data, fileName: url.lastPathComponent) else {
            return fallback
        }
        return route.name
    }

#if DEBUG
    private static let previewGPX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="SpiderRoute">
      <trk><name>Shared weekend route</name><trkseg>
        <trkpt lat="53.9006" lon="27.5484"/>
        <trkpt lat="53.9105" lon="27.5773"/>
        <trkpt lat="53.8950" lon="27.6014"/>
      </trkseg></trk>
    </gpx>
    """
#endif
}

@MainActor
final class ReferenceRouteStore: ObservableObject {
    @Published private(set) var routes: [ReferenceRoute] = [] {
        didSet { displayCache = displayCache.filter { id, _ in routes.contains { $0.id == id } } }
    }
    @Published private(set) var selectedRouteID: UUID?
    @Published var isVisible = true {
        didSet {
            guard oldValue != isVisible else { return }
            persist()
        }
    }

    @Published var showsDistanceMarkers = true {
        didSet { if oldValue != showsDistanceMarkers { persist() } }
    }
    @Published private(set) var reversedRouteIDs: Set<UUID> = []
    @Published private var guideRecords: [UUID: PersistedRouteGuide] = [:] {
        didSet { guideMapPoints = guideRecords.mapValues { $0.guide.points.map(RouteGuideMapPoint.init) } }
    }
    private var guideMapPoints: [UUID: [RouteGuideMapPoint]] = [:]

    var visibleGuideMapPoints: [RouteGuideMapPoint] {
        guard isVisible, let route else { return [] }
#if DEBUG
        if processArguments.contains("--debug-map-guides-off") { return [] }
        if processArguments.contains("--debug-map-guides-on") { return guideMapPoints[route.id] ?? [] }
#endif
        guard isGuideEnabled(for: route) else { return [] }
        return guideMapPoints[route.id] ?? []
    }

    func guide(for route: ReferenceRoute) -> RouteGuide? { guideRecords[route.id]?.guide }

    func isGuideEnabled(for route: ReferenceRoute) -> Bool {
        guideRecords[route.id]?.enabled ?? false
    }

    /// Reading during map updates never hashes or scans the original track.
    var visibleGuidePoints: [RouteGuidePoint] {
        guard isVisible, let route, let record = guideRecords[route.id], record.enabled else { return [] }
        return record.guide.points
    }

    @discardableResult
    func importGuide(from url: URL, for route: ReferenceRoute) throws -> RouteGuide {
        try importGuide(data: RouteGuideImporter.read(from: url), for: route)
    }

    @discardableResult
    func importGuide(data: Data, for route: ReferenceRoute) throws -> RouteGuide {
        guard let storedRoute = routes.first(where: { $0.id == route.id }) else {
            throw RouteGuideImportError.routeMissing
        }
        let guide = try RouteGuideImporter.decode(data: data, for: storedRoute)
        let record = PersistedRouteGuide(guide: guide, enabled: true)
        // Publish only after the complete validated replacement is saved atomically.
        try persistGuide(record, routeID: route.id)
        try? fileManager.removeItem(at: guideURL(for: route.id)!.appendingPathExtension("enabled"))
        guideRecords[route.id] = record
        return guide
    }

    @discardableResult
    func setGuideEnabled(_ enabled: Bool, for route: ReferenceRoute) -> Bool {
        guard let record = guideRecords[route.id] else { return !enabled }
        guard record.enabled != enabled else { return true }
        let updated = PersistedRouteGuide(guide: record.guide, enabled: enabled)
        guard let url = guideURL(for: route.id)?.appendingPathExtension("enabled") else { return false }
        do { try JSONEncoder().encode(enabled).write(to: url, options: .atomic) }
        catch { return false }
        guideRecords[route.id] = updated
        return true
    }

    @discardableResult
    func removeGuide(for route: ReferenceRoute) -> Bool {
        if let url = guideURL(for: route.id), fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) }
            catch { return false }
        }
        guideRecords.removeValue(forKey: route.id)
        return true
    }

    func isReversed(_ route: ReferenceRoute) -> Bool { reversedRouteIDs.contains(route.id) }

    func reverseDirection(of route: ReferenceRoute) {
        guard route.supportsDistanceMarkers, routes.contains(where: { $0.id == route.id }) else { return }
        if !reversedRouteIDs.insert(route.id).inserted { reversedRouteIDs.remove(route.id) }
        persist()
    }

    func markers(for route: ReferenceRoute) -> [ReferenceRouteMarker] {
        let display = display(for: route)
        let markers = isReversed(route) ? display.reverseMarkers : display.forwardMarkers
        return showsDistanceMarkers ? markers : markers.filter { $0.kind != .distance }
    }

    var route: ReferenceRoute? {
        routes.first(where: { $0.id == selectedRouteID }) ?? routes.first
    }

    private(set) var displayPreparationCount = 0
    private var displayCache: [UUID: ReferenceRouteDisplay] = [:]

    func display(for route: ReferenceRoute) -> ReferenceRouteDisplay {
        if let cached = displayCache[route.id] { return cached }
        displayPreparationCount += 1
        let cached = ReferenceRouteDisplay(route: route)
        displayCache[route.id] = cached
        return cached
    }

    private struct PersistedLibrary: Codable {
        let version: Int
        let routes: [ReferenceRoute]
        let selectedRouteID: UUID?
        let isVisible: Bool
        let showsDistanceMarkers: Bool?
        let reversedRouteIDs: Set<UUID>?
    }

    private struct LegacyPersistedState: Codable {
        let route: ReferenceRoute
        let isVisible: Bool
    }

    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    private var loadTask: Task<Void, Never>?
    private let persistenceWorker = CoalescingPersistenceWorker(label: "com.wowcoded.speedometergps.references")
    private var usesBackgroundPersistence = false
    private var isRestoring = false
    private let fileManager: FileManager
    private let storageURL: URL?
    private let processArguments: [String]
    private let fileName = "reference-route.json"

    init(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        loadInBackground: Bool = false
    ) {
        self.fileManager = fileManager
        self.storageURL = (applicationSupportURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)?
            .appendingPathComponent(fileName)
        self.processArguments = processArguments
#if DEBUG
        if processArguments.contains(where: { $0.hasPrefix("--ui-screen=") }) {
            if let storageURL { try? fileManager.removeItem(at: storageURL) }
        }
#endif
        usesBackgroundPersistence = loadInBackground
        if loadInBackground {
            isLoading = true
            let url = storageURL
            loadTask = Task { [weak self] in
                let loaded = await Task.detached(priority: .userInitiated) { Self.readLibrary(at: url) }.value
                guard let self else { return }
                self.isRestoring = true
                if let library = loaded.library {
                    self.routes = library.routes
                    self.selectedRouteID = library.selectedRouteID.flatMap { id in library.routes.contains { $0.id == id } ? id : nil } ?? library.routes.first?.id
                    self.showsDistanceMarkers = library.showsDistanceMarkers ?? true
                    self.reversedRouteIDs = (library.reversedRouteIDs ?? []).intersection(Set(library.routes.map(\.id)))
                    self.isVisible = library.isVisible && !library.routes.isEmpty
                    self.guideRecords = loaded.guides
                    self.displayCache = loaded.displays
                }
                self.isRestoring = false
                self.preparePreviewRoutesIfNeeded()
                self.preparePreviewGuidesIfNeeded()
                self.isLoading = false
            }
            return
        }
        load()
        loadGuides()
#if DEBUG
        // Physical-device check: use real data, never seed or clear the library.
        if processArguments.contains("--debug-import-route-guide"),
           let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            var report: [String: Any] = [:]
            do {
                let data = try RouteGuideImporter.read(from: documents.appendingPathComponent("mogilev-vitebsk.route-guide.json"))
                let guide = try JSONDecoder().decode(RouteGuide.self, from: data)
                guard let route = routes.first(where: { RouteGuideImporter.fingerprint(for: $0) == guide.routeFingerprint }) else {
                    throw RouteGuideImportError.routeMismatch
                }
                _ = try importGuide(data: data, for: route)
                report = ["success": true, "points": guide.points.count, "photos": guide.points.reduce(0) { $0 + ($1.photos?.count ?? 0) }]
            } catch { report = ["success": false, "error": String(describing: error)]
                if let data = try? Data(contentsOf: documents.appendingPathComponent("mogilev-vitebsk.route-guide.json")),
                   let guide = try? JSONDecoder().decode(RouteGuide.self, from: data) {
                    report["validationFailures"] = RouteGuideImporter.validationFailures(guide)
                } }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: fileManager.temporaryDirectory.appendingPathComponent("route-guide-import-report.json"), options: .atomic)
            }
        }
#endif
        preparePreviewRoutesIfNeeded()
        preparePreviewGuidesIfNeeded()
    }

    private struct LoadedLibrary {
        var library: PersistedLibrary?
        var guides: [UUID: PersistedRouteGuide] = [:]
        var displays: [UUID: ReferenceRouteDisplay] = [:]
    }

    nonisolated private static func readLibrary(at url: URL?) -> LoadedLibrary {
        var result = LoadedLibrary()
        guard let url, let data = try? Data(contentsOf: url) else { return result }
        if let library = try? JSONDecoder().decode(PersistedLibrary.self, from: data) { result.library = library }
        else if let old = try? JSONDecoder().decode(LegacyPersistedState.self, from: data) {
            result.library = PersistedLibrary(version: 3, routes: [old.route], selectedRouteID: old.route.id,
                isVisible: old.isVisible, showsDistanceMarkers: true, reversedRouteIDs: [])
        }
        for route in result.library?.routes ?? [] {
            let guideURL = url.deletingLastPathComponent().appendingPathComponent("route-guides").appendingPathComponent("\(route.id.uuidString).json")
            if let bytes = try? RouteGuideImporter.read(from: guideURL),
               let record = try? JSONDecoder().decode(PersistedRouteGuide.self, from: bytes),
               (try? RouteGuideImporter.validate(record.guide, for: route)) != nil {
                let enabled = (try? Data(contentsOf: guideURL.appendingPathExtension("enabled"))).flatMap { try? JSONDecoder().decode(Bool.self, from: $0) } ?? record.enabled
                result.guides[route.id] = PersistedRouteGuide(guide: record.guide, enabled: enabled)
            }
            result.displays[route.id] = ReferenceRouteDisplay(route: route)
        }
        return result
    }

    func waitForLoad() async { await loadTask?.value }

    func checkpointForLifecycle() {
        let task = BackgroundPersistenceTask(name: "Save reference library")
        persistenceWorker.queue.async { DispatchQueue.main.async { task.finish() } }
    }

    @discardableResult
    func importRouteInBackground(from url: URL, nameOverride: String? = nil) async throws -> ReferenceRoute {
        guard !isImporting else { throw ReferenceRouteImportError.invalidRoute }
        isImporting = true
        let protection = BackgroundPersistenceTask(name: "Import route data")
        defer { isImporting = false; protection.finish() }
        let value = try await Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let decoded = try ReferenceRouteImporter.decode(data: Data(contentsOf: url), fileName: url.lastPathComponent)
            let name = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            let route = ReferenceRoute(id: decoded.id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? decoded.name,
                sourceFileName: decoded.sourceFileName, segments: decoded.segments)
            return (route, ReferenceRouteDisplay(route: route))
        }.value
        routes.append(value.0)
        displayCache[value.0.id] = value.1
        selectedRouteID = value.0.id
        isVisible = true
        persist()
        return value.0
    }

    @discardableResult
    func importGuideInBackground(from url: URL, for route: ReferenceRoute) async throws -> RouteGuide {
        guard !isImporting, routes.contains(where: { $0.id == route.id }), let destination = guideURL(for: route.id) else { throw RouteGuideImportError.routeMissing }
        isImporting = true
        let protection = BackgroundPersistenceTask(name: "Import route data")
        defer { isImporting = false; protection.finish() }
        let guide = try await Task.detached(priority: .userInitiated) {
            let guide = try RouteGuideImporter.decode(data: RouteGuideImporter.read(from: url), for: route)
            let record = PersistedRouteGuide(guide: guide, enabled: true)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            return guide
        }.value
        try? fileManager.removeItem(at: destination.appendingPathExtension("enabled"))
        guideRecords[route.id] = PersistedRouteGuide(guide: guide, enabled: true)
        return guide
    }

    @discardableResult
    func importRoute(from url: URL, nameOverride: String? = nil) throws -> ReferenceRoute {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try importRoute(data: Data(contentsOf: url), fileName: url.lastPathComponent, nameOverride: nameOverride)
    }

    @discardableResult
    func importRoute(data: Data, fileName: String, nameOverride: String? = nil) throws -> ReferenceRoute {
        let decoded = try ReferenceRouteImporter.decode(data: data, fileName: fileName)
        let trimmedOverride = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imported = ReferenceRoute(
            id: decoded.id,
            name: trimmedOverride.flatMap { $0.isEmpty ? nil : $0 } ?? decoded.name,
            sourceFileName: decoded.sourceFileName,
            segments: decoded.segments
        )
        routes.append(imported)
        selectedRouteID = imported.id
        isVisible = true
        persist()
        return imported
    }

    @discardableResult
    func rename(_ routeID: UUID, to name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = routes.firstIndex(where: { $0.id == routeID }) else { return false }
        let existing = routes[index]
        guard existing.name != trimmedName else { return true }
        routes[index] = ReferenceRoute(
            id: existing.id,
            name: trimmedName,
            sourceFileName: existing.sourceFileName,
            segments: existing.segments
        )
        persist()
        return true
    }

    func select(_ routeID: UUID) {
        guard routes.contains(where: { $0.id == routeID }) else { return }
        selectedRouteID = routeID
        isVisible = true
        persist()
    }

    func delete(_ routeID: UUID) {
        if let deleted = routes.first(where: { $0.id == routeID }) {
            _ = removeGuide(for: deleted)
        }
        guideRecords.removeValue(forKey: routeID)
        reversedRouteIDs.remove(routeID)
        routes.removeAll { $0.id == routeID }
        if selectedRouteID == routeID { selectedRouteID = routes.first?.id }
        if routes.isEmpty { isVisible = false }
        persist()
    }

    private func guideURL(for routeID: UUID) -> URL? {
        storageURL?.deletingLastPathComponent().appendingPathComponent("route-guides", isDirectory: true)
            .appendingPathComponent("\(routeID.uuidString).json")
    }

    private func loadGuides() {
        for route in routes {
            guard let url = guideURL(for: route.id),
                  let data = try? RouteGuideImporter.read(from: url),
                  let record = try? JSONDecoder().decode(PersistedRouteGuide.self, from: data),
                  (try? RouteGuideImporter.validate(record.guide, for: route)) != nil else { continue }
            let enabled = (try? Data(contentsOf: url.appendingPathExtension("enabled"))).flatMap { try? JSONDecoder().decode(Bool.self, from: $0) } ?? record.enabled
            guideRecords[route.id] = PersistedRouteGuide(guide: record.guide, enabled: enabled)
        }
    }

    private func persistGuide(_ record: PersistedRouteGuide, routeID: UUID) throws {
        guard let url = guideURL(for: routeID) else { throw RouteGuideImportError.storageUnavailable }
        let data = try JSONEncoder().encode(record)
        // The wrapper adds a few bytes beyond the external guide document.
        guard data.count <= RouteGuideImporter.maximumFileBytes else { throw RouteGuideImportError.fileTooLarge }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path
        )
    }

    private func load() {
        guard let storageURL, let data = try? Data(contentsOf: storageURL) else { return }
        if let library = try? JSONDecoder().decode(PersistedLibrary.self, from: data) {
            isRestoring = true
            defer { isRestoring = false }
            routes = library.routes
            selectedRouteID = library.selectedRouteID.flatMap { id in
                library.routes.contains(where: { $0.id == id }) ? id : nil
            } ?? library.routes.first?.id
            showsDistanceMarkers = library.showsDistanceMarkers ?? true
            reversedRouteIDs = (library.reversedRouteIDs ?? []).intersection(Set(routes.map(\.id)))
            isVisible = library.isVisible && !library.routes.isEmpty
            return
        }
        if let legacy = try? JSONDecoder().decode(LegacyPersistedState.self, from: data) {
            routes = [legacy.route]
            selectedRouteID = legacy.route.id
            isVisible = legacy.isVisible
            persist()
        }
    }

    private func persist() {
        guard !isRestoring else { return }
        guard let storageURL else { return }
        let snapshot = PersistedLibrary(version: 3, routes: routes, selectedRouteID: selectedRouteID,
            isVisible: isVisible, showsDistanceMarkers: showsDistanceMarkers, reversedRouteIDs: reversedRouteIDs)
        let write = {
            guard let data = try? JSONEncoder().encode(snapshot) else { return false }
            do {
                try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: storageURL, options: .atomic)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: storageURL.path)
                return true
            } catch { return false }
        }
        if usesBackgroundPersistence { persistenceWorker.submit(write) } else { _ = write() }
    }

    private func preparePreviewRoutesIfNeeded() {
#if DEBUG
        let screen = processArguments.first(where: { $0.hasPrefix("--ui-screen=") })
        guard screen == "--ui-screen=map.route-progress"
                || screen == "--ui-screen=map.route-progress-fullscreen"
                || screen == "--ui-screen=map.camera-reference"
                || screen == "--ui-screen=map.reference-route"
                || screen == "--ui-screen=map.reference-route-menu"
                || screen == "--ui-screen=map.reference-route-fullscreen-menu"
                || screen == "--ui-screen=map.guide"
                || screen == "--ui-screen=map.guide-point"
                || screen == "--ui-screen=map.guide-library"
                || screen == "--ui-screen=map.guide-fullscreen"
                || screen == "--ui-screen=map.guide-replace"
                || screen == "--ui-screen=settings.reference-routes"
                || screen == "--ui-screen=settings.reference-route-rename"
                || screen == "--ui-screen=settings.reference-route-delete-confirmation" else { return }
        var previewRoutes = ReferenceRoute.previewRoutes
        if processArguments.contains("--ui-long-route"),
           let imported = try? ReferenceRouteImporter.decode(data: LongRouteFixture.gpx, fileName: "two-hour-ride.gpx") {
            previewRoutes[0] = imported
        }
        if processArguments.contains("--ui-distant-reference-route") {
            let base = previewRoutes[0]
            previewRoutes[0] = ReferenceRoute(id: base.id, name: base.name, sourceFileName: base.sourceFileName,
                segments: base.segments.map { $0.map { .init(latitude: $0.latitude, longitude: $0.longitude + 3) } })
        }
        let filePrefix = "--ui-reference-route-file="
        if let fileName = processArguments.first(where: { $0.hasPrefix(filePrefix) })?.dropFirst(filePrefix.count),
           let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? Data(contentsOf: documentsURL.appendingPathComponent(String(fileName))),
           let imported = try? ReferenceRouteImporter.decode(data: data, fileName: String(fileName)) {
            previewRoutes[0] = imported
        }
        if processArguments.contains("--ui-reference-disconnected") {
            let existing = previewRoutes[0]
            let points = existing.segments[0]
            let middle = points.count / 2
            previewRoutes[0] = ReferenceRoute(id: existing.id, name: existing.name, sourceFileName: existing.sourceFileName,
                segments: [Array(points[..<middle]), Array(points[middle...])])
        }
        routes = previewRoutes
        selectedRouteID = routes.first?.id
        isVisible = true
        persist()
#endif
    }

    private func preparePreviewGuidesIfNeeded() {
#if DEBUG
        guard processArguments.contains(where: { $0.hasPrefix("--ui-screen=map.guide") }),
              let route else { return }
        let filePrefix = "--ui-guide-file="
        if let fileName = processArguments.first(where: { $0.hasPrefix(filePrefix) })?.dropFirst(filePrefix.count),
           let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            // An explicit invalid QA file must not silently become a passing demo.
            _ = try? importGuide(from: documentsURL.appendingPathComponent(String(fileName)), for: route)
            return
        }
        let coordinates = route.segments.flatMap { $0 }
        if let fixture = ScreenshotCityFixture.current {
            let points = [0.2, 0.5, 0.8].enumerated().map { index, fraction in
                let coordinate = coordinates[min(coordinates.count-1, Int(Double(coordinates.count-1)*fraction))]
                return RouteGuidePoint(id: "city-\(index)", title: "\(fixture.cityLabel) · \(index+1)",
                    latitude: coordinate.latitude, longitude: coordinate.longitude, category: .settlement,
                    summary: fixture.cityLabel, details: nil,
                    sources: [.init(title: "OpenStreetMap", url: "https://www.openstreetmap.org")],
                    distanceFromRouteMeters: 0, distanceAlongRouteMeters: nil)
            }
            let guide = RouteGuide(schemaVersion: 1, title: fixture.cityLabel, language: fixture.uiLocale,
                routeFingerprint: RouteGuideImporter.fingerprint(for: route), points: points)
            if let data = try? JSONEncoder().encode(guide) { _ = try? importGuide(data: data, for: route) }
            return
        }
        let samples = processArguments.contains("--ui-long-route")
            ? (0..<39).map { coordinates[min(coordinates.count - 1, $0 * coordinates.count / 39)] }
            : Array(coordinates.prefix(3))
        let categories: [RouteGuidePoint.Category] = [.heritage, .memorial, .nature]
        var points = samples.enumerated().map { index, point in
            RouteGuidePoint(id: "demo-\(index)", title: ["Демонстрационная усадьба", "Демонстрационный мемориал", "Демонстрационная река"][index % 3],
                latitude: point.latitude, longitude: point.longitude, category: categories[index % 3],
                summary: "Демонстрационная карточка для проверки карты. Это пример интерфейса, а не исторические сведения о месте.",
                details: nil, sources: [.init(title: "Демонстрационный источник", url: "https://example.org")],
                distanceFromRouteMeters: 0, distanceAlongRouteMeters: nil)
        }
        let mediaPreview = processArguments.contains("--ui-guide-photo")
        if mediaPreview, !points.isEmpty {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            }.pngData()!
            points[0].icon = .grave
            points[0].photos = [.init(id: "demo-photo", title: "Тестовое изображение интерфейса", sourceURL: "https://example.org",
                                      author: "UI test fixture", license: "Test fixture", licenseURL: nil, imageURL: nil, data: data)]
        }
        let guide = RouteGuide(schemaVersion: mediaPreview ? 2 : 1, title: "Демонстрационный путеводитель", language: "ru",
                               routeFingerprint: RouteGuideImporter.fingerprint(for: route), points: points)
        if let data = try? JSONEncoder().encode(guide) { _ = try? importGuide(data: data, for: route) }
#endif
    }
}

#if DEBUG
extension ReferenceRoute {
    static let previewRoutes: [ReferenceRoute] = {
        if let fixture = ScreenshotCityFixture.current { return fixture.referenceRoutes }
        return [
        ReferenceRoute(
            id: UUID(uuidString: "4EAEC599-4B55-4DB7-B115-231476528850")!,
            name: "Minsk–Babruysk",
            sourceFileName: "bobr-180km.gpx",
            segments: [[
                .init(latitude: 53.92276, longitude: 27.62459), .init(latitude: 53.87106, longitude: 27.69116),
                .init(latitude: 53.81437, longitude: 27.72163), .init(latitude: 53.74328, longitude: 27.76096),
                .init(latitude: 53.61867, longitude: 27.85419), .init(latitude: 53.56742, longitude: 28.01605),
                .init(latitude: 53.49889, longitude: 28.14981), .init(latitude: 53.37106, longitude: 28.34643),
                .init(latitude: 53.30056, longitude: 28.48392), .init(latitude: 53.28550, longitude: 28.65584),
                .init(latitude: 53.16978, longitude: 28.77624), .init(latitude: 53.16249, longitude: 29.03902),
                .init(latitude: 53.13750, longitude: 29.14049), .init(latitude: 53.13974, longitude: 29.22458)
            ]]
        ),
        ReferenceRoute(
            id: UUID(uuidString: "E14FE010-A11B-40F8-84E0-B1455A879CA7")!,
            name: "Minsk training loop",
            sourceFileName: "minsk-loop.geojson",
            segments: [[
                .init(latitude: 53.9006, longitude: 27.5484), .init(latitude: 53.9105, longitude: 27.5773),
                .init(latitude: 53.8950, longitude: 27.6014), .init(latitude: 53.8818, longitude: 27.5701),
                .init(latitude: 53.9006, longitude: 27.5484)
            ]]
        )
        ]
    }()
}
#endif

/// Immutable display data. Original coordinates stay in the route library.
struct ReferenceRouteDisplay {
    let drawingGroups: [RouteDrawingGroup]
    let segments: [[CLLocationCoordinate2D]]
    let region: MKCoordinateRegion
    let distance: CLLocationDistance
    let forwardMarkers: [ReferenceRouteMarker]
    let reverseMarkers: [ReferenceRouteMarker]

    init(route: ReferenceRoute) {
        let coordinates = route.coordinates
        distance = route.distance
        forwardMarkers = route.supportsDistanceMarkers ? ReferenceRouteMarker.make(points: route.segments[0]) : []
        reverseMarkers = route.supportsDistanceMarkers ? ReferenceRouteMarker.make(points: Array(route.segments[0].reversed())) : []
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-distance-label-comparison") {
            let fit = RouteMapGeometry.region(fitting: forwardMarkers.filter { $0.meters >= 5_000 && $0.meters <= 20_000 }.map(\.coordinate))
            region = MKCoordinateRegion(center: fit.center, span: .init(latitudeDelta: fit.span.latitudeDelta * 1.25, longitudeDelta: fit.span.longitudeDelta * 1.25))
        } else if ProcessInfo.processInfo.arguments.contains("--ui-reference-tick-repro"),
           let sixty = forwardMarkers.first(where: { $0.meters == 60_000 }),
           let seventyFive = forwardMarkers.first(where: { $0.meters == 75_000 }) {
            region = MKCoordinateRegion(center: .init(latitude: (sixty.latitude + seventyFive.latitude) / 2,
                longitude: (sixty.longitude + seventyFive.longitude) / 2), span: .init(latitudeDelta: 0.55, longitudeDelta: 0.6))
        } else if ProcessInfo.processInfo.arguments.contains("--ui-reference-marker-closeup"),
           let five = forwardMarkers.first(where: { $0.meters == 5_000 }),
           let ten = forwardMarkers.first(where: { $0.meters == 10_000 }) {
            region = MKCoordinateRegion(center: .init(latitude: (five.latitude + ten.latitude) / 2 + 0.003,
                longitude: (five.longitude + ten.longitude) / 2), span: .init(latitudeDelta: 0.035, longitudeDelta: 0.05))
        } else { region = RouteMapGeometry.region(fitting: coordinates) }
#else
        region = RouteMapGeometry.region(fitting: coordinates)
#endif
#if DEBUG
        // Retain a deterministic A/B fixture for the old independent polyline path.
        let pinTicks = !(ScreenshotState.requested != nil && ProcessInfo.processInfo.arguments.contains("--ui-reference-tick-unpinned"))
#else
        let pinTicks = true
#endif
        if route.supportsDistanceMarkers && pinTicks {
            segments = ReferenceMarkerAnchoredPath.make(points: route.segments[0],
                forward: forwardMarkers, reverse: reverseMarkers)
        } else {
            segments = route.segments.flatMap { RouteDisplayPath.chunks(for: $0.map(\.coordinate)) }
        }
        drawingGroups = RouteDrawingGroup.make(segments)
    }
}

/// Pin each true-distance coordinate as a polyline endpoint. MapKit may
/// generalize interior vertices at low zoom, but it cannot move path endpoints.
/// Prepare once per immutable route; no nearest-line searches during gestures.
enum ReferenceMarkerAnchoredPath {
    static func make(points: [ReferenceRoutePoint], forward: [ReferenceRouteMarker],
                     reverse: [ReferenceRouteMarker]) -> [[CLLocationCoordinate2D]] {
        guard points.count > 1 else { return [points.map(\.coordinate)] }
        var pins: [Int: [(fraction: Double, coordinate: CLLocationCoordinate2D)]] = [:]
        for marker in forward where marker.kind == .distance {
            pins[marker.sourceLegIndex, default: []].append((marker.sourceLegFraction, marker.coordinate))
        }
        for marker in reverse where marker.kind == .distance {
            let index = points.count - 2 - marker.sourceLegIndex
            pins[index, default: []].append((1 - marker.sourceLegFraction, marker.coordinate))
        }
        var result: [[CLLocationCoordinate2D]] = []
        var tail = [points[0].coordinate]
        func appendDistinct(_ coordinate: CLLocationCoordinate2D) {
            if let last = tail.last, last.latitude == coordinate.latitude, last.longitude == coordinate.longitude { return }
            tail.append(coordinate)
        }
        for index in 0..<(points.count - 1) {
            for pin in (pins[index] ?? []).sorted(by: { $0.fraction < $1.fraction }) {
                appendDistinct(pin.coordinate)
                if tail.count > 1 { result += RouteDisplayPath.chunks(for: tail) }
                tail = [pin.coordinate]
            }
            appendDistinct(points[index + 1].coordinate)
        }
        if tail.count > 1 { result += RouteDisplayPath.chunks(for: tail) }
        return result.isEmpty ? [points.map(\.coordinate)] : result
    }
}

/// Immutable, revisioned native draw units. A fix invalidates only its last
/// group; renderers never regroup or hash all earlier coordinates on the main UI.
struct RouteDrawingGroup: Identifiable {
    let id: String
    let revision = UUID()
    let segments: [[CLLocationCoordinate2D]]
    var isVideo = false
    static let chunkCount = 16
    static func make(_ segments: [[CLLocationCoordinate2D]]) -> [Self] {
        stride(from: 0, to: segments.count, by: chunkCount).map { start in
            Self(id: String(start / chunkCount), segments: Array(segments[start..<min(start + chunkCount, segments.count)]))
        }
    }
}

/// Bound simplification work to 256 source points and retain completed chunks.
/// Shared endpoints avoid seams; callers reset at real segment boundaries.
struct RouteDisplayPath {
    private(set) var drawingGroups: [RouteDrawingGroup] = []
    private(set) var segments: [[CLLocationCoordinate2D]] = []
    private var tail: [CLLocationCoordinate2D] = []
    static let chunkSize = 256
    static let toleranceMeters = 1.0

    init() {}

    /// Recovery simplifies each completed chunk once, instead of simplifying all
    /// 256 growing prefixes of every chunk. Keep the raw tail for the next GPS fix.
    init(points: [TrackPoint]) {
        for point in points {
            if tail.isEmpty || point.beginsNewSegment {
                if !tail.isEmpty { segments.append(Self.simplify(tail)) }
                tail = [point.coordinate]
            } else if tail.count == Self.chunkSize {
                segments.append(Self.simplify(tail))
                tail = [tail.last!, point.coordinate]
            } else {
                tail.append(point.coordinate)
            }
        }
        if !tail.isEmpty { segments.append(Self.simplify(tail)) }
        drawingGroups = RouteDrawingGroup.make(segments)
    }

    mutating func append(_ coordinate: CLLocationCoordinate2D, beginsNewSegment: Bool = false) {
        defer { refreshTailDrawingGroup() }
        if tail.isEmpty || beginsNewSegment {
            tail = [coordinate]
            segments.append(tail)
            return
        }
        if tail.count == Self.chunkSize {
            tail = [tail.last!, coordinate]
            segments.append(tail)
        } else {
            tail.append(coordinate)
            segments[segments.count - 1] = Self.simplify(tail)
        }
    }

    private mutating func refreshTailDrawingGroup() {
        guard !segments.isEmpty else { return }
        let index = (segments.count - 1) / RouteDrawingGroup.chunkCount
        let start = index * RouteDrawingGroup.chunkCount
        let group = RouteDrawingGroup(id: String(index), segments: Array(segments[start...]))
        if index < drawingGroups.count { drawingGroups[index] = group } else { drawingGroups.append(group) }
    }

    static func chunks(for coordinates: [CLLocationCoordinate2D]) -> [[CLLocationCoordinate2D]] {
        guard !coordinates.isEmpty else { return [] }
        var result: [[CLLocationCoordinate2D]] = []
        var start = 0
        while start < coordinates.count - 1 {
            let end = min(start + chunkSize, coordinates.count)
            result.append(simplify(Array(coordinates[start..<end])))
            start = end - 1
        }
        return result.isEmpty ? [coordinates] : result
    }

    /// Iterative Douglas–Peucker, with a conservative projected tolerance.
    /// No recursion, averaging, source mutation, or joining separate segments.
    static func simplify(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2 else { return coordinates }
        let points = coordinates.map(MKMapPoint.init)
        let tolerance = coordinates.map { MKMapPointsPerMeterAtLatitude($0.latitude) }.min()! * toleranceMeters
        var retained: Set<Int> = [0, points.count - 1]
        var ranges = [(0, points.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], b = points[last]
            let dx = b.x - a.x, dy = b.y - a.y
            let squaredLength = dx * dx + dy * dy
            var farthest = -1
            var maximum = tolerance * tolerance
            for index in (first + 1)..<last {
                let p = points[index]
                let t = squaredLength == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squaredLength))
                let ex = p.x - (a.x + t * dx), ey = p.y - (a.y + t * dy)
                let distance = ex * ex + ey * ey
                if distance > maximum { maximum = distance; farthest = index }
            }
            if farthest >= 0 {
                retained.insert(farthest)
                ranges.append((first, farthest))
                ranges.append((farthest, last))
            }
        }
        return retained.sorted().map { coordinates[$0] }
    }
}

#if DEBUG
/// Procedural fixture exercises the real GPX parser without shipping route files.
enum LongRouteFixture {
    static var replayTrip: TripRecord? {
        guard ProcessInfo.processInfo.arguments.contains("--ui-replay-trip"),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: directory.appendingPathComponent("performance-trip.json")) else { return nil }
        return try? JSONDecoder().decode(TripRecord.self, from: data)
    }

    static func coordinate(_ index: Int) -> CLLocationCoordinate2D {
        .init(latitude: 53.9 + Double(index) * 0.000025,
              longitude: 27.55 + sin(Double(index) / 500) * 0.02)
    }

    static var gpx: Data {
        let points = (0..<20_000).map { index in
            let point = coordinate(index)
            return "<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\"/>"
        }.joined()
        return Data("<gpx><trk><name>Long cycling route</name><trkseg>\(points)</trkseg></trk></gpx>".utf8)
    }
}
#endif

/// Kilometer ticks use original geodesic leg lengths, never simplified display points.
/// Distances restart only at the selected endpoint; disconnected routes are excluded.
struct ReferenceRouteMarker: Identifiable, Equatable {
    enum Kind: String { case start, distance, finish }
    let kind: Kind
    let meters: Double
    let latitude: Double
    let longitude: Double
    var horizontalOffset: Double = 0
    var course: Double = 0
    // Display-only location along the original source leg; never persisted.
    var sourceLegIndex: Int = 0
    var sourceLegFraction: Double = 0
    var id: String { kind == .distance ? "km-\(Int(meters / 1_000))" : kind.rawValue }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    static func make(points: [ReferenceRoutePoint]) -> [Self] {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return [] }
        var result = [Self(kind: .start, meters: 0, latitude: first.latitude, longitude: first.longitude)]
        var traveled = 0.0
        var nextTick = 5_000.0
        for (index, pair) in zip(points, points.dropFirst()).enumerated() {
            let (a, b) = pair
            let length = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            guard length > 0 else { continue }
            while nextTick <= traveled + length {
                let fraction = (nextTick - traveled) / length
                let coordinate = interpolate(a.coordinate, b.coordinate, fraction: fraction)
                result.append(Self(kind: .distance, meters: nextTick, latitude: coordinate.latitude, longitude: coordinate.longitude,
                                   course: RouteMapGeometry.heading(for: [a.coordinate, b.coordinate]),
                                   sourceLegIndex: index, sourceLegFraction: fraction))
                nextTick += 5_000
            }
            traveled += length
        }
        // The finish label owns its distance when an exact 5 km tick coincides.
        if let tick = result.last, tick.kind == .distance, abs(tick.meters - traveled) < 1 {
            result.removeLast()
        }
        result.append(Self(kind: .finish, meters: traveled, latitude: last.latitude, longitude: last.longitude))
        if CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)) < 28 {
            result[0].horizontalOffset = -28
            result[result.count - 1].horizontalOffset = 28
        }
        return result
    }

    /// Great-circle interpolation handles long sparse legs and the date line.
    private static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, fraction: Double) -> CLLocationCoordinate2D {
        let radians = Double.pi / 180
        let lat1 = a.latitude * radians, lon1 = a.longitude * radians
        let lat2 = b.latitude * radians, lon2 = b.longitude * radians
        let cosine = min(1, max(-1, sin(lat1) * sin(lat2) + cos(lat1) * cos(lat2) * cos(lon2 - lon1)))
        let angle = acos(cosine)
        guard angle > 1e-10 else { return a }
        // A truly antipodal leg has no unique direction; use its shortest longitude arc.
        guard abs(sin(angle)) > 1e-10 else {
            let delta = (b.longitude - a.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            let longitude = (a.longitude + delta * fraction + 540).truncatingRemainder(dividingBy: 360) - 180
            return .init(latitude: a.latitude + (b.latitude - a.latitude) * fraction, longitude: longitude)
        }
        let u = sin((1 - fraction) * angle) / sin(angle), v = sin(fraction * angle) / sin(angle)
        let x = u * cos(lat1) * cos(lon1) + v * cos(lat2) * cos(lon2)
        let y = u * cos(lat1) * sin(lon1) + v * cos(lat2) * sin(lon2)
        let z = u * sin(lat1) + v * sin(lat2)
        return .init(latitude: atan2(z, sqrt(x*x + y*y)) / radians, longitude: atan2(y, x) / radians)
    }
}
