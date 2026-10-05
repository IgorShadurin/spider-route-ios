import CryptoKit
import CoreLocation
import MapKit
import XCTest
@testable import SpeedometerGPS

final class TripVideoTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func points(_ count: Int, breakAt: Int? = nil) -> [TrackPoint] {
        (0..<count).map { index in
            TrackPoint(latitude: 53.9 + Double(index) * 0.00001,
                longitude: 27.55 + sin(Double(index) / 100) * 0.002, altitude: 200,
                metersPerSecond: 6, timestamp: start.addingTimeInterval(Double(index)),
                beginsNewSegment: index == breakAt)
        }
    }
    private func receipt(offset: Double = 10, duration: Double = 30,
                         state: CameraVideoReceipt.State = .saved) -> CameraVideoReceipt {
        CameraVideoReceipt(id: UUID(), fileName: "actual-clip.mov", startedAt: start.addingTimeInterval(offset),
            duration: duration, reportedAt: start.addingTimeInterval(100), state: state)
    }

    @MainActor
    func testLocalArchiveBecomesReadyBeforeBlockedCloudAndPreservesCloudOnlyRides() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("local")
        let cloud = directory.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let old = TripRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(100), points: points(100), activity: "activity_cycling")
        let newer = TripRecord(id: UUID(), startedAt: start.addingTimeInterval(200), endedAt: start.addingTimeInterval(300), points: points(100), activity: "activity_cycling")
        let filename = "speedometer-routes.json"
        try JSONEncoder().encode([old]).write(to: local.appendingPathComponent(filename))
        try JSONEncoder().encode([newer, old]).write(to: cloud.appendingPathComponent("Documents").appendingPathComponent(filename))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let archive = RouteArchiveStore(localDocumentsURL: local, cloudContainerURL: { _ in
            _ = gate.wait(timeout: .now() + 10)
            return cloud
        })
        let began = Date()
        while archive.isLoadingLocal && Date().timeIntervalSince(began) < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(archive.isLoadingLocal, "Map launch must not wait for iCloud")
        XCTAssertTrue(archive.isLoading, "Cloud recovery still protects history mutations")
        XCTAssertEqual(archive.trips, [old])
        archive.delete(old, syncWithICloud: true)
        archive.clear(syncWithICloud: true)
        archive.add(newer, syncWithICloud: true)
        XCTAssertEqual(archive.trips, [old], "Do not overwrite unread cloud rides")
        gate.signal()
        await archive.waitForLoad()
        XCTAssertEqual(archive.trips, [newer, old])
        archive.delete(old, syncWithICloud: true)
        archive.flushPersistence()
        let onDisk = try JSONDecoder().decode([TripRecord].self, from: Data(contentsOf: local.appendingPathComponent(filename)))
        XCTAssertEqual(onDisk, [newer], "Cloud saves must retain a current offline copy")
    }

    @MainActor
    func testMissingLocalArchiveDoesNotBlockMapWhileCloudRestores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let archive = RouteArchiveStore(localDocumentsURL: directory, cloudContainerURL: { _ in
            _ = gate.wait(timeout: .now() + 10)
            return nil
        })
        let began = Date()
        while archive.isLoadingLocal && Date().timeIntervalSince(began) < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(archive.isLoadingLocal)
        XCTAssertTrue(archive.isLoading)
        XCTAssertTrue(archive.trips.isEmpty)
        gate.signal()
        await archive.waitForLoad()
        XCTAssertFalse(archive.isLoading)
    }

    @MainActor
    func testArchiveReleasesAfterLoadingAndObservingCloudIdentity() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var archive: RouteArchiveStore? = RouteArchiveStore(localDocumentsURL: directory, cloudContainerIdentifier: nil)
        weak var retained: RouteArchiveStore?
        retained = archive
        await archive?.waitForLoad()
        archive = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(retained)
    }

    func testOldTripAndCheckpointReadWithoutVideoMetadataAndRoundTripKeepsPoints() throws {
        let original = TripRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(100),
                                  points: points(100), activity: "activity_cycling")
        let encoded = try JSONEncoder().encode(original)
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(oldJSON["videoMetadata"])
        var updated = try JSONDecoder().decode(TripRecord.self, from: encoded)
        XCTAssertTrue(updated.videoRecordings.isEmpty)
        updated.videoMetadata = TripVideoMetadata(recordings: [TripVideoRecording(receipt: receipt(), receivedAt: start.addingTimeInterval(100))])
        let decoded = try JSONDecoder().decode(TripRecord.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded, updated)
        XCTAssertEqual(decoded.points, original.points)
        var damaged = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        damaged["videoMetadata"] = "unsupported metadata"
        XCTAssertEqual(try JSONDecoder().decode(TripRecord.self, from: JSONSerialization.data(withJSONObject: damaged)).points, original.points)
        let checkpoint = ActiveTripCheckpoint(state: .recording, startedAt: start, points: original.points,
                                              elapsed: 100, savedAt: start.addingTimeInterval(100))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        old["videoMetadata"] = ["bad": true]
        XCTAssertEqual(try JSONDecoder().decode(ActiveTripCheckpoint.self, from: JSONSerialization.data(withJSONObject: old)).points, original.points)
    }

    func testOptionalReceiptsPreserveWireCompatibilityAndStayWithinPacketLimit() throws {
        let oldStatus = RemoteCameraStatus()
        let oldData = try JSONEncoder().encode(oldStatus)
        XCTAssertNil(try JSONDecoder().decode(RemoteCameraStatus.self, from: oldData).videoReceipts)
        var status = oldStatus
        status.videoReceipts = (0..<8).map { _ in
            CameraVideoReceipt(id: UUID(), fileName: String(repeating: "a", count: 251) + ".mov",
                startedAt: start, duration: 25_200, reportedAt: start.addingTimeInterval(25_200), state: .saved)
        }
        let key = Curve25519.Signing.PrivateKey()
        let packet = RemoteCameraPacket(kind: "status", publicKey: key.publicKey.rawRepresentation,
            nonce: UUID(), sequence: 1, status: status)
        let envelope = try RemoteCameraEnvelope(packet: packet, key: key)
        XCTAssertLessThan(envelope.payload.count, 16_384)
        XCTAssertEqual(try envelope.verifiedPacket().status?.videoReceipts, status.videoReceipts)
    }

    func testConfirmedTailCanCatchUpWithoutNewGPSAndKeepsTheRestStable() {
        let track = points(7201, breakAt: 3600)
        var receipt = receipt(offset: 7150, duration: 10, state: .recording)
        var video = TripVideoRecording(receipt: receipt, receivedAt: receipt.reportedAt)
        var cache = VideoRouteDisplayCache()
        cache.update(points: track, recordings: [video])
        let before = cache.sections.dropLast(3).map(\.id)
        let count = cache.rebuiltChunkCount
        let confirmed = video.confirmedThrough
        receipt.duration = 40
        video.update(receipt)
        cache.update(points: track, recordings: [video], changed: confirmed...video.confirmedThrough)
        XCTAssertLessThanOrEqual(cache.rebuiltChunkCount - count, 1)
        XCTAssertEqual(cache.sections.dropLast(3).map(\.id), before)
        XCTAssertEqual(cache.sections.last(where: { $0.recordingID != nil })!.coordinates.last!.latitude,
                       track[7190].latitude, accuracy: 0.0000001)
        // With no fresh receipt the cache remains at the confirmed endpoint.
        XCTAssertEqual(video.confirmedThrough, start.addingTimeInterval(7190))
    }

    func testReceiptClockOffsetAndDuplicateFinalState() {
        var camera = receipt()
        camera.reportedAt = camera.reportedAt.addingTimeInterval(600)
        let skewed = CameraVideoReceipt(id: camera.id, fileName: camera.fileName,
            startedAt: camera.startedAt.addingTimeInterval(600), duration: 30,
            reportedAt: camera.reportedAt, state: .recording)
        var local = TripVideoRecording(receipt: skewed, receivedAt: start.addingTimeInterval(100))
        XCTAssertEqual(local.startedAt, start.addingTimeInterval(10))
        XCTAssertEqual(local.confirmedThrough, start.addingTimeInterval(40))
        var final = skewed; final.state = .saved; final.duration = 29.8
        local.update(final)
        let saved = local
        local.update(skewed)
        XCTAssertEqual(local, saved)
        XCTAssertEqual(local.duration, 29.8)
    }

    func testColoredSectionsSplitTheActualLineAndNeverBridgeAPause() {
        let track = points(41, breakAt: 25)
        var clip = receipt(offset: 5.5, duration: 29)
        clip.reportedAt = start.addingTimeInterval(100)
        let video = TripVideoRecording(receipt: clip, receivedAt: clip.reportedAt)
        var cache = VideoRouteDisplayCache()
        cache.update(points: track, recordings: [video])
        let purple = cache.sections.filter { $0.recordingID == video.id }
        XCTAssertEqual(purple.count, 2)
        XCTAssertEqual(purple[0].coordinates.last!.latitude, track[24].latitude, accuracy: 0.0000001)
        XCTAssertEqual(purple[1].coordinates.first!.latitude, track[25].latitude, accuracy: 0.0000001)
        for section in cache.sections {
            for pair in zip(section.coordinates, section.coordinates.dropFirst()) {
                XCTAssertFalse(pair.0.latitude <= track[24].latitude && pair.1.latitude >= track[25].latitude)
            }
        }
        let ending = purple.last!.coordinates.last!
        XCTAssertEqual(ending.latitude, (track[34].latitude + track[35].latitude) / 2, accuracy: 0.0000001)
        let coordinate = purple[0].coordinates[0]
        let ids = VideoRouteHitTest.recordings(at: CGPoint(x: coordinate.longitude * 100_000, y: coordinate.latitude * 100_000), sections: cache.sections) {
            CGPoint(x: $0.longitude * 100_000, y: $0.latitude * 100_000)
        }
        XCTAssertEqual(ids, [video.id])
        XCTAssertTrue(VideoRouteHitTest.recordings(at: .zero, sections: cache.sections) { _ in CGPoint(x: 500, y: 500) }.isEmpty)
    }

    @MainActor
    func testCheckpointRecoveryAndLateVideoSaveUpdateTheArchivedTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoints = ActiveTripCheckpointStore(applicationSupportURL: directory)
        let recorder = TripRecorder(checkpointStore: checkpoints, loadRecoveryInBackground: false)
        recorder.start(now: start)
        for point in points(61) {
            recorder.add(CLLocation(coordinate: point.coordinate, altitude: 200, horizontalAccuracy: 5,
                verticalAccuracy: 5, timestamp: point.timestamp))
        }
        var live = receipt(offset: 10, duration: 30, state: .recording)
        recorder.observeCameraReceipts([live], receivedAt: start.addingTimeInterval(100))
        recorder.observeCameraReceipts([live], receivedAt: start.addingTimeInterval(101))
        XCTAssertEqual(recorder.videoRecordings.count, 1)
        recorder.checkpointForLifecycle(now: start.addingTimeInterval(100))
        recorder.flushCheckpoints()
        let recovered = TripRecorder(checkpointStore: checkpoints, loadRecoveryInBackground: false)
        recovered.continueRecoveredTrip(now: start.addingTimeInterval(100))
        XCTAssertEqual(recovered.videoRecordings, recorder.videoRecordings)
        XCTAssertFalse(recovered.videoDisplay.sections.isEmpty)
        let trip = try XCTUnwrap(recovered.finish(activity: "activity_cycling", now: start.addingTimeInterval(100)))
        let archive = RouteArchiveStore(localDocumentsURL: directory, cloudContainerIdentifier: nil, loadInBackground: false)
        archive.add(trip, syncWithICloud: false)
        live.duration = 55; live.state = .saved
        archive.updateVideoReceipts([live], syncWithICloud: false)
        archive.flushPersistence()
        let reloaded = RouteArchiveStore(localDocumentsURL: directory, cloudContainerIdentifier: nil, loadInBackground: false)
        XCTAssertEqual(reloaded.trips[0].points, trip.points)
        XCTAssertEqual(reloaded.trips[0].videoRecordings[0].duration, 55)
        XCTAssertEqual(reloaded.trips[0].videoRecordings[0].state, .saved)
        _ = recorder.finish(activity: "activity_cycling", now: start.addingTimeInterval(101))
    }

    @MainActor
    func testFinalVideoReceiptDuringAsyncArchiveLoadIsAppliedAndSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = receipt(state: .recording)
        let trip = TripRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(100),
            points: points(100), activity: "activity_cycling",
            videoRecordings: [TripVideoRecording(receipt: live, receivedAt: live.reportedAt)])
        let initial = RouteArchiveStore(localDocumentsURL: directory, cloudContainerIdentifier: nil, loadInBackground: false)
        initial.add(trip, syncWithICloud: false)
        initial.flushPersistence()
        let archive = RouteArchiveStore(localDocumentsURL: directory, cloudContainerIdentifier: nil)
        XCTAssertTrue(archive.isLoading)
        var final = live; final.state = .saved; final.duration = 55
        archive.updateVideoReceipts([final], syncWithICloud: false)
        await archive.waitForLoad()
        archive.flushPersistence()
        let reloaded = RouteArchiveStore(localDocumentsURL: directory, cloudContainerIdentifier: nil)
        await reloaded.waitForLoad()
        XCTAssertEqual(reloaded.trips.first?.points, trip.points)
        XCTAssertEqual(reloaded.trips.first?.videoRecordings.first?.duration, 55)
        XCTAssertEqual(reloaded.trips.first?.videoRecordings.first?.state, .saved)
    }

    @MainActor
    func testThousandKilometerNativeOverlayBatchesPreserveGapsAndTailIdentity() {
        var track = ThousandKilometerFixture.points()
        let videos = TripVideoFixture.recordings(start: track[0].timestamp, duration: 180_000)
        var cache = VideoRouteDisplayCache()
        cache.update(points: track, recordings: videos)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 375, height: 600))
        let coordinator = LegacyRouteMapSurface.Coordinator(onCameraChanged: { _,_,_ in }, onCameraSettled: { _,_,_ in })
        func snapshot() -> RouteMapSnapshot {
            RouteMapSnapshot(routeSegments: [], referenceSegments: [], eventMarkers: [], markerOffsets: [:],
                currentCoordinate: nil, currentCourse: 0, currentState: .recording, theme: .lime, recordedSections: cache.sections, recordedDrawingGroups: cache.drawingGroups)
        }
        coordinator.render(snapshot(), in: map)
        XCTAssertLessThan(map.overlays.count, 150)
        let lines = map.overlays.compactMap { $0 as? MKMultiPolyline }.flatMap(\.polylines)
        XCTAssertEqual(lines.count, cache.sections.count, "Batching must keep every disconnected section")
        XCTAssertEqual(lines.reduce(0) { $0 + $1.pointCount }, cache.sections.reduce(0) { $0 + $1.coordinates.count })
        let previous = Set(map.overlays.map { ObjectIdentifier($0 as AnyObject) })
        let last = track.last!
        let next = ThousandKilometerFixture.coordinate(track.count)
        track.append(TrackPoint(latitude: next.latitude, longitude: next.longitude, altitude: 210,
            metersPerSecond: 6, timestamp: last.timestamp.addingTimeInterval(1)))
        cache.update(points: track, recordings: videos, changed: last.timestamp...track.last!.timestamp)
        coordinator.render(snapshot(), in: map)
        let after = Set(map.overlays.map { ObjectIdentifier($0 as AnyObject) })
        XCTAssertLessThanOrEqual(previous.subtracting(after).count, 2, "An append must not replace completed batches")
        print("THOUSAND_KM_MAP native_overlays=\(map.overlays.count) sections=\(cache.sections.count)")
    }

    @MainActor
    func testSevenHourGeometryAndLegacyOverlaysRetainCompletedChunks() throws {
        var track = points(25_200, breakAt: 12_600)
        var videos = TripVideoFixture.recordings(start: start, duration: 25_200)
        let began = ProcessInfo.processInfo.systemUptime
        var cache = VideoRouteDisplayCache()
        cache.update(points: track, recordings: videos)
        let initialTime = ProcessInfo.processInfo.systemUptime - began
        XCTAssertLessThan(initialTime, 5, "Unbounded initial seven-hour geometry work")
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 375, height: 600))
        let coordinator = LegacyRouteMapSurface.Coordinator(onCameraChanged: { _,_,_ in }, onCameraSettled: { _,_,_ in })
        let reference = RouteDisplayPath.chunks(for: track.map(\.coordinate))
        func snapshot() -> RouteMapSnapshot {
            RouteMapSnapshot(routeSegments: [], referenceSegments: reference, eventMarkers: [], markerOffsets: [:],
                currentCoordinate: nil, currentCourse: 0, currentState: .recording, theme: .amber, recordedSections: cache.sections)
        }
        coordinator.render(snapshot(), in: map)
        let previous = Set(map.overlays.map { ObjectIdentifier($0 as AnyObject) })
        let rebuilds = cache.rebuiltChunkCount
        track.append(points(25_201).last!)
        let next = receipt(offset: 25_180, duration: 20, state: .recording)
        videos.append(TripVideoRecording(receipt: next, receivedAt: next.reportedAt))
        let updateBegan = ProcessInfo.processInfo.systemUptime
        cache.update(points: track, recordings: videos, changed: start.addingTimeInterval(25_180)...start.addingTimeInterval(25_201))
        coordinator.render(snapshot(), in: map)
        let updateTime = ProcessInfo.processInfo.systemUptime - updateBegan
        XCTAssertLessThanOrEqual(cache.rebuiltChunkCount - rebuilds, 2)
        let after = Set(map.overlays.map { ObjectIdentifier($0 as AnyObject) })
        XCTAssertGreaterThan(Double(previous.intersection(after).count) / Double(previous.count), 0.98)
        XCTAssertLessThan(updateTime, 1, "A bounded tail update must not freeze the map")
        let metadataBytes = try JSONEncoder().encode(TripVideoMetadata(recordings: videos)).count
        XCTAssertLessThan(metadataBytes, 150_000)
        print("VIDEO_PERF points=\(track.count) clips=\(videos.count) sections=\(cache.sections.count) initial=\(initialTime)s update=\(updateTime)s metadata=\(metadataBytes)B")
    }
}
