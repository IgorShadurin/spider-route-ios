import Foundation
import UIKit

/// Small, disposable artwork derived only from saved GPS data. Never owns a map
/// view, tile connection, disk image, or a second full-resolution route.
enum TripPreviewGeometry {
    struct Vertex: Equatable {
        let point: CGPoint
        let beginsSegment: Bool
    }
    static let size = CGSize(width: 96, height: 72)
    static let sampleBudget = 768

    static func make(points: [TrackPoint], cancelled: () -> Bool = { false }) -> [Vertex]? {
        guard !points.isEmpty else { return [] }
        var minimum = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        var maximum = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        var extrema = Set<Int>()
        var minX = 0, maxX = 0, minY = 0, maxY = 0
        var first: Int?, last: Int?, previousX: Double?
        // Full bounds retain excursions that may fall between thumbnail samples.
        for (index, point) in points.enumerated() {
            if index % 1024 == 0 && cancelled() { return nil }
            guard valid(point) else { continue }
            let projected = CGPoint(x: unwrapX(point.longitude, previousX: &previousX),
                                    y: -min(85.05112878, max(-85.05112878, point.latitude)))
            if first == nil { first = index }; last = index
            if projected.x < minimum.x { minimum.x = projected.x; minX = index }
            if projected.y < minimum.y { minimum.y = projected.y; minY = index }
            if projected.x > maximum.x { maximum.x = projected.x; maxX = index }
            if projected.y > maximum.y { maximum.y = projected.y; maxY = index }
        }
        guard let first, let last else { return [] }
        extrema.formUnion([first, last, minX, maxX, minY, maxY])
        minimum.y = projectedY(-minimum.y)
        maximum.y = projectedY(-maximum.y)
        let width = maximum.x - minimum.x, height = maximum.y - minimum.y
        let scale = max(width / (size.width - 20), height / (size.height - 20))
        let stride = max(1, (points.count + sampleBudget - 1) / sampleBudget)
        var result: [Vertex] = []
        result.reserveCapacity(min(points.count, sampleBudget + 6))
        previousX = nil
        var needsMove = true
        for (index, point) in points.enumerated() {
            if index % 1024 == 0 && cancelled() { return nil }
            if point.beginsNewSegment { needsMove = true }
            guard valid(point) else { needsMove = true; continue }
            let x = unwrapX(point.longitude, previousX: &previousX)
            guard index % stride == 0 || extrema.contains(index) else { continue }
            let projected = CGPoint(x: x, y: projectedY(point.latitude))
            let pixel = scale > 0 ? CGPoint(
                x: (projected.x - (minimum.x + width / 2)) / scale + size.width / 2,
                y: (projected.y - (minimum.y + height / 2)) / scale + size.height / 2
            ) : CGPoint(x: size.width / 2, y: size.height / 2)
            result.append(Vertex(point: pixel, beginsSegment: needsMove))
            needsMove = false
        }
        return cancelled() ? nil : result
    }

    private static func valid(_ point: TrackPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite
            && abs(point.latitude) <= 90 && abs(point.longitude) <= 180
    }

    private static func unwrapX(_ longitude: Double, previousX: inout Double?) -> Double {
        var x = longitude / 360
        if let previousX { x += (previousX - x).rounded() }
        previousX = x
        return x
    }

    private static func projectedY(_ degrees: Double) -> Double {
        let latitude = min(85.05112878, max(-85.05112878, degrees)) * .pi / 180
        return -log(tan(.pi / 4 + latitude / 2)) / (2 * .pi)
    }
}

final class TripPreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class TripRoutePreviewCache: @unchecked Sendable {
    static let shared = TripRoutePreviewCache()
    static let byteLimit = 4 * 1024 * 1024
    private let images = NSCache<NSUUID, UIImage>()
    private let queue: OperationQueue
    private let admissionLock = NSLock()
    private var admitted = 0
    private var cacheGeneration: UInt64 = 0
    static let jobLimit = 8

    init() {
        images.totalCostLimit = Self.byteLimit
        images.countLimit = 24
        queue = OperationQueue()
        queue.name = "com.wowcoded.speedometergps.ride-previews"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    func cached(_ identity: UUID) -> UIImage? { images.object(forKey: identity as NSUUID) }
    func remove(_ identity: UUID) {
        admissionLock.lock(); defer { admissionLock.unlock() }
        cacheGeneration &+= 1
        images.removeObject(forKey: identity as NSUUID)
    }
    func removeAll() {
        admissionLock.lock(); defer { admissionLock.unlock() }
        cacheGeneration &+= 1
        images.removeAllObjects()
    }

    private func admit() -> UInt64? {
        admissionLock.lock(); defer { admissionLock.unlock() }
        guard admitted < Self.jobLimit else { return nil }
        admitted += 1; return cacheGeneration
    }
    private func store(_ image: UIImage, identity: UUID, generation: UInt64) {
        admissionLock.lock(); defer { admissionLock.unlock() }
        guard generation == cacheGeneration else { return }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: identity as NSUUID, cost: cost)
    }
    private func release() {
        admissionLock.lock(); admitted -= 1; admissionLock.unlock()
    }

    func image(identity: UUID, points: [TrackPoint]) async -> UIImage? {
        if Task.isCancelled { return nil }
        if let image = cached(identity) { return image }
        // Back-pressure belongs to the visible row's cancellable task; never
        // enqueue the entire archive or grow an unbounded renderer backlog.
        var generation = admit()
        while generation == nil {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return nil }
            if Task.isCancelled { return nil }
            if let image = cached(identity) { return image }
            generation = admit()
        }
        let admittedGeneration = generation!
        let cancellation = TripPreviewCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.addOperation { [self] in
                    defer { release() }
                    // Cancelled queued work still executes this tiny block so its
                    // continuation resumes exactly once and releases source points.
                    let image: UIImage? = autoreleasepool {
                        guard !cancellation.isCancelled else { return nil }
                        if let image = cached(identity) { return image }
                        guard let vertices = TripPreviewGeometry.make(points: points, cancelled: { cancellation.isCancelled }),
                              !cancellation.isCancelled else { return nil }
                        let image = Self.draw(vertices)
                        guard !cancellation.isCancelled else { return nil }
                        store(image, identity: identity, generation: admittedGeneration)
                        return image
                    }
                    continuation.resume(returning: image)
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private static func draw(_ vertices: [TripPreviewGeometry.Vertex]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: TripPreviewGeometry.size, format: format).image { context in
            let cg = context.cgContext
            guard let first = vertices.first, let last = vertices.last else {
                // A stationary/empty legacy ride still has a finished placeholder,
                // never an endlessly loading image or an invented route.
                cg.setStrokeColor(UIColor(white: 0.55, alpha: 1).cgColor)
                cg.setLineWidth(2)
                cg.strokeEllipse(in: CGRect(x: 43, y: 31, width: 10, height: 10))
                return
            }
            let path = CGMutablePath()
            for vertex in vertices {
                if vertex.beginsSegment { path.move(to: vertex.point) }
                else { path.addLine(to: vertex.point) }
            }
            cg.setLineCap(.round); cg.setLineJoin(.round)
            cg.addPath(path); cg.setStrokeColor(UIColor.white.cgColor); cg.setLineWidth(5); cg.strokePath()
            cg.addPath(path); cg.setStrokeColor(UIColor(red: 0.05, green: 0.38, blue: 0.90, alpha: 1).cgColor)
            cg.setLineWidth(2.5); cg.strokePath()
            // Outer start ring stays visible when a loop finishes at its start.
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(x: first.point.x - 5, y: first.point.y - 5, width: 10, height: 10))
            cg.setFillColor(UIColor(red: 0.1, green: 0.65, blue: 0.3, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: first.point.x - 4, y: first.point.y - 4, width: 8, height: 8))
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(x: last.point.x - 3.3, y: last.point.y - 3.3, width: 6.6, height: 6.6))
            cg.setFillColor(UIColor(red: 0.06, green: 0.18, blue: 0.14, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: last.point.x - 2.4, y: last.point.y - 2.4, width: 4.8, height: 4.8))
        }
    }
}
