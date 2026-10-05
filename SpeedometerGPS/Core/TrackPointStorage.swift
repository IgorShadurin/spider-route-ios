import CoreLocation
import Foundation

/// Compact optional sensor quality, shared by route storage and video exports.
/// Negative values mean unavailable; a missing object means a historical sample.
/// Coordinates, sample time and the original valid speed remain Double in TrackPoint.
struct GPSMeasurement: Codable, Equatable {
    let horizontalAccuracy: Float
    let verticalAccuracy: Float
    let course: Float
    let courseAccuracy: Float
    let speedAccuracy: Float
    let rawSpeed: Float

    init(location: CLLocation) {
        func value(_ source: Double) -> Float {
            let result = Float(source)
            return result.isFinite && result >= 0 ? result : -1
        }
        horizontalAccuracy = value(location.horizontalAccuracy)
        verticalAccuracy = value(location.verticalAccuracy)
        course = value(location.course)
        courseAccuracy = value(location.courseAccuracy)
        speedAccuracy = value(location.speedAccuracy)
        rawSpeed = value(location.speed)
    }

    init(values: [Float]) {
        horizontalAccuracy = values[0]; verticalAccuracy = values[1]
        course = values[2]; courseAccuracy = values[3]
        speedAccuracy = values[4]; rawSpeed = values[5]
    }

    var values: [Float] { [horizontalAccuracy, verticalAccuracy, course, courseAccuracy, speedAccuracy, rawSpeed] }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(1) // Explicit version; old route JSON has no gps member.
        for value in values { try c.encode(value) }
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        guard try c.decode(Int.self) == 1 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported GPS measurement version")
        }
        var values: [Float] = []
        for _ in 0..<6 { values.append(try c.decode(Float.self)) }
        guard c.isAtEnd, values.allSatisfy({ $0.isFinite }) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid GPS measurement")
        }
        self.init(values: values)
    }
}

/// Versioned, little-endian SQLite BLOB: 61 bytes without GPS quality, 85 with it.
/// No platform struct layout, quantization, whole-track encoding or parallel log.
/// Existing JSON rows are decoded in place; only new rows use this encoding.
enum TrackPointStorage {
    private static let magic = Data([0x53, 0x52, 0x50, 0x31]) // SRP1

    static func encode(_ point: TrackPoint) throws -> Data {
        let numbers = [point.latitude, point.longitude, point.altitude, point.metersPerSecond,
                       point.timestamp.timeIntervalSinceReferenceDate]
        guard numbers.allSatisfy({ $0.isFinite }), point.gps?.values.allSatisfy({ $0.isFinite }) != false else {
            throw EncodingError.invalidValue(point, .init(codingPath: [], debugDescription: "Track point contains nonfinite sensor values"))
        }
        var data = magic
        data.reserveCapacity(point.gps == nil ? 61 : 85)
        data.append((point.beginsNewSegment ? 1 : 0) | (point.gps == nil ? 0 : 2))
        var uuid = point.id.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        for value in numbers { append(value.bitPattern, to: &data) }
        if let gps = point.gps { for value in gps.values { append(value.bitPattern, to: &data) } }
        return data
    }

    static func decode(_ data: Data) throws -> TrackPoint {
        guard data.starts(with: magic) else { return try JSONDecoder().decode(TrackPoint.self, from: data) }
        guard data.count >= 5 else { throw CocoaError(.fileReadCorruptFile) }
        let flags = data[data.startIndex + 4]
        guard flags & ~3 == 0, data.count == (flags & 2 == 0 ? 61 : 85) else { throw CocoaError(.fileReadCorruptFile) }
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = withUnsafeMutableBytes(of: &uuid) { data.copyBytes(to: $0, from: 5..<21) }
        var offset = 21
        let numbers = (0..<5).map { _ in Double(bitPattern: read(data, offset: &offset, as: UInt64.self)) }
        let gps = flags & 2 == 0 ? nil : GPSMeasurement(values: (0..<6).map { _ in Float(bitPattern: read(data, offset: &offset, as: UInt32.self)) })
        guard numbers.allSatisfy({ $0.isFinite }), gps?.values.allSatisfy({ $0.isFinite }) != false else { throw CocoaError(.fileReadCorruptFile) }
        return TrackPoint(id: UUID(uuid: uuid), latitude: numbers[0], longitude: numbers[1], altitude: numbers[2],
            metersPerSecond: numbers[3], timestamp: Date(timeIntervalSinceReferenceDate: numbers[4]),
            beginsNewSegment: flags & 1 != 0, gps: gps)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var word = value.littleEndian
        withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, offset: inout Int, as: T.Type) -> T {
        var word: T = 0
        _ = withUnsafeMutableBytes(of: &word) { data.copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size)) }
        offset += MemoryLayout<T>.size
        return T(littleEndian: word)
    }
}
