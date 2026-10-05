import SwiftUI

struct TripsView: View {
    @ObservedObject var routes: RouteArchiveStore
    @ObservedObject var settings: AppSettings
    let hiddenTripIDs: Set<UUID>
    let onRequestDelete: (TripRecord) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTrip: TripRecord?

    init(
        routes: RouteArchiveStore,
        settings: AppSettings,
        hiddenTripIDs: Set<UUID> = [],
        onRequestDelete: @escaping (TripRecord) -> Void = { _ in }
    ) {
        self.routes = routes
        self.settings = settings
        self.hiddenTripIDs = hiddenTripIDs
        self.onRequestDelete = onRequestDelete
#if DEBUG
        _selectedTrip = State(initialValue: ScreenshotState.requested?.opensTripDetail == true ? Self.mockTrip : nil)
#else
        _selectedTrip = State(initialValue: nil)
#endif
    }

    private var displayedTrips: [TripRecord] {
#if DEBUG
        // The empty screenshot must not depend on this simulator's saved library.
        if ScreenshotState.requested == .tripsEmpty { return [] }
        if ScreenshotState.requested?.usesMockTrips == true {
            let trips = ProcessInfo.processInfo.arguments.contains("--ui-trip-preview-stress") ? Self.previewStressFixtures
                : (ProcessInfo.processInfo.arguments.contains("--ui-trip-preview-fixtures") ? Self.previewFixtures : [Self.mockTrip])
            return trips.filter { !hiddenTripIDs.contains($0.id) }
        }
#endif
        return routes.trips.filter { !hiddenTripIDs.contains($0.id) }
    }

    var body: some View {
        List {
            summary
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if routes.isLoading {
                ProgressView().frame(maxWidth: .infinity)
                    .accessibilityIdentifier("trips.loading")
            }
            if displayedTrips.isEmpty && !routes.isLoading {
                emptyState
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(displayedTrips) { trip in
                    TripRow(trip: trip, unit: settings.unit) { selectedTrip = trip }
                    .accessibilityIdentifier("trip.row.\(trip.id.uuidString)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            onRequestDelete(trip)
                        } label: {
                            Label(L10n.tr("common_delete"), systemImage: PlatformSymbol.name("trash"))
                        }
                        .disabled(routes.isLoading)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .platformHiddenScrollBackground()
        .platformBottomContentMargin(10)
        .frame(maxWidth: 752)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("screen.trips")
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(
                trip: trip,
                settings: settings,
                showsExportOptionsOnAppear: showsExportOptionsOnAppear
            )
        }
    }

    private var summary: some View {
        let totalDistance = displayedTrips.map(\.distance).reduce(0, +)
        let totalTime = displayedTrips.map(\.duration).reduce(0, +)
        return HStack(spacing: 10) {
            MetricCard(title: L10n.tr("trips_total_distance"), value: SpeedFormatter.distance(totalDistance), systemName: "road.lanes", accent: AppPalette.brandAccent)
            MetricCard(title: L10n.tr("trips_drive_time"), value: SpeedFormatter.duration(totalTime), systemName: "timer", accent: AppPalette.brandAccent)
            MetricCard(title: L10n.tr("trips_count"), value: displayedTrips.count.formatted(), systemName: "flag.checkered", accent: AppPalette.brandAccent)
        }
    }

    private var emptyState: some View {
        Group {
            if #available(iOS 17.0, *) {
                ContentUnavailableView(
                    L10n.tr("trips_empty_title"),
                    systemImage: PlatformSymbol.name("point.topleft.down.to.point.bottomright.curvepath"),
                    description: Text(L10n.tr("trips_empty_body"))
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: PlatformSymbol.name("point.topleft.down.to.point.bottomright.curvepath"))
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("trips_empty_title"))
                        .font(.headline)
                    Text(L10n.tr("trips_empty_body"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
        .frame(minHeight: 310)
    }

    static let mockTrip: TripRecord = {
#if DEBUG
        if let fixture = ScreenshotCityFixture.current {
            let points = fixture.trackPoints
            return TripRecord(id: UUID(uuidString: "67A1C0DE-4F5A-4C67-9B20-000000000067")!,
                startedAt: points.first!.timestamp, endedAt: points.last!.timestamp, points: points,
                activity: "activity_cycling")
        }
#endif
        var activity = "activity_cycling"
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-unknown-activity") { activity = "activity_unknown" }
#endif
        var trip = TripRecord(
        id: UUID(uuidString: "67A1C0DE-4F5A-4C67-9B20-000000000067")!, startedAt: Date().addingTimeInterval(-2_240), endedAt: Date().addingTimeInterval(-240),
        points: RouteMapView.mockRoute.enumerated().map { index, point in
            TrackPoint(latitude: point.latitude, longitude: point.longitude, altitude: 215 + Double(index), metersPerSecond: 5 + Double(index) * 0.25, timestamp: Date().addingTimeInterval(Double(index) * 250 - 2_240), beginsNewSegment: index == 3 || index == 5)
        }, activity: activity
        )
#if DEBUG
        if ScreenshotState.requested == .tripsVideoSections {
            trip.videoMetadata = TripVideoMetadata(recordings: TripVideoFixture.shortRecordings(points: trip.points))
        }
#endif
        return trip
    }()

#if DEBUG
    static let previewStressFixtures: [TripRecord] = {
        [mockTrip] + (1...40).map { index in
            let sample = previewFixtures[index % previewFixtures.count]
            let start = sample.startedAt.addingTimeInterval(-Double(index) * 86400)
            return TripRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(sample.duration),
                points: sample.points, activity: sample.activity)
        }
    }()

    static let previewFixtures: [TripRecord] = {
        let date = Date(timeIntervalSince1970: 1_790_741_400)
        let shapes: [[(Double, Double)]] = [
            [(0,0), (0,2), (1,3), (3,3), (4,2), (3,0), (1,-1), (0,0)],
            [(0,0), (0,1), (2,1), (2,3), (1,3), (1,4), (4,4), (4,2), (5,2)]
        ]
        return [mockTrip] + shapes.enumerated().map { ride, shape in
            let start = date.addingTimeInterval(Double(-ride - 1) * 86400)
            let points = shape.enumerated().map { index, coordinate in
                TrackPoint(latitude: 51.5 + coordinate.0 * 0.007, longitude: -0.12 + coordinate.1 * 0.007,
                    altitude: 20, metersPerSecond: 5.5, timestamp: start.addingTimeInterval(Double(index) * 280))
            }
            return TripRecord(id: UUID(uuidString: "67A1C0DE-4F5A-4C67-9B20-00000000000\(ride + 1)")!,
                startedAt: start, endedAt: points.last!.timestamp, points: points, activity: "activity_cycling")
        }
    }()
#endif

    private var showsExportOptionsOnAppear: Bool {
#if DEBUG
        ScreenshotState.requested == .tripsExport || ScreenshotState.requested == .tripsExportPreparing
#else
        false
#endif
    }
}

struct TripRow: View {
    let trip: TripRecord
    let unit: SpeedUnit
    let onSelect: () -> Void
    @State private var preview: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) { content }
        .buttonStyle(.plain)
        .onDisappear { preview = nil }
        .task(id: trip.previewIdentity) {
            preview = TripRoutePreviewCache.shared.cached(trip.previewIdentity)
            if preview == nil {
                let image = await TripRoutePreviewCache.shared.image(identity: trip.previewIdentity, points: trip.points)
                guard !Task.isCancelled else { return }
                preview = image
            }
#if DEBUG
            if preview != nil, ScreenshotState.requested != nil {
                try? Data("ready".utf8).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("trip-preview-\(trip.id.uuidString)"), options: .atomic)
            }
#endif
        }
#if DEBUG
        .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-trip-preview-probe") ? (preview == nil ? "preview-loading" : "preview-ready") : "")
#endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                routePreview
                VStack(alignment: .leading, spacing: 3) {
                    Text(trip.startedAt, format: .dateTime.month(.abbreviated).day().year())
                        .font(.headline)
                    Text(trip.startedAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: PlatformSymbol.name("chevron.forward"))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Label(SpeedFormatter.distance(trip.distance), systemImage: PlatformSymbol.name("road.lanes"))
                Label(SpeedFormatter.duration(trip.duration), systemImage: PlatformSymbol.name("timer"))
                Label(SpeedFormatter.number(trip.topSpeed, unit: unit, decimals: false) + " " + unit.rawValue, systemImage: PlatformSymbol.name("gauge.with.needle"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(AppPalette.raisedCard(colorScheme), in: RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private var routePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.12, green: 0.18, blue: 0.17) : Color(red: 0.91, green: 0.95, blue: 0.93))
            if let preview {
                Image(uiImage: preview).resizable().interpolation(.high)
            } else {
                Image(systemName: PlatformSymbol.name("point.topleft.down.to.point.bottomright.curvepath"))
                    .font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 72)
        // Geographic orientation is invariant; the enclosing row mirrors for RTL.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}
