import XCTest
import CoreLocation
import SQLite3
@testable import SpeedometerGPS

final class ActiveTripPersistenceTests: XCTestCase {
    private func store() -> ActiveTripCheckpointStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ActiveTripCheckpointStore(applicationSupportURL: directory)
    }

    private func points(_ count: Int) -> [TrackPoint] {
        (0..<count).map { index -> TrackPoint in
            let latitude = 53.9 + Double(index) * 0.00003
            let longitude = 30.3 + sin(Double(index) / 20.0) * 0.01
            let timestamp = Date(timeIntervalSince1970: 1_000_000.125 + Double(index))
            return TrackPoint(latitude: latitude,
                longitude: longitude,
                altitude: 123.456, metersPerSecond: 7.25,
                timestamp: timestamp,
                beginsNewSegment: index > 0 && index % 3600 == 0)
        }
    }

    private func checkpoint(_ points: [TrackPoint], elapsed: Double = 25_200) -> ActiveTripCheckpoint {
        ActiveTripCheckpoint(state: .recording, startedAt: Date(timeIntervalSince1970: 1_000_000),
            points: points, elapsed: elapsed, savedAt: Date(timeIntervalSince1970: 1_025_200.5))
    }

    func testSevenHourCheckpointOnlyEncodesNewPointsAndPreservesExactRecovery() throws {
        let store = store()
        let database = try ActiveTripDatabase(url: store.databaseURL)
        let track = points(25_320)
        let initial = checkpoint(Array(track.prefix(25_200)))
        let began = CFAbsoluteTimeGetCurrent()
        try database.save(initial)
        let seedTime = CFAbsoluteTimeGetCurrent() - began
        let initialBytes = database.encodedBytes
        let appendStart = CFAbsoluteTimeGetCurrent()
        for count in 25_201...25_320 { try database.save(checkpoint(Array(track.prefix(count)))) }
        let appendTime = CFAbsoluteTimeGetCurrent() - appendStart
        XCTAssertEqual(database.encodedPointCount, track.count, "Previously confirmed points must never be re-encoded on append")
        XCTAssertLessThan(database.encodedBytes - initialBytes, 120_000)
        XCTAssertEqual(store.load(), checkpoint(track))
        print("CHECKPOINT_PERF seed_points=25200 seed_seconds=\(seedTime) appends=120 append_seconds=\(appendTime) incremental_bytes=\(database.encodedBytes - initialBytes)")
    }

    @MainActor
    func testThousandKilometerAsyncRecoveryPreservesEveryPointDurationAndGaps() async throws {
        let store = store()
        let track = ThousandKilometerFixture.points()
        let saved = checkpoint(track, elapsed: 180_000)
        try await Task.detached { try store.save(saved) }.value
        let recorder = TripRecorder(checkpointStore: store)
        XCTAssertTrue(recorder.isLoadingRecovery)
        // A tap while startup is reading must never overwrite the confirmed trip.
        recorder.start()
        XCTAssertEqual(recorder.state, .idle)
        await recorder.waitForRecoveryLoad()
        XCTAssertEqual(recorder.pendingRecovery, saved)
        XCTAssertGreaterThan(recorder.recoveryDistance, 1_000_000)
        XCTAssertLessThan(recorder.recoveryDistance, 1_010_000)
        let resume = track.last!.timestamp.addingTimeInterval(3600)
        recorder.continueRecoveredTrip(now: resume)
        XCTAssertEqual(recorder.points, track)
        XCTAssertEqual(recorder.elapsed, 180_000)
        XCTAssertEqual(recorder.mapEventMarkers.count, 100)
        let before = recorder.distance
        let c = ThousandKilometerFixture.coordinate(track.count + 1000)
        recorder.add(CLLocation(coordinate: c, altitude: 210, horizontalAccuracy: 5,
            verticalAccuracy: 5, course: 0, speed: 6, timestamp: resume.addingTimeInterval(1)))
        XCTAssertEqual(recorder.distance, before, "No connecting distance across a terminated interval")
        XCTAssertTrue(recorder.points.last!.beginsNewSegment)
        await recorder.awaitCheckpointWrites()
        let restored = await Task.detached { store.load() }.value
        XCTAssertEqual(restored?.points, recorder.points)
        XCTAssertEqual(restored?.elapsed, 180_001)
        let finished = try XCTUnwrap(recorder.finish(activity: "activity_cycling", now: resume.addingTimeInterval(1)))
        XCTAssertEqual(finished.distance, before)
        XCTAssertEqual(finished.duration, 180_001)
        XCTAssertEqual(finished.segments.count, 51)
        let archiveDirectory = store.fileURL.deletingLastPathComponent().appendingPathComponent("archive")
        let archive = RouteArchiveStore(localDocumentsURL: archiveDirectory, cloudContainerIdentifier: nil)
        await archive.waitForLoad()
        archive.add(finished, syncWithICloud: false)
        archive.flushPersistence()
        let relaunched = RouteArchiveStore(localDocumentsURL: archiveDirectory, cloudContainerIdentifier: nil)
        XCTAssertTrue(relaunched.isLoading)
        await relaunched.waitForLoad()
        XCTAssertEqual(relaunched.trips, [finished])
        print("THOUSAND_KM points=\(track.count) distance_km=\(before / 1000) duration=\(finished.duration) exact_recovery=true")
    }

    func testThousandKilometerIncrementalCommitDoesNotRewriteHistory() throws {
        let store = store()
        let database = try ActiveTripDatabase(url: store.databaseURL)
        let points = ThousandKilometerFixture.points(count: 180_120)
        try database.save(checkpoint(Array(points.prefix(180_000)), elapsed: 180_000))
        let previousBytes = database.encodedBytes
        for count in 180_001...180_120 {
            try database.save(checkpoint(Array(points.prefix(count)), elapsed: Double(count)))
        }
        XCTAssertEqual(database.encodedPointCount, points.count)
        XCTAssertLessThan(database.encodedBytes - previousBytes, 120_000)
        XCTAssertEqual(store.load()?.points, points)
    }

    func testThousandKilometerExportsKeepPointCountAndSegmentBoundaries() throws {
        let points = ThousandKilometerFixture.points()
        let trip = TripRecord(id: UUID(), startedAt: points[0].timestamp,
            endedAt: points.last!.timestamp, points: points, activity: "activity_cycling", recordedDuration: 180_000)
        for format in RouteExportFormat.allCases {
            try autoreleasepool {
                let data = try RouteExporter.data(for: trip, format: format)
                let imported = try ReferenceRouteImporter.decode(data: data, fileName: "long.\(format.filenameExtension)")
                XCTAssertEqual(imported.pointCount, points.count, format.rawValue)
                XCTAssertEqual(imported.segments.count, 50, format.rawValue)
                XCTAssertEqual(imported.segments.first?.first?.latitude ?? 0, points[0].latitude, accuracy: 0.0000001)
                XCTAssertEqual(imported.segments.last?.last?.longitude ?? 0, points.last!.longitude, accuracy: 0.0000001)
                print("THOUSAND_KM_EXPORT format=\(format.rawValue) bytes=\(data.count) points=\(imported.pointCount)")
            }
        }
    }

    @MainActor
    func testFinishHandoffKeepsCheckpointOnFailureAndRetiresAlreadyArchivedRecovery() async throws {
        let store = store()
        let saved = checkpoint(points(100))
        try store.save(saved)
        let recorder = TripRecorder(checkpointStore: store)
        await recorder.waitForRecoveryLoad()
        recorder.continueRecoveredTrip(now: saved.savedAt)
        recorder.togglePause(now: saved.savedAt)
        await recorder.awaitCheckpointWrites()
        let trip = try XCTUnwrap(recorder.finishedRecord(activity: "activity_cycling", now: saved.savedAt))
        let invalidDestination = store.fileURL.deletingLastPathComponent().appendingPathComponent("not-a-directory")
        try Data([1]).write(to: invalidDestination)
        let invalidArchive = RouteArchiveStore(localDocumentsURL: invalidDestination, cloudContainerIdentifier: nil)
        let failed = await invalidArchive.saveFinishedTrip(trip, syncWithICloud: false)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.load()?.points, saved.points)
        XCTAssertEqual(recorder.state, .paused)
        let archive = RouteArchiveStore(localDocumentsURL: invalidDestination.deletingLastPathComponent().appendingPathComponent("archive"), cloudContainerIdentifier: nil)
        let success = await archive.saveFinishedTrip(trip, syncWithICloud: false)
        XCTAssertTrue(success)
        // Relaunch at the crash boundary: archive has committed, active checkpoint remains.
        let relaunched = TripRecorder(checkpointStore: store)
        await relaunched.waitForRecoveryLoad()
        await relaunched.retireAlreadyArchivedRecovery(in: archive.trips)
        XCTAssertNil(relaunched.pendingRecovery)
        XCTAssertNil(store.load())
        XCTAssertEqual(archive.trips, [trip])
    }

    func testCheckpointWithFifteenHundredClipsWritesOnlyChangedMetadata() throws {
        let store = store()
        let database = try ActiveTripDatabase(url: store.databaseURL)
        let track = points(180)
        let start = track[0].timestamp
        var videos = TripVideoMetadata(recordings: TripVideoFixture.recordings(start: start, duration: 180_000))
        var saved = checkpoint(Array(track.prefix(60)))
        saved.videoMetadata = videos
        try database.save(saved)
        XCTAssertEqual(database.encodedVideoCount, 1500)
        let initialBytes = database.encodedBytes
        for count in 61...180 {
            var next = checkpoint(Array(track.prefix(count)))
            next.videoMetadata = videos
            try database.save(next)
        }
        XCTAssertEqual(database.encodedVideoCount, 1500, "GPS fixes must not re-encode clip history")
        XCTAssertLessThan(database.encodedBytes - initialBytes, 120_000)
        videos.recordings[videos.recordings.count - 1].duration += 1
        var last = checkpoint(track); last.videoMetadata = videos
        try database.save(last)
        XCTAssertEqual(database.encodedVideoCount, 1501)
        XCTAssertEqual(store.load(), last)
        // A failed clip update must leave both route and metadata at the preceding commit.
        videos.recordings[0].duration = .nan
        var invalid = last; invalid.videoMetadata = videos
        XCTAssertThrowsError(try database.save(invalid))
        XCTAssertEqual(store.load(), last)
        try database.clear()
        XCTAssertNil(store.load())
    }

    func testLegacyJSONMigratesOnlyAfterCommitAndClearCannotResurrectIt() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode(checkpoint(points(500)))
        try legacyData.write(to: store.fileURL, options: .atomic)
        let legacy = try XCTUnwrap(store.load())
        XCTAssertEqual(legacy.points.count, 500)
        try store.save(legacy)
        XCTAssertEqual(store.load(), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        // Even an undeletable/restored legacy file must not override a tombstone.
        store.clear()
        try legacyData.write(to: store.fileURL, options: .atomic)
        XCTAssertNil(store.load())
    }

    func testEarlierSQLiteInlineVideosMigrateWithoutLosingMetadata() throws {
        let store = store()
        var saved = checkpoint(points(180))
        saved.videoMetadata = TripVideoMetadata(recordings: TripVideoFixture.recordings(start: saved.startedAt, duration: 360))
        try store.save(saved)
        // Recreate the previous schema's inline header with no video tables.
        let header = ActiveTripCheckpoint(state: saved.state, startedAt: saved.startedAt, points: [],
            elapsed: saved.elapsed, savedAt: saved.savedAt, videoMetadata: saved.videoMetadata)
        let data = try JSONEncoder().encode(header)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE videos; DROP TABLE video_header;", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE header SET payload=? WHERE id=1", -1, &statement, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }, SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        XCTAssertEqual(store.load(), saved)
        saved = ActiveTripCheckpoint(state: saved.state, startedAt: saved.startedAt, points: saved.points,
            elapsed: saved.elapsed + 1, savedAt: saved.savedAt, videoMetadata: saved.videoMetadata)
        try store.save(saved)
        XCTAssertEqual(store.load(), saved)
        saved.videoMetadata = nil
        try store.save(saved)
        XCTAssertNil(store.load()?.videoMetadata)
    }

    func testUncommittedTransactionLeavesPreviousCheckpointIntact() throws {
        let store = store()
        let saved = checkpoint(points(300))
        try store.save(saved)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.databaseURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE; DELETE FROM points; UPDATE header SET pointCount=0;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db) // Simulate interruption before COMMIT: SQLite rolls back.
        XCTAssertEqual(store.load(), saved)
    }

    func testQueuedSnapshotsCoalesceWithoutLosingPointsAndClearOrdersNewTrip() throws {
        let store = store()
        let queue = DispatchQueue(label: "checkpoint-test.blocked")
        let writer = ActiveTripCheckpointWriter(store: store, queue: queue)
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let track = points(200)
        for count in 1...200 { writer.save(checkpoint(Array(track.prefix(count))), synchronously: false) }
        gate.signal(); writer.flush()
        XCTAssertEqual(store.load(), checkpoint(track))
        writer.save(checkpoint(track), synchronously: false)
        writer.clear()
        XCTAssertNil(store.load())
        let next = ActiveTripCheckpoint(state: .paused, startedAt: Date(timeIntervalSince1970: 2_000_000),
            points: Array(track.prefix(2)), elapsed: 2, savedAt: Date(timeIntervalSince1970: 2_000_002))
        writer.save(next, synchronously: true)
        XCTAssertEqual(store.load(), next)
    }

    func testFailedSaveCanRetryAllUncommittedPoints() throws {
        let store = store()
        let saved = checkpoint(points(10))
        try store.save(saved)
        let database = try ActiveTripDatabase(url: store.databaseURL)
        var invalid = saved.points
        invalid.append(TrackPoint(latitude: .nan, longitude: 0, altitude: 0, metersPerSecond: 1, timestamp: Date()))
        XCTAssertThrowsError(try database.save(checkpoint(invalid)))
        XCTAssertEqual(store.load(), saved)
        let good = saved.points + points(1)
        try database.save(checkpoint(good))
        XCTAssertEqual(store.load()?.points, good)
    }

    @MainActor
    func testLifecycleCheckpointReturnsWithoutWaitingForDiskAndFlushRecovers() throws {
        let store = store()
        let saved = checkpoint(points(25_200))
        try store.save(saved)
        let queue = DispatchQueue(label: "lifecycle-test.blocked")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let writer = ActiveTripCheckpointWriter(store: store, queue: queue)
        let recorder = TripRecorder(checkpointStore: store, checkpointWriter: writer, loadRecoveryInBackground: false)
        let began = CFAbsoluteTimeGetCurrent()
        recorder.continueRecoveredTrip(now: saved.savedAt)
        let recoverySeconds = CFAbsoluteTimeGetCurrent() - began
        let lifecycleStart = CFAbsoluteTimeGetCurrent()
        recorder.checkpointForLifecycle(now: saved.savedAt.addingTimeInterval(1))
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - lifecycleStart, 0.25)
        gate.signal()
        recorder.flushCheckpoints()
        XCTAssertEqual(store.load()?.points, saved.points)
        XCTAssertEqual(store.load()?.elapsed, saved.elapsed + 1)
        print("RECOVERY_PERF points=25200 seconds=\(recoverySeconds)")
    }

    func testBulkRecoveryGeometryMatchesLiveAppendIncludingNextPointAndGaps() {
        let track = points(8_000)
        var incremental = RouteDisplayPath()
        for point in track { incremental.append(point.coordinate, beginsNewSegment: point.beginsNewSegment) }
        var bulk = RouteDisplayPath(points: track)
        func values(_ path: RouteDisplayPath) -> [[Double]] {
            path.segments.map { $0.flatMap { [$0.latitude, $0.longitude] } }
        }
        XCTAssertEqual(values(bulk), values(incremental))
        XCTAssertEqual(bulk.drawingGroups.flatMap(\.segments).count, bulk.segments.count)
        let beforeGroups = bulk.drawingGroups.map(\.revision)
        let next = CLLocationCoordinate2D(latitude: 54.2, longitude: 30.8)
        bulk.append(next); incremental.append(next)
        XCTAssertEqual(Array(bulk.drawingGroups.map(\.revision).dropLast()), Array(beforeGroups.dropLast()), "A fix must retain all completed native groups")
        XCTAssertEqual(values(bulk), values(incremental))
        bulk.append(next, beginsNewSegment: true); incremental.append(next, beginsNewSegment: true)
        XCTAssertEqual(values(bulk), values(incremental))
    }
}

final class RideTelemetryTests: XCTestCase {
    private func store() -> ActiveTripCheckpointStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ActiveTripCheckpointStore(applicationSupportURL: directory)
    }

    func testCompactPointEncodingPreservesExactSamplesAndRejectsTruncation() throws {
        for index in [0, 1, 59, 600, 18_000] {
            let location = LongRecordingProbe.telemetryLocation(index: index, timestamp: Date(timeIntervalSince1970: 1_700_000_000.125 + Double(index)))
            let point = TrackPoint(location: location, beginsNewSegment: index == 18_000)
            let data = try TrackPointStorage.encode(point)
            XCTAssertEqual(data.count, 85)
            XCTAssertEqual(try TrackPointStorage.decode(data), point)
            XCTAssertThrowsError(try TrackPointStorage.decode(data.dropLast()))
            let json = try JSONEncoder().encode(point)
            XCTAssertEqual(try TrackPointStorage.decode(json), point)
        }
        let old = TrackPoint(latitude: 1, longitude: 2, altitude: 3, metersPerSecond: 4, timestamp: Date())
        XCTAssertEqual(try TrackPointStorage.encode(old).count, 61)
        XCTAssertNil(try TrackPointStorage.decode(JSONEncoder().encode(old)).gps)
    }

    func testTwentyHourCompactCheckpointAndMixedLegacyRowsRoundTrip() throws {
        let store = store()
        let db = try ActiveTripDatabase(url: store.databaseURL)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points = (0..<72_000).map { index in
            TrackPoint(location: LongRecordingProbe.telemetryLocation(index: index, timestamp: start.addingTimeInterval(Double(index))), beginsNewSegment: index > 0 && index % 18_000 == 0)
        }
        func checkpoint() -> ActiveTripCheckpoint {
            ActiveTripCheckpoint(state: .paused, startedAt: start, points: points, elapsed: 72_000, savedAt: start.addingTimeInterval(72_000))
        }
        try db.save(checkpoint())
        XCTAssertEqual(db.encodedPointCount, 72_000)
        XCTAssertLessThan(db.encodedBytes, 72_000 * 85 + 1024)
        XCTAssertEqual(try db.load(), checkpoint())
        // Replace the last committed row with the previous JSON representation.
        // The next append must read the legacy boundary and retain every row.
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.databaseURL.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let json = try JSONEncoder().encode(points.last!)
        let hex = json.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE points SET payload=x'\(hex)' WHERE position=71999", nil, nil, nil), SQLITE_OK)
        let before = db.encodedPointCount
        points.append(TrackPoint(location: LongRecordingProbe.telemetryLocation(index: 72_000, timestamp: start.addingTimeInterval(72_010)), beginsNewSegment: true))
        try db.save(checkpoint())
        XCTAssertEqual(db.encodedPointCount - before, 1)
        XCTAssertEqual(store.load(), checkpoint())
    }

    @MainActor
    func testRecorderPreservesUnknownSpeedAndRecoveryGap() async throws {
        let store = store()
        let recorder = TripRecorder(checkpointStore: store, loadRecoveryInBackground: false)
        let start = Date()
        recorder.start(now: start)
        recorder.add(LongRecordingProbe.telemetryLocation(index: 5, timestamp: start.addingTimeInterval(-1)))
        for index in 0..<3 {
            recorder.add(LongRecordingProbe.telemetryLocation(index: index, timestamp: start.addingTimeInterval(Double(index))))
        }
        await recorder.awaitCheckpointWrites()
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.points.count, 3)
        XCTAssertEqual(saved.points[0].gps?.rawSpeed, -1)
        XCTAssertEqual(saved.points[1].gps?.rawSpeed, 0)
        let resumed = TripRecorder(checkpointStore: store)
        await resumed.waitForRecoveryLoad()
        resumed.continueRecoveredTrip(now: start.addingTimeInterval(60))
        resumed.add(LongRecordingProbe.telemetryLocation(index: 50, timestamp: start.addingTimeInterval(50)))
        resumed.add(LongRecordingProbe.telemetryLocation(index: 61, timestamp: start.addingTimeInterval(61)))
        await resumed.awaitCheckpointWrites()
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(Array(restored.points.prefix(3)), saved.points)
        XCTAssertTrue(restored.points[3].beginsNewSegment)
        XCTAssertEqual(restored.elapsed, 3)
        _ = recorder.finish(activity: "activity_cycling")
        _ = resumed.finish(activity: "activity_cycling")
    }

    func testVideoExportsPreserveUTCOffsetAccuracyAndMissingSpeed() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let points = [0, 1, 61, 62].map { index in
            TrackPoint(location: LongRecordingProbe.telemetryLocation(index: index, timestamp: start.addingTimeInterval(Double(index))), beginsNewSegment: index == 61)
        }
        let trip = TripRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(62), points: points, activity: "activity_cycling")
        let csv = String(decoding: try RouteExporter.data(for: trip, format: .csv), as: UTF8.self)
        let rows = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[1][5], "")
        XCTAssertEqual(rows[1][8], "false")
        XCTAssertEqual(rows[2][5], "0.000")
        XCTAssertEqual(rows[2][8], "true")
        XCTAssertEqual(rows[3][0], "2")
        XCTAssertEqual(rows[3][7], "61.000")
        XCTAssertEqual(rows[3][13], "0.250")
        XCTAssertTrue(rows[1][1].contains(".125Z"))
        let gpx = String(decoding: try RouteExporter.data(for: trip, format: .gpx), as: UTF8.self)
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertEqual(gpx.components(separatedBy: "<speedometer:speed unit=").count - 1, 3)
        XCTAssertTrue(gpx.contains("<speedometer:speedValid>false</speedometer:speedValid>"))
        XCTAssertTrue(gpx.contains("<speedometer:speedAccuracy unit=\"m/s\">0.250</speedometer:speedAccuracy>"))
        let imported = try ReferenceRouteImporter.decode(data: Data(gpx.utf8), fileName: "telemetry.gpx")
        XCTAssertEqual(imported.pointCount, 4)
    }
}
