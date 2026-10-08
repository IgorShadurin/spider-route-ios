import MapKit
import SwiftUI

struct TripDetailView: View {
    private let initialTrip: TripRecord
    @EnvironmentObject private var archive: RouteArchiveStore
    private var trip: TripRecord { archive.trips.first(where: { $0.id == initialTrip.id }) ?? initialTrip }
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingExportOptions: Bool
    @State private var showingVideos = false

    init(trip: TripRecord, settings: AppSettings, showsExportOptionsOnAppear: Bool = false) {
        self.initialTrip = trip
        self.settings = settings
        _showingExportOptions = State(initialValue: showsExportOptionsOnAppear)
    }

    var body: some View {
        PlatformNavigationContainer {
            ScrollView {
                VStack(spacing: 16) {
                    RoutePreviewMap(trip: trip, theme: settings.theme, mapProvider: settings.mapProvider, mapLanguageID: settings.mapLanguageID)
                        .frame(height: 260)

                    metrics
                    routeInformation
                    if !trip.videoRecordings.isEmpty {
                        Button { showingVideos = true } label: {
                            Label(L10n.tr("video_route_title"), systemImage: "video.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .foregroundStyle(settings.theme.videoRouteAccent)
                        .accessibilityIdentifier("trip.video-recordings")
                    }

                    CapsuleActionButton(
                        action: { showingExportOptions = true }
                    ) {
                        Label(L10n.tr("route_export"), systemImage: PlatformSymbol.name("square.and.arrow.up"))
                    }
                    .accessibilityIdentifier("route.export")
                }
                .padding(16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(AppPalette.canvas(colorScheme))
            .navigationTitle(L10n.tr("route_detail_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common_done")) { dismiss() }
                }
            }
        }
        .tint(AppPalette.brandAccent)
        .sheet(isPresented: $showingVideos) {
            VideoRecordingInfoSheet(recordings: trip.videoRecordings)
        }
        .sheet(isPresented: $showingExportOptions) {
            RouteExportSheet(trip: trip, theme: settings.theme)
                .platformLargeSheetPresentation()
        }
        .accessibilityIdentifier("screen.trip-detail")
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricCard(
                title: L10n.tr("metric_distance"),
                value: SpeedFormatter.distance(trip.distance),
                systemName: "road.lanes",
                accent: AppPalette.brandAccent
            )
            MetricCard(
                title: L10n.tr("metric_duration"),
                value: SpeedFormatter.duration(trip.duration),
                systemName: "timer",
                accent: AppPalette.brandAccent
            )
            MetricCard(
                title: L10n.tr("metric_top_speed"),
                value: speedText(trip.topSpeed),
                systemName: "gauge.with.needle.fill",
                accent: AppPalette.brandAccent
            )
            MetricCard(
                title: L10n.tr("metric_average_speed"),
                value: speedText(trip.averageSpeed),
                systemName: "speedometer",
                accent: AppPalette.brandAccent
            )
        }
    }

    private var routeInformation: some View {
        VStack(spacing: 0) {
            detailRow(
                icon: "calendar",
                title: L10n.tr("route_started"),
                value: trip.startedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(L10n.locale))
            )
            Divider().padding(.leading, 52)
            if trip.activity != "activity_unknown", !trip.activity.isEmpty {
                detailRow(
                    icon: "figure.walk.motion",
                    title: L10n.tr("route_activity"),
                    value: L10n.tr(trip.activity)
                )
                .accessibilityIdentifier("trip.activity")
                Divider().padding(.leading, 52)
            }
            detailRow(
                icon: "mappin.and.ellipse",
                title: L10n.tr("route_points"),
                value: L10n.format("route_points_format", trip.points.count)
            )
        }
        .background(AppPalette.raisedCard(colorScheme), in: RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: PlatformSymbol.name(icon))
                .foregroundStyle(AppPalette.brandAccent)
                .frame(width: 28)
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .frame(minHeight: 50)
        .padding(.horizontal, 14)
    }

    private func speedText(_ metersPerSecond: Double) -> String {
        SpeedFormatter.number(metersPerSecond, unit: settings.unit, decimals: false) + " " + settings.unit.rawValue
    }
}

private struct TripMapPreparationKey: Hashable {
    let id: UUID
    let metadata: TripVideoMetadata?
}

private struct PreparedTripMap {
    let drawingGroups: [RouteDrawingGroup]
    let segments: [[CLLocationCoordinate2D]]
    let sections: [VideoRouteSection]
    let markers: [RouteEventMarker]
    let region: MKCoordinateRegion
    init(trip: TripRecord) {
        segments = trip.segments.flatMap { RouteDisplayPath.chunks(for: $0.map(\.coordinate)) }
        var cache = VideoRouteDisplayCache()
        cache.update(points: trip.points, recordings: trip.videoRecordings)
        sections = cache.sections
        drawingGroups = sections.isEmpty ? RouteDrawingGroup.make(segments) : cache.drawingGroups
        markers = RouteEventMarkers.make(points: trip.points, isFinished: true)
        var fittedRegion = RouteMapGeometry.region(fitting: segments.flatMap { $0 })
#if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-trip-endpoint=") }),
           let point = argument.hasSuffix("=start") ? trip.points.first : trip.points.last {
            fittedRegion = MKCoordinateRegion(center: point.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003))
        }
#endif
        region = fittedRegion
    }
}

private struct RoutePreviewMap: View {
    let trip: TripRecord
    let theme: SpeedTheme
    let mapProvider: MapProvider
    let mapLanguageID: String?
    @State private var prepared: PreparedTripMap?
    @State private var videoSelection: VideoRecordingSelection?

    var body: some View {
        Group {
            if let prepared {
                RoutePreviewMapSurface(mapProvider: mapProvider, mapLanguageID: mapLanguageID, sourcePointCount: trip.points.count, routeSegments: prepared.segments, eventMarkers: prepared.markers,
                    theme: theme, region: prepared.region, recordedSections: prepared.sections,
                    onVideoSelection: { ids in
                        if !ids.isEmpty { videoSelection = VideoRecordingSelection(recordingIDs: ids) }
                    }, drawingGroups: prepared.drawingGroups)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .clipShape(RoundedRectangle(cornerRadius: UIShape.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: UIShape.card, style: .continuous).stroke(Color.primary.opacity(0.10)))
        .task(id: TripMapPreparationKey(id: trip.id, metadata: trip.videoMetadata)) {
            let snapshot = trip
            let result = await Task.detached(priority: .userInitiated) { PreparedTripMap(trip: snapshot) }.value
            guard !Task.isCancelled else { return }
            prepared = result
        }
        .sheet(item: $videoSelection) { selection in
            VideoRecordingInfoSheet(recordings: trip.videoRecordings.filter { selection.recordingIDs.contains($0.id) })
        }
    }
}

struct VideoRecordingSelection: Identifiable {
    let id = UUID()
    let recordingIDs: [UUID]
}

struct VideoRecordingInfoSheet: View {
    let recordings: [TripVideoRecording]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PlatformNavigationContainer {
            List {
                ForEach(recordings) { recording in
                    Section {
                        Text(recording.fileName).font(.headline).textSelection(.enabled)
                            .accessibilityIdentifier("video.recording.filename")
                        Label(recording.cameraStartedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second().locale(L10n.locale)), systemImage: "calendar")
                            .accessibilityLabel(L10n.tr("route_started"))
                            .accessibilityValue(recording.cameraStartedAt.formatted(.dateTime.day().month(.wide).year().hour().minute().second().locale(L10n.locale)))
                        HStack {
                            Text(L10n.tr("metric_duration"))
                            Spacer()
                            Text(SpeedFormatter.duration(recording.duration)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("video.recording.duration")
                        Text(L10n.tr(recording.state == .saved ? "video_route_saved" : "video_route_unconfirmed"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.tr("video_route_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("common_done")) { dismiss() } } }
        }
        .accessibilityIdentifier("video.recording.info")
    }
}

private struct RouteExportSheet: View {
    let trip: TripRecord
    let theme: SpeedTheme

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedFormat: RouteExportFormat = .gpx
    @State private var document = RouteExportDocument()
    @State private var filename = "route.gpx"
    @State private var showingFileExporter = false
    @State private var showingError = false
    @State private var exportSucceeded = false
    @State private var preparationID: UUID?
    @State private var isPreparing = false
    @State private var exportAction: ExportAction = .save
    @State private var sharedFile: SharedRouteFile?
    @State private var retainedSharedFile: SharedRouteFile?

    private enum ExportAction { case save, share }

    var body: some View {
        PlatformNavigationContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.tr("route_export_body"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(RouteExportFormat.allCases) { format in
                        Button { selectedFormat = format; exportSucceeded = false } label: {
                            exportCard(format)
                            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(AppPalette.raisedCard(colorScheme), in: RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous).stroke(selectedFormat == format ? AppPalette.brandAccent : Color.primary.opacity(0.08), lineWidth: selectedFormat == format ? 2 : 1))
                            .contentShape(RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("route.export.\(format.rawValue)")
                        .disabled(isPreparing || showingFileExporter || sharedFile != nil)
                        .accessibilityAddTraits(selectedFormat == format ? .isSelected : [])
                        .accessibilityValue(isPreparing && selectedFormat == format ? L10n.tr("route_export_preparing") : "")
                    }

                    VStack(spacing: 10) {
                        Button { beginExport(.share) } label: {
                            Label(L10n.tr("route_export_share"), systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("route.export.share")
                        Button { beginExport(.save) } label: {
                            Label(L10n.tr("route_export_save"), systemImage: "folder")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("route.export.save")
                    }
                    .disabled(isPreparing || showingFileExporter || sharedFile != nil)

                    if exportSucceeded {
                        Label(L10n.tr("route_export_success"), systemImage: PlatformSymbol.name("checkmark.circle.fill"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                }
                .padding(16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(L10n.tr("route_export_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common_close")) {
                        preparationID = nil
                        isPreparing = false
                        dismiss()
                    }
                    .accessibilityIdentifier("route.export.close")
                }
            }
        }
        .tint(AppPalette.brandAccent)
        .onAppear {
#if DEBUG
            if ScreenshotState.requested == .tripsExportPreparing { isPreparing = true }
#endif
        }
        .interactiveDismissDisabled(isPreparing)
        .task(id: preparationID) {
            guard let request = preparationID else { return }
            do {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-export-slow") {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                }
#endif
                let prepared = try await RouteExporter.prepare(trip: trip, format: selectedFormat)
                guard preparationID == request, !Task.isCancelled else { return }
                document = prepared
                filename = RouteExporter.filename(for: trip, format: selectedFormat)
                if exportAction == .share {
                    let data = prepared.data
                    let name = filename
                    let file = try await Task.detached(priority: .userInitiated) {
                        try SharedRouteFile(data: data, filename: name)
                    }.value
                    guard preparationID == request, !Task.isCancelled else { return }
                    retainedSharedFile = file
                    sharedFile = file
                } else {
                    showingFileExporter = true
                }
                isPreparing = false
            } catch is CancellationError {
                // Closing or cancelling must never present a stale exporter.
            } catch {
                guard preparationID == request, !Task.isCancelled else { return }
                isPreparing = false
                showingError = true
            }
        }
        .sheet(item: $sharedFile, onDismiss: { retainedSharedFile = nil }) { file in
            RouteShareSheet(file: file) { error in
                if error != nil { showingError = true }
            }
        }
        .fileExporter(
            isPresented: $showingFileExporter,
            document: document,
            contentType: selectedFormat.contentType,
            defaultFilename: filename
        ) { result in
            switch result {
            case .success:
                withAnimation(.easeInOut(duration: 0.2)) { exportSucceeded = true }
            case .failure:
                showingError = true
            }
        }
        .alert(L10n.tr("route_export_failed_title"), isPresented: $showingError) {
            Button(L10n.tr("common_ok"), role: .cancel) {}
        } message: {
            Text(L10n.tr("route_export_failed_body"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.route-export")
    }

    @ViewBuilder
    private func exportCard(_ format: RouteExportFormat) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    exportIcon(format)
                    Text(L10n.tr(format.titleKey))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    exportExtension(format)
                }

                Text(L10n.tr(isPreparing && selectedFormat == format ? "route_export_preparing" : format.detailKey))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 14) {
                exportIcon(format)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr(format.titleKey))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(L10n.tr(isPreparing && selectedFormat == format ? "route_export_preparing" : format.detailKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)
                exportExtension(format)
            }
        }
    }

    private func exportIcon(_ format: RouteExportFormat) -> some View {
        Group {
            if isPreparing && selectedFormat == format {
                ProgressView()
                    .tint(AppPalette.brandAccent)
                    .accessibilityIdentifier("route.export.preparing")
            } else {
                Image(systemName: PlatformSymbol.name(selectedFormat == format ? "checkmark.circle.fill" : icon(for: format)))
                    .font(.title3.weight(.bold))
            }
        }
            .foregroundStyle(AppPalette.brandAccent)
            .frame(width: 44, height: 44)
            .background(AppPalette.brandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func exportExtension(_ format: RouteExportFormat) -> some View {
        Text(format.filenameExtension.uppercased())
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(AppPalette.brandAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppPalette.brandAccent.opacity(0.12), in: Capsule())
    }

    private func beginExport(_ action: ExportAction) {
        guard !isPreparing, !showingFileExporter, sharedFile == nil else { return }
        exportAction = action
        exportSucceeded = false
        isPreparing = true
        preparationID = UUID()
    }

    private func icon(for format: RouteExportFormat) -> String {
        switch format {
        case .gpx: "point.topleft.down.to.point.bottomright.curvepath"
        case .kml: "map"
        case .geoJSON: "curlybraces.square"
        case .csv: "tablecells"
        }
    }
}


/// Each share owns a separate temporary copy, retained through activity completion.
private final class SharedRouteFile: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL

    init(data: Data, filename: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouteShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private struct RouteShareSheet: UIViewControllerRepresentable {
    let file: SharedRouteFile
    let onCompletion: (Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { [file] _, _, _, error in
            // Keep the file alive even if SwiftUI dismisses before UIKit finishes.
            withExtendedLifetime(file) { onCompletion(error) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
