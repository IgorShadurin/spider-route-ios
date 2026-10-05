import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum RouteExportFormat: String, CaseIterable, Identifiable {
    case gpx
    case kml
    case geoJSON = "geojson"
    case csv

    var id: String { rawValue }
    var filenameExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .gpx: .speedometerGPX
        case .kml: .speedometerKML
        case .geoJSON: .speedometerGeoJSON
        case .csv: .commaSeparatedText
        }
    }

    var titleKey: String { "route_export_format_\(rawValue)" }
    var detailKey: String { "route_export_format_\(rawValue)_detail" }
}

extension UTType {
    static let speedometerGPX = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static let speedometerKML = UTType(importedAs: "com.google.earth.kml", conformingTo: .xml)
    static let speedometerGeoJSON = UTType(importedAs: "public.geojson", conformingTo: .json)
}

struct RouteExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { RouteExportFormat.allCases.map(\.contentType) }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum RouteExporter {
    private static let applicationURL = "https://apps.apple.com/app/id6801154513"
    private static let preparationQueue = DispatchQueue(label: "com.wowcoded.speedometergps.export", qos: .userInitiated)

    static func prepare(trip: TripRecord, format: RouteExportFormat) async throws -> RouteExportDocument {
        try Task.checkCancellation()
        let document: RouteExportDocument = try await withCheckedThrowingContinuation { continuation in
            preparationQueue.async {
                continuation.resume(with: Result { try Self.document(for: trip, format: format) })
            }
        }
        try Task.checkCancellation()
        return document
    }

    static func document(for trip: TripRecord, format: RouteExportFormat) throws -> RouteExportDocument {
        RouteExportDocument(data: try data(for: trip, format: format))
    }

    static func data(for trip: TripRecord, format: RouteExportFormat) throws -> Data {
        switch format {
        case .gpx: gpx(for: trip)
        case .kml: Data(kml(for: trip).utf8)
        case .geoJSON: try geoJSON(for: trip)
        case .csv: csv(for: trip)
        }
    }

    static func filename(for trip: TripRecord, format: RouteExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "SpiderRoute-Ride-\(formatter.string(from: trip.startedAt)).\(format.filenameExtension)"
    }

    private static func gpx(for trip: TripRecord) -> Data {
        let clock = exportClock()
        var output = Data()
        func append(_ text: String) { output.append(contentsOf: text.utf8) }
        append("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SpiderRoute" xmlns="http://www.topografix.com/GPX/1/1" xmlns:speedometer="https://yumcut.com/mobile/speedometer-gps">
          <metadata>
            <link href="\(applicationURL)"><text>SpiderRoute</text><type>text/html</type></link>
            <time>\(clock.string(from: trip.startedAt))</time>
          </metadata>
          <trk>
            <name>\(xmlEscaped(routeName(for: trip)))</name>
            <type>\(xmlEscaped(trip.activity))</type>
        """)
        // Append directly to one output buffer. Do not build copied segments and
        // one retained String per historical point during large exports.
        for (index, point) in trip.points.enumerated() {
            autoreleasepool {
                if index == 0 || point.beginsNewSegment {
                    if index > 0 { append("\n    </trkseg>") }
                    append("\n    <trkseg>")
                }
                append("\n      <trkpt lat=\"\(decimal(point.latitude, digits: 7))\" lon=\"\(decimal(point.longitude, digits: 7))\">")
                if point.gps == nil || point.gps!.verticalAccuracy >= 0 { append("<ele>\(decimal(point.altitude, digits: 2))</ele>") }
                append("<time>\(clock.string(from: point.timestamp))</time><extensions>")
                if point.gps == nil || point.gps!.rawSpeed >= 0 {
                    append("<speedometer:speed unit=\"m/s\">\(decimal(point.metersPerSecond, digits: 3))</speedometer:speed>")
                }
                if let gps = point.gps {
                    append("<speedometer:speedValid>\(gps.rawSpeed >= 0 ? "true" : "false")</speedometer:speedValid>")
                    let fields: [(String, String, Float)] = [
                        ("horizontalAccuracy", "m", gps.horizontalAccuracy), ("verticalAccuracy", "m", gps.verticalAccuracy),
                        ("course", "deg", gps.course), ("courseAccuracy", "deg", gps.courseAccuracy),
                        ("speedAccuracy", "m/s", gps.speedAccuracy)]
                    for (name, unit, value) in fields where value >= 0 {
                        append("<speedometer:\(name) unit=\"\(unit)\">\(decimal(Double(value), digits: 3))</speedometer:\(name)>")
                    }
                }
                append("</extensions></trkpt>")
            }
        }
        if !trip.points.isEmpty { append("\n    </trkseg>") }
        append("\n  </trk>\n</gpx>")
        return output
    }

    private static func kml(for trip: TripRecord) -> String {
        let geometry = trip.segments.map { segment in
            let coordinates = segment.map { point in
                "\(decimal(point.longitude, digits: 7)),\(decimal(point.latitude, digits: 7)),\(decimal(point.altitude, digits: 2))"
            }.joined(separator: "\n              ")
            return """
              <LineString>
                <tessellate>1</tessellate>
                <altitudeMode>absolute</altitudeMode>
                <coordinates>
                  \(coordinates)
                </coordinates>
              </LineString>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>\(xmlEscaped(routeName(for: trip)))</name>
            <Placemark>
              <name>\(xmlEscaped(routeName(for: trip)))</name>
              <ExtendedData>
                <Data name="applicationURL"><value>\(applicationURL)</value></Data>
                <Data name="startedAt"><value>\(timestamp(trip.startedAt))</value></Data>
                <Data name="endedAt"><value>\(timestamp(trip.endedAt))</value></Data>
                <Data name="activity"><value>\(xmlEscaped(trip.activity))</value></Data>
              </ExtendedData>
              <MultiGeometry>
        \(geometry)
              </MultiGeometry>
            </Placemark>
          </Document>
        </kml>
        """
    }

    private static func geoJSON(for trip: TripRecord) throws -> Data {
        let routeSegments = trip.segments.filter { $0.count >= 2 }
        let payload = GeoJSONFeatureCollection(
            type: "FeatureCollection",
            features: [
                GeoJSONFeature(
                    type: "Feature",
                    properties: .init(
                        name: routeName(for: trip),
                        applicationURL: applicationURL,
                        startedAt: timestamp(trip.startedAt),
                        endedAt: timestamp(trip.endedAt),
                        activity: trip.activity,
                        distanceMeters: trip.distance,
                        topSpeedMetersPerSecond: trip.topSpeed,
                        averageSpeedMetersPerSecond: trip.averageSpeed
                    ),
                    geometry: routeSegments.isEmpty ? nil : .init(
                        type: "MultiLineString",
                        coordinates: routeSegments.map { segment in
                            segment.map { [$0.longitude, $0.latitude, $0.altitude] }
                        }
                    )
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    private static func csv(for trip: TripRecord) -> Data {
        var output = Data("segment,timestamp,latitude,longitude,altitude_m,speed_m_s,activity,elapsed_s,speed_valid,horizontal_accuracy_m,vertical_accuracy_m,course_deg,course_accuracy_deg,speed_accuracy_m_s,schema_version\n".utf8)
        let clock = exportClock()
        let activity = csvEscaped(trip.activity)
        var segment = 0
        for (index, point) in trip.points.enumerated() {
            autoreleasepool {
                if index == 0 || point.beginsNewSegment { segment += 1 }
                func quality(_ value: Float?) -> String {
                    guard let value, value >= 0 else { return "" }
                    return decimal(Double(value), digits: 3)
                }
                let speedValid = point.gps.map { $0.rawSpeed >= 0 }
                let columns = [String(segment), csvEscaped(clock.string(from: point.timestamp)),
                    decimal(point.latitude, digits: 7), decimal(point.longitude, digits: 7),
                    point.gps.map { $0.verticalAccuracy < 0 } == true ? "" : decimal(point.altitude, digits: 2), speedValid == false ? "" : decimal(point.metersPerSecond, digits: 3),
                    activity, decimal(point.timestamp.timeIntervalSince(trip.startedAt), digits: 3),
                    speedValid.map { $0 ? "true" : "false" } ?? "",
                    quality(point.gps?.horizontalAccuracy), quality(point.gps?.verticalAccuracy),
                    quality(point.gps?.course), quality(point.gps?.courseAccuracy), quality(point.gps?.speedAccuracy), "2"]
                output.append(contentsOf: (columns.joined(separator: ",") + "\n").utf8)
            }
        }
        return output
    }

    private static func exportClock() -> ISO8601DateFormatter {
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return clock
    }

    private static func routeName(for trip: TripRecord) -> String {
        "SpiderRoute Ride \(timestamp(trip.startedAt))"
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.speedometer.string(from: date)
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        // Locale-aware Foundation formatting for every column dominated long
        // exports. Fixed SI decimals need no locale object or formatter state.
        let scales: [Int64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000]
        guard scales.indices.contains(digits) else { return String(value) }
        let scale = scales[digits]
        let rounded = (abs(value) * Double(scale)).rounded(.toNearestOrEven)
        guard rounded.isFinite, rounded < Double(Int64.max) else {
            return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
        }
        let integer = Int64(rounded)
        let sign = value.sign == .minus ? "-" : ""
        guard digits > 0 else { return sign + String(integer) }
        let fraction = String(integer % scale)
        return sign + String(integer / scale) + "." + String(repeating: "0", count: digits - fraction.count) + fraction
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func csvEscaped(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private extension ISO8601DateFormatter {
    static let speedometer: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct GeoJSONFeatureCollection: Encodable {
    let type: String
    let features: [GeoJSONFeature]
}

private struct GeoJSONFeature: Encodable {
    struct Properties: Encodable {
        let name: String
        let applicationURL: String
        let startedAt: String
        let endedAt: String
        let activity: String
        let distanceMeters: Double
        let topSpeedMetersPerSecond: Double
        let averageSpeedMetersPerSecond: Double
    }

    struct Geometry: Encodable {
        let type: String
        let coordinates: [[[Double]]]
    }

    let type: String
    let properties: Properties
    let geometry: Geometry?
}
