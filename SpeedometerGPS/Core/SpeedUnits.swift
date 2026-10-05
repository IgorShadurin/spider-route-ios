import Foundation

enum SpeedUnit: String, CaseIterable, Identifiable, Codable {
    case kilometersPerHour = "km/h"
    case milesPerHour = "mph"
    case metersPerSecond = "m/s"
    case knots = "kn"

    var id: String { rawValue }

    func value(fromMetersPerSecond speed: Double) -> Double {
        switch self {
        case .kilometersPerHour: speed * 3.6
        case .milesPerHour: speed * 2.236_936
        case .metersPerSecond: speed
        case .knots: speed * 1.943_844
        }
    }

    func metersPerSecond(from value: Double) -> Double {
        switch self {
        case .kilometersPerHour: value / 3.6
        case .milesPerHour: value / 2.236_936
        case .metersPerSecond: value
        case .knots: value / 1.943_844
        }
    }

    var localizedName: String {
        switch self {
        case .kilometersPerHour: L10n.tr("unit_kmh")
        case .milesPerHour: L10n.tr("unit_mph")
        case .metersPerSecond: L10n.tr("unit_ms")
        case .knots: L10n.tr("unit_knots")
        }
    }
}

enum SpeedFormatter {
    static func number(_ metersPerSecond: Double, unit: SpeedUnit, decimals: Bool) -> String {
        let value = max(0, unit.value(fromMetersPerSecond: metersPerSecond))
        return value.formatted(.number.precision(.fractionLength(decimals ? 1 : 0)))
    }

    static func distance(_ meters: Double) -> String {
        if meters < 1_000 { return L10n.format("distance_meters_format", Int(meters)) }
        return L10n.format("distance_kilometers_format", meters / 1_000)
    }

    static func routeDistance(_ meters: Double, total: Double) -> String {
        L10n.format("distance_route_progress_format", max(0, meters) / 1_000, max(0, total) / 1_000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}
