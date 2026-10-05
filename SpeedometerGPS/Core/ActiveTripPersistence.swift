import Foundation
import SQLite3
import UIKit
import OSLog

/// The legacy JSON remains readable. New checkpoints atomically commit only new
/// points and a small header; saving a seven-hour ride never encodes seven hours
/// of history on every GPS fix. SQLite is supplied by iOS, including iOS 15.
struct ActiveTripCheckpointStore {
    let fileURL: URL
    var databaseURL: URL { fileURL.appendingPathExtension("sqlite") }

    init(fileManager: FileManager = .default, applicationSupportURL: URL? = nil,
         fileName: String = "active-trip-checkpoint.json") {
        let directory = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        fileURL = directory.appendingPathComponent(fileName)
    }

    func load() -> ActiveTripCheckpoint? {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do {
                let database = try ActiveTripDatabase(url: databaseURL)
                // A committed empty header is a tombstone, not permission to
                // resurrect a legacy file after Finish/Discard.
                if try database.hasHeader { return try database.load() }
            } catch { Self.log.error("Checkpoint read failed: \(String(describing: error), privacy: .public)") }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let checkpoint = try? decoder.decode(ActiveTripCheckpoint.self, from: data),
              checkpoint.version == ActiveTripCheckpoint.currentVersion,
              checkpoint.state != .idle else { return nil }
        return checkpoint
    }

    func save(_ checkpoint: ActiveTripCheckpoint) throws {
        try ActiveTripDatabase(url: databaseURL).save(checkpoint)
        retireLegacyFile()
    }

    func clear() {
        do { try ActiveTripDatabase(url: databaseURL).clear(); retireLegacyFile() }
        catch { Self.log.error("Checkpoint clear failed: \(String(describing: error), privacy: .public)") }
    }

    func retireLegacyFile() { try? FileManager.default.removeItem(at: fileURL) }
    static let log = Logger(subsystem: "com.wowcoded.speedometergps", category: "checkpoint")
}

/// Confined to its owner's serial worker. A transaction includes points, elapsed
/// time, state and video metadata, so a killed process cannot recover a mixed save.
final class ActiveTripDatabase {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var hasVideoCache = false
    private var cachedVideos: TripVideoMetadata?
    private(set) var encodedVideoCount = 0
    private(set) var encodedPointCount = 0
    private(set) var encodedBytes = 0
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // The database and WAL must remain writable while the recording phone is
        // locked, with the same protection as completeFileProtectionUntilFirstUserAuthentication.
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let failure = error(); sqlite3_close(db); db = nil; throw failure
        }
        do {
            sqlite3_busy_timeout(db, 1_000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=256;")
            try execute("CREATE TABLE IF NOT EXISTS header (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB, pointCount INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS points (position INTEGER PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS video_header (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB); CREATE TABLE IF NOT EXISTS videos (position INTEGER PRIMARY KEY, payload BLOB NOT NULL);")
            for path in [url.path, url.path + "-wal", url.path + "-shm"] where manager.fileExists(atPath: path) {
                try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { sqlite3_close(db) }

    var hasHeader: Bool {
        get throws {
            let statement = try prepare("SELECT id FROM header WHERE id=1")
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw error() }
            return result == SQLITE_ROW
        }
    }

    private func header() throws -> (ActiveTripCheckpoint?, Int) {
        let statement = try prepare("SELECT payload, pointCount FROM header WHERE id=1")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return (nil, 0) }
        guard result == SQLITE_ROW else { throw error() }
        let count = Int(sqlite3_column_int64(statement, 1))
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return (nil, count) }
        return (try decoder.decode(ActiveTripCheckpoint.self, from: blob(statement, column: 0)), count)
    }

    func load() throws -> ActiveTripCheckpoint? {
        try execute("BEGIN DEFERRED")
        defer { try? execute("ROLLBACK") }
        let (metadata, expectedCount) = try header()
        guard let metadata, metadata.version == ActiveTripCheckpoint.currentVersion, metadata.state != .idle else { return nil }
        let statement = try prepare("SELECT position, payload FROM points ORDER BY position")
        defer { sqlite3_finalize(statement) }
        var points: [TrackPoint] = []
        points.reserveCapacity(expectedCount)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, sqlite3_column_int64(statement, 0) == points.count else { throw error() }
            points.append(try autoreleasepool { try TrackPointStorage.decode(blob(statement, column: 1)) })
        }
        guard points.count == expectedCount else { throw CocoaError(.fileReadCorruptFile) }
        return ActiveTripCheckpoint(version: metadata.version, state: metadata.state, startedAt: metadata.startedAt,
            points: points, elapsed: metadata.elapsed, savedAt: metadata.savedAt,
            videoMetadata: (try? loadVideos(fallback: metadata.videoMetadata)) ?? nil)
    }

    private func loadVideos(fallback: TripVideoMetadata?) throws -> TripVideoMetadata? {
        let header = try prepare("SELECT payload FROM video_header WHERE id=1")
        defer { sqlite3_finalize(header) }
        let result = sqlite3_step(header)
        if result == SQLITE_DONE { return fallback } // Earlier SQLite checkpoint schema.
        guard result == SQLITE_ROW else { throw error() }
        guard sqlite3_column_type(header, 0) != SQLITE_NULL else { return nil }
        var metadata = try decoder.decode(TripVideoMetadata.self, from: blob(header, column: 0))
        let statement = try prepare("SELECT position, payload FROM videos ORDER BY position")
        defer { sqlite3_finalize(statement) }
        while true {
            let row = sqlite3_step(statement)
            if row == SQLITE_DONE { break }
            guard row == SQLITE_ROW, sqlite3_column_int64(statement, 0) == metadata.recordings.count else { throw error() }
            metadata.recordings.append(try decoder.decode(TripVideoRecording.self, from: blob(statement, column: 1)))
        }
        return metadata
    }

    private func saveVideos(_ metadata: TripVideoMetadata?, reset: Bool) throws {
        let recordings = metadata?.recordings ?? []
        let old = cachedVideos?.recordings ?? []
        let replace = reset || !hasVideoCache
        if replace { try execute("DELETE FROM videos") }
        let insert = try prepare("INSERT OR REPLACE INTO videos (position,payload) VALUES (?,?)")
        defer { sqlite3_finalize(insert) }
        for index in recordings.indices where replace || index >= old.count || old[index] != recordings[index] {
            let data = try encoder.encode(recordings[index])
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            sqlite3_bind_int64(insert, 1, Int64(index)); try bind(data, to: insert, index: 2)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw error() }
            encodedVideoCount += 1; encodedBytes += data.count
        }
        if !replace && old.count > recordings.count { try execute("DELETE FROM videos WHERE position>=\(recordings.count)") }
        if replace || cachedVideos?.version != metadata?.version {
            if let metadata {
                let data = try encoder.encode(TripVideoMetadata(version: metadata.version, recordings: []))
                let statement = try prepare("INSERT OR REPLACE INTO video_header (id,payload) VALUES (1,?)")
                defer { sqlite3_finalize(statement) }
                try bind(data, to: statement, index: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
                encodedBytes += data.count
            } else { try execute("INSERT OR REPLACE INTO video_header (id,payload) VALUES (1,NULL)") }
        }
    }

    func save(_ checkpoint: ActiveTripCheckpoint) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let (previous, count) = try header()
            var offset = count
            // Only append-only snapshots of the same trip may reuse stored rows.
            // Verify the retained boundary so replacing a fixture/trip is safe too.
            var continues = previous?.startedAt == checkpoint.startedAt && count <= checkpoint.points.count
            if continues && count > 0 {
                let statement = try prepare("SELECT payload FROM points WHERE position=\(count - 1)")
                defer { sqlite3_finalize(statement) }
                continues = try sqlite3_step(statement) == SQLITE_ROW
                    && (try TrackPointStorage.decode(blob(statement, column: 0))) == checkpoint.points[count - 1]
            }
            if !continues { try execute("DELETE FROM points"); offset = 0 }
            let insert = try prepare("INSERT INTO points (position,payload) VALUES (?,?)")
            defer { sqlite3_finalize(insert) }
            for index in offset..<checkpoint.points.count {
                try autoreleasepool {
                    let data = try TrackPointStorage.encode(checkpoint.points[index])
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    sqlite3_bind_int64(insert, 1, Int64(index))
                    try bind(data, to: insert, index: 2)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw error() }
                    encodedPointCount += 1; encodedBytes += data.count
                }
            }
            try saveVideos(checkpoint.videoMetadata, reset: !continues)
            let metadata = ActiveTripCheckpoint(version: checkpoint.version, state: checkpoint.state,
                startedAt: checkpoint.startedAt, points: [], elapsed: checkpoint.elapsed,
                savedAt: checkpoint.savedAt, videoMetadata: nil)
            let data = try encoder.encode(metadata)
            let update = try prepare("INSERT OR REPLACE INTO header (id,payload,pointCount) VALUES (1,?,?)")
            defer { sqlite3_finalize(update) }
            try bind(data, to: update, index: 1)
            sqlite3_bind_int64(update, 2, Int64(checkpoint.points.count))
            guard sqlite3_step(update) == SQLITE_DONE else { throw error() }
            try execute("COMMIT")
            cachedVideos = checkpoint.videoMetadata
            hasVideoCache = true
            encodedBytes += data.count
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func clear() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM points; DELETE FROM videos; DELETE FROM video_header; INSERT OR REPLACE INTO header (id,payload,pointCount) VALUES (1,NULL,0); COMMIT;")
            cachedVideos = nil; hasVideoCache = false
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func error() -> NSError {
        NSError(domain: "ActiveTripDatabase", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
        guard result == SQLITE_OK else { throw error() }
    }
    private func blob(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// At most one in-flight snapshot and one newest pending snapshot. Coalescing
/// drops no points: each snapshot includes every accepted point, and the worker
/// writes only the suffix absent from the last committed transaction.
// Mutable scheduling state is protected by lock; the database is queue-confined.
final class ActiveTripCheckpointWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let store: ActiveTripCheckpointStore
    private var pending: ActiveTripCheckpoint?
    private var scheduled = false
    private var database: ActiveTripDatabase?

    init(store: ActiveTripCheckpointStore,
         queue: DispatchQueue = DispatchQueue(label: "com.wowcoded.speedometergps.checkpoint", qos: .utility)) {
        self.store = store; self.queue = queue
    }

    func save(_ checkpoint: ActiveTripCheckpoint, synchronously: Bool) {
        lock.lock()
        pending = checkpoint
        if !scheduled {
            scheduled = true
            queue.async { self.drain() }
        }
        lock.unlock()
        if synchronously { flush() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else { scheduled = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            do {
                try autoreleasepool {
                    if database == nil { database = try ActiveTripDatabase(url: store.databaseURL) }
                    try database!.save(snapshot)
                    store.retireLegacyFile()
                }
            } catch {
                ActiveTripCheckpointStore.log.error("Checkpoint write failed: \(String(describing: error), privacy: .public)")
                // Retain the newest complete state for retry on the next fix.
                lock.lock()
                if pending == nil { pending = snapshot }
                scheduled = false
                lock.unlock()
                return
            }
        }
    }

    func clear() {
        lock.lock(); pending = nil; lock.unlock()
        queue.sync {
            lock.lock(); pending = nil; scheduled = false; lock.unlock()
            do {
                if database == nil { database = try ActiveTripDatabase(url: store.databaseURL) }
                try database!.clear()
                store.retireLegacyFile()
            } catch { ActiveTripCheckpointStore.log.error("Checkpoint clear failed: \(String(describing: error), privacy: .public)") }
        }
    }

    func clearInBackground() async {
        await withCheckedContinuation { continuation in
            // Start a barrier from a worker; clear's serial ordering remains shared
            // with tests and a subsequent recorder, without blocking UIKit.
            DispatchQueue.global(qos: .utility).async {
                self.clear()
                continuation.resume()
            }
        }
    }

    func flush() { queue.sync {} }
    func flush(completion: @escaping @MainActor () -> Void) {
        queue.async { DispatchQueue.main.async { completion() } }
    }
}

/// Finite background time protects a queued commit without blocking UIKit's
/// scene transition. Expiration simply ends the assertion; SQLite rolls back an
/// interrupted transaction and the preceding confirmed checkpoint stays valid.
@MainActor
final class BackgroundPersistenceTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.finish() }
    }
    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// One executing snapshot and one newest pending snapshot, including completion
/// acknowledgements. Used for infrequent whole-library writes, never GPS fixes.
final class CoalescingPersistenceWorker {
    let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: (() -> Bool)?
    private var completions: [(Bool) -> Void] = []
    private var scheduled = false
    init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }
    func submit(_ write: @escaping () -> Bool, completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        pending = write
        if let completion { completions.append(completion) }
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule { queue.async { self.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let write = pending else { scheduled = false; lock.unlock(); return }
            let callbacks = completions
            pending = nil; completions = []
            lock.unlock()
            let success = autoreleasepool(invoking: write)
            DispatchQueue.main.async { callbacks.forEach { $0(success) } }
        }
    }
}
