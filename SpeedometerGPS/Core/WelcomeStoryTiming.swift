import Foundation
import CoreGraphics

enum WelcomeStoryTiming {
    static let loaderDuration: TimeInterval = 1.5
    static let routeLoopDuration: TimeInterval = 6.0
    static let routeTravelDuration: TimeInterval = 5.0
    static let routeHoldDuration: TimeInterval = 0.6
    static let displayLoopDuration: TimeInterval = 6.6
    static let displayTransitionDuration: TimeInterval = 0.9

    static func loadingProgress(at elapsed: TimeInterval, reducedMotion: Bool = false) -> Double {
        reducedMotion ? 1 : smootherStep(elapsed / loaderDuration)
    }

    static func routeSnapshot(at elapsed: TimeInterval, reducedMotion: Bool = false) -> WelcomeRouteSnapshot {
        if reducedMotion {
            return WelcomeRouteSnapshot(progress: 1, opacity: 1, speed: 0)
        }

        let phase = positiveRemainder(elapsed, divisor: routeLoopDuration)
        let travel = min(max(phase / routeTravelDuration, 0), 1)
        let progress = smoothStep(travel)
        let fadeStart = routeTravelDuration + routeHoldDuration
        let opacity = phase < fadeStart ? 1 : max(0, 1 - (phase - fadeStart) / (routeLoopDuration - fadeStart))
        let speed = phase <= routeTravelDuration
            ? 18 + sin(.pi * travel) * 9
            : 0
        return WelcomeRouteSnapshot(progress: progress, opacity: opacity, speed: speed)
    }

    static func displaySnapshot(at elapsed: TimeInterval, reducedMotion: Bool = false) -> WelcomeDisplaySnapshot {
        guard !reducedMotion else { return WelcomeDisplaySnapshot(pageOffset: 0, speed: 24) }

        let phase = positiveRemainder(elapsed, divisor: displayLoopDuration)
        let firstHoldEnd = 1.2
        let firstTransitionEnd = firstHoldEnd + displayTransitionDuration
        let gaugeHoldEnd = firstTransitionEnd + 2.0
        let secondTransitionEnd = gaugeHoldEnd + displayTransitionDuration

        let pageOffset: Double
        switch phase {
        case ..<firstHoldEnd:
            pageOffset = 0
        case ..<firstTransitionEnd:
            pageOffset = smootherStep((phase - firstHoldEnd) / displayTransitionDuration)
        case ..<gaugeHoldEnd:
            pageOffset = 1
        case ..<secondTransitionEnd:
            pageOffset = 1 + smootherStep((phase - gaugeHoldEnd) / displayTransitionDuration)
        default:
            pageOffset = 2
        }

        let speedProgress = sin(.pi * phase / displayLoopDuration)
        return WelcomeDisplaySnapshot(pageOffset: pageOffset, speed: 18 + speedProgress * 9)
    }

    private static func positiveRemainder(_ value: Double, divisor: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder >= 0 ? remainder : remainder + divisor
    }

    private static func smootherStep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }

    private static func smoothStep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

struct WelcomeDisplaySnapshot: Equatable {
    let pageOffset: Double
    let speed: Double
}

struct WelcomeRouteSnapshot: Equatable {
    let progress: Double
    let opacity: Double
    let speed: Double
}

enum WelcomeRouteGeometry {
    // A simplified illustrative route from Pall Mall through Trafalgar Square and
    // east along the Strand. Geometry is derived from OpenStreetMap data.
    private static let londonRoute = [
        CGPoint(x: 0.1009, y: 0.5061),
        CGPoint(x: 0.1219, y: 0.5542),
        CGPoint(x: 0.1288, y: 0.5497),
        CGPoint(x: 0.1359, y: 0.5518),
        CGPoint(x: 0.1554, y: 0.5908),
        CGPoint(x: 0.1713, y: 0.5851),
        CGPoint(x: 0.2501, y: 0.5363),
        CGPoint(x: 0.3718, y: 0.5583),
        CGPoint(x: 0.3782, y: 0.5540),
        CGPoint(x: 0.4213, y: 0.5575),
        CGPoint(x: 0.4545, y: 0.5512),
        CGPoint(x: 0.4992, y: 0.5234),
        CGPoint(x: 0.6031, y: 0.4192),
        CGPoint(x: 0.6113, y: 0.4221),
        CGPoint(x: 0.7333, y: 0.3061),
        CGPoint(x: 0.8229, y: 0.2345),
        CGPoint(x: 0.9000, y: 0.1805)
    ]
    private static let smoothedLondonRoute = roundedRoute(londonRoute, iterations: 3)

    static func layout(in size: CGSize) -> WelcomeRouteLayout {
        WelcomeRouteLayout(points: smoothedLondonRoute.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
    }

    static func point(at progress: Double, in size: CGSize) -> CGPoint {
        layout(in: size).position(at: progress).point
    }

    static func heading(at progress: Double, in size: CGSize) -> Double {
        layout(in: size).position(at: progress).heading
    }

    private static func roundedRoute(_ route: [CGPoint], iterations: Int) -> [CGPoint] {
        guard route.count > 2, iterations > 0 else { return route }
        var result = route

        for _ in 0..<iterations {
            guard let first = result.first, let last = result.last else { return result }
            var rounded = [first]
            for (start, end) in zip(result, result.dropFirst()) {
                rounded.append(interpolate(start, end, fraction: 0.25))
                rounded.append(interpolate(start, end, fraction: 0.75))
            }
            rounded.append(last)
            result = rounded
        }

        return result
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, fraction: Double) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        )
    }
}

/// Prepared once per viewport, outside TimelineView. Frame sampling only performs
/// three binary searches; it never projects or allocates a route-sized array.
struct WelcomeRouteLayout {
    let points: [CGPoint]
    let distances: [CGFloat]
    var length: CGFloat { distances.last ?? 0 }

    init(points: [CGPoint]) {
        self.points = points
        var cumulative: [CGFloat] = points.isEmpty ? [] : [0]
        for (a, b) in zip(points, points.dropFirst()) {
            cumulative.append((cumulative.last ?? 0) + hypot(b.x - a.x, b.y - a.y))
        }
        distances = cumulative
    }

    func position(at progress: Double) -> (point: CGPoint, heading: Double) {
        let distance = min(max(progress, 0), 1) * length
        let window = max(length * 0.03, 5)
        let before = point(at: distance - window)
        let after = point(at: distance + window)
        return (point(at: distance), atan2(after.y - before.y, after.x - before.x))
    }

    private func point(at distance: CGFloat) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let target = min(max(distance, 0), length)
        var low = 1
        var high = distances.count - 1
        while low < high {
            let middle = (low + high) / 2
            if distances[middle] < target { low = middle + 1 } else { high = middle }
        }
        let span = distances[low] - distances[low - 1]
        let fraction = span > 0 ? (target - distances[low - 1]) / span : 0
        return CGPoint(x: points[low - 1].x + (points[low].x - points[low - 1].x) * fraction,
                       y: points[low - 1].y + (points[low].y - points[low - 1].y) * fraction)
    }
}
