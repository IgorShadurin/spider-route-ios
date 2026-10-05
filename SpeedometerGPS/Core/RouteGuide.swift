import CoreLocation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A deliberately separate, optional companion to the original route geometry.
struct RouteGuide: Codable, Equatable {
    let schemaVersion: Int
    let title: String
    let language: String
    let routeFingerprint: String
    let points: [RouteGuidePoint]
}

/// Maps retain only annotation presentation. Photo bytes, prose and source URLs
/// belong to the guide library and are resolved by ID only after a tap.
struct RouteGuideMapPoint: Equatable, Identifiable {
    let id: String
    let title: String
    let latitude: Double
    let longitude: Double
    let category: RouteGuidePoint.Category
    let icon: RouteGuidePoint.Icon?
    typealias Icon = RouteGuidePoint.Icon

    init(_ point: RouteGuidePoint) {
        id = point.id; title = point.title
        latitude = point.latitude; longitude = point.longitude
        category = point.category; icon = point.icon
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct RouteGuidePoint: Codable, Equatable, Identifiable {
    enum Category: String, Codable, CaseIterable {
        case memorial, heritage, nature, settlement
    }

    let id: String
    let title: String
    let latitude: Double
    let longitude: Double
    let category: Category
    let summary: String
    let details: String?
    let sources: [RouteGuideSource]
    let distanceFromRouteMeters: Double?
    let distanceAlongRouteMeters: Double?
    var icon: Icon? = nil
    var photos: [RouteGuidePhoto]? = nil

    enum Icon: String, Codable, CaseIterable {
        case grave, person, memorial, church, monastery, museum, castle, ruins
        case bridge, river, lake, settlement, sculpture, building
    }

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}

/// Embedded bytes keep the guide portable and usable without network access.
struct RouteGuidePhoto: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let sourceURL: String
    let author: String
    let license: String
    let licenseURL: String?
    let imageURL: String?
    let data: Data
}

struct RouteGuideSource: Codable, Equatable {
    let title: String
    let url: String
}

enum RouteGuideImportError: Error, Equatable {
    case fileTooLarge
    case unsupportedVersion
    case invalidGuide
    case routeMismatch
    case routeMissing
    case storageUnavailable
}

enum RouteGuideImporter {
    static let maximumFileBytes = 40 * 1_024 * 1_024
    static let maximumPhotoBytes = 1_024 * 1_024
    static let maximumTotalPhotoBytes = 24 * 1_024 * 1_024
    static let maximumPhotoDimension = 4_096
    static let maximumPhotoPixels = 8_000_000
    static let maximumPointCount = 1_000

    /// SHA-256 of UTF-8 `route-guide-v1\n`, then `--\n` per segment,
    /// and `latitudeMicrodegrees,longitudeMicrodegrees\n` per source point.
    /// Microdegrees round to nearest, ties away from zero. No route name, UUID,
    /// elevation, time, display simplification or selected direction participates.
    static func fingerprint(for route: ReferenceRoute) -> String {
        var hash = SHA256()
        hash.update(data: Data("route-guide-v1\n".utf8))
        for segment in route.segments {
            hash.update(data: Data("--\n".utf8))
            // One update per bounded chunk keeps long-route import work linear.
            var chunk = ""
            for (index, point) in segment.enumerated() {
                let latitude = Int64((point.latitude * 1_000_000).rounded(.toNearestOrAwayFromZero))
                let longitude = Int64((point.longitude * 1_000_000).rounded(.toNearestOrAwayFromZero))
                chunk += "\(latitude),\(longitude)\n"
                if index % 256 == 255 {
                    hash.update(data: Data(chunk.utf8))
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            hash.update(data: Data(chunk.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func read(from url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw RouteGuideImportError.fileTooLarge }
        return data
    }

    static func decode(data: Data, for route: ReferenceRoute) throws -> RouteGuide {
        guard data.count <= maximumFileBytes else { throw RouteGuideImportError.fileTooLarge }
        let guide: RouteGuide
        do { guide = try JSONDecoder().decode(RouteGuide.self, from: data) }
        catch { throw RouteGuideImportError.invalidGuide }
        try validate(guide, for: route)
        return guide
    }

    static func validate(_ guide: RouteGuide, for route: ReferenceRoute) throws {
        guard [1, 2].contains(guide.schemaVersion) else { throw RouteGuideImportError.unsupportedVersion }
        let photos = guide.points.flatMap { $0.photos ?? [] }
        // Apply whole-document budgets before decompressing any image.
        guard photos.count <= 120,
              photos.reduce(0, { $0 + $1.data.count }) <= maximumTotalPhotoBytes,
              photos.isEmpty || guide.schemaVersion == 2,
              validText(guide.title, maximum: 200), validText(guide.language, maximum: 35),
              guide.points.count <= maximumPointCount,
              Set(guide.points.map(\.id)).count == guide.points.count,
              guide.points.allSatisfy(validPoint) else { throw RouteGuideImportError.invalidGuide }
        guard guide.routeFingerprint == fingerprint(for: route) else {
            throw RouteGuideImportError.routeMismatch
        }
    }

    private static func validPoint(_ point: RouteGuidePoint) -> Bool {
        validText(point.id, maximum: 200) && validText(point.title, maximum: 200)
            && point.latitude.isFinite && (-90...90).contains(point.latitude)
            && point.longitude.isFinite && (-180...180).contains(point.longitude)
            && validText(point.summary, maximum: 500)
            && (point.details.map { validText($0, maximum: 5_000) } ?? true)
            && !point.sources.isEmpty && point.sources.count <= 20
            && point.sources.allSatisfy { validText($0.title, maximum: 300) && validURL($0.url) }
            && (point.photos.map { photos in
                photos.count <= 3 && Set(photos.map(\.id)).count == photos.count && photos.allSatisfy { photo in autoreleasepool { validPhoto(photo) } }
            } ?? true)
            && validDistance(point.distanceFromRouteMeters)
            && validDistance(point.distanceAlongRouteMeters)
    }

    /// iOS 15 does not automatically percent-encode Unicode paths as newer
    /// Foundation versions do. Preserve existing escapes and URL delimiters.
    static func sourceURL(_ value: String) -> URL? {
        guard value.count <= 2_048,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let ascii = value.utf8.map { byte in
            byte < 128 ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
        guard let components = URLComponents(string: ascii),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    private static func validURL(_ value: String) -> Bool { sourceURL(value) != nil }

    private static func validPhoto(_ photo: RouteGuidePhoto) -> Bool {
        guard validText(photo.id, maximum: 200), validText(photo.title, maximum: 300),
              validText(photo.author, maximum: 300), validText(photo.license, maximum: 200),
              validURL(photo.sourceURL), photo.licenseURL.map(validURL) ?? true,
              photo.imageURL.map(validURL) ?? true,
              !photo.data.isEmpty, photo.data.count <= maximumPhotoBytes,
              let source = CGImageSourceCreateWithData(photo.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPhotoDimension, height <= maximumPhotoDimension,
              width * height <= maximumPhotoPixels else { return false }
        // Decode only after bounding dimensions; force decompression to reject corrupt payloads.
        guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else { return false }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }

#if DEBUG
    static func validationFailures(_ guide: RouteGuide) -> [String] {
        guide.points.flatMap { point -> [String] in
            guard !validPoint(point) else { return [] }
            var issues = [point.id]
            for source in point.sources where !validURL(source.url) { issues.append("source URL: \(source.url)") }
            for photo in point.photos ?? [] where !validPhoto(photo) {
                issues.append("photo: \(photo.id)")
                for url in [photo.sourceURL, photo.licenseURL, photo.imageURL].compactMap({ $0 }) where !validURL(url) {
                    issues.append("photo URL: \(url)")
                }
                if let image = CGImageSourceCreateWithData(photo.data as CFData, nil) {
                    issues.append("image status: \(CGImageSourceGetStatus(image).rawValue)")
                }
            }
            return issues
        }
    }
#endif

    private static func validDistance(_ value: Double?) -> Bool {
        value.map { $0.isFinite && $0 >= 0 } ?? true
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maximum
    }
}

/// Stored separately so legacy route libraries and GPX/other exports are untouched.
struct PersistedRouteGuide: Codable {
    let guide: RouteGuide
    let enabled: Bool
}
