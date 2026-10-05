#if DEBUG
import CoreLocation
import UIKit
import Combine

/// Explicit physical-device replay. All persistence is under tmp; no screenshot
/// state, entitlement override, route-library mutation or production recorder use.
@MainActor
enum LongRecordingProbe {
    static var mapProvider: MapProvider {
        let prefix = "--debug-map-provider="
        let value = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        return value.flatMap(MapProvider.init(rawValue:)) ?? MapProvider(rawValue: UserDefaults.standard.string(forKey: "map_provider") ?? "") ?? .openStreetMap
    }
    private static var running = false
    private static var probeTask: Task<Void, Never>?
    static func startIfRequested() {
        guard probeTask == nil else { return }
        probeTask = Task { await runIfRequested(); probeTask = nil }
    }
    private static var activeRecorder: TripRecorder?
    private static var backgroundTransitions = 0

    static func checkpointForLifecycle() {
        guard let activeRecorder else { return }
        backgroundTransitions += 1
        activeRecorder.checkpointForLifecycle()
    }

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--debug-route-persistence-probe"), !running else { return }
        running = true
        backgroundTransitions = 0
        if ProcessInfo.processInfo.arguments.contains("--debug-route-20h") {
            await runAcceleratedTwentyHours()
            running = false
            activeRecorder = nil
            return
        }
        let resumePrefix = "--debug-route-probe-resume="
        let resume = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(resumePrefix) }.map { String($0.dropFirst(resumePrefix.count)) }
        if let resume, !resume.hasPrefix("recording-probe-") || UUID(uuidString: String(resume.dropFirst("recording-probe-".count))) == nil {
            write(["phase": "failed", "error": "Invalid isolated checkpoint directory"])
            running = false
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(resume ?? "recording-probe-\(UUID().uuidString)")
        let store = ActiveTripCheckpointStore(applicationSupportURL: directory)
        let now = Date()
        let thousand = ProcessInfo.processInfo.arguments.contains("--debug-route-1000km")
        let count = thousand ? 180_000 : 25_200
        let durationArgument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--debug-route-probe-seconds=") }
        let samples = min(3600, max(1, durationArgument.flatMap { Int($0.split(separator: "=").last ?? "") } ?? 120))
        let start = now.addingTimeInterval(-Double(count))
        var report: [String: Any] = ["os": UIDevice.current.systemVersion, "started_at": ISO8601DateFormatter().string(from: now), "synthetic_replay": true,
            "checkpoint_directory": directory.lastPathComponent, "resumed_process_checkpoint": resume != nil,
            "map_provider": mapProvider.rawValue, "network_style": OSMMapStyle.permitsNetwork]
        write(report.merging(["phase": "preparing"]) { _, new in new })
        do {
            let seedStart = CACurrentMediaTime()
            if resume == nil {
            let points = (0..<count).map { index -> TrackPoint in
                let c = thousand ? ThousandKilometerFixture.coordinate(index) : LongRouteFixture.coordinate(index * 2)
                return TrackPoint(latitude: c.latitude, longitude: c.longitude, altitude: 210,
                    metersPerSecond: 6, timestamp: start.addingTimeInterval(Double(index)),
                    beginsNewSegment: index == 3600 || index == 14_400)
            }
            let seed = ActiveTripCheckpoint(state: .recording, startedAt: start, points: points,
                elapsed: Double(count), savedAt: now, videoMetadata: TripVideoMetadata(recordings: TripVideoFixture.recordings(start: start, duration: Double(count))))
            try await Task.detached(priority: .utility) { try store.save(seed) }.value
            }
            report["seed_seconds"] = CACurrentMediaTime() - seedStart
            let loadStart = CACurrentMediaTime()
            let recorder = TripRecorder(checkpointStore: store)
            activeRecorder = recorder
            LongRecordingProbeState.shared.recorder = recorder
            await recorder.waitForRecoveryLoad()
            report["load_seconds"] = CACurrentMediaTime() - loadStart
            guard recorder.pendingRecovery != nil else { throw CocoaError(.fileReadCorruptFile) }
            report["recovered_elapsed"] = recorder.pendingRecovery?.elapsed
            let recoverStart = CACurrentMediaTime()
            recorder.continueRecoveredTrip(now: Date())
            report["recovery_seconds"] = CACurrentMediaTime() - recoverStart
            report["seed_distance_km"] = recorder.distance / 1_000
            report["seed_points"] = recorder.points.count
            let baseCount = recorder.points.count
            if recorder.state == .paused { recorder.togglePause() }
            if thousand {
                let guide = await Task.detached(priority: .utility) { ThousandKilometerFixture.guidePoints(includePhotos: true) }.value
                LongRecordingProbeState.shared.guidePoints = guide
                report["guide_places"] = guide.count
                report["guide_photos"] = guide.flatMap { $0.photos ?? [] }.count
                report["guide_photo_bytes"] = guide.flatMap { $0.photos ?? [] }.reduce(0) { $0 + $1.data.count }
            }
            write(report.merging(["phase": "appending"]) { _, new in new })
            var appends: [Double] = [], commits: [Double] = [], lifecycle: [Double] = [], memory: [UInt64] = []
            var mapLifetimes: [[String: Int]] = []
            var cpuSamples: [[String: Double]] = []
            let cpuStart = OSMDeviceMemory.cpuSeconds(), wallStart = CACurrentMediaTime()
            for index in 0..<samples {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let c = thousand ? ThousandKilometerFixture.coordinate(baseCount + index) : LongRouteFixture.coordinate((baseCount + index) * 2)
                let began = CACurrentMediaTime()
                recorder.add(CLLocation(coordinate: c, altitude: 210, horizontalAccuracy: 5,
                    verticalAccuracy: 5, course: 0, speed: 6, timestamp: Date()))
                appends.append((CACurrentMediaTime() - began) * 1_000)
                await recorder.awaitCheckpointWrites()
                commits.append((CACurrentMediaTime() - began) * 1_000)
                if index % 10 == 0 {
                    let began = CACurrentMediaTime()
                    recorder.checkpointForLifecycle()
                    lifecycle.append((CACurrentMediaTime() - began) * 1_000)
                    memory.append(footprint())
                    mapLifetimes.append(OSMMapLifetimeProbe.counts)
                    cpuSamples.append(["wall_seconds": CACurrentMediaTime() - wallStart,
                                       "cpu_seconds": OSMDeviceMemory.cpuSeconds() - cpuStart])
                    write(report.merging(["phase": "appending", "samples": index + 1,
                        "append_ms": stats(appends), "commit_ms": stats(commits), "lifecycle_ms": stats(lifecycle), "footprint_bytes": memory, "osm_lifetimes": mapLifetimes, "cpu_samples": cpuSamples]) { _, new in new })
                }
            }
            recorder.checkpointForLifecycle()
            // Wait asynchronously; never add a sync barrier to the probe's UI.
            await recorder.awaitCheckpointWrites()
            let saved = await Task.detached(priority: .utility) { store.load() }.value
            report["sampled_recovered_points"] = saved?.points.count ?? 0
            report["live_points"] = recorder.points.count
            report["resume_starts_new_segment"] = recorder.points.count > baseCount && recorder.points[baseCount].beginsNewSegment
            report["finished_at"] = ISO8601DateFormatter().string(from: Date())
            report["all_points_recovered"] = saved?.points == recorder.points
            report["background_transitions"] = backgroundTransitions
            report["append_ms"] = stats(appends)
            report["commit_ms"] = stats(commits)
            report["lifecycle_ms"] = stats(lifecycle)
            report["footprint_bytes"] = memory
            report["osm_lifetimes"] = mapLifetimes
            report["cpu_samples"] = cpuSamples
            report["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
            // Exercise the saved-trip JSON path too, in isolated storage.
            recorder.togglePause()
            await recorder.awaitCheckpointWrites()
            if let trip = recorder.finishedRecord(activity: "activity_cycling") {
                let archive = RouteArchiveStore(localDocumentsURL: directory.appendingPathComponent("archive"), cloudContainerIdentifier: nil)
                let began = CACurrentMediaTime()
                report["archive_saved"] = await archive.saveFinishedTrip(trip, syncWithICloud: false)
                let reloaded = RouteArchiveStore(localDocumentsURL: directory.appendingPathComponent("archive"), cloudContainerIdentifier: nil)
                await reloaded.waitForLoad()
                report["archive_exact"] = reloaded.trips.first?.points == trip.points
                report["archive_save_reload_seconds"] = CACurrentMediaTime() - began
                report["archive_footprint_bytes"] = footprint()
            }
            report["phase"] = "complete"
            write(report)
        } catch {
            report["phase"] = "failed"; report["error"] = String(describing: error); write(report)
        }
        running = false
        activeRecorder = nil
    }

    /// 72,000 real recorder calls at accelerated wall-clock speed, not a seeded
    /// array pretending to exercise ingestion. Pauses and missing speed are real
    /// input states. Uses only isolated tmp storage and shipping serialization.
    private static func runAcceleratedTwentyHours() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-probe-\(UUID().uuidString)")
        let store = ActiveTripCheckpointStore(applicationSupportURL: directory)
        let began = CACurrentMediaTime()
        let start = Date().addingTimeInterval(-72_900)
        var report: [String: Any] = ["phase": "preparing", "synthetic_replay": true,
            "accelerated": true, "simulated_active_hours": 20, "sample_rate_hz": 1,
            "os": UIDevice.current.systemVersion, "started_at": ISO8601DateFormatter().string(from: Date()),
            "checkpoint_directory": directory.lastPathComponent]
        write(report)
        do {
            let recorder = TripRecorder(checkpointStore: store)
            activeRecorder = recorder
            LongRecordingProbeState.shared.recorder = recorder
            await recorder.waitForRecoveryLoad()
            if !ProcessInfo.processInfo.arguments.contains("--debug-map-guides-off") {
                let places = await Task.detached(priority: .utility) { ThousandKilometerFixture.guidePoints(includePhotos: true) }.value
                LongRecordingProbeState.shared.guidePoints = places
                report["guide_places"] = places.count
                report["guide_photo_bytes"] = places.flatMap { $0.photos ?? [] }.reduce(0) { $0 + $1.data.count }
            } else { report["guide_places"] = 0 }
            recorder.start(now: start)
            var appends: [Double] = [], commits: [Double] = [], memory: [UInt64] = []
            var lastTime = start
            for index in 0..<72_000 {
                let time = start.addingTimeInterval(Double(index + (index / 18_000) * 300))
                if index > 0 && index % 18_000 == 0 {
                    recorder.togglePause(now: time.addingTimeInterval(-300))
                    recorder.togglePause(now: time)
                }
                let location = telemetryLocation(index: index, timestamp: time)
                let tick = CACurrentMediaTime()
                recorder.add(location)
                appends.append((CACurrentMediaTime() - tick) * 1000)
                if index % 4096 == 0 { recorder.add(location) } // Duplicate timestamp must be ignored.
                lastTime = time
                if (index + 1) % 32 == 0 {
                    let commitStart = CACurrentMediaTime()
                    await recorder.awaitCheckpointWrites()
                    commits.append((CACurrentMediaTime() - commitStart) * 1000)
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                if (index + 1) % 6000 == 0 {
                    memory.append(footprint())
                    write(report.merging(["phase": "appending", "samples": index + 1, "footprint_bytes": memory]) { _, new in new })
                }
            }
            recorder.togglePause(now: lastTime.addingTimeInterval(1))
            await recorder.awaitCheckpointWrites()
            report["ingest_seconds"] = CACurrentMediaTime() - began
            report["append_ms"] = stats(appends)
            report["batch_commit_wait_ms"] = stats(commits)
            report["footprint_bytes"] = memory
            let loadStart = CACurrentMediaTime()
            let saved = await Task.detached(priority: .utility) { store.load() }.value
            report["load_seconds"] = CACurrentMediaTime() - loadStart
            report["all_points_recovered"] = saved?.points == recorder.points
            report["sampled_recovered_points"] = saved?.points.count ?? 0
            report["live_points"] = recorder.points.count
            report["active_duration_seconds"] = saved?.elapsed
            report["segment_count"] = recorder.points.reduce(1) { $0 + ($1.beginsNewSegment ? 1 : 0) }
            report["gps_measurements"] = recorder.points.filter { $0.gps != nil }.count
            report["invalid_speed_samples"] = recorder.points.filter { $0.gps?.rawSpeed == -1 }.count
            guard recorder.points.count == 72_000, saved?.points == recorder.points,
                  saved?.elapsed == 72_000 else { throw CocoaError(.fileReadCorruptFile) }
            guard let trip = recorder.finishedRecord(activity: "activity_cycling", now: lastTime.addingTimeInterval(1)) else { throw CocoaError(.fileReadCorruptFile) }
            let archive = RouteArchiveStore(localDocumentsURL: directory.appendingPathComponent("archive"), cloudContainerIdentifier: nil)
            report["archive_saved"] = await archive.saveFinishedTrip(trip, syncWithICloud: false)
            let reloaded = RouteArchiveStore(localDocumentsURL: directory.appendingPathComponent("archive"), cloudContainerIdentifier: nil)
            await reloaded.waitForLoad()
            report["archive_exact"] = reloaded.trips.first?.points == trip.points
            let exportStart = CACurrentMediaTime()
            let exports = try await Task.detached(priority: .utility) { () -> [String: Int] in
                var sizes: [String: Int] = [:]
                for format in [RouteExportFormat.gpx, .csv] {
                    let data = try RouteExporter.data(for: trip, format: format)
                    try data.write(to: directory.appendingPathComponent("telemetry.\(format.rawValue)"), options: .atomic)
                    sizes[format.rawValue] = data.count
                }
                return sizes
            }.value
            report["export_bytes"] = exports
            report["export_seconds"] = CACurrentMediaTime() - exportStart
            report["final_footprint_bytes"] = footprint()
            report["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
            report["background_transitions"] = backgroundTransitions
            report["finished_at"] = ISO8601DateFormatter().string(from: Date())
            report["phase"] = "complete"
            write(report)
        } catch {
            report["phase"] = "failed"; report["error"] = String(describing: error); write(report)
        }
    }

    nonisolated static func telemetryLocation(index: Int, timestamp: Date) -> CLLocation {
        let coordinate = ThousandKilometerFixture.coordinate(Int(Double(index) * 2.5))
        let speed = index % 600 == 0 ? -1 : (index % 3600 < 60 ? 0 : 12 + sin(Double(index) / 50) * 3)
        return CLLocation(coordinate: coordinate, altitude: 210 + sin(Double(index) / 100) * 20,
            horizontalAccuracy: 3 + Double(index % 11), verticalAccuracy: index % 100 == 0 ? -1 : 5,
            course: Double(index % 360), courseAccuracy: 2, speed: speed, speedAccuracy: speed < 0 ? -1 : 0.25, timestamp: timestamp)
    }

    private static func write(_ report: [String: Any]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-probe.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func stats(_ samples: [Double]) -> [String: Double] {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return [:] }
        return ["mean": sorted.reduce(0,+) / Double(sorted.count), "p95": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], "max": sorted.last!]
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
/// Over 1,000 km at one fix/second for 50 hours, with hourly recording gaps.
/// Synthetic geometry, never a navigable route or a user's location history.
enum ThousandKilometerFixture {
    static let pointCount = 180_000
    static func coordinate(_ index: Int) -> CLLocationCoordinate2D {
        .init(latitude: 45 + Double(index) * 0.0000501,
              longitude: 8 + sin(Double(index) / 2000) * 0.0005)
    }
    static func guidePoints(includePhotos: Bool = false) -> [RouteGuidePoint] {
        let photo = includePhotos ? photoData() : nil
        let values = (0..<1000).map { index in
            let c = coordinate(index * 180)
            return RouteGuidePoint(id: "long-place-\(index)", title: "Place \(index + 1)", latitude: c.latitude,
                longitude: c.longitude, category: .heritage, summary: "Synthetic place for long-route performance testing.",
                details: nil, sources: [RouteGuideSource(title: "Fixture", url: "https://example.org/fixture")],
                distanceFromRouteMeters: 0, distanceAlongRouteMeters: Double(index) * 1000, icon: .building,
                photos: index % 8 == 0 && index / 8 < 120 ? photo.map { [RouteGuidePhoto(id: "photo-\(index)", title: "Synthetic photo",
                    sourceURL: "https://example.org/fixture", author: "SpiderRoute test fixture", license: "CC0",
                    licenseURL: nil, imageURL: nil, data: $0)] } : nil)
        }
        // Match imported JSON ownership: distinct decoded Data for each photo.
        guard includePhotos, let data = try? JSONEncoder().encode(values),
              let decoded = try? JSONDecoder().decode([RouteGuidePoint].self, from: data) else { return values }
        return decoded
    }
    private static func photoData() -> Data? {
        let side = 768
        var state: UInt32 = 17
        let bytes: [UInt8] = (0..<(side * side * 4)).map { index in
            if index % 4 == 3 { return 255 }
            state = state &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let source = UIImage(cgImage: image)
        var low: CGFloat = 0, high: CGFloat = 1, best = source.jpegData(compressionQuality: 0)
        for _ in 0..<10 {
            let middle = (low + high) / 2
            if let data = source.jpegData(compressionQuality: middle), data.count <= RouteGuideImporter.maximumTotalPhotoBytes / 120 {
                best = data; low = middle
            } else { high = middle }
        }
        return best
    }
    static func points(count: Int = pointCount, start: Date = Date(timeIntervalSince1970: 1_000_000)) -> [TrackPoint] {
        (0..<count).map { index in
            let c = coordinate(index)
            return TrackPoint(latitude: c.latitude, longitude: c.longitude, altitude: 210,
                metersPerSecond: 5.56, timestamp: start.addingTimeInterval(Double(index)),
                beginsNewSegment: index > 0 && index % 3600 == 0)
        }
    }
}
@MainActor
final class LongRecordingProbeState: ObservableObject {
    static let shared = LongRecordingProbeState()
    @Published var recorder: TripRecorder?
    @Published var guidePoints: [RouteGuidePoint] = []
}
#endif
