import Foundation
import MapKit

/// Camera-authoritative metadata. The bounded recent ledger is sent with status;
/// video bytes and device-local URLs never travel with the GPS trip.
struct CameraVideoReceipt: Codable, Equatable, Identifiable {
    enum State: String, Codable { case recording, saving, saved, interrupted }
    let id: UUID
    let fileName: String
    let startedAt: Date
    var duration: TimeInterval
    var reportedAt: Date
    var state: State
    var isFinal: Bool { state == .saved || state == .interrupted }
    var isValid: Bool {
        duration.isFinite && duration >= 0 && duration < 30 * 24 * 3600
            && startedAt.timeIntervalSince1970.isFinite && reportedAt.timeIntervalSince1970.isFinite && fileName.count <= 255
            && !fileName.contains("/") && !fileName.contains("\\")
    }
}

/// One entry per clip, not per GPS point. Dates used for route association are on
/// the GPS phone's clock; the camera's original date is retained for the info sheet.
struct TripVideoMetadata: Codable, Equatable, Hashable {
    var version = 1
    var recordings: [TripVideoRecording]
}

struct TripVideoRecording: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var fileName: String
    let cameraStartedAt: Date
    let startedAt: Date
    var confirmedThrough: Date
    var duration: TimeInterval
    var state: CameraVideoReceipt.State

    init(receipt: CameraVideoReceipt, receivedAt: Date) {
        id = receipt.id
        fileName = receipt.fileName
        cameraStartedAt = receipt.startedAt
        startedAt = receivedAt.addingTimeInterval(-receipt.reportedAt.timeIntervalSince(receipt.startedAt))
        confirmedThrough = startedAt.addingTimeInterval(receipt.duration)
        duration = receipt.duration
        state = receipt.state
    }

    var isValid: Bool {
        startedAt.timeIntervalSince1970.isFinite && cameraStartedAt.timeIntervalSince1970.isFinite
            && confirmedThrough.timeIntervalSince1970.isFinite && confirmedThrough >= startedAt
            && duration.isFinite && duration >= 0 && fileName.count <= 255
    }

    mutating func update(_ receipt: CameraVideoReceipt) {
        guard receipt.id == id, receipt.isValid, !(state == .saved && receipt.state != .saved) else { return }
        fileName = receipt.fileName
        // A finalized movie supplies the actual media duration, including a short
        // correction to an earlier heartbeat/stop-request estimate.
        duration = receipt.state == .saved ? receipt.duration : max(duration, receipt.duration)
        confirmedThrough = startedAt.addingTimeInterval(duration)
        state = receipt.state
    }
}

struct VideoRouteSection: Identifiable {
    let id: String
    let recordingID: UUID?
    let coordinates: [CLLocationCoordinate2D]
    let bounds: MKMapRect

    init(id: String, recordingID: UUID?, coordinates: [CLLocationCoordinate2D]) {
        self.id = id; self.recordingID = recordingID; self.coordinates = coordinates
        bounds = coordinates.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: MKMapPoint($1), size: MKMapSize(width: 0.01, height: 0.01))) }
    }
}

/// Source-index chunks stay stable when clip boundaries arrive late. A GPS sample
/// or heartbeat rebuilds only intersecting 256-point chunks; camera gestures never
/// rebuild geometry. Both colors are sections of this SAME simplified source path.
struct VideoRouteDisplayCache {
    private var chunks: [[VideoRouteSection]] = []
    private var groupedChunks: [[RouteDrawingGroup]] = []
    private(set) var drawingGroups: [RouteDrawingGroup] = []
    private(set) var sections: [VideoRouteSection] = []
    private(set) var rebuiltChunkCount = 0
    static let stride = RouteDisplayPath.chunkSize - 1

    mutating func update(points: [TrackPoint], recordings: [TripVideoRecording], changed: ClosedRange<Date>? = nil) {
        guard points.count > 1, !recordings.isEmpty else {
            chunks = []; sections = []; groupedChunks = []; drawingGroups = []; return
        }
        let count = (points.count - 2) / Self.stride + 1
        let rebuildAll = chunks.isEmpty || count < chunks.count || changed == nil
        if count < chunks.count { chunks = []; groupedChunks = [] }
        while chunks.count < count { chunks.append([]) }
        let ordered = recordings.sorted { $0.startedAt < $1.startedAt }
        let first: Int, last: Int
        if !rebuildAll, let changed {
            first = max(0, Self.lowerBound(points, date: changed.lowerBound) - 1) / Self.stride
            last = min(count - 1, Self.lowerBound(points, date: changed.upperBound) / Self.stride)
        } else { first = 0; last = count - 1 }
        guard first <= last else { return }
        for chunk in first...last {
            let lower = chunk * Self.stride
            let upper = min(points.count - 1, lower + Self.stride)
            let candidates = ordered.filter { $0.startedAt <= points[upper].timestamp && $0.confirmedThrough >= points[lower].timestamp }
            chunks[chunk] = Self.makeSections(points: points, range: lower...upper, recordings: candidates, chunk: chunk)
            rebuiltChunkCount += 1
        }
        sections = chunks.flatMap { $0 }
        let groups = (count + RouteDrawingGroup.chunkCount - 1) / RouteDrawingGroup.chunkCount
        while groupedChunks.count < groups { groupedChunks.append([]) }
        for index in (first / RouteDrawingGroup.chunkCount)...(last / RouteDrawingGroup.chunkCount) {
            let start = index * RouteDrawingGroup.chunkCount
            let sections = chunks[start..<min(start + RouteDrawingGroup.chunkCount, count)].flatMap { $0 }
            groupedChunks[index] = [false, true].compactMap { isVideo in
                let paths = sections.filter { ($0.recordingID != nil) == isVideo }.map(\.coordinates)
                return paths.isEmpty ? nil : RouteDrawingGroup(id: "\(index):\(isVideo)", segments: paths, isVideo: isVideo)
            }
        }
        drawingGroups = groupedChunks.flatMap { $0 }
    }

    static func lowerBound(_ points: [TrackPoint], date: Date) -> Int {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func makeSections(points: [TrackPoint], range: ClosedRange<Int>, recordings: [TripVideoRecording], chunk: Int) -> [VideoRouteSection] {
        var result: [VideoRouteSection] = []
        var run: [CLLocationCoordinate2D] = []
        var currentID: UUID?
        var runStart: Date?
        func flush() {
            if run.count > 1, let runStart {
                result.append(VideoRouteSection(id: "\(chunk):\(runStart.timeIntervalSinceReferenceDate):\(currentID?.uuidString ?? "gps")",
                    recordingID: currentID, coordinates: RouteDisplayPath.simplify(run)))
            }
            run = []; runStart = nil
        }
        for index in range.dropFirst() {
            let a = points[index - 1], b = points[index]
            guard !b.beginsNewSegment, b.timestamp > a.timestamp else { flush(); continue }
            let candidates = recordings.filter { $0.startedAt < b.timestamp && $0.confirmedThrough > a.timestamp }
            var times = [a.timestamp, b.timestamp]
            for clip in candidates {
                if clip.startedAt > a.timestamp && clip.startedAt < b.timestamp { times.append(clip.startedAt) }
                if clip.confirmedThrough > a.timestamp && clip.confirmedThrough < b.timestamp { times.append(clip.confirmedThrough) }
            }
            times = Array(Set(times)).sorted()
            for pair in zip(times, times.dropFirst()) {
                let midpoint = pair.0.addingTimeInterval(pair.1.timeIntervalSince(pair.0) / 2)
                let id = candidates.last { $0.startedAt <= midpoint && $0.confirmedThrough >= midpoint }?.id
                if runStart == nil || id != currentID { flush(); currentID = id; runStart = pair.0; run = [interpolate(a, b, at: pair.0)] }
                run.append(interpolate(a, b, at: pair.1))
            }
        }
        flush()
        return result
    }

    private static func interpolate(_ a: TrackPoint, _ b: TrackPoint, at date: Date) -> CLLocationCoordinate2D {
        let t = max(0, min(1, date.timeIntervalSince(a.timestamp) / b.timestamp.timeIntervalSince(a.timestamp)))
        let x = MKMapPoint(a.coordinate), y = MKMapPoint(b.coordinate)
        var dx = y.x - x.x
        let width = MKMapRect.world.size.width
        if dx > width / 2 { dx -= width }; if dx < -width / 2 { dx += width }
        return MKMapPoint(x: (x.x + dx * t + width).truncatingRemainder(dividingBy: width), y: x.y + (y.y - x.y) * t).coordinate
    }
}

enum VideoRouteHitTest {
    /// Work happens only for a tap, against simplified displayed sections. Returning
    /// every coincident clip keeps repeated passes along the same road selectable.
    static func recordings(at tap: CGPoint, sections: [VideoRouteSection], tolerance: CGFloat = 22,
                           project: (CLLocationCoordinate2D) -> CGPoint?) -> [UUID] {
        var hits: [(UUID, CGFloat)] = []
        for section in sections {
            guard let id = section.recordingID else { continue }
            var distance = CGFloat.infinity
            for pair in zip(section.coordinates, section.coordinates.dropFirst()) {
                guard let a = project(pair.0), let b = project(pair.1) else { continue }
                let dx = b.x - a.x, dy = b.y - a.y
                let square = dx * dx + dy * dy
                let t = square == 0 ? 0 : max(0, min(1, ((tap.x - a.x) * dx + (tap.y - a.y) * dy) / square))
                distance = min(distance, hypot(tap.x - a.x - t * dx, tap.y - a.y - t * dy))
            }
            if distance <= tolerance { hits.append((id, distance)) }
        }
        var seen = Set<UUID>()
        return hits.sorted { $0.1 < $1.1 }.map(\.0).filter { seen.insert($0).inserted }
    }
}

#if DEBUG
/// Fast-forwarded fixtures exercise hours of real source geometry without waiting
/// hours or retaining private rides in the bundle.
enum TripVideoFixture {
    static func recordings(start: Date, duration: TimeInterval) -> [TripVideoRecording] {
        stride(from: 30.0, to: duration - 1, by: 120).enumerated().map { index, offset in
            let began = start.addingTimeInterval(offset)
            let receipt = CameraVideoReceipt(id: UUID(), fileName: String(format: "ride-%04d.mov", index + 1),
                startedAt: began, duration: min(45, duration - offset), reportedAt: began, state: .saved)
            return TripVideoRecording(receipt: receipt, receivedAt: began)
        }
    }
    static func shortRecordings(points: [TrackPoint]) -> [TripVideoRecording] {
        guard let first = points.first, let last = points.last else { return [] }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        return [(0.12, 0.33), (0.60, 0.25)].enumerated().map { index, window in
            let began = first.timestamp.addingTimeInterval(span * window.0)
            let receipt = CameraVideoReceipt(id: UUID(uuidString: index == 0 ? "4AE9ABC1-7123-4010-ABA1-AFBFA3300001" : "4AE9ABC1-7123-4010-ABA1-AFBFA3300002")!,
                fileName: "ride-\(index + 1).mov", startedAt: began, duration: span * window.1, reportedAt: began, state: .saved)
            return TripVideoRecording(receipt: receipt, receivedAt: began)
        }
    }
}
#endif
