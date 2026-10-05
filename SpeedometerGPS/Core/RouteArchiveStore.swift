import Foundation

@MainActor
final class RouteArchiveStore: ObservableObject {
    @Published private(set) var trips: [TripRecord] = []
    @Published private(set) var storageStatusKey = "icloud_status_local"

    private let worker = CoalescingPersistenceWorker(label: "com.wowcoded.speedometergps.archive")
    private var persistenceQueue: DispatchQueue { worker.queue }
    @Published private(set) var isLoading = true
    // Local readiness controls launch. iCloud recovery must not hold the map
    // behind a network/account-service lookup; archive edits still await it.
    @Published private(set) var isLoadingLocal = true
    private let cloudContainerURL: @Sendable (String) -> URL?
    private var identityObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var pendingVideoReceipts: [UUID: CameraVideoReceipt] = [:]
    private var pendingReceiptSync = false
    private var persistenceRevision = 0
    private var completedVideoSignatures: [UUID: String] = [:]
    private let fileManager: FileManager
    private let localDocumentsURL: URL?
    private let cloudContainerIdentifier: String?
    private let fileName = "speedometer-routes.json"

    init(
        fileManager: FileManager = .default,
        localDocumentsURL: URL? = nil,
        cloudContainerIdentifier: String? = "iCloud.com.wowcoded.speedometergps",
        loadInBackground: Bool = true,
        cloudContainerURL: @escaping @Sendable (String) -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: $0)
        }
    ) {
        self.cloudContainerURL = cloudContainerURL
        self.fileManager = fileManager
        self.localDocumentsURL = localDocumentsURL
        self.cloudContainerIdentifier = cloudContainerIdentifier
        if loadInBackground { load() } else { loadSynchronously() }
        identityObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    deinit {
        if let identityObserver { NotificationCenter.default.removeObserver(identityObserver) }
    }

    func add(_ trip: TripRecord, syncWithICloud: Bool) {
        guard !isLoading else { return }
        trips.insert(trip, at: 0)
        persist(syncWithICloud: syncWithICloud)
    }

    func clear(syncWithICloud: Bool) {
        guard !isLoading else { return }
        trips = []
        TripRoutePreviewCache.shared.removeAll()
        persist(syncWithICloud: syncWithICloud)
    }

    func delete(_ trip: TripRecord, syncWithICloud: Bool) {
        guard !isLoading else { return }
        trips.removeAll { $0.id == trip.id }
        TripRoutePreviewCache.shared.remove(trip.previewIdentity)
        persist(syncWithICloud: syncWithICloud, mirror: true)
    }

    private func loadSynchronously() {
        // An iCloud identity notification must not reload an older snapshot while
        // a locally initiated save/delete is still queued.
        defer { isLoading = false; isLoadingLocal = false }
        flushPersistence()
        let candidates = [cloudURL(), localURL()].compactMap { $0 }
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([TripRecord].self, from: data) else { continue }
            trips = decoded.sorted { $0.startedAt > $1.startedAt }
            storageStatusKey = url.path.contains("Mobile Documents") ? "icloud_status_synced" : "icloud_status_local"
            return
        }
    }

    /// Decode and derive summaries on the serial worker, never during app init.
    private func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let revision = persistenceRevision
        let local = localURL(), identifier = cloudContainerIdentifier, resolveCloud = cloudContainerURL
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            let localTrips: [TripRecord]? = await withCheckedContinuation { continuation in
                self.persistenceQueue.async {
                    let decoded = local.flatMap { try? Data(contentsOf: $0) }
                        .flatMap { try? JSONDecoder().decode([TripRecord].self, from: $0) }
                    continuation.resume(returning: decoded?.sorted { $0.startedAt > $1.startedAt })
                }
            }
            guard self.loadGeneration == generation else { return }
            if self.persistenceRevision == revision, let localTrips {
                self.trips = localTrips
                self.storageStatusKey = "icloud_status_local"
            }
            self.isLoadingLocal = false
            let result: ([TripRecord], Bool)? = await withCheckedContinuation { continuation in
                self.persistenceQueue.async {
                    let cloud = identifier.flatMap(resolveCloud)?
                        .appendingPathComponent("Documents").appendingPathComponent("speedometer-routes.json")
                    for url in [cloud].compactMap({ $0 }) {
                        if let data = try? Data(contentsOf: url), let trips = try? JSONDecoder().decode([TripRecord].self, from: data) {
#if DEBUG
                            if ProcessInfo.processInfo.arguments.contains("--debug-backup-cloud-archive") {
                                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("device-cloud-archive-backup.json"), options: .atomic)
                            }
#endif
                            continuation.resume(returning: (trips.sorted { $0.startedAt > $1.startedAt }, url == cloud))
                            return
                        }
                    }
                    continuation.resume(returning: localTrips.map { ($0, false) })
                }
            }
            guard self.loadGeneration == generation else { return }
            // UI mutations are disabled until the first read completes; an identity
            // reload must also never replace changes made while its read was queued.
            if self.persistenceRevision == revision, let result {
                self.trips = result.0
                self.storageStatusKey = result.1 ? "icloud_status_synced" : "icloud_status_local"
                self.completedVideoSignatures.removeAll()
            }
            self.isLoading = false
            let receipts = Array(self.pendingVideoReceipts.values)
            self.pendingVideoReceipts.removeAll()
            self.updateVideoReceipts(receipts, syncWithICloud: self.pendingReceiptSync)
        }
    }

    func waitForLoad() async {
        while isLoading, let task = loadTask { await task.value }
    }

    func updateVideoReceipts(_ receipts: [CameraVideoReceipt], syncWithICloud: Bool) {
        if isLoading {
            // Camera finalization may arrive while the archive is decoding. Keep
            // one latest receipt per clip until that finite load completes.
            for receipt in receipts where receipt.isValid && receipt.isFinal {
                pendingVideoReceipts[receipt.id] = receipt
            }
            pendingReceiptSync = syncWithICloud
            return
        }
        var changed = false
        for receipt in receipts where receipt.isValid && receipt.isFinal {
            let signature = "\(receipt.state.rawValue):\(receipt.duration):\(receipt.fileName)"
            guard completedVideoSignatures[receipt.id] != signature else { continue }
            completedVideoSignatures[receipt.id] = signature
            for index in trips.indices {
                var videos = trips[index].videoRecordings
                guard let videoIndex = videos.firstIndex(where: { $0.id == receipt.id }) else { continue }
                let previous = videos[videoIndex]
                videos[videoIndex].update(receipt)
                if previous != videos[videoIndex] {
                    trips[index].videoMetadata = TripVideoMetadata(recordings: videos)
                    changed = true
                }
            }
        }
        if completedVideoSignatures.count > 128 {
            let retained = Set(receipts.map(\.id))
            completedVideoSignatures = completedVideoSignatures.filter { retained.contains($0.key) }
        }
        if changed { persist(syncWithICloud: syncWithICloud) }
    }

    /// Ordering barrier for reloads/tests. Scene callbacks use the asynchronous
    /// checkpoint below; routine updates encode the archive on its worker.
    func flushPersistence() { persistenceQueue.sync {} }

    func checkpointForLifecycle() {
        let backgroundSave = BackgroundPersistenceTask(name: "Save trip archive")
        persistenceQueue.async { DispatchQueue.main.async { backgroundSave.finish() } }
    }

    func saveFinishedTrip(_ trip: TripRecord, syncWithICloud: Bool) async -> Bool {
        await waitForLoad()
        trips.insert(trip, at: 0)
        let success = await withCheckedContinuation { continuation in
            persist(syncWithICloud: syncWithICloud) { continuation.resume(returning: $0) }
        }
        if !success { trips.removeAll { $0.id == trip.id } }
        return success
    }

    private func persist(syncWithICloud: Bool, mirror: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let snapshot = trips
        let local = localURL(), identifier = cloudContainerIdentifier, resolveCloud = cloudContainerURL
        persistenceRevision += 1
        let revision = persistenceRevision
        worker.submit({
            let manager = FileManager()
            let cloud = (syncWithICloud || mirror ? identifier : nil).flatMap(resolveCloud)?
                .appendingPathComponent("Documents").appendingPathComponent("speedometer-routes.json")
            guard let destination = syncWithICloud ? (cloud ?? local) : local,
                  let data = try? JSONEncoder().encode(snapshot) else { return false }
            func write(_ url: URL) -> Bool {
                do {
                    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    return true
                } catch { return false }
            }
            let primarySaved = write(destination)
            let fallbackSaved = !primarySaved && local != destination ? local.map(write) ?? false : false
            // Keep a local copy of successful cloud saves for the next offline launch.
            let mirrorURL = syncWithICloud ? local : (mirror ? cloud : nil)
            if let mirrorURL, mirrorURL != destination { _ = write(mirrorURL) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.persistenceRevision == revision else { return }
                self.storageStatusKey = primarySaved && destination == cloud ? "icloud_status_synced" : "icloud_status_local"
            }
            return primarySaved || fallbackSaved
        }, completion: completion)
    }

    private func cloudURL() -> URL? {
        guard let cloudContainerIdentifier else { return nil }
        return cloudContainerURL(cloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private func localURL() -> URL? {
        (localDocumentsURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)?.appendingPathComponent(fileName)
    }
}
