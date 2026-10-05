import Foundation
import MapKit
import MapLibre

struct DownloadedMapMetadata: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let languageID: String
    let regionID: String?
    let styleVersion: Int?
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    init(name: String, languageID: String, bounds: MLNCoordinateBounds, regionID: String? = nil, styleVersion: Int? = nil) {
        id = UUID(); self.name = name; self.regionID = regionID; self.styleVersion = styleVersion
        self.languageID = AppLanguage.normalized(languageID)
        south = bounds.sw.latitude; west = bounds.sw.longitude
        north = bounds.ne.latitude; east = bounds.ne.longitude
    }
    var bounds: MLNCoordinateBounds {
        MLNCoordinateBounds(sw: .init(latitude: south, longitude: west), ne: .init(latitude: north, longitude: east))
    }
    var frozenStyleURL: URL? {
        guard styleVersion == 1 else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OSMDownloads/" + id.uuidString, isDirectory: true)
            .appendingPathComponent("liberty-v1-" + OSMMapStyle.languageCode(languageID) + ".json")
    }
    var languageName: String { AppLanguage.all.first { $0.id == languageID }?.nativeName ?? languageID }
}

enum OSMMapStyle {
    static func languageCode(_ id: String) -> String {
        let normalized = AppLanguage.normalized(id)
        if normalized == "zh-Hans" { return "zh" }
        if normalized == "zh-Hant" { return "zh-Hant" }
        return normalized.split(separator: "-").first.map(String.init) ?? "en"
    }

    static func localized(_ data: Data, languageID: String) throws -> Data {
        var style = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var layers = style["layers"] as! [[String: Any]]
        let code = languageCode(languageID)
        for index in layers.indices {
            guard var layout = layers[index]["layout"] as? [String: Any],
                  let field = layout["text-field"],
                  String(describing: field).contains("name") else { continue }
            // Absent translations fall back to the local OSM name.
            layout["text-field"] = ["coalesce", ["get", "name:" + code], ["get", "name_" + code], ["get", "name"]]
            layers[index]["layout"] = layout
        }
        style["layers"] = layers
        return try JSONSerialization.data(withJSONObject: style, options: [.sortedKeys])
    }

    /// Inline the dated tile templates so future /planet updates cannot orphan a pack.
    static func frozen(_ styleData: Data, tileJSON: Data) throws -> Data {
        guard var style = try JSONSerialization.jsonObject(with: styleData) as? [String: Any],
              var sources = style["sources"] as? [String: [String: Any]],
              var source = sources["openmaptiles"],
              let tileInfo = try JSONSerialization.jsonObject(with: tileJSON) as? [String: Any],
              let tiles = tileInfo["tiles"] as? [String], !tiles.isEmpty,
              tiles.allSatisfy(isHTTPSMapTileTemplate) else { throw CocoaError(.fileReadCorruptFile) }
        source.removeValue(forKey: "url")
        for key in ["tiles", "minzoom", "maxzoom", "attribution", "bounds", "scheme"] {
            if let value = tileInfo[key] { source[key] = value }
        }
        sources["openmaptiles"] = source; style["sources"] = sources
        return try JSONSerialization.data(withJSONObject: style, options: [.sortedKeys])
    }

    /// A tile template is not a literal URL. iOS 15 rejects raw braces while
    /// newer Foundation versions percent-encode them automatically. Validate a
    /// concrete sample and retain the original XYZ tokens for MapLibre.
    static func isHTTPSMapTileTemplate(_ template: String) -> Bool {
        let sample = ["{z}", "{x}", "{y}"].reduce(template) {
            $0.replacingOccurrences(of: $1, with: "0")
        }
        guard !sample.contains("{"), !sample.contains("}"),
              let url = URL(string: sample), url.scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    static func prepareDownloadStyle(_ metadata: DownloadedMapMetadata) async throws -> URL {
        guard let url = metadata.frozenStyleURL,
              let bundled = Bundle.main.url(forResource: "OSMLiberty", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "SpiderRoute/1.5 (+https://spiderroute.com)"]
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: URL(string: "https://tiles.openfreemap.org/planet")!)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        try await Task.detached(priority: .userInitiated) {
            let style = try frozen(localized(Data(contentsOf: bundled), languageID: metadata.languageID), tileJSON: data)
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try style.write(to: url, options: .atomic)
        }.value
        return url
    }

    static func url(languageID: String, permitsNetwork: Bool = true) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OSMStyles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(permitsNetwork ? "liberty-v1-\(languageCode(languageID)).json" : "fixture-v1.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            if permitsNetwork {
                guard let bundled = Bundle.main.url(forResource: "OSMLiberty", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
                data = try localized(Data(contentsOf: bundled), languageID: languageID)
            } else {
                data = Data(##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#eef1e8"}}]}"##.utf8)
            }
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    static var permitsNetwork: Bool {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--ui-live-map-tiles") || (ScreenshotState.requested == nil && !args.contains("--debug-route-persistence-probe") && !args.contains("--debug-map-pan-probe"))
#else
        return true
#endif
    }

    static func estimatedTileCount(_ bounds: MLNCoordinateBounds) -> Int {
        guard bounds.sw.latitude.isFinite, bounds.ne.latitude.isFinite,
              bounds.sw.longitude.isFinite, bounds.ne.longitude.isFinite,
              bounds.sw.latitude >= -85, bounds.ne.latitude <= 85,
              bounds.sw.longitude >= -180, bounds.ne.longitude <= 180,
              bounds.sw.latitude < bounds.ne.latitude, bounds.sw.longitude < bounds.ne.longitude else { return Int.max }
        var count = 0
        for zoom in 0...14 {
            let n = pow(2.0, Double(zoom))
            func y(_ latitude: Double) -> Double { (1 - asinh(tan(latitude * .pi / 180)) / .pi) / 2 * n }
            let columns = floor((bounds.ne.longitude + 180) / 360 * n) - floor((bounds.sw.longitude + 180) / 360 * n) + 1
            let rows = floor(y(bounds.sw.latitude)) - floor(y(bounds.ne.latitude)) + 1
            count += Int(columns * rows)
            if count > 2_500 { return count }
        }
        return count
    }
}

@MainActor
final class OfflineMapStore: ObservableObject {
    static let shared = OfflineMapStore()
    struct Entry: Identifiable {
        let metadata: DownloadedMapMetadata
        let progress: Double
        let bytes: UInt64
        let state: MLNOfflinePackState
        var id: UUID { metadata.id }
    }
    @Published private(set) var entries: [Entry] = []
    @Published var selectedID: UUID? { didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selected_offline_map") } }
    @Published var failed = false
    @Published private(set) var isCreating = false
    var lastRegion = MKCoordinateRegion(center: .init(latitude: 53.9, longitude: 27.5667), span: .init(latitudeDelta: 0.03, longitudeDelta: 0.04))
    private var packs: [UUID: MLNOfflinePack] = [:]
    private var observation: NSKeyValueObservation?
    private var deleting = Set<ObjectIdentifier>()
    private var reloadScheduled = false
#if DEBUG
    private var cleanedQA = false
    private(set) var debugLastError: String?
#endif
    private var observers: [NSObjectProtocol] = []
    var selectedLanguageID: String? { entries.first { $0.id == selectedID && $0.state == .complete }?.metadata.languageID }

    var selectedStyleURL: URL? { entries.first { $0.id == selectedID && $0.state == .complete }?.metadata.frozenStyleURL }

    init() {
        selectedID = UserDefaults.standard.string(forKey: "selected_offline_map").flatMap(UUID.init(uuidString:))
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "SpiderRoute/1.5 (+https://spiderroute.com)"]
        config.httpMaximumConnectionsPerHost = 4
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-offline-map") {
            config.protocolClasses = [OSMBlockedNetworkProtocol.self]
            config.urlCache = nil
        }
#endif
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
        observation = MLNOfflineStorage.shared.observe(\.packs, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.reload() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .MLNOfflinePackError, object: nil, queue: .main) { [weak self] notice in
            let pack = notice.object as? MLNOfflinePack
            Task { @MainActor in
                guard let self, let pack, self.packs.values.contains(where: { $0 === pack }) else { return }
#if DEBUG
                self.debugLastError = String(describing: notice.userInfo)
#endif
                pack.suspend(); self.failed = true; self.reload()
            }
        })
    }
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadScheduled = false; self?.reload()
        }
    }
    private func reload() {
        let loaded = MLNOfflineStorage.shared.packs ?? []
        var next: [UUID: MLNOfflinePack] = [:]
        entries = loaded.compactMap { pack in
            guard !deleting.contains(ObjectIdentifier(pack)) else { return nil }
            guard let metadata = try? JSONDecoder().decode(DownloadedMapMetadata.self, from: pack.context) else { return nil }
            next[metadata.id] = pack
            let p = pack.progress
            return Entry(metadata: metadata, progress: p.countOfResourcesExpected == 0 ? 0 : min(1, Double(p.countOfResourcesCompleted) / Double(p.countOfResourcesExpected)), bytes: p.countOfBytesCompleted, state: pack.state)
        }
        let newlyLoaded = Set(next.keys).subtracting(packs.keys)
        packs = next
#if DEBUG
        if !cleanedQA, MLNOfflineStorage.shared.packs != nil {
            cleanedQA = true
            if ProcessInfo.processInfo.arguments.contains("--ui-clean-offline-qa") {
                for entry in entries where ["QA Minsk Russian", "QA Monaco Country", "QA San Marino Province"].contains(entry.metadata.name) { delete(entry.id) }
            }
        }
#endif
        for id in newlyLoaded { packs[id]?.requestProgress() }
    }
    /// Use the actual pack geometry, including holes/islands, rather than its bounding box.
    func downloadedShape(for metadata: DownloadedMapMetadata) -> MLNShape {
        if let region = packs[metadata.id]?.region as? MLNShapeOfflineRegion { return region.shape }
        var coordinates = [metadata.bounds.sw,
            CLLocationCoordinate2D(latitude: metadata.south, longitude: metadata.east),
            metadata.bounds.ne,
            CLLocationCoordinate2D(latitude: metadata.north, longitude: metadata.west), metadata.bounds.sw]
        return MLNPolygon(coordinates: &coordinates, count: UInt(coordinates.count))
    }

    func download(name: String, languageID: String, bounds: MLNCoordinateBounds, region: OfflineRegion? = nil, shape: MLNShape? = nil, completion: @escaping (Bool) -> Void) {
        guard !isCreating, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (region != nil ? shape != nil : OSMMapStyle.estimatedTileCount(bounds) <= 2_500) else { failed = true; completion(false); return }
        isCreating = true
        Task { @MainActor in
            var pendingStyleURL: URL?
            do {
                let metadata = DownloadedMapMetadata(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), languageID: languageID, bounds: region?.coordinateBounds ?? bounds, regionID: region?.id, styleVersion: 1)
                let styleURL = try await OSMMapStyle.prepareDownloadStyle(metadata)
                pendingStyleURL = styleURL
                let offlineRegion: MLNOfflineRegion
                if region != nil, let shape {
                    // Named administrative regions use the full polygon, including islands.
                    // The custom-area tile cap does not silently crop a named country.
                    offlineRegion = MLNShapeOfflineRegion(styleURL: styleURL, shape: shape, fromZoomLevel: 0, toZoomLevel: 16)
                } else {
                    offlineRegion = MLNTilePyramidOfflineRegion(styleURL: styleURL, bounds: bounds, fromZoomLevel: 0, toZoomLevel: 16)
                }
                let context = try JSONEncoder().encode(metadata)
                let pack = try await MLNOfflineStorage.shared.addPack(for: offlineRegion, withContext: context)
                isCreating = false
                reload(); selectedID = metadata.id; pack.resume(); completion(true)
            } catch {
#if DEBUG
                debugLastError = String(reflecting: error) + " " + String(describing: (error as NSError).userInfo)
#endif
                if let url = pendingStyleURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                isCreating = false; failed = true; completion(false)
            }
        }
    }
    func toggle(_ id: UUID) {
        guard let pack = packs[id] else { return }
        if pack.state == .active { pack.suspend() } else if pack.state != .complete { pack.resume() }
        reload()
    }
    func delete(_ id: UUID) {
        guard let pack = packs.removeValue(forKey: id) else { return }
        if pack.state == .active { pack.suspend() }
        let styleURL = entries.first { $0.id == id }?.metadata.frozenStyleURL
        deleting.insert(ObjectIdentifier(pack))
        if selectedID == id { selectedID = nil }
        entries.removeAll { $0.id == id }
        Task { @MainActor in
            do {
                try await MLNOfflineStorage.shared.removePack(pack)
                if let styleURL { try? FileManager.default.removeItem(at: styleURL.deletingLastPathComponent()) }
            } catch { failed = true; MLNOfflineStorage.shared.reloadPacks() }
            // Retain the invalidated pack through completion, then retire its identity.
            deleting.remove(ObjectIdentifier(pack)); reload()
        }
    }
}

#if DEBUG
/// Deterministic offline QA: every HTTP(S) request fails before a connection can open.
final class OSMBlockedNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { ["https", "http"].contains(request.url?.scheme ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Opt-in weak registry. It neither retains map trees nor performs file I/O on
/// render callbacks. Instruments remains responsible for SDK/system leak checks.
enum OSMMapLifetimeProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--debug-osm-lifetimes")
    private static let maps = NSHashTable<AnyObject>.weakObjects()
    private static let coordinators = NSHashTable<AnyObject>.weakObjects()
    static func register(map: MLNMapView, coordinator: AnyObject) {
        guard enabled else { return }
        maps.add(map); coordinators.add(coordinator)
    }
    static var renderedContent: [[String: Any]] {
        autoreleasepool {
            maps.allObjects.compactMap { object in
                guard let map = object as? MLNMapView else { return nil }
                let features = map.visibleFeatures(in: map.bounds)
                let names = features.compactMap {
                    $0.attribute(forKey: "name:ru") as? String ?? $0.attribute(forKey: "name") as? String
                }
                return ["features": features.count, "names": Array(Set(names)).sorted().prefix(40).map { $0 }]
            }
        }
    }
    static var counts: [String: Int] {
        // Foundation's allObjects snapshot temporarily retains its members.
        // Drain it here, rather than keeping old maps alive until a future UI event.
        autoreleasepool {
            ["maps": maps.allObjects.count, "coordinators": coordinators.allObjects.count]
        }
    }
}

/// Read weak counts at the accessibility query itself, so a hidden/revealed
/// map cannot expose a stale count from its previous render callback.
final class OSMMapLifetimeAccessibilityProbe: UIView {
    override var accessibilityValue: String? {
        get {
            let counts = OSMMapLifetimeProbe.counts
            return "maps:\(counts["maps"] ?? 0),coordinators:\(counts["coordinators"] ?? 0)"
        }
        set { }
    }
}

final class OSMRenderedLabelsProbe {
    func install(in map: MLNMapView) {
        guard ProcessInfo.processInfo.arguments.contains("--ui-map-label-probe") else { return }
        let probe = OSMRenderedLabelsAccessibilityView(frame: .init(x: 0, y: 0, width: 1, height: 1))
        probe.map = map
        probe.isAccessibilityElement = true; probe.isUserInteractionEnabled = false
        probe.accessibilityIdentifier = "map.rendered-labels"; map.addSubview(probe)
    }
}

private final class OSMRenderedLabelsAccessibilityView: UIView {
    weak var map: MLNMapView?
    override var accessibilityValue: String? {
        get {
            guard let map else { return "" }
            // A partially covered offline viewport may never become fully idle.
            // Query the rendered features now instead of keeping an empty sample
            // from the first frame before tiles and glyphs reached the renderer.
            let layers = Set(map.style?.layers.compactMap { ($0 as? MLNSymbolStyleLayer)?.identifier } ?? [])
            let code = map.styleURL?.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "liberty-v1-", with: "") ?? "en"
            let features = map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: layers)
            let names = features.compactMap { feature in
                feature.attribute(forKey: "name:" + code) as? String ?? feature.attribute(forKey: "name_" + code) as? String ?? feature.attribute(forKey: "name") as? String
            }
            return Array(Set(names)).sorted().joined(separator: " | ")
        }
        set { }
    }
}

#endif

/// Preserve the SDK's map/annotation accessibility container while exposing QA probes.
final class SpiderRouteOSMMapView: MLNMapView {
    var onFirstLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.height > 0, let callback = onFirstLayout {
            onFirstLayout = nil
            callback()
        }
    }
#if DEBUG
    private var qaElements: [UIView] { subviews.filter { $0.accessibilityIdentifier?.hasPrefix("map.") == true && $0.isAccessibilityElement } }
    override func accessibilityElementCount() -> Int { super.accessibilityElementCount() + qaElements.count }
    override func accessibilityElement(at index: Int) -> Any? {
        let count = super.accessibilityElementCount()
        return index < count ? super.accessibilityElement(at: index) : qaElements.indices.contains(index - count) ? qaElements[index - count] : nil
    }
    override func index(ofAccessibilityElement element: Any) -> Int {
        if let index = qaElements.firstIndex(where: { $0 === (element as AnyObject) }) { return super.accessibilityElementCount() + index }
        return super.index(ofAccessibilityElement: element)
    }
#endif
}
