import CoreLocation
import Foundation

struct ActiveTripCheckpoint: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let state: TripState
    let startedAt: Date
    let points: [TrackPoint]
    let elapsed: TimeInterval
    let savedAt: Date
    var videoMetadata: TripVideoMetadata?

    init(
        version: Int = Self.currentVersion,
        state: TripState,
        startedAt: Date,
        points: [TrackPoint],
        elapsed: TimeInterval,
        savedAt: Date,
        videoMetadata: TripVideoMetadata? = nil
    ) {
        self.version = version
        self.state = state
        self.startedAt = startedAt
        self.points = points
        self.elapsed = max(0, elapsed)
        self.savedAt = savedAt
        self.videoMetadata = videoMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case version, state, startedAt, points, elapsed, savedAt, videoMetadata
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        state = try c.decode(TripState.self, forKey: .state)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        points = try c.decode([TrackPoint].self, forKey: .points)
        elapsed = try c.decode(TimeInterval.self, forKey: .elapsed)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        videoMetadata = try? c.decodeIfPresent(TripVideoMetadata.self, forKey: .videoMetadata)
    }

    var distance: Double { TripMetrics.distance(for: points) }
    var topSpeed: Double { points.map(\.metersPerSecond).max() ?? 0 }
}

/// Constructed on the recovery worker before publishing the recovery decision.
private struct PreparedTripRecovery {
    let checkpoint: ActiveTripCheckpoint
    let path: RouteDisplayPath
    let statistics: TripStatistics
    let markers: [RouteEventMarker]
    var videos: [TripVideoRecording]
    var videoDisplay: VideoRouteDisplayCache
    init(_ checkpoint: ActiveTripCheckpoint) {
        self.checkpoint = checkpoint
        path = RouteDisplayPath(points: checkpoint.points)
        statistics = TripStatistics(points: checkpoint.points)
        markers = RouteEventMarkers.make(points: checkpoint.points)
        videos = checkpoint.videoMetadata?.version == 1 ? checkpoint.videoMetadata!.recordings.filter(\.isValid) : []
        videoDisplay = VideoRouteDisplayCache()
        if !videos.isEmpty { videoDisplay.update(points: checkpoint.points, recordings: videos) }
    }
}

@MainActor
final class TripRecorder: ObservableObject {
    @Published private(set) var state: TripState = .idle
    @Published private(set) var startedAt: Date?
    // Publishing the whole Array forces a retained old value and a route-sized
    // copy on every append. Publish the mutation signal, keep source storage unique.
    private(set) var points: [TrackPoint] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var pendingRecovery: ActiveTripCheckpoint?

    @Published private(set) var isLoadingRecovery = true
    private var recoveryTask: Task<Void, Never>?
    private var preparedRecovery: PreparedTripRecovery?
    var recoveryDistance: Double { preparedRecovery?.statistics.distance ?? pendingRecovery?.distance ?? 0 }

    private let checkpointStore: ActiveTripCheckpointStore
    private let checkpointWriter: ActiveTripCheckpointWriter
    private(set) var displayPath = RouteDisplayPath()
    private(set) var distance: Double = 0
    private(set) var topSpeed: Double = 0
    @Published private(set) var videoRecordings: [TripVideoRecording] = []
    private(set) var videoDisplay = VideoRouteDisplayCache()
    private var videoIndices: [UUID: Int] = [:]
    private var speedTotal: Double = 0
    private var boundaryMarkers: [RouteEventMarker] = []
#if DEBUG
    private var stressNextIndex: Int?
    private var stressReplayPoints: [TrackPoint]?
    var isReplayingSuppliedRoute: Bool { stressReplayPoints != nil }
#endif
    private var timer: Timer?
    private var recordedElapsedBeforeCurrentRun: TimeInterval = 0
    private var currentRunStartedAt: Date?
    private var lastCheckpointDate: Date?
    private var lastCheckpointPointCount = 0
    private var nextPointBeginsNewSegment = false

    init(checkpointStore: ActiveTripCheckpointStore = ActiveTripCheckpointStore(), checkpointWriter: ActiveTripCheckpointWriter? = nil, loadRecoveryInBackground: Bool = true) {
        self.checkpointStore = checkpointStore
        self.checkpointWriter = checkpointWriter ?? ActiveTripCheckpointWriter(store: checkpointStore)
        if loadRecoveryInBackground {
            recoveryTask = Task { [weak self] in
                let prepared = await Task.detached(priority: .userInitiated) {
                    checkpointStore.load().map(PreparedTripRecovery.init)
                }.value
                guard let self else { return }
                self.preparedRecovery = prepared
                self.pendingRecovery = prepared?.checkpoint
                self.isLoadingRecovery = false
            }
        } else {
            // Explicit synchronous mode is only used by deterministic fixtures/tests.
            preparedRecovery = checkpointStore.load().map(PreparedTripRecovery.init)
            pendingRecovery = preparedRecovery?.checkpoint
            isLoadingRecovery = false
        }
    }

    func waitForRecoveryLoad() async { await recoveryTask?.value }

    var averageSpeed: Double { points.isEmpty ? 0 : speedTotal / Double(points.count) }
    var mapEventMarkers: [RouteEventMarker] {
        guard hasUnclosedPause, let last = points.last else { return boundaryMarkers }
        return boundaryMarkers + [RouteEventMarker(id: "active-pause-\(last.id)", kind: .pause, coordinate: last.coordinate)]
    }

    private func appendDisplayAndMetrics(_ point: TrackPoint, previous: TrackPoint?, index: Int, updateDisplay: Bool = true) {
        if updateDisplay { displayPath.append(point.coordinate, beginsNewSegment: point.beginsNewSegment) }
        topSpeed = max(topSpeed, point.metersPerSecond)
        speedTotal += point.metersPerSecond
        if let previous, !point.beginsNewSegment {
            distance += CLLocation(latitude: point.latitude, longitude: point.longitude)
                .distance(from: CLLocation(latitude: previous.latitude, longitude: previous.longitude))
        }
        if index == 0 {
            boundaryMarkers.append(RouteEventMarker(id: "start-\(point.id)", kind: .start, coordinate: point.coordinate))
        } else if point.beginsNewSegment, let previous {
            boundaryMarkers.append(RouteEventMarker(id: "pause-\(previous.id)-\(index)", kind: .pause, coordinate: previous.coordinate))
            boundaryMarkers.append(RouteEventMarker(id: "resume-\(point.id)-\(index)", kind: .resume, coordinate: point.coordinate))
        }
    }

    private func resetDisplayAndMetrics() {
        displayPath = RouteDisplayPath()
        distance = 0
        topSpeed = 0
        speedTotal = 0
        boundaryMarkers = []
        videoRecordings = []
        videoIndices = [:]
        videoDisplay = VideoRouteDisplayCache()
    }

    var segments: [[TrackPoint]] {
        points.reduce(into: [[TrackPoint]]()) { segments, point in
            if segments.isEmpty || point.beginsNewSegment {
                segments.append([point])
            } else {
                segments[segments.count - 1].append(point)
            }
        }
    }

    var needsRecoveryDecision: Bool { pendingRecovery != nil }
    var hasUnclosedPause: Bool { state == .paused || nextPointBeginsNewSegment }

    func start(now: Date = Date()) {
        guard !isLoadingRecovery, pendingRecovery == nil else { return }
        checkpointWriter.clear()
        pendingRecovery = nil
        nextPointBeginsNewSegment = false
        state = .recording
        startedAt = now
        resetDisplayAndMetrics()
        points = []
        recordedElapsedBeforeCurrentRun = 0
        currentRunStartedAt = now
        let inferredElapsed = max(0, Date().timeIntervalSince(now))
        elapsed = inferredElapsed < 24 * 60 * 60 ? inferredElapsed : 0
        startTimer()
        persistCheckpoint(now: now, force: true)
    }

    func togglePause(now: Date = Date()) {
        switch state {
        case .recording:
            updateElapsed(now: now)
            recordedElapsedBeforeCurrentRun = elapsed
            currentRunStartedAt = nil
            state = .paused
            timer?.invalidate()
            persistCheckpoint(now: now, force: true)
        case .paused:
            state = .recording
            currentRunStartedAt = now
            nextPointBeginsNewSegment = !points.isEmpty
            startTimer()
            persistCheckpoint(now: now, force: true)
        case .idle:
            break
        }
    }

    func add(_ location: CLLocation) {
        guard state == .recording, location.horizontalAccuracy >= 0, location.horizontalAccuracy.isFinite,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.altitude.isFinite, location.speed.isFinite,
              location.timestamp.timeIntervalSinceReferenceDate.isFinite else { return }
        if let currentRunStartedAt, location.timestamp < currentRunStartedAt { return }
        if let last = points.last, location.timestamp <= last.timestamp { return }
        objectWillChange.send()
        let point = TrackPoint(location: location, beginsNewSegment: nextPointBeginsNewSegment)
        appendDisplayAndMetrics(point, previous: points.last, index: points.count)
        points.append(point)
        if !videoRecordings.isEmpty {
            videoDisplay.update(points: points, recordings: videoRecordings,
                changed: (points.count > 1 ? points[points.count - 2].timestamp : point.timestamp)...point.timestamp)
        }
        nextPointBeginsNewSegment = false
        updateElapsed(now: location.timestamp)
        persistCheckpoint(now: Date())
    }

    func observeCameraReceipts(_ receipts: [CameraVideoReceipt], receivedAt: Date = Date()) {
        guard state != .idle, let startedAt else { return }
        var changedStart: Date?, changedEnd: Date?
        var changed = false
        for receipt in receipts where receipt.isValid {
            let existingIndex = videoIndices[receipt.id]
            let previous = existingIndex.map { videoRecordings[$0] }
            var value = previous ?? TripVideoRecording(receipt: receipt, receivedAt: receivedAt)
            guard value.confirmedThrough >= startedAt, value.startedAt <= receivedAt else { continue }
            value.update(receipt)
            guard value != previous else { continue }
            if let existingIndex { videoRecordings[existingIndex] = value }
            else { videoIndices[value.id] = videoRecordings.count; videoRecordings.append(value) }
            changed = true
            let from = previous.map { min($0.confirmedThrough, value.confirmedThrough) } ?? value.startedAt
            let through = max(previous?.confirmedThrough ?? value.confirmedThrough, value.confirmedThrough)
            changedStart = min(changedStart ?? from, from)
            changedEnd = max(changedEnd ?? through, through)
        }
        guard changed else { return }
        if let changedStart, let changedEnd {
            videoDisplay.update(points: points, recordings: videoRecordings, changed: changedStart...changedEnd)
        }
        // Encode/write on the checkpoint worker, including a stop while stationary.
        persistCheckpoint(now: receivedAt, metadataChanged: true)
    }

    func checkpointForLifecycle(now: Date = Date()) {
        guard state != .idle else { return }
        updateElapsed(now: now)
        let backgroundSave = BackgroundPersistenceTask(name: "Save active route")
        persistCheckpoint(now: now, force: true)
        checkpointWriter.flush { backgroundSave.finish() }
    }

    /// Explicit ordering barrier for tests; never call from scene callbacks.
    func flushCheckpoints() { checkpointWriter.flush() }

    func awaitCheckpointWrites() async {
        await withCheckedContinuation { continuation in
            checkpointWriter.flush { continuation.resume() }
        }
    }

    func continueRecoveredTrip(now: Date = Date()) {
        guard let checkpoint = pendingRecovery else { return }
        let prepared = preparedRecovery ?? PreparedTripRecovery(checkpoint)
        preparedRecovery = nil
        pendingRecovery = nil
        startedAt = checkpoint.startedAt
        resetDisplayAndMetrics()
        displayPath = prepared.path
        distance = prepared.statistics.distance
        topSpeed = prepared.statistics.topSpeed
        speedTotal = prepared.statistics.speedTotal
        boundaryMarkers = prepared.markers
        points = checkpoint.points
        videoRecordings = prepared.videos
        videoIndices = Dictionary(videoRecordings.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        videoDisplay = prepared.videoDisplay
        recordedElapsedBeforeCurrentRun = checkpoint.elapsed
        elapsed = checkpoint.elapsed
        nextPointBeginsNewSegment = !checkpoint.points.isEmpty

        if checkpoint.state == .recording {
            state = .recording
            currentRunStartedAt = now
            startTimer()
        } else {
            state = .paused
            currentRunStartedAt = nil
            timer?.invalidate()
        }
        persistCheckpoint(now: now, force: true)
    }

    func discardRecoveredTrip() {
        preparedRecovery = nil
        guard pendingRecovery != nil else { return }
        pendingRecovery = nil
        reset(clearCheckpoint: true)
    }

#if DEBUG
    func installLongRideFixture(now: Date = Date()) {
        if let trip = LongRouteFixture.replayTrip {
            let prefix = "--ui-replay-seconds="
            let seconds = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
                .flatMap { Double($0.dropFirst(prefix.count)) } ?? 7_200
            let points = trip.points.prefix { $0.timestamp.timeIntervalSince(trip.startedAt) <= seconds }
            pendingRecovery = ActiveTripCheckpoint(state: .recording, startedAt: trip.startedAt,
                points: Array(points), elapsed: seconds, savedAt: now)
            continueRecoveredTrip(now: now)
            stressReplayPoints = trip.points
            stressNextIndex = points.count
            return
        }
        let prefix = "--ui-long-seconds="
        let requested = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
            .flatMap { Int($0.dropFirst(prefix.count)) } ?? 7_200
        let seconds = min(86_400, max(300, requested))
        let start = now.addingTimeInterval(-Double(seconds))
        let points = (0..<seconds).map { index in
            let coordinate = LongRouteFixture.coordinate(index)
            return TrackPoint(latitude: coordinate.latitude, longitude: coordinate.longitude,
                              altitude: 210, metersPerSecond: 6, timestamp: start.addingTimeInterval(Double(index)),
                              beginsNewSegment: index == 3_600)
        }
        let videos = ProcessInfo.processInfo.arguments.contains("--ui-video-route")
            ? TripVideoFixture.recordings(start: start, duration: Double(seconds)) : []
        pendingRecovery = ActiveTripCheckpoint(state: .recording, startedAt: start, points: points,
            elapsed: Double(seconds), savedAt: now, videoMetadata: TripVideoMetadata(recordings: videos))
        continueRecoveredTrip(now: now)
        stressNextIndex = seconds
    }

    func installVideoFixture() {
        guard videoRecordings.isEmpty else { return }
        videoRecordings = TripVideoFixture.shortRecordings(points: points)
        videoIndices = Dictionary(uniqueKeysWithValues: videoRecordings.enumerated().map { ($0.element.id, $0.offset) })
        videoDisplay.update(points: points, recordings: videoRecordings)
    }

    func installMockRecoveryCheckpoint(now: Date = Date()) {
        guard state == .idle else { return }
        let startedAt = now.addingTimeInterval(-1_143)
        let coordinates = RouteMapView.mockRoute
        let points = coordinates.enumerated().map { index, coordinate in
            TrackPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                altitude: 210 + Double(index),
                metersPerSecond: 12 + Double(index),
                timestamp: startedAt.addingTimeInterval(Double(index) * 42)
            )
        }
        pendingRecovery = ActiveTripCheckpoint(
            state: .recording,
            startedAt: startedAt,
            points: points,
            elapsed: 18 * 60 + 42,
            savedAt: now.addingTimeInterval(-7)
        )
    }
#endif

    func finishedRecord(activity: String, now: Date = Date()) -> TripRecord? {
        guard let startedAt, state != .idle else { return nil }
        updateElapsed(now: now)
        let record = TripRecord(
            id: UUID(),
            startedAt: startedAt,
            endedAt: now,
            points: points,
            activity: activity,
            recordedDuration: elapsed,
            videoRecordings: videoRecordings,
            statistics: TripStatistics(distance: distance, topSpeed: topSpeed, speedTotal: speedTotal)
        )
        return record
    }

    func finish(activity: String, now: Date = Date()) -> TripRecord? {
        guard let record = finishedRecord(activity: activity, now: now) else { return nil }
        reset(clearCheckpoint: true)
        return record
    }

    /// Called only after the archive acknowledges a durable successful write.
    func completeFinishedTrip() async {
        reset(clearCheckpoint: false)
        await checkpointWriter.clearInBackground()
    }

    /// Covers interruption after archive commit but before checkpoint retirement.
    func retireAlreadyArchivedRecovery(in trips: [TripRecord]) async {
        guard let checkpoint = pendingRecovery else { return }
        let matched = await Task.detached(priority: .utility) {
            trips.contains { $0.startedAt == checkpoint.startedAt && $0.duration >= checkpoint.elapsed && $0.points == checkpoint.points }
        }.value
        guard matched, pendingRecovery?.startedAt == checkpoint.startedAt else { return }
        pendingRecovery = nil
        preparedRecovery = nil
        await checkpointWriter.clearInBackground()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateElapsed(now: Date())
#if DEBUG
                if let index = self.stressNextIndex {
                    if let replay = self.stressReplayPoints, index >= replay.count { return }
                    let coordinate = self.stressReplayPoints?[index].coordinate ?? LongRouteFixture.coordinate(index)
                    self.add(CLLocation(coordinate: coordinate, altitude: 210, horizontalAccuracy: 5,
                                        verticalAccuracy: 5, course: 0, speed: 6, timestamp: Date()))
                    self.stressNextIndex = index + 1
                }
#endif
            }
        }
    }

    private func updateElapsed(now: Date) {
        guard state == .recording, let currentRunStartedAt else { return }
        elapsed = recordedElapsedBeforeCurrentRun + max(0, now.timeIntervalSince(currentRunStartedAt))
    }

    private func persistCheckpoint(now: Date, force: Bool = false, metadataChanged: Bool = false) {
        guard let startedAt, state != .idle else { return }
        let hasNewPoint = points.count != lastCheckpointPointCount
        let checkpointIsDue = lastCheckpointDate.map { now.timeIntervalSince($0) >= 5 } ?? true
        guard force || metadataChanged || hasNewPoint || checkpointIsDue else { return }

        let checkpoint = ActiveTripCheckpoint(
            state: state,
            startedAt: startedAt,
            points: points,
            elapsed: elapsed,
            savedAt: now,
            videoMetadata: videoRecordings.isEmpty ? nil : TripVideoMetadata(recordings: videoRecordings)
        )
        checkpointWriter.save(checkpoint, synchronously: false)
        lastCheckpointDate = now
        lastCheckpointPointCount = points.count
    }

    private func reset(clearCheckpoint: Bool) {
        timer?.invalidate()
#if DEBUG
        stressNextIndex = nil
        stressReplayPoints = nil
#endif
        state = .idle
        startedAt = nil
        resetDisplayAndMetrics()
        points = []
        elapsed = 0
        recordedElapsedBeforeCurrentRun = 0
        currentRunStartedAt = nil
        lastCheckpointDate = nil
        lastCheckpointPointCount = 0
        nextPointBeginsNewSegment = false
        if clearCheckpoint { checkpointWriter.clear() }
    }
}

private enum TripMetrics {
    static func distance(for points: [TrackPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { result, pair in
            guard !pair.1.beginsNewSegment else { return result }
            let first = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let second = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return result + second.distance(from: first)
        }
    }
}
