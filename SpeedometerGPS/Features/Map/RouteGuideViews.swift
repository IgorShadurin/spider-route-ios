import SwiftUI
import UniformTypeIdentifiers
import ImageIO

extension RouteGuideMapPoint {
    var effectiveIcon: Icon {
        icon ?? (category == .memorial ? .memorial : category == .nature ? .river : category == .settlement ? .settlement : .building)
    }
    var symbolName: String {
        let symbol: String
        switch effectiveIcon {
        case .person: symbol = "person.fill"
        case .church, .monastery: symbol = "house.fill"
        case .museum: symbol = "building.columns.fill"
        case .building: symbol = "building.2.fill"
        case .castle: symbol = "building.2.fill"
        case .ruins: symbol = "square.dashed"
        case .bridge: symbol = "rectangle.connected.to.line.below"
        case .settlement: symbol = "house.fill"
        case .sculpture, .memorial: symbol = "star.circle"
        case .grave: symbol = "rectangle.portrait"
        case .river, .lake: symbol = "drop.fill"
        }
        return PlatformSymbol.name(symbol, fallback: "mappin")
    }
    var tint: Color {
        switch effectiveIcon {
        case .river, .lake: .blue
        case .grave, .memorial: .purple
        case .person: .indigo
        default: .orange
        }
    }
}

extension RouteGuidePoint {
    var effectiveIcon: Icon { RouteGuideMapPoint(self).effectiveIcon }
    var symbolName: String { RouteGuideMapPoint(self).symbolName }
    var tint: Color { RouteGuideMapPoint(self).tint }
}

/// Small original vector symbols avoid depending on newer SF Symbols on iOS 15.
struct RouteGuideSymbol: View {
    let point: RouteGuidePoint
    var body: some View {
        Group {
            switch point.effectiveIcon {
            case .grave:
                ZStack {
                    UnevenGraveShape().stroke(lineWidth: 1.8)
                    VStack(spacing: 3) {
                        Rectangle().frame(width: 7, height: 1.5)
                        Rectangle().frame(width: 10, height: 1.5)
                    }
                }.frame(width: 17, height: 19)
            case .river, .lake:
                WaterGuideShape(isLake: point.effectiveIcon == .lake)
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 21, height: 18)
            case .memorial, .bridge, .castle, .sculpture:
                HeritageGuideShape(kind: point.effectiveIcon)
                    .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 21, height: 21)
            case .church, .monastery:
                ZStack {
                    Image(systemName: "house").offset(y: 3)
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold)).offset(y: -8)
                }.frame(width: 23, height: 24)
            default:
                Image(systemName: point.symbolName)
            }
        }.accessibilityHidden(true)
    }
}

private struct UnevenGraveShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.width / 2))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.width / 2), control: CGPoint(x: r.midX, y: r.minY - r.width / 2))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct WaterGuideShape: Shape {
    let isLake: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        for row in 0..<3 {
            let y = r.height * (0.2 + Double(row) * 0.3)
            p.move(to: CGPoint(x: 0, y: y))
            p.addCurve(to: CGPoint(x: r.width, y: y), control1: CGPoint(x: r.width / 3, y: y - 5), control2: CGPoint(x: r.width * 2 / 3, y: y + 5))
        }
        if isLake { p.addEllipse(in: r.insetBy(dx: -3, dy: -3)) }
        return p
    }
}

private struct HeritageGuideShape: Shape {
    let kind: RouteGuidePoint.Icon
    func path(in r: CGRect) -> Path {
        var p = Path()
        func move(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x: x*r.width, y: y*r.height)) }
        func line(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x: x*r.width, y: y*r.height)) }
        switch kind {
        case .bridge:
            move(0, 0.35); line(1, 0.35)
            move(0, 0.5); line(1, 0.5)
            move(0, 0.9); line(0.15, 0.9)
            p.addQuadCurve(to: CGPoint(x: r.width*0.85, y: r.height*0.9), control: CGPoint(x: r.midX, y: r.height*0.05))
            line(1, 0.9)
        case .castle:
            move(0.08, 0.95); line(0.08, 0.12); line(0.25, 0.12); line(0.25, 0.3)
            line(0.4, 0.3); line(0.4, 0.12); line(0.6, 0.12); line(0.6, 0.3)
            line(0.75, 0.3); line(0.75, 0.12); line(0.92, 0.12); line(0.92, 0.95); p.closeSubpath()
            p.addRoundedRect(in: CGRect(x: r.width*0.38, y: r.height*0.63, width: r.width*0.24, height: r.height*0.32), cornerSize: CGSize(width: 2, height: 2))
        case .sculpture:
            p.addEllipse(in: CGRect(x: r.width*0.34, y: 0, width: r.width*0.32, height: r.height*0.32))
            move(0.2, 0.65); line(0.3, 0.4); line(0.7, 0.4); line(0.8, 0.65); p.closeSubpath()
            p.addRect(CGRect(x: r.width*0.35, y: r.height*0.65, width: r.width*0.3, height: r.height*0.28))
            move(0.15, 0.95); line(0.85, 0.95)
        default:
            move(0.35, 0.78); line(0.4, 0.12); line(0.5, 0); line(0.6, 0.12); line(0.65, 0.78); p.closeSubpath()
            p.addRect(CGRect(x: r.width*0.2, y: r.height*0.78, width: r.width*0.6, height: r.height*0.18))
        }
        return p
    }
}

struct RouteGuideMarker: View {
    let point: RouteGuideMapPoint
    var showsDetails = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Both renderers reuse the same tiny bitmap; no live material surface or
        // vector hierarchy for each place during native map camera animation.
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light),
            UITraitCollection(displayScale: displayScale)
        ])
        Image(uiImage: RouteGuideMarkerImage.image(for: point, details: showsDetails, traits: traits))
            .frame(width: 66, height: 44)
            .contentShape(Rectangle())
    }
}

/// Native MapKit must not keep one live SwiftUI/material tree per POI on A9.
/// These tiny cached bitmaps preserve the same semantic artwork and hit targets.
@MainActor
enum RouteGuideMarkerImage {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for point: RouteGuideMapPoint, details: Bool, traits: UITraitCollection) -> UIImage {
        let key = "\(point.effectiveIcon.rawValue)-\(details)-\(traits.userInterfaceStyle.rawValue)-\(traits.displayScale)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = traits.displayScale > 0 ? traits.displayScale : 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: 66, height: 44), format: format).image { renderer in
            let c = renderer.cgContext
            let color = UIColor(point.tint).resolvedColor(with: traits)
            c.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
            c.setLineWidth(1)
            if details {
                c.move(to: CGPoint(x: 0, y: 44)); c.addLine(to: CGPoint(x: 30, y: 22)); c.strokePath()
            }
            let radius: CGFloat = details ? 15 : 6
            let circle = CGRect(x: 44 - radius, y: 22 - radius, width: radius * 2, height: radius * 2)
            c.setFillColor(UIColor.systemBackground.resolvedColor(with: traits).cgColor)
            c.fillEllipse(in: circle); c.strokeEllipse(in: circle)
            guard details else {
                c.setFillColor(color.cgColor)
                c.fillEllipse(in: CGRect(x: 40, y: 18, width: 8, height: 8))
                return
            }
            c.setStrokeColor(color.cgColor); c.setLineWidth(1.7)
            c.setLineCap(.round); c.setLineJoin(.round)
            c.saveGState(); c.translateBy(x: 35.5, y: 12.5)
            let rect = CGRect(x: 0, y: 0, width: 17, height: 19)
            switch point.effectiveIcon {
            case .grave:
                c.addPath(UnevenGraveShape().path(in: rect).cgPath); c.strokePath()
                c.move(to: CGPoint(x: 5, y: 8)); c.addLine(to: CGPoint(x: 12, y: 8))
                c.move(to: CGPoint(x: 4, y: 12)); c.addLine(to: CGPoint(x: 13, y: 12)); c.strokePath()
            case .river, .lake:
                c.addPath(WaterGuideShape(isLake: point.effectiveIcon == .lake).path(in: rect).cgPath); c.strokePath()
            case .memorial, .bridge, .castle, .sculpture:
                c.addPath(HeritageGuideShape(kind: point.effectiveIcon).path(in: rect).cgPath); c.strokePath()
            case .church, .monastery:
                c.move(to: CGPoint(x: 0, y: 10)); c.addLine(to: CGPoint(x: 8.5, y: 4)); c.addLine(to: CGPoint(x: 17, y: 10))
                c.move(to: CGPoint(x: 2, y: 9)); c.addLine(to: CGPoint(x: 2, y: 19)); c.addLine(to: CGPoint(x: 15, y: 19)); c.addLine(to: CGPoint(x: 15, y: 9))
                c.move(to: CGPoint(x: 8.5, y: -3)); c.addLine(to: CGPoint(x: 8.5, y: 4))
                c.move(to: CGPoint(x: 5.5, y: 0)); c.addLine(to: CGPoint(x: 11.5, y: 0)); c.strokePath()
            default:
                UIImage(systemName: point.symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))?
                    .withTintColor(color, renderingMode: .alwaysOriginal).draw(in: rect)
            }
            c.restoreGState()
        }
        cache.countLimit = 64
        cache.setObject(image, forKey: key)
        return image
    }
}

struct RouteGuidePhotoView: View {
    let photo: RouteGuidePhoto
    @State private var decodedImage: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decodedImage {
                Image(uiImage: decodedImage).resizable().scaledToFit()
                    .accessibilityLabel(photo.title)
                    .accessibilityIdentifier("route-guide.photo.\(photo.id)")
            }
            Text(photo.title).font(.subheadline)
            if let source = RouteGuideImporter.sourceURL(photo.sourceURL) {
                Link(photo.author, destination: source).font(.caption)
            }
            if let url = photo.licenseURL.flatMap(RouteGuideImporter.sourceURL) {
                Link(photo.license, destination: url).font(.caption)
            } else { Text(photo.license).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: photo.id) {
            let data = photo.data
            decodedImage = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1_600,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        }
    }
}

struct RouteGuidePointContent: View {
    let point: RouteGuidePoint
    var onFocus: (() -> Void)? = nil
    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    RouteGuideSymbol(point: point).foregroundStyle(point.tint)
                    Text(point.title)
                }
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("route-guide.point.title")
                Text(point.summary)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("route-guide.point.summary")
                if let distance = point.distanceFromRouteMeters {
                    Text(L10n.format("route_guide_distance", SpeedFormatter.distance(distance)))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let onFocus {
                    Button(action: onFocus) {
                        Label(L10n.tr("route_guide_map"), systemImage: "map")
                    }.accessibilityIdentifier("route-guide.point.focus")
                }
            } footer: {
                Text(L10n.tr("route_guide_straight_line"))
            }
            if let details = point.details, !details.isEmpty {
                Section(L10n.tr("route_guide_details")) {
                    Text(details).font(.body).textSelection(.enabled)
                        .accessibilityIdentifier("route-guide.point.details")
                }
            }
            if let photos = point.photos, !photos.isEmpty {
                Section {
                    ForEach(photos) { RouteGuidePhotoView(photo: $0) }
                }
            }
            Section(L10n.tr("route_guide_sources")) {
                ForEach(Array(point.sources.enumerated()), id: \.offset) { _, source in
                    if let url = RouteGuideImporter.sourceURL(source.url) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title)
                                Text(url.host ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.tr("route_guide_title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.route-guide.point")
    }
}

struct RouteGuidePointSheet: View {
    let point: RouteGuidePoint
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PlatformNavigationContainer {
            RouteGuidePointContent(point: point)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common_done")) { dismiss() }
                } }
        }
    }
}

/// The same optional per-road file picker is available from Map and Settings.
struct RouteGuideLibrarySheet: View {
    @ObservedObject var store: ReferenceRouteStore
    let route: ReferenceRoute
    var onFocus: ((RouteGuidePoint) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    @State private var showingError = false
    @State private var confirmingReplacement = false

    var body: some View {
        PlatformNavigationContainer {
            List {
                Section {
                    Text(route.name).font(.headline)
                    if store.guide(for: route) != nil {
                        Toggle(L10n.tr("route_guide_show"), isOn: Binding(
                            get: { store.isGuideEnabled(for: route) },
                            set: { if !store.setGuideEnabled($0, for: route) { showingError = true } }
                        ))
                        .accessibilityIdentifier("route-guide.enabled")
                    } else {
                        Text(L10n.tr("route_guide_none")).foregroundStyle(.secondary)
                    }
                    Button {
                        if store.guide(for: route) != nil { confirmingReplacement = true }
                        else { showingImporter = true }
                    } label: {
                        Label(L10n.tr("route_guide_import"), systemImage: "square.and.arrow.down")
                    }.accessibilityIdentifier("route-guide.import")
                } footer: { Text(L10n.tr("route_guide_footer")) }

                if let guide = store.guide(for: route) {
                    Section(guide.title) {
                        if guide.points.isEmpty {
                            Text(L10n.tr("route_guide_empty")).foregroundStyle(.secondary)
                        }
                        ForEach(guide.points) { point in
                            NavigationLink {
                                RouteGuidePointContent(point: point, onFocus: onFocus.map { callback in
                                    { dismiss(); callback(point) }
                                })
                            } label: {
                                HStack(spacing: 12) {
                                    RouteGuideSymbol(point: point).foregroundStyle(point.tint)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(point.title).font(.headline)
                                        Text(point.summary).font(.subheadline).foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("route-guide.row.\(point.id)")
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("route_guide_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("common_done")) { dismiss() }
            } }
            .disabled(store.isImporting)
            .overlay { if store.isImporting { ProgressView().padding().background(.regularMaterial) } }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                Task {
                    do { try await store.importGuideInBackground(from: result.get(), for: route) }
                    catch { showingError = true }
                }
            }
            .alert(L10n.tr("reference_route_import_failed_title"), isPresented: $showingError) {
                Button(L10n.tr("common_ok"), role: .cancel) {}
            } message: { Text(L10n.tr("route_guide_import_error")) }
            .accessibilityIdentifier("screen.route-guide.library")
            .overlay {
                if confirmingReplacement {
                    DecisionConfirmationModal(
                        title: L10n.tr("route_guide_replace_title"),
                        message: L10n.tr("route_guide_replace_message"),
                        confirmLabel: L10n.tr("route_guide_replace"), confirmRole: .destructive,
                        systemName: "arrow.triangle.2.circlepath", accessibilityName: "route-guide.replace.confirmation",
                        onCancel: { confirmingReplacement = false },
                        onConfirm: { confirmingReplacement = false; showingImporter = true }
                    )
                }
            }
            .onAppear {
#if DEBUG
                if ScreenshotState.requested == .mapGuideReplace { confirmingReplacement = true }
#endif
            }
        }
    }
}

/// Hysteresis prevents flicker while zooming near the roadside-detail threshold.
enum RouteGuideMapVisibility {
    static func showsDetails(distance: Double, wasVisible: Bool) -> Bool {
        distance.isFinite && distance > 0 && distance <= (wasVisible ? 5_000 : 4_000)
    }
}
