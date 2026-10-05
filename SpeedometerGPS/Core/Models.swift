import CoreLocation
import Foundation

struct TrackPoint: Codable, Identifiable, Equatable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let metersPerSecond: Double
    let timestamp: Date
    let beginsNewSegment: Bool
    let gps: GPSMeasurement?

    init(id: UUID = UUID(), location: CLLocation, beginsNewSegment: Bool = false) {
        self.id = id
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        metersPerSecond = max(0, location.speed)
        timestamp = location.timestamp
        self.beginsNewSegment = beginsNewSegment
        gps = GPSMeasurement(location: location)
    }

    init(id: UUID = UUID(), latitude: Double, longitude: Double, altitude: Double, metersPerSecond: Double, timestamp: Date, beginsNewSegment: Bool = false, gps: GPSMeasurement? = nil) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.metersPerSecond = metersPerSecond
        self.timestamp = timestamp
        self.gps = gps
        self.beginsNewSegment = beginsNewSegment
    }

    private enum CodingKeys: String, CodingKey {
        case id, latitude, longitude, altitude, metersPerSecond, timestamp, beginsNewSegment, gps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        altitude = try container.decode(Double.self, forKey: .altitude)
        metersPerSecond = try container.decode(Double.self, forKey: .metersPerSecond)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        beginsNewSegment = try container.decodeIfPresent(Bool.self, forKey: .beginsNewSegment) ?? false
        gps = try container.decodeIfPresent(GPSMeasurement.self, forKey: .gps)
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Derived once from immutable source points; excluded from the archive format.
struct TripStatistics: Equatable {
    var distance: Double = 0
    var topSpeed: Double = 0
    var speedTotal: Double = 0
    init(distance: Double, topSpeed: Double, speedTotal: Double) {
        self.distance = distance; self.topSpeed = topSpeed; self.speedTotal = speedTotal
    }
    init(points: [TrackPoint]) {
        var previous: CLLocation?
        for point in points {
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            if let previous, !point.beginsNewSegment { distance += location.distance(from: previous) }
            previous = location
            topSpeed = max(topSpeed, point.metersPerSecond)
            speedTotal += point.metersPerSecond
        }
    }
}

struct TripRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let points: [TrackPoint]
    let activity: String
    let recordedDuration: TimeInterval?
    let statistics: TripStatistics
    // In-memory revision of immutable geometry; never persisted or compared as data.
    let previewIdentity = UUID()
    var videoMetadata: TripVideoMetadata?
    var videoRecordings: [TripVideoRecording] { videoMetadata?.version == 1 ? videoMetadata!.recordings.filter(\.isValid) : [] }

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        points: [TrackPoint],
        activity: String,
        recordedDuration: TimeInterval? = nil,
        videoRecordings: [TripVideoRecording] = [],
        statistics: TripStatistics? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.points = points
        self.activity = activity
        self.recordedDuration = recordedDuration
        self.statistics = statistics ?? TripStatistics(points: points)
        videoMetadata = videoRecordings.isEmpty ? nil : TripVideoMetadata(recordings: videoRecordings)
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, points, activity, recordedDuration, videoMetadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        points = try c.decode([TrackPoint].self, forKey: .points)
        activity = try c.decode(String.self, forKey: .activity)
        recordedDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .recordedDuration)
        statistics = TripStatistics(points: points)
        // Optional media metadata must never prevent reading the GPS route.
        videoMetadata = try? c.decodeIfPresent(TripVideoMetadata.self, forKey: .videoMetadata)
    }

    static func == (lhs: TripRecord, rhs: TripRecord) -> Bool {
        lhs.id == rhs.id && lhs.startedAt == rhs.startedAt && lhs.endedAt == rhs.endedAt
            && lhs.activity == rhs.activity && lhs.recordedDuration == rhs.recordedDuration
            && lhs.statistics == rhs.statistics && lhs.videoMetadata == rhs.videoMetadata
            && lhs.points == rhs.points
    }

    var duration: TimeInterval { max(0, recordedDuration ?? endedAt.timeIntervalSince(startedAt)) }
    var topSpeed: Double { statistics.topSpeed }
    var averageSpeed: Double { points.isEmpty ? 0 : statistics.speedTotal / Double(points.count) }
    var segments: [[TrackPoint]] {
        points.reduce(into: [[TrackPoint]]()) { segments, point in
            if segments.isEmpty || point.beginsNewSegment {
                segments.append([point])
            } else {
                segments[segments.count - 1].append(point)
            }
        }
    }
    var distance: Double { statistics.distance }
}

enum TripState: String, Codable, Equatable {
    case idle
    case recording
    case paused
}

enum RouteEventKind: String, Equatable {
    case start
    case pause
    case resume
    case finish
}

struct RouteEventMarker: Identifiable, Equatable {
    let id: String
    let kind: RouteEventKind
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: RouteEventMarker, rhs: RouteEventMarker) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

enum RouteEventMarkers {
    /// Route events are derived from segment boundaries so the visible markers,
    /// measured distance, and exported geometry always describe the same trip.
    static func make(points: [TrackPoint], isCurrentlyPaused: Bool = false, isFinished: Bool = false) -> [RouteEventMarker] {
        guard let first = points.first else { return [] }
        var markers = [RouteEventMarker(id: "start-\(first.id)", kind: .start, coordinate: first.coordinate)]

        for index in points.indices where index > points.startIndex && points[index].beginsNewSegment {
            let pausedPoint = points[points.index(before: index)]
            let resumedPoint = points[index]
            markers.append(RouteEventMarker(id: "pause-\(pausedPoint.id)-\(index)", kind: .pause, coordinate: pausedPoint.coordinate))
            markers.append(RouteEventMarker(id: "resume-\(resumedPoint.id)-\(index)", kind: .resume, coordinate: resumedPoint.coordinate))
        }

        if isCurrentlyPaused, let last = points.last {
            markers.append(RouteEventMarker(id: "active-pause-\(last.id)", kind: .pause, coordinate: last.coordinate))
        }
        if isFinished, let last = points.last {
            markers.append(RouteEventMarker(id: "finish-\(last.id)", kind: .finish, coordinate: last.coordinate))
        }
        return markers
    }

    /// Markers keep their real map coordinate. Only their badges are fanned out
    /// in screen space when events happen within a few GPS meters of each other.
    static func visualOffsets(for markers: [RouteEventMarker], overlapDistance: CLLocationDistance = 28) -> [String: CGSize] {
        guard markers.count > 1 else { return Dictionary(uniqueKeysWithValues: markers.map { ($0.id, .zero) }) }
        var visited = Set<Int>()
        var result = [String: CGSize]()

        for root in markers.indices where !visited.contains(root) {
            var cluster = [Int]()
            var queue = [root]
            visited.insert(root)
            while let current = queue.popLast() {
                cluster.append(current)
                let source = CLLocation(latitude: markers[current].coordinate.latitude, longitude: markers[current].coordinate.longitude)
                for candidate in markers.indices where !visited.contains(candidate) {
                    let target = CLLocation(latitude: markers[candidate].coordinate.latitude, longitude: markers[candidate].coordinate.longitude)
                    if source.distance(from: target) <= overlapDistance {
                        visited.insert(candidate)
                        queue.append(candidate)
                    }
                }
            }

            for (position, markerIndex) in cluster.sorted().enumerated() {
                result[markers[markerIndex].id] = offset(position: position, count: cluster.count)
            }
        }
        return result
    }

    private static func offset(position: Int, count: Int) -> CGSize {
        guard count > 1 else { return .zero }
        if count == 2 {
            return CGSize(width: position == 0 ? -14 : 14, height: -11)
        }
        let radius = min(26, 17 + CGFloat(count - 3) * 2)
        let angle = (-CGFloat.pi / 2) + (2 * CGFloat.pi * CGFloat(position) / CGFloat(count))
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}
