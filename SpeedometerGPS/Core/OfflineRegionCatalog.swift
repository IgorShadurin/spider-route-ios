import Foundation
import MapLibre

struct OfflineRegion: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let parentID: String?
    let subdivisionCode: String?
    let countryCode: String
    let name: String
    let names: [String: String]
    /// GeoJSON order: west, south, east, north. Used for preview only.
    let bounds: [Double]
    let offset: UInt64
    let length: Int

    var coordinateBounds: MLNCoordinateBounds {
        .init(sw: .init(latitude: max(-85, bounds[1]), longitude: bounds[0]),
              ne: .init(latitude: min(85, bounds[3]), longitude: bounds[2]))
    }

    func localizedName(locale: Locale) -> String {
        if parentID == nil, countryCode.count == 2,
           let translated = locale.localizedString(forRegionCode: countryCode) { return translated }
        let language = OSMMapStyle.languageCode(locale.identifier)
        return names[language == "zh-Hant" ? "zht" : language] ?? names["en"] ?? name
    }

    /// Read only the selected shape. Never decode the world's geometry on the UI thread.
    func shapeData(bundle: Bundle = .main) throws -> Data {
        guard let url = bundle.url(forResource: "geometry", withExtension: "bin", subdirectory: "OfflineRegions") else { throw CocoaError(.fileNoSuchFile) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: length), data.count == length else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}

enum OfflineRegionCatalog {
    static func load(bundle: Bundle = .main) throws -> [OfflineRegion] {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "OfflineRegions") else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode([OfflineRegion].self, from: Data(contentsOf: url))
    }
}
