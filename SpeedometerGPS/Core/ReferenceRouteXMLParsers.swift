import Foundation

final class GPXRouteParserDelegate: NSObject, XMLParserDelegate {
    private(set) var routeName: String?
    private(set) var segments = [[ReferenceRoutePoint]]()
    private var currentSegment: [ReferenceRoutePoint]?
    private var loosePoints = [ReferenceRoutePoint]()
    private var nameBuffer: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName.lowercased() {
        case "trkseg": currentSegment = []
        case "trkpt", "rtept":
            guard let latitudeText = attributeDict["lat"], let longitudeText = attributeDict["lon"],
                  let latitude = Double(latitudeText), let longitude = Double(longitudeText) else { return }
            let point = ReferenceRoutePoint(latitude: latitude, longitude: longitude)
            if currentSegment != nil { currentSegment?.append(point) } else { loosePoints.append(point) }
        case "name": nameBuffer = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if nameBuffer != nil { nameBuffer?.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName.lowercased() {
        case "name":
            if routeName == nil {
                let candidate = nameBuffer?.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate?.isEmpty == false { routeName = candidate }
            }
            nameBuffer = nil
        case "trkseg":
            if let currentSegment { segments.append(currentSegment) }
            currentSegment = nil
        case "rte":
            if loosePoints.count >= 2 { segments.append(loosePoints); loosePoints = [] }
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if let currentSegment, currentSegment.count >= 2 { segments.append(currentSegment) }
        if loosePoints.count >= 2 { segments.append(loosePoints) }
    }
}

final class KMLRouteParserDelegate: NSObject, XMLParserDelegate {
    private(set) var routeName: String?
    private(set) var segments = [[ReferenceRoutePoint]]()
    private var nameBuffer: String?
    private var coordinatesBuffer: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName.lowercased() {
        case "name": nameBuffer = ""
        case "coordinates": coordinatesBuffer = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if nameBuffer != nil { nameBuffer?.append(string) }
        if coordinatesBuffer != nil { coordinatesBuffer?.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName.lowercased() {
        case "name":
            if routeName == nil {
                let candidate = nameBuffer?.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate?.isEmpty == false { routeName = candidate }
            }
            nameBuffer = nil
        case "coordinates":
            let points = (coordinatesBuffer ?? "").split(whereSeparator: { $0.isWhitespace }).compactMap { value -> ReferenceRoutePoint? in
                let components = value.split(separator: ",", omittingEmptySubsequences: false)
                guard components.count >= 2, let longitude = Double(components[0]), let latitude = Double(components[1]) else { return nil }
                return .init(latitude: latitude, longitude: longitude)
            }
            if points.count >= 2 { segments.append(points) }
            coordinatesBuffer = nil
        default: break
        }
    }
}
