import MapKit
import MapLibre
import SwiftUI

private struct MapShowsAttributionKey: EnvironmentKey {
    static let defaultValue = true
}

private struct MapScaleTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct MapControlsTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var mapShowsAttribution: Bool {
        get { self[MapShowsAttributionKey.self] }
        set { self[MapShowsAttributionKey.self] = newValue }
    }
    var mapScaleTopInset: CGFloat {
        get { self[MapScaleTopInsetKey.self] }
        set { self[MapScaleTopInsetKey.self] = newValue }
    }
    var mapControlsTopInset: CGFloat {
        get { self[MapControlsTopInsetKey.self] }
        set { self[MapControlsTopInsetKey.self] = newValue }
    }
}

struct RouteCameraState: Equatable {
    let center: CLLocationCoordinate2D
    let distance: CLLocationDistance
    let heading: CLLocationDirection
    let pitch: CGFloat

    var isUsable: Bool {
        CLLocationCoordinate2DIsValid(center) && distance.isFinite && distance > 0
            && heading.isFinite && pitch.isFinite
    }

    static func == (lhs: RouteCameraState, rhs: RouteCameraState) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.distance == rhs.distance
            && lhs.heading == rhs.heading
            && lhs.pitch == rhs.pitch
    }
}

enum RouteMapCameraTarget: Equatable {
    case region(MKCoordinateRegion)
    case camera(RouteCameraState)

    static func == (lhs: RouteMapCameraTarget, rhs: RouteMapCameraTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.region(left), .region(right)):
            return left.center.latitude == right.center.latitude
                && left.center.longitude == right.center.longitude
                && left.span.latitudeDelta == right.span.latitudeDelta
                && left.span.longitudeDelta == right.span.longitudeDelta
        case let (.camera(left), .camera(right)):
            return left == right
        default:
            return false
        }
    }
}

struct RouteMapCameraCommand: Equatable {
    let id = UUID()
    let target: RouteMapCameraTarget
    var overridesUserCamera = false
}

struct RouteMapSnapshot {
    let routeSegments: [[CLLocationCoordinate2D]]
    let referenceSegments: [[CLLocationCoordinate2D]]
    let eventMarkers: [RouteEventMarker]
    let markerOffsets: [String: CGSize]
    let currentCoordinate: CLLocationCoordinate2D?
    let currentCourse: CLLocationDirection
    let currentState: TripState
    let theme: SpeedTheme
    var mapProvider: MapProvider = .openStreetMap
    var mapLanguageID: String? = nil
    var distanceLabelSize: RouteDistanceLabelSize = .two
    var sourcePointCount = 0
    var referenceMarkers: [ReferenceRouteMarker] = []
    var guidePoints: [RouteGuideMapPoint] = []
    var onGuideSelection: ((String) -> Void)? = nil
    var recordedSections: [VideoRouteSection] = []
    var onVideoSelection: (([UUID]) -> Void)? = nil
    var recordedDrawingGroups: [RouteDrawingGroup] = []
    var referenceDrawingGroups: [RouteDrawingGroup] = []
}

enum RouteMapRendererKind: Equatable {
    case legacyUIKit
    case modernSwiftUI
    case osmVector
}

enum RouteMapRendererSelector {
    static func kind(forMajorVersion majorVersion: Int, contentCount: Int = 0,
                     sourcePointCount: Int = 0, mapProvider: MapProvider = .apple) -> RouteMapRendererKind {
        // Long recordings use MKMapView's stable gesture camera. SwiftUI Map
        // can lose a user pinch while its large route snapshot updates.
        if mapProvider == .openStreetMap { return .osmVector }
        return majorVersion >= 17 && contentCount <= 500 && sourcePointCount < 5_000
            ? .modernSwiftUI : .legacyUIKit
    }
}

/// Camera telemetry is consumed by follow commands, not by the view layout.
/// Publishing every gesture/animation frame would rebuild all map content.
private final class RouteCameraTrackingState: ObservableObject {
    var userHasAdjustedCamera = false
    var currentCamera: RouteCameraState?
    var userCamera: RouteCameraState?
    var lastUserCameraChange: Date?
}

struct RouteMapView: View {
    @StateObject private var eventLayout = RouteEventMarkerLayoutCache()
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var remoteCamera: RemoteCameraController
    @ObservedObject var recorder: TripRecorder
    @ObservedObject var location: LocationMotionService
    @ObservedObject var routes: RouteArchiveStore
    @ObservedObject var referenceRoute: ReferenceRouteStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var subscription: SubscriptionStore
    let onShowPaywall: () -> Void
    let onRequestFinish: () -> Void

    @State private var cameraCommand = RouteMapCameraCommand(target: .region(RouteMapGeometry.fallbackRegion))
    @StateObject private var cameraTracking = RouteCameraTrackingState()
    @State private var isMapExpanded = false
    @State private var isReviewingGuide = false
    @State private var showingGuideStorageError = false
    @State private var guideSelection: RouteGuidePoint?
    @State private var fullscreenGuideSelection: RouteGuidePoint?
    @State private var guideLibraryRoute: ReferenceRoute?
    @State private var fullscreenGuideLibraryRoute: ReferenceRoute?
    @State private var videoSelection: VideoRecordingSelection?
    @State private var fullscreenVideoSelection: VideoRecordingSelection?
    @State private var showingDisableFollowConfirmation = false
    @State private var showingReferenceRouteMenu = false
    @State private var showingFullscreenReferenceRouteMenu = false

    init(recorder: TripRecorder, location: LocationMotionService, routes: RouteArchiveStore,
         referenceRoute: ReferenceRouteStore, settings: AppSettings, subscription: SubscriptionStore,
         onShowPaywall: @escaping () -> Void, onRequestFinish: @escaping () -> Void) {
        self.recorder = recorder
        self.location = location
        self.routes = routes
        self.referenceRoute = referenceRoute
        self.settings = settings
        self.subscription = subscription
        self.onShowPaywall = onShowPaywall
        self.onRequestFinish = onRequestFinish
        // Seed the native map with its real initial region. A fallback camera's
        // first callback can otherwise race the onAppear fit command.
        let initialRegion: MKCoordinateRegion
        if let route = referenceRoute.route, referenceRoute.isVisible {
            initialRegion = referenceRoute.display(for: route).region
        } else {
            initialRegion = RouteMapGeometry.region(fitting: recorder.displayPath.segments.flatMap { $0 })
        }
        var initialTarget = RouteMapCameraTarget.region(initialRegion)
#if DEBUG
        if ScreenshotState.requested != nil, ProcessInfo.processInfo.arguments.contains("--ui-map-compass") {
            initialTarget = .camera(RouteCameraState(center: initialRegion.center, distance: 4_000, heading: 45, pitch: 0))
        }
#endif
        _cameraCommand = State(initialValue: RouteMapCameraCommand(target: initialTarget))
    }

    private var points: [CLLocationCoordinate2D] {
        if !recorder.points.isEmpty { return recorder.displayPath.segments.flatMap { $0 } }
#if DEBUG
        if ScreenshotState.requested?.usesMockRoute == true { return Self.mockRoute }
#endif
        return []
    }

    private var routeSegments: [[CLLocationCoordinate2D]] {
        guard !recorder.points.isEmpty else {
#if DEBUG
            if ScreenshotState.requested?.usesMockRoute == true { return [Self.mockRoute] }
#endif
            return []
        }
        return recorder.displayPath.segments
    }

    private var referenceSegments: [[CLLocationCoordinate2D]] {
        guard referenceRoute.isVisible, let route = referenceRoute.route else { return [] }
        return referenceRoute.display(for: route).segments
    }

    private var referenceDrawingGroups: [RouteDrawingGroup] {
        guard referenceRoute.isVisible, let route = referenceRoute.route else { return [] }
        return referenceRoute.display(for: route).drawingGroups
    }

    private var referenceMarkers: [ReferenceRouteMarker] {
        guard referenceRoute.isVisible, let route = referenceRoute.route else { return [] }
        return referenceRoute.markers(for: route)
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        if let coordinate = location.coordinate { return coordinate }
        return points.last
    }

    private var currentCourse: CLLocationDirection {
        let course = location.latestLocation?.course ?? -1
        return course >= 0 ? course : RouteMapGeometry.heading(for: points)
    }

    private var followDirection: CLLocationDirection? {
        if recorder.state != .idle, points.count > 1 {
            return RouteMapGeometry.heading(for: points)
        }
        if let currentCoordinate, !referenceSegments.isEmpty {
            return RouteMapGeometry.heading(
                along: referenceSegments,
                nearestTo: currentCoordinate,
                preferredDirection: location.latestLocation?.course
            )
        }
        let course = location.latestLocation?.course ?? -1
        if course >= 0 { return course }
        return points.count > 1 ? RouteMapGeometry.heading(for: points) : nil
    }

    private var cameraCoordinates: [CLLocationCoordinate2D] {
        if recorder.state == .idle, recorder.points.isEmpty, !referenceSegments.isEmpty {
            return referenceSegments.flatMap { $0 }
        }
        guard let currentCoordinate else { return points }
        return points + [currentCoordinate]
    }

    private var eventMarkers: [RouteEventMarker] {
        recorder.mapEventMarkers
    }

    private var currentMetersPerSecond: Double {
        if location.latestLocation != nil { return location.metersPerSecond }
        return recorder.points.last?.metersPerSecond ?? 0
    }

    private var currentSpeedNumber: String {
        SpeedFormatter.number(
            currentMetersPerSecond,
            unit: settings.unit,
            decimals: settings.showDecimal
        )
    }

    private var currentSpeedText: String {
        currentSpeedNumber + " " + settings.unit.rawValue
    }

    private var averageSpeedText: String {
        return SpeedFormatter.number(recorder.averageSpeed, unit: settings.unit, decimals: settings.showDecimal)
            + " " + settings.unit.rawValue
    }

    private var tripDistanceText: String {
        guard recorder.state != .idle, referenceRoute.isVisible, let route = referenceRoute.route else {
            return SpeedFormatter.distance(recorder.distance)
        }
        return SpeedFormatter.routeDistance(recorder.distance, total: referenceRoute.display(for: route).distance)
    }

    private var shouldFollowCamera: Bool {
        if isReviewingGuide { return false }
#if DEBUG
        // Route/event QA states need the entire frozen fixture visible. The
        // dedicated follow override exercises live camera behavior in UI tests.
        if let requested = ScreenshotState.requested,
           requested.isMapRoute,
           !ProcessInfo.processInfo.arguments.contains("--ui-map-follow-camera"),
           requested != .mapFollowDisableConfirmation {
            return false
        }
#endif
        return settings.followLocationOnMap
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 650

            VStack(spacing: compact ? 8 : 10) {
                routeMap(cornerRadius: UIShape.card, showsExpandControl: true)
                    .frame(maxHeight: .infinity)

                HStack(spacing: 10) {
                    LiveRouteSpeedCard(
                        value: currentSpeedNumber,
                        unit: settings.unit.rawValue
                    )

                    LiveRouteSummaryCard(
                        duration: SpeedFormatter.duration(recorder.elapsed),
                        distance: tripDistanceText,
                        averageSpeed: averageSpeedText,
                        accent: AppPalette.brandAccent
                    )
                }
                .frame(height: 148)

                TripRecordingControls(
                    recorder: recorder,
                    location: location,
                    routes: routes,
                    settings: settings,
                    subscription: subscription,
                    onShowPaywall: onShowPaywall,
                    onRequestFinish: onRequestFinish
                )
            }
            .frame(maxWidth: 820, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.map")
#if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-long-route") {
                Text(verbatim: String(recorder.points.count))
                    .font(.system(size: 1)).opacity(0.01)
                    .accessibilityIdentifier("map.recorded-point-count")
                    .accessibilityValue(recorder.isReplayingSuppliedRoute ? "supplied" : "synthetic")
                    .allowsHitTesting(false)
            }
        }
#endif
        .onAppear {
            updateCamera()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--debug-map-free-browse-probe") ||
               ProcessInfo.processInfo.arguments.contains("--debug-map-longest-route") {
                Task { @MainActor in
                    let originalID = referenceRoute.selectedRouteID
                    let originalFollow = settings.followLocationOnMap
                    let originalCamera = cameraCommand
                    let useLongest = ProcessInfo.processInfo.arguments.contains("--debug-map-longest-route")
                    if useLongest, let longest = referenceRoute.routes.max(by: { $0.pointCount < $1.pointCount }) {
                        referenceRoute.select(longest.id)
                        settings.followLocationOnMap = false
                        cameraCommand = RouteMapCameraCommand(target: .region(referenceRoute.display(for: longest).region), overridesUserCamera: true)
                    }
                    defer {
                        if useLongest {
                            if let originalID { referenceRoute.select(originalID) }
                            settings.followLocationOnMap = originalFollow
                            cameraCommand = originalCamera
                        }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--debug-map-free-browse-probe") {
                        await verifyFreeBrowsingOnDevice()
                    } else {
                        // The existing native pan benchmark finishes after 19 seconds.
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                    }
                }
            }
            if ScreenshotState.requested?.rawValue.hasPrefix("map.guide") == true {
                if ScreenshotState.requested == .mapGuideFullscreen { isMapExpanded = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if ProcessInfo.processInfo.arguments.contains("--ui-guide-closeup"),
                       let point = referenceRoute.visibleGuidePoints.first { focusGuidePoint(point) }
                    if ScreenshotState.requested == .mapGuidePoint {
                        let prefix = "--ui-guide-point-id="
                        let requestedID = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
                        guideSelection = referenceRoute.visibleGuidePoints.first(where: { $0.id == requestedID }) ?? referenceRoute.visibleGuidePoints.first
                    } else if ScreenshotState.requested == .mapGuideLibrary || ScreenshotState.requested == .mapGuideReplace {
                        guideLibraryRoute = referenceRoute.route
                    }
                }
            }
            if ScreenshotState.requested == .mapVideoSectionsFullscreen || ScreenshotState.requested == .mapRouteFullscreen || ScreenshotState.requested == .mapRouteProgressFullscreen || ScreenshotState.requested == .mapCameraFullscreenReady || ScreenshotState.requested == .mapCameraFullscreenRecording {
                isMapExpanded = true
            } else if ScreenshotState.requested == .mapFollowDisableConfirmation {
                showingDisableFollowConfirmation = true
            } else if ScreenshotState.requested == .mapReferenceRouteMenu {
                Task { @MainActor in
                    await Task.yield()
                    showingReferenceRouteMenu = true
                }
            } else if ScreenshotState.requested == .mapReferenceRouteFullscreenMenu {
                isMapExpanded = true
            }
            // Device screenshot QA preserves the existing recorder and route library.
            if ProcessInfo.processInfo.arguments.contains("--debug-map-expanded") {
                isMapExpanded = true
            }
#endif
        }
        .onChange(of: recorder.videoRecordings) { videos in
#if DEBUG
            if ScreenshotState.requested == .mapVideoInfo, !videos.isEmpty {
                videoSelection = VideoRecordingSelection(recordingIDs: [videos[0].id])
            }
#endif
        }
        .onChange(of: recorder.points.count) { _ in updateCamera() }
        .onChange(of: recorder.state) { _ in updateCamera() }
        .onReceive(location.$latestLocation.compactMap { $0 }) { _ in updateCamera() }
        .onChange(of: settings.followLocationOnMap) { enabled in
            if enabled { isReviewingGuide = false; updateCamera() }
        }
        .fullScreenCover(isPresented: $isMapExpanded) {
            expandedMap
                .sheet(item: $fullscreenGuideSelection) { RouteGuidePointSheet(point: $0) }
                .sheet(item: $fullscreenGuideLibraryRoute) { route in
                    RouteGuideLibrarySheet(store: referenceRoute, route: route, onFocus: focusGuidePoint)
                }
                .sheet(item: $fullscreenVideoSelection) { selection in
                    VideoRecordingInfoSheet(recordings: recorder.videoRecordings.filter { selection.recordingIDs.contains($0.id) })
                }
        }
        .sheet(item: $guideSelection) { RouteGuidePointSheet(point: $0) }
        .sheet(item: $guideLibraryRoute) { route in
            RouteGuideLibrarySheet(store: referenceRoute, route: route, onFocus: focusGuidePoint)
        }
        .sheet(item: $videoSelection) { selection in
            VideoRecordingInfoSheet(recordings: recorder.videoRecordings.filter { selection.recordingIDs.contains($0.id) })
        }
        .overlay {
            if showingDisableFollowConfirmation, !isMapExpanded {
                disableFollowConfirmation
            }
        }
    }

    private func routeMap(
        cornerRadius: CGFloat,
        showsExpandControl: Bool,
        showsReferenceRouteControls: Bool = true
    ) -> some View {
        let markerOffsets = eventLayout.prepare(eventMarkers)
        let snapshot = RouteMapSnapshot(
            routeSegments: routeSegments,
            referenceSegments: referenceSegments,
            eventMarkers: eventMarkers,
            markerOffsets: markerOffsets,
            currentCoordinate: currentCoordinate,
            currentCourse: currentCourse,
            currentState: recorder.state,
            theme: settings.theme,
            mapProvider: settings.mapProvider,
            mapLanguageID: settings.mapLanguageID,
            distanceLabelSize: settings.distanceLabelSize,
            sourcePointCount: max(recorder.points.count,
                                  referenceRoute.isVisible ? referenceRoute.route?.pointCount ?? 0 : 0),
            referenceMarkers: referenceMarkers,
            guidePoints: referenceRoute.visibleGuideMapPoints,
            onGuideSelection: { id in
                guard let route = referenceRoute.route,
                      let point = referenceRoute.guide(for: route)?.points.first(where: { $0.id == id }) else { return }
                if isMapExpanded { fullscreenGuideSelection = point }
                else { guideSelection = point }
            },
            recordedSections: recorder.videoDisplay.sections,
            onVideoSelection: { ids in
                guard !ids.isEmpty else { return }
                if isMapExpanded { fullscreenVideoSelection = VideoRecordingSelection(recordingIDs: ids) }
                else { videoSelection = VideoRecordingSelection(recordingIDs: ids) }
            },
            recordedDrawingGroups: recorder.videoDisplay.sections.isEmpty ? recorder.displayPath.drawingGroups : recorder.videoDisplay.drawingGroups,
            referenceDrawingGroups: referenceDrawingGroups
        )
        return PlatformRouteMapSurface(
            snapshot: snapshot,
            cameraCommand: cameraCommand,
            onCameraChanged: { camera, region, user in
                guard showsExpandControl != isMapExpanded else { return }
                cameraDidChange(camera, region, user)
            },
            onCameraSettled: { camera, region, user in
                guard showsExpandControl != isMapExpanded else { return }
                cameraDidSettle(camera, region, user)
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.live-route")
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 8) {
                if showsReferenceRouteControls {
                    referenceRouteControls(menuIsPresented: $showingReferenceRouteMenu)
                }
                Spacer(minLength: 0)
                if showsExpandControl && remoteCamera.showsRemote { cameraCaptureControls }
            }
            .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            if showsExpandControl {
                VStack(spacing: 8) {
                    if remoteCamera.showsRemote { RemoteCameraMapControls(showsCapture: false, showsInformation: true) }
                    followLocationButton
                    CircularIconButton(
                        systemName: "arrow.up.left.and.arrow.down.right",
                        accessibilityLabel: L10n.tr("tab_map_title"),
                        tint: AppPalette.brandAccent
                    ) {
                        isMapExpanded = true
                    }
                    .accessibilityIdentifier("map.expand")
                }
                .padding(10)
            }
        }
    }

    private var expandedMap: some View {
        GeometryReader { geometry in
            expandedMapContent(topInset: geometry.safeAreaInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    routeMap(cornerRadius: 0, showsExpandControl: false, showsReferenceRouteControls: false)
                        .environment(\.mapControlsTopInset, geometry.safeAreaInsets.top)
                        .environment(\.mapScaleTopInset, settings.mapProvider == .openStreetMap ?
                            68 : 0)
                        .environment(\.mapShowsAttribution, false)
                        // The map fills the screen; interactive overlays keep safe-area bounds.
                        .frame(width: geometry.size.width,
                               height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
                        .position(x: geometry.size.width / 2,
                                  y: (geometry.size.height + geometry.safeAreaInsets.bottom - geometry.safeAreaInsets.top) / 2)
                }
        }
    }

    private func expandedMapContent(topInset: CGFloat) -> some View {
        ZStack {
            if settings.mapProvider == .openStreetMap && colorScheme == .dark {
                // Keep light status items readable while leaving the map visible around the island.
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset + 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    referenceRouteControls(menuIsPresented: $showingFullscreenReferenceRouteMenu)
                        .frame(maxWidth: 260, alignment: .leading)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 0) {
                        if settings.mapProvider == .openStreetMap {
                            OpenStreetMapAttribution(compact: true)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if remoteCamera.showsRemote {
                            // OSM compass now owns the slot below the credit;
                            // capture stays beneath it with permanent clearance.
                            cameraCaptureControls
                                .padding(.top, settings.mapProvider == .openStreetMap ? 12 : 0)
                        }
                    }
                }

                Spacer(minLength: 0)

                ExpandedMapPanel(
                    settings: settings,
                    speed: currentSpeedText,
                    duration: SpeedFormatter.duration(recorder.elapsed),
                    distance: tripDistanceText,
                    averageSpeed: averageSpeedText
                ) {
                    fullscreenMapActions
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)


            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.map.fullscreen")
        .onAppear {
#if DEBUG
            if ScreenshotState.requested == .mapReferenceRouteFullscreenMenu {
                Task { @MainActor in
                    await Task.yield()
                    showingFullscreenReferenceRouteMenu = true
                }
            }
#endif
        }
        .overlay {
            if showingDisableFollowConfirmation {
                disableFollowConfirmation
            }
        }
    }

    private var fullscreenMapActions: some View {
        VStack(spacing: 8) {
            if remoteCamera.showsRemote {
                RemoteCameraMapControls(showsCapture: false, showsInformation: true)
            }
            followLocationButton
            CircularIconButton(
                systemName: "arrow.down.right.and.arrow.up.left",
                accessibilityLabel: L10n.tr("common_close"),
                tint: AppPalette.brandAccent
            ) {
                showingFullscreenReferenceRouteMenu = false
                isMapExpanded = false
            }
            .accessibilityIdentifier("map.collapse")
        }
    }

    private var cameraCaptureControls: some View {
        // MapKit owns the compass in the upper trailing corner on both map
        // renderers. Keep a permanent slot for its 44-point control plus a gap,
        // even while north-up hides it, so capture never overlaps or jumps.
        RemoteCameraMapControls().padding(.top, 64)
    }

    private var followLocationButton: some View {
        CircularIconButton(
            systemName: settings.followLocationOnMap && !isReviewingGuide ? "location.fill" : "location",
            accessibilityLabel: L10n.tr("map_follow_location"),
            tint: settings.followLocationOnMap && !isReviewingGuide ? AppPalette.brandAccent : .secondary
        ) {
            if isReviewingGuide {
                isReviewingGuide = false
                settings.followLocationOnMap = true
                updateCamera()
            } else if settings.followLocationOnMap {
                showingDisableFollowConfirmation = true
            } else {
                settings.followLocationOnMap = true
            }
        }
        .accessibilityValue(L10n.tr(settings.followLocationOnMap && !isReviewingGuide ? "common_on" : "common_off"))
        .accessibilityIdentifier("map.follow-location")
    }

    private var disableFollowConfirmation: some View {
        DestructiveConfirmationModal(
            title: L10n.tr("map_follow_disable_title"),
            message: L10n.tr("map_follow_disable_message"),
            confirmLabel: L10n.tr("map_follow_disable_confirm"),
            confirmRole: .neutral,
            systemName: "location.slash.fill",
            onCancel: { showingDisableFollowConfirmation = false },
            onConfirm: {
                settings.followLocationOnMap = false
                showingDisableFollowConfirmation = false
            }
        )
        .accessibilityIdentifier("map.follow-location.disable-confirmation")
    }

    @ViewBuilder private func referenceRouteControls(menuIsPresented: Binding<Bool>) -> some View {
        if let route = referenceRoute.route {
            HStack(spacing: 4) {
                Button {
                    menuIsPresented.wrappedValue = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: PlatformSymbol.name(referenceRoute.isVisible ? "eye.fill" : "eye.slash.fill"))
                            .foregroundStyle(AppPalette.brandAccent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(route.name)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            Text(SpeedFormatter.distance(referenceRoute.display(for: route).distance))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: PlatformSymbol.name("chevron.down"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(route.name)
                .accessibilityValue(
                    "\(L10n.tr("reference_route_options")), \(L10n.tr(referenceRoute.isVisible ? "common_on" : "common_off"))"
                )
                .accessibilityIdentifier("map.reference-route.menu")
                .popover(isPresented: menuIsPresented, arrowEdge: .top) {
                    referenceRouteMenu
                        .platformPopoverPresentation()
                }

                Button(action: focusReferenceRoute) {
                    Image(systemName: PlatformSymbol.name("scope"))
                        .font(.body.weight(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("reference_route_focus"))
                .accessibilityIdentifier("map.reference-route.focus")
            }
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
    }

    private var referenceRouteMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.tr("reference_route_show"), isOn: $referenceRoute.isVisible)
                .tint(AppPalette.brandAccent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("map.reference-route.visibility")

            if let route = referenceRoute.route, route.supportsDistanceMarkers {
                Toggle(L10n.tr("reference_route_distance_marks"), isOn: $referenceRoute.showsDistanceMarkers)
                    .tint(AppPalette.brandAccent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("map.reference-route.distance-markers")
                ReferenceRouteDirectionControl(store: referenceRoute, route: route)
            }

            if let route = referenceRoute.route {
                if referenceRoute.guide(for: route) != nil {
                    Toggle(L10n.tr("route_guide_show"), isOn: Binding(
                        get: { referenceRoute.isGuideEnabled(for: route) },
                        set: { if !referenceRoute.setGuideEnabled($0, for: route) { showingGuideStorageError = true } }
                    ))
                    .tint(AppPalette.brandAccent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("map.route-guide.enabled")
                }
                Button {
                    showingReferenceRouteMenu = false
                    showingFullscreenReferenceRouteMenu = false
                    // Present from the owning map after its popover has dismissed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if isMapExpanded { fullscreenGuideLibraryRoute = route }
                        else { guideLibraryRoute = route }
                    }
                } label: {
                    Label(L10n.tr("route_guide_title"), systemImage: "mappin.and.ellipse")
                        .frame(minHeight: 44)
                }.accessibilityIdentifier("map.route-guide.open")
            }
            Divider()
            Text(L10n.tr("reference_routes_imported"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if referenceRoute.routes.count <= 3 {
                referenceRouteMenuRows
            } else {
                ScrollView { referenceRouteMenuRows }
                    .frame(height: 208)
            }
        }
        .font(.subheadline)
        .padding(12)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.reference-route.menu-panel")
        .alert(L10n.tr("route_guide_title"), isPresented: $showingGuideStorageError) {
            Button(L10n.tr("common_ok"), role: .cancel) { }
        } message: { Text(L10n.tr("route_guide_import_error")) }
    }

    private var referenceRouteMenuRows: some View {
        VStack(spacing: 2) {
            ForEach(referenceRoute.routes) { candidate in
                Button { selectReferenceRoute(candidate) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: PlatformSymbol.name(candidate.id == referenceRoute.selectedRouteID ? "checkmark.circle.fill" : "circle"))
                            .foregroundStyle(candidate.id == referenceRoute.selectedRouteID ? AppPalette.brandAccent : Color.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(SpeedFormatter.distance(referenceRoute.display(for: candidate).distance))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(candidate.id == referenceRoute.selectedRouteID ? AppPalette.brandAccent.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(candidate.id == referenceRoute.selectedRouteID ? L10n.tr("reference_routes_selected") : "")
                .accessibilityIdentifier("map.reference-route.option.\(candidate.id.uuidString)")
            }
        }
    }


#if DEBUG
    /// Uses the installed route and real map, without seeding GPS or touching trips.
    @MainActor private func verifyFreeBrowsingOnDevice() async {
        guard ScreenshotState.requested == nil, recorder.state == .idle,
              let route = referenceRoute.route, referenceRoute.isVisible else { return }
        let originalFollow = settings.followLocationOnMap
        let originalCommand = cameraCommand
        defer {
            settings.followLocationOnMap = originalFollow
            cameraCommand = originalCommand
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        settings.followLocationOnMap = false
        try? await Task.sleep(nanoseconds: 500_000_000)
        let region = referenceRoute.display(for: route).region
        cameraCommand = RouteMapCameraCommand(target: .region(region), overridesUserCamera: true)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let observed = cameraTracking.currentCamera else { return }
        let browse = RouteCameraState(center: CLLocationCoordinate2D(
            latitude: observed.center.latitude + 0.25, longitude: observed.center.longitude + 0.3),
            distance: observed.distance, heading: observed.heading, pitch: observed.pitch)
        cameraCommand = RouteMapCameraCommand(target: .camera(browse), overridesUserCamera: true)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let settled = cameraTracking.currentCamera else { return }
        for _ in 0..<15 {
            updateCamera() // Same callback as incoming GPS/trip updates.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let retained = cameraTracking.currentCamera else { return }
        func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        settings.followLocationOnMap = true
        updateCamera()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        var report: [String: Any] = ["finished_at": ISO8601DateFormatter().string(from: Date()),
            "free_browse_drift_m": distance(settled.center, retained.center),
            "source_point_count": route.pointCount,
            "rendered_point_count": referenceRoute.display(for: route).segments.reduce(0) { $0 + $1.count },
            "route_distance_m": route.distance,
            "original_follow_restored": originalFollow]
        if let location = currentCoordinate, let camera = cameraTracking.currentCamera {
            report["follow_distance_m"] = distance(location, camera.center)
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("map-free-browse-profile.json"), options: .atomic)
        }
    }
#endif

    private func updateCamera(now: Date = Date()) {
#if DEBUG
        if ScreenshotState.requested != nil, ProcessInfo.processInfo.arguments.contains("--ui-map-compass") {
            cameraCommand = RouteMapCameraCommand(target: .camera(RouteCameraState(
                center: RouteMapGeometry.region(fitting: cameraCoordinates).center,
                distance: 4_000, heading: 45, pitch: 0)))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-reference-marker-closeup"), let route = referenceRoute.route {
            cameraCommand = RouteMapCameraCommand(target: .region(referenceRoute.display(for: route).region))
            return
        }
#endif
        // GPS/trip updates redraw content without repositioning a free map.
        // Initial framing is seeded in init; explicit route focus is independent.
        guard shouldFollowCamera else { return }
        if currentCoordinate != nil, cameraTracking.currentCamera != nil {
            guard RouteMapCameraPolicy.shouldApplyAutomaticFollow(
                lastUserCameraChange: cameraTracking.lastUserCameraChange,
                now: now
            ) else { return }
            followCurrentLocation()
            return
        }
        guard RouteMapCameraPolicy.shouldAutomaticallyFit(
            hasCoordinates: !cameraCoordinates.isEmpty,
            userHasAdjustedCamera: cameraTracking.userHasAdjustedCamera,
            positionIsUserControlled: false,
            tripState: recorder.state
        ) else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraCommand = RouteMapCameraCommand(target: .region(RouteMapGeometry.region(fitting: cameraCoordinates)))
        }
    }

    private func followCurrentLocation(preserving camera: RouteCameraState? = nil) {
        guard shouldFollowCamera,
              let currentCoordinate,
              let camera = camera ?? RouteMapCameraPolicy.followCamera(
                userCamera: cameraTracking.userCamera,
                command: cameraCommand,
                observedCamera: cameraTracking.currentCamera
              ) else { return }
        let followedCamera = RouteMapCameraPolicy.followedCamera(
            preserving: camera,
            location: currentCoordinate,
            direction: followDirection
        )
        withAnimation(.easeInOut(duration: RouteMapCameraPolicy.followAnimationDuration)) {
            cameraCommand = RouteMapCameraCommand(target: .camera(followedCamera))
        }
    }

    private func cameraDidChange(_ camera: RouteCameraState, _: MKCoordinateRegion, _ positionedByUser: Bool) {
        guard camera.isUsable else { return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-map-compass"), abs(camera.heading - 45) < 0.1 {
            let ready = FileManager.default.temporaryDirectory.appendingPathComponent("map-compass-ready")
            if !FileManager.default.fileExists(atPath: ready.path) { try? Data("ready".utf8).write(to: ready, options: .atomic) }
        }
#endif
        cameraTracking.currentCamera = camera
        guard positionedByUser else { return }
        cameraTracking.userHasAdjustedCamera = true
        cameraTracking.userCamera = camera
        cameraTracking.lastUserCameraChange = Date()
    }

    private func cameraDidSettle(_ camera: RouteCameraState, _: MKCoordinateRegion, _ positionedByUser: Bool) {
        guard camera.isUsable else { return }
        cameraTracking.currentCamera = camera
        guard positionedByUser else { return }
        cameraTracking.userHasAdjustedCamera = true
        cameraTracking.userCamera = camera
        cameraTracking.lastUserCameraChange = Date()
        // Retain the completed user camera as the latest command as well as
        // local state. If SwiftUI recreates the Map after a trip-state change,
        // onAppear now restores the user's zoom instead of an older fit region.
        cameraCommand = RouteMapCameraCommand(target: .camera(camera))
    }

    private func focusGuidePoint(_ point: RouteGuidePoint) {
        isReviewingGuide = true
        if let route = referenceRoute.route { _ = referenceRoute.setGuideEnabled(true, for: route) }
        referenceRoute.isVisible = true
        cameraTracking.userHasAdjustedCamera = true
        cameraCommand = RouteMapCameraCommand(
            target: .camera(RouteCameraState(center: point.coordinate, distance: 1_200, heading: 0, pitch: 0)),
            overridesUserCamera: true
        )
    }

    private func focusReferenceRoute() {
        guard let route = referenceRoute.route else { return }
        if !referenceRoute.isVisible { referenceRoute.isVisible = true }
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraCommand = RouteMapCameraCommand(
                target: .region(referenceRoute.display(for: route).region),
                overridesUserCamera: true
            )
        }
    }

    private func selectReferenceRoute(_ route: ReferenceRoute) {
        isReviewingGuide = false
        referenceRoute.select(route.id)
        showingReferenceRouteMenu = false
        showingFullscreenReferenceRouteMenu = false
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraCommand = RouteMapCameraCommand(
                target: .region(referenceRoute.display(for: route).region),
                overridesUserCamera: true
            )
        }
    }

    static let mockRoute: [CLLocationCoordinate2D] = {
#if DEBUG
        if let coordinates = ScreenshotCityFixture.coordinates { return coordinates }
#endif
        return [
        .init(latitude: 53.8995, longitude: 27.5520), .init(latitude: 53.9010, longitude: 27.5555),
        .init(latitude: 53.9030, longitude: 27.5580), .init(latitude: 53.9053, longitude: 27.5632),
        .init(latitude: 53.9068, longitude: 27.5680), .init(latitude: 53.90675, longitude: 27.56812),
        .init(latitude: 53.9058, longitude: 27.5703), .init(latitude: 53.9049, longitude: 27.5720)
        ]
    }()
}

/// Retain camera intent when a growing route crosses the native-renderer budget.
final class RouteMapRendererContinuity: ObservableObject {
    var camera: RouteCameraState?
    private var previousKind: RouteMapRendererKind?
    private var requestedID: UUID?
    private var restoration: RouteMapCameraCommand?
    func command(kind: RouteMapRendererKind, requested: RouteMapCameraCommand) -> RouteMapCameraCommand {
        let hasNewRequest = requestedID != requested.id
        if hasNewRequest { restoration = nil; requestedID = requested.id }
        // Selecting a new large route can change renderer and issue a fit in
        // the same update. That explicit command wins over the old viewport.
        if !hasNewRequest, let previousKind, previousKind != kind, let camera {
            restoration = RouteMapCameraCommand(target: .camera(camera), overridesUserCamera: true)
        }
        previousKind = kind
        return restoration ?? requested
    }
}

final class RouteEventMarkerLayoutCache: ObservableObject {
    private var markers: [RouteEventMarker] = []
    private var offsets: [String: CGSize] = [:]
    private(set) var preparationCount = 0
    func prepare(_ next: [RouteEventMarker]) -> [String: CGSize] {
        if markers != next {
            markers = next; offsets = RouteEventMarkers.visualOffsets(for: next); preparationCount += 1
        }
        return offsets
    }
}

private struct OpenStreetMapAttribution: View {
    var targetAlignment: Alignment = .bottom
    var compact = false
    @State private var showingSources = false

    @ViewBuilder var body: some View {
        if compact {
            Button { showingSources = true } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: "© OpenMapTiles")
                    Text(verbatim: "© OpenStreetMap")
                }
                .font(.system(size: 10))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(minHeight: 44, alignment: .trailing)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "© OpenMapTiles, © OpenStreetMap contributors"))
            .accessibilityIdentifier("map.openstreetmap-attribution")
            .sheet(isPresented: $showingSources) {
                NavigationView {
                    List {
                        Link("© OpenMapTiles", destination: URL(string: "https://openmaptiles.org/")!)
                            .frame(minHeight: 44)
                        Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                            .frame(minHeight: 44)
                    }
                    .navigationTitle("OpenStreetMap / OpenMapTiles")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(L10n.tr("common_close")) { showingSources = false }
                        }
                    }
                }
                .navigationViewStyle(.stack)
            }
        } else {
        HStack(spacing: 5) {
            Link("© OpenMapTiles", destination: URL(string: "https://openmaptiles.org/")!)
            Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
        }
            .font(.system(size: 10))
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
            // Keep a 44-point target while aligning the visible credit to its host.
            .frame(minHeight: 44, alignment: targetAlignment)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map.openstreetmap-attribution")
        }
    }
}

private struct PlatformRouteMapSurface: View {
    @Environment(\.mapShowsAttribution) private var showsAttribution
    @StateObject private var continuity = RouteMapRendererContinuity()
    @ObservedObject private var offlineMaps = OfflineMapStore.shared
    private static var forceLegacyRenderer: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-legacy-map")
#else
        false
#endif
    }

    let snapshot: RouteMapSnapshot
    let cameraCommand: RouteMapCameraCommand
    let onCameraChanged: (RouteCameraState, MKCoordinateRegion, Bool) -> Void
    let onCameraSettled: (RouteCameraState, MKCoordinateRegion, Bool) -> Void

    @ViewBuilder
    var body: some View {
        let contentCount = snapshot.guidePoints.count + snapshot.referenceSegments.count
            + (snapshot.recordedSections.isEmpty ? snapshot.routeSegments.count : snapshot.recordedSections.count)
        let kind = Self.forceLegacyRenderer && snapshot.mapProvider == .apple ? RouteMapRendererKind.legacyUIKit
            : RouteMapRendererSelector.kind(
                forMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                contentCount: contentCount,
                sourcePointCount: snapshot.sourcePointCount,
                mapProvider: snapshot.mapProvider
            )
        let command = continuity.command(kind: kind, requested: cameraCommand)
        Group {
        if kind == .osmVector {
            VectorRouteMapSurface(snapshot: snapshot, cameraCommand: command,
                languageID: offlineMaps.selectedLanguageID ?? snapshot.mapLanguageID ?? L10n.locale.identifier,
                frozenStyleURL: OSMMapStyle.permitsNetwork ? offlineMaps.selectedStyleURL : nil,
                onCameraChanged: { state, region, user in continuity.camera = state; onCameraChanged(state, region, user) },
                onCameraSettled: { state, region, user in continuity.camera = state; onCameraSettled(state, region, user) })
        } else if #available(iOS 17.0, *), kind == .modernSwiftUI {
            ModernRouteMapSurface(
                snapshot: snapshot,
                cameraCommand: command,
                onCameraChanged: { state, region, user in continuity.camera = state; onCameraChanged(state, region, user) },
                onCameraSettled: { state, region, user in continuity.camera = state; onCameraSettled(state, region, user) }
            )
        } else {
            LegacyRouteMapSurface(
                snapshot: snapshot,
                cameraCommand: command,
                onCameraChanged: { state, region, user in continuity.camera = state; onCameraChanged(state, region, user) },
                onCameraSettled: { state, region, user in continuity.camera = state; onCameraSettled(state, region, user) }
            )
        }
        }
        .overlay(alignment: .bottomLeading) {
            if snapshot.mapProvider == .openStreetMap, showsAttribution {
                OpenStreetMapAttribution().padding(.leading, 10).padding(.bottom, 8)
            }
        }
#if DEBUG
        .overlay(alignment: .bottomLeading) {
            if snapshot.mapProvider == .apple, let fixture = ScreenshotCityFixture.current {
                Link(fixture.attribution, destination: fixture.fixMapURL)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.white.opacity(0.9))
                    .padding(.leading, 10).padding(.bottom, 28)
            }
        }
#endif
    }
}

struct RoutePreviewMapSurface: View {
    var mapProvider: MapProvider = .openStreetMap
    var mapLanguageID: String? = nil
    var sourcePointCount = 0
    @StateObject private var eventLayout = RouteEventMarkerLayoutCache()
    let routeSegments: [[CLLocationCoordinate2D]]
    let eventMarkers: [RouteEventMarker]
    let theme: SpeedTheme
    let region: MKCoordinateRegion
    var recordedSections: [VideoRouteSection] = []
    var onVideoSelection: (([UUID]) -> Void)? = nil
    var drawingGroups: [RouteDrawingGroup] = []
    @State private var retainedCommand: RouteMapCameraCommand?

    private var initialCommand: RouteMapCameraCommand {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-map-compass") {
            return RouteMapCameraCommand(target: .camera(RouteCameraState(
                center: region.center, distance: 600, heading: 45, pitch: 0)))
        }
#endif
        return RouteMapCameraCommand(target: .region(region))
    }

    var body: some View {
        PlatformRouteMapSurface(
            snapshot: RouteMapSnapshot(
                routeSegments: routeSegments,
                referenceSegments: [],
                eventMarkers: eventMarkers,
                markerOffsets: eventLayout.prepare(eventMarkers),
                currentCoordinate: nil,
                currentCourse: 0,
                currentState: .idle,
                theme: theme,
                mapProvider: mapProvider,
                mapLanguageID: mapLanguageID,
                sourcePointCount: sourcePointCount,
                recordedSections: recordedSections,
                onVideoSelection: onVideoSelection,
                recordedDrawingGroups: drawingGroups
            ),
            cameraCommand: retainedCommand ?? initialCommand,
            onCameraChanged: { _, _, _ in },
            onCameraSettled: { _, _, _ in }
        )
        .onAppear { if retainedCommand == nil { retainedCommand = initialCommand } }
    }
}

/// Gesture and camera samples do not affect map content. Publishing these on
/// every frame can rebuild SwiftUI Map while its native pinch is still active.
private final class ModernMapCameraTrackingState: ObservableObject {
    var cameraSettleTask: Task<Void, Never>?
    var markerLayoutTask: Task<Void, Never>?
    var latestCamera: RouteCameraState?
    var latestRegion: MKCoordinateRegion?
    var isUserGestureActive = false
}

@available(iOS 17.0, *)
private struct ModernRouteMapSurface: View {
    @Environment(\.mapControlsTopInset) private var mapControlsTopInset
    let snapshot: RouteMapSnapshot
    let cameraCommand: RouteMapCameraCommand
    let onCameraChanged: (RouteCameraState, MKCoordinateRegion, Bool) -> Void
    let onCameraSettled: (RouteCameraState, MKCoordinateRegion, Bool) -> Void
    @State private var position: MapCameraPosition
    @StateObject private var tracking = ModernMapCameraTrackingState()
    @State private var referenceMarkerLayout = ReferenceMarkerLayoutState()
    @State private var showsGuideDetails = false
#if DEBUG
    @StateObject private var debugCamera = MapCameraDebugState()
#endif

    init(
        snapshot: RouteMapSnapshot,
        cameraCommand: RouteMapCameraCommand,
        onCameraChanged: @escaping (RouteCameraState, MKCoordinateRegion, Bool) -> Void,
        onCameraSettled: @escaping (RouteCameraState, MKCoordinateRegion, Bool) -> Void
    ) {
        self.snapshot = snapshot
        self.cameraCommand = cameraCommand
        self.onCameraChanged = onCameraChanged
        self.onCameraSettled = onCameraSettled
        _position = State(initialValue: Self.position(for: cameraCommand))
        let layout = ReferenceMarkerLayoutState()
        layout.distanceLabelSize = snapshot.distanceLabelSize
        _referenceMarkerLayout = State(initialValue: layout)
    }

    var body: some View {
        MapReader { proxy in
        Map(position: $position) {
            ForEach(Array(snapshot.referenceSegments.enumerated()), id: \.offset) { _, segment in
                if segment.count > 1 {
                    MapPolyline(coordinates: segment)
                        .stroke(
                            Color.blue.opacity(0.92),
                            style: StrokeStyle(lineWidth: 3.25, lineCap: .round, lineJoin: .round)
                        )
                }
            }

            if snapshot.recordedSections.isEmpty {
            ForEach(Array(snapshot.routeSegments.enumerated()), id: \.offset) { _, segment in
                if segment.count > 1 {
                    MapPolyline(coordinates: segment)
                        .stroke(
                            snapshot.theme.accent,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            } else {
                ForEach(snapshot.recordedSections) { section in
                    MapPolyline(coordinates: section.coordinates)
                        .stroke(section.recordingID == nil ? snapshot.theme.accent : snapshot.theme.videoRouteAccent,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
            }

            ForEach(snapshot.guidePoints) { point in
                Annotation(point.title, coordinate: point.coordinate, anchor: .bottomLeading) {
                    Button { snapshot.onGuideSelection?(point.id) } label: { RouteGuideMarker(point: point, showsDetails: showsGuideDetails) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(point.title)
                        .accessibilityIdentifier("map.guide-point.\(point.id)")
                }.annotationTitles(.hidden)
            }

            ForEach(snapshot.referenceMarkers) { marker in
                Annotation("", coordinate: marker.coordinate, anchor: .bottom) {
                    ReferenceRouteMarkerView(marker: marker, layout: referenceMarkerLayout).offset(y: 4)
                        .allowsHitTesting(false)
                }
            }

            ForEach(Array(snapshot.eventMarkers.enumerated()), id: \.element.id) { index, marker in
                Annotation("", coordinate: marker.coordinate, anchor: .center) {
                    RouteEventMarkerView(
                        marker: marker,
                        visualOffset: snapshot.markerOffsets[marker.id] ?? .zero,
                        theme: snapshot.theme
                    )
                    .allowsHitTesting(false)
                    .zIndex(Double(index + 1))
                }
            }

            if let currentCoordinate = snapshot.currentCoordinate {
                Annotation("", coordinate: currentCoordinate) {
                    CurrentLocationMarker(
                        theme: snapshot.theme,
                        course: snapshot.currentCourse,
                        mapHeading: position.camera?.heading ?? 0,
                        state: snapshot.currentState
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .simultaneousGesture(
            SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture(count: 1))
                .onEnded { value in
                    guard case .second(let tap) = value else { return }
                    if let point = snapshot.guidePoints.first(where: { point in
                        guard let position = proxy.convert(point.coordinate, to: .local) else { return false }
                        return hypot(position.x + 44 - tap.location.x, position.y - 22 - tap.location.y) <= 22
                    }) {
                        // Other route/event annotations may overlap the native
                        // button. Resolve a visible place first, as on MKMapView.
                        snapshot.onGuideSelection?(point.id)
                        return
                    }
                    let ids = VideoRouteHitTest.recordings(at: tap.location, sections: snapshot.recordedSections) { proxy.convert($0, to: .local) }
                    if !ids.isEmpty { snapshot.onVideoSelection?(ids) }
                }
        )
        .accessibilityAction(named: Text(L10n.tr("video_route_title"))) {
            snapshot.onVideoSelection?(Array(Set(snapshot.recordedSections.compactMap(\.recordingID))))
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        // The edge-to-edge SwiftUI map otherwise places its compass under the
        // status bar. MKMapView already accounts for this inset on iOS 15/16.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: mapControlsTopInset)
        }
        .onAppear { apply(cameraCommand) }
        // Consume the new value: a MapReader closure can retain the previous
        // command while its ID observation has already advanced.
        .onChange(of: cameraCommand) { command in apply(command) }
        .onChange(of: position.positionedByUser) { positionedByUser in
            guard positionedByUser else { return }
            publishPositionedUserCamera()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            let camera = RouteCameraState(
                center: context.camera.centerCoordinate,
                distance: context.camera.distance,
                heading: context.camera.heading,
                pitch: context.camera.pitch
            )
            guard camera.isUsable else { return }
            let region = context.region
            let gestureWasActive = tracking.isUserGestureActive
            // These samples are deliberately not published SwiftUI state:
            // gesture callbacks must see the current native camera immediately.
            tracking.latestCamera = camera
            tracking.latestRegion = region
            // MapProxy belongs to this MapReader update. Resolve its coordinates
            // now; an unstructured task can outlive that SwiftUI attribute graph.
            let layout = referenceMarkerLayout.prepare(markers: snapshot.referenceMarkers, heading: camera.heading) {
                proxy.convert($0, to: .local)
            }
            let showGuides = RouteGuideMapVisibility.showsDetails(distance: camera.distance, wasVisible: showsGuideDetails)
            tracking.markerLayoutTask?.cancel()
            tracking.markerLayoutTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                referenceMarkerLayout.apply(layout)
                if showsGuideDetails != showGuides { showsGuideDetails = showGuides }
            }
            publishCameraChange(camera, region: region, gestureWasActive: gestureWasActive)
#if DEBUG
            Task { @MainActor in debugCamera.span = region.span; debugCamera.center = region.center }
#endif
        }
        .overlay {
            MapGestureActivityObserver(
                onChanged: userCameraGestureChanged,
                onEnded: userCameraGestureEnded
            )
            .allowsHitTesting(false)
        }
#if DEBUG
        .overlay {
            MapCameraDebugProbe(state: debugCamera)
            if ProcessInfo.processInfo.arguments.contains("--ui-video-hit-probe"),
               let section = snapshot.recordedSections.last(where: { $0.recordingID != nil }),
               let coordinate = section.coordinates.dropFirst(section.coordinates.count / 2).first {
                NativeVideoHitProbe(coordinate: coordinate).allowsHitTesting(false)
            }
        }
#endif
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { referenceMarkerLayout.size = proxy.size }
                    .onChange(of: proxy.size) { referenceMarkerLayout.size = $0 }
            }
        }
        .onChange(of: snapshot.distanceLabelSize) { size in
            tracking.markerLayoutTask?.cancel()
            referenceMarkerLayout.distanceLabelSize = size
            referenceMarkerLayout.update(markers: snapshot.referenceMarkers, heading: tracking.latestCamera?.heading ?? 0) { proxy.convert($0, to: .local) }
        }
        .onChange(of: snapshot.referenceMarkers) { markers in
            tracking.markerLayoutTask?.cancel()
            referenceMarkerLayout.update(markers: markers, heading: tracking.latestCamera?.heading ?? 0) { proxy.convert($0, to: .local) }
        }
        .onDisappear {
            tracking.cameraSettleTask?.cancel()
            tracking.markerLayoutTask?.cancel()
        }
        }
    }

    private func apply(_ command: RouteMapCameraCommand) {
        guard !tracking.isUserGestureActive else { return }
        if case .camera(let requestedCamera) = command.target,
           requestedCamera == tracking.latestCamera { return }
        tracking.cameraSettleTask?.cancel()
        withAnimation(.easeInOut(duration: 0.45)) {
            switch command.target {
            case .region:
                guard command.overridesUserCamera || !position.positionedByUser else { return }
                position = Self.position(for: command)
            case .camera(let requestedCamera):
                // MapCameraPosition is the authoritative source during user
                // interaction. Even if the parent callback is one transaction
                // behind, an automatic follow command may recenter only; it
                // must not restore an older distance, heading, or pitch.
                if position.positionedByUser, let liveCamera = position.camera {
                    position = .camera(
                        MapCamera(
                            centerCoordinate: requestedCamera.center,
                            distance: liveCamera.distance,
                            heading: liveCamera.heading,
                            pitch: liveCamera.pitch
                        )
                    )
                } else {
                    position = Self.position(for: command)
                }
            }
        }
    }

    private func userCameraGestureChanged() {
        tracking.isUserGestureActive = true
        tracking.cameraSettleTask?.cancel()
        guard let latestCamera = tracking.latestCamera, let latestRegion = tracking.latestRegion else { return }
        onCameraChanged(latestCamera, latestRegion, true)
    }

    private func userCameraGestureEnded() {
        tracking.isUserGestureActive = false
        guard let latestCamera = tracking.latestCamera, let latestRegion = tracking.latestRegion else { return }
        onCameraChanged(latestCamera, latestRegion, true)
        scheduleCameraSettlement()
    }

    private func publishPositionedUserCamera() {
        guard let latestCamera = tracking.latestCamera, let latestRegion = tracking.latestRegion else { return }
        onCameraChanged(latestCamera, latestRegion, true)
        scheduleCameraSettlement()
    }

    private func publishCameraChange(
        _ camera: RouteCameraState,
        region: MKCoordinateRegion,
        gestureWasActive: Bool
    ) {
        // Native gesture tracking also covers frames before the binding marks
        // the camera as user-positioned.
        let positionedByUser = gestureWasActive || position.positionedByUser
        onCameraChanged(camera, region, positionedByUser)
        if positionedByUser {
            scheduleCameraSettlement()
        }
    }

    private func scheduleCameraSettlement() {
        tracking.cameraSettleTask?.cancel()
        tracking.cameraSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, !tracking.isUserGestureActive,
                  let latestCamera = tracking.latestCamera,
                  let latestRegion = tracking.latestRegion else { return }
            onCameraChanged(latestCamera, latestRegion, true)
            onCameraSettled(latestCamera, latestRegion, true)
        }
    }

    private static func position(for command: RouteMapCameraCommand) -> MapCameraPosition {
        switch command.target {
        case .region(let region):
            return .region(region)
        case .camera(let camera):
            return .camera(
                MapCamera(
                    centerCoordinate: camera.center,
                    distance: camera.distance,
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            )
        }
    }
}

private struct MapGestureActivityObserver: UIViewRepresentable {
    let onChanged: () -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.onMovedToWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            DispatchQueue.main.async { coordinator.attach(toMapsNear: view) }
        }
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.attach(toMapsNear: view)
        }
    }

    final class ObserverView: UIView {
        var onMovedToWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onMovedToWindow?()
        }
    }

    final class Coordinator: NSObject {
        var onChanged: () -> Void
        var onEnded: () -> Void
        private var observedGestureRecognizers = Set<ObjectIdentifier>()
        private var activeGestureRecognizers = Set<ObjectIdentifier>()

        init(onChanged: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(toMapsNear observer: UIView) {
            var ancestor = observer.superview
            while let candidate = ancestor {
                let countBefore = observedGestureRecognizers.count
                observeGestures(in: candidate, excluding: observer)
                if observedGestureRecognizers.count > countBefore { return }
                ancestor = candidate.superview
            }
        }

        private func observeGestures(in view: UIView, excluding observer: UIView) {
            guard view !== observer else { return }
            for gestureRecognizer in view.gestureRecognizers ?? [] {
                guard gestureRecognizer is UIPinchGestureRecognizer
                        || gestureRecognizer is UIPanGestureRecognizer
                        || gestureRecognizer is UIRotationGestureRecognizer else { continue }
                let identifier = ObjectIdentifier(gestureRecognizer)
                guard observedGestureRecognizers.insert(identifier).inserted else { continue }
                gestureRecognizer.addTarget(self, action: #selector(gestureChanged(_:)))
            }
            for subview in view.subviews {
                observeGestures(in: subview, excluding: observer)
            }
        }

        @objc private func gestureChanged(_ gestureRecognizer: UIGestureRecognizer) {
            let identifier = ObjectIdentifier(gestureRecognizer)
            switch gestureRecognizer.state {
            case .began, .changed:
                activeGestureRecognizers.insert(identifier)
                onChanged()
            case .ended, .cancelled, .failed:
                activeGestureRecognizers.remove(identifier)
                if activeGestureRecognizers.isEmpty { onEnded() }
            default:
                break
            }
        }
    }
}

struct LegacyRouteMapSurface: UIViewRepresentable {
    let snapshot: RouteMapSnapshot
    let cameraCommand: RouteMapCameraCommand
    let onCameraChanged: (RouteCameraState, MKCoordinateRegion, Bool) -> Void
    let onCameraSettled: (RouteCameraState, MKCoordinateRegion, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCameraChanged: onCameraChanged, onCameraSettled: onCameraSettled)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
#if DEBUG
        let cameraProbe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        cameraProbe.isAccessibilityElement = true
        cameraProbe.accessibilityIdentifier = "map.camera-span"
        cameraProbe.accessibilityLabel = "camera-span:0.0250000,0.0250000"
        cameraProbe.isUserInteractionEnabled = false
        mapView.addSubview(cameraProbe)
        context.coordinator.cameraProbe = cameraProbe
#endif
        context.coordinator.observeGestures(in: mapView)
        let videoTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.videoTapped(_:)))
        videoTap.cancelsTouchesInView = false
        videoTap.delegate = context.coordinator
        for gesture in mapView.gestureRecognizers ?? [] {
            if let tap = gesture as? UITapGestureRecognizer, tap.numberOfTapsRequired > 1 { videoTap.require(toFail: tap) }
        }
        mapView.addGestureRecognizer(videoTap)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.onCameraChanged = onCameraChanged
        context.coordinator.onCameraSettled = onCameraSettled
        context.coordinator.observeGestures(in: mapView)
        context.coordinator.render(snapshot, in: mapView)
        context.coordinator.apply(cameraCommand, to: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onCameraChanged: (RouteCameraState, MKCoordinateRegion, Bool) -> Void
        var onCameraSettled: (RouteCameraState, MKCoordinateRegion, Bool) -> Void
        private var lastCommandID: UUID?
        private var changeWasUserInitiated = false
        private var observedGestureRecognizers = Set<ObjectIdentifier>()
        private var annotationsByKey = [LegacyMapAnnotationKey: LegacyMapAnnotation]()
        private var annotationInputs: (guides: [RouteGuideMapPoint], references: [ReferenceRouteMarker], events: [RouteEventMarker], offsets: [String: CGSize], theme: SpeedTheme)?
        private var preparedRecordedRevisions: [UUID] = []
        private var preparedReferenceRevisions: [UUID] = []
        private var drawingRevisions: [String: UUID] = [:]
        private var overlaySignature: [String: [LegacyMapPolylineSignature]] = [:]
        private var routeOverlays: [String: MKMultiPolyline] = [:]
        private var recordedSections: [VideoRouteSection] = []
        private var onGuideSelection: ((String) -> Void)?
        private var onVideoSelection: (([UUID]) -> Void)?
        private var currentTheme = SpeedTheme.lime
        private let referenceMarkerLayout = ReferenceMarkerLayoutState()
        private var referenceMarkers: [ReferenceRouteMarker] = []
        private var showsGuideDetails = false
#if DEBUG
        weak var cameraProbe: UIView?
        private weak var videoProbe: UIView?
        private var panProbe: MapPanPerformanceProbe?
#endif

        init(
            onCameraChanged: @escaping (RouteCameraState, MKCoordinateRegion, Bool) -> Void,
            onCameraSettled: @escaping (RouteCameraState, MKCoordinateRegion, Bool) -> Void
        ) {
            self.onCameraChanged = onCameraChanged
            self.onCameraSettled = onCameraSettled
        }

        func render(_ snapshot: RouteMapSnapshot, in mapView: MKMapView) {
#if DEBUG
            let renderStarted = CACurrentMediaTime()
            defer { panProbe?.recordRender(seconds: CACurrentMediaTime() - renderStarted) }
#endif
            recordedSections = snapshot.recordedSections
            onVideoSelection = snapshot.onVideoSelection
            onGuideSelection = snapshot.onGuideSelection
            mapView.accessibilityCustomActions = recordedSections.contains(where: { $0.recordingID != nil })
                ? [UIAccessibilityCustomAction(name: L10n.tr("video_route_title"), target: self, selector: #selector(showAllVideos))] : []
#if DEBUG
            updateVideoProbe(in: mapView)
            if panProbe == nil, ProcessInfo.processInfo.arguments.contains("--debug-map-pan-probe") {
                panProbe = MapPanPerformanceProbe(map: mapView)
            }
#endif
            referenceMarkerLayout.distanceLabelSize = snapshot.distanceLabelSize
            referenceMarkers = snapshot.referenceMarkers
            referenceMarkerLayout.size = mapView.bounds.size
            updateReferenceMarkerLayout(in: mapView)
            renderOverlays(snapshot, in: mapView)
            updateGuideVisibility(in: mapView)

            // Route/guide annotations are immutable between imports, selections,
            // pauses and theme changes. A GPS fix updates only the live arrow.
            if let inputs = annotationInputs,
               inputs.guides == snapshot.guidePoints, inputs.references == snapshot.referenceMarkers,
               inputs.events == snapshot.eventMarkers, inputs.offsets == snapshot.markerOffsets,
               inputs.theme == snapshot.theme {
                updateCurrentAnnotation(snapshot, in: mapView)
                return
            }
            annotationInputs = (snapshot.guidePoints, snapshot.referenceMarkers, snapshot.eventMarkers, snapshot.markerOffsets, snapshot.theme)
            var desiredAnnotations = [LegacyMapAnnotationKey: LegacyMapAnnotation.Payload]()
            for marker in snapshot.eventMarkers {
                desiredAnnotations[.event(marker.id)] = .event(
                    marker,
                    snapshot.markerOffsets[marker.id] ?? .zero,
                    snapshot.theme
                )
            }
            for point in snapshot.guidePoints {
                desiredAnnotations[.guide(point.id)] = .guide(point)
            }
            for marker in snapshot.referenceMarkers {
                desiredAnnotations[.reference(marker.id)] = .reference(marker)
            }
            if let coordinate = snapshot.currentCoordinate {
                desiredAnnotations[.currentLocation] = .current(
                    coordinate,
                    snapshot.theme,
                    snapshot.currentCourse,
                    mapView.camera.heading,
                    snapshot.currentState
                )
            }

            let plan = LegacyMapAnnotationReconciliation.make(
                existing: Set(annotationsByKey.keys),
                desired: Set(desiredAnnotations.keys)
            )
            for key in plan.removed {
                guard let annotation = annotationsByKey.removeValue(forKey: key) else { continue }
                mapView.removeAnnotation(annotation)
            }
            for key in plan.retained {
                guard let annotation = annotationsByKey[key], let payload = desiredAnnotations[key] else { continue }
                update(annotation, payload: payload, in: mapView)
            }
            for key in plan.added {
                guard let payload = desiredAnnotations[key] else { continue }
                let annotation = LegacyMapAnnotation(key: key, payload: payload)
                annotationsByKey[key] = annotation
                mapView.addAnnotation(annotation)
            }
        }

        private func updateCurrentAnnotation(_ snapshot: RouteMapSnapshot, in map: MKMapView) {
            guard let coordinate = snapshot.currentCoordinate else {
                if let old = annotationsByKey.removeValue(forKey: .currentLocation) { map.removeAnnotation(old) }
                return
            }
            let payload = LegacyMapAnnotation.Payload.current(coordinate, snapshot.theme, snapshot.currentCourse,
                map.camera.heading, snapshot.currentState)
            if let annotation = annotationsByKey[.currentLocation] { update(annotation, payload: payload, in: map) }
            else {
                let annotation = LegacyMapAnnotation(key: .currentLocation, payload: payload)
                annotationsByKey[.currentLocation] = annotation; map.addAnnotation(annotation)
            }
        }

        private func renderOverlays(_ snapshot: RouteMapSnapshot, in mapView: MKMapView) {
            let themeChanged = currentTheme != snapshot.theme
            currentTheme = snapshot.theme
            let preparedRecorded = (snapshot.routeSegments.isEmpty && snapshot.recordedSections.isEmpty) || !snapshot.recordedDrawingGroups.isEmpty
            let preparedReference = snapshot.referenceSegments.isEmpty || !snapshot.referenceDrawingGroups.isEmpty
            if preparedRecorded && preparedReference && (!snapshot.recordedDrawingGroups.isEmpty || !snapshot.referenceDrawingGroups.isEmpty) {
                let recordedRevisions = snapshot.recordedDrawingGroups.map(\.revision)
                let referenceRevisions = snapshot.referenceDrawingGroups.map(\.revision)
                if !themeChanged && preparedRecordedRevisions == recordedRevisions && preparedReferenceRevisions == referenceRevisions { return }
                preparedRecordedRevisions = recordedRevisions
                preparedReferenceRevisions = referenceRevisions
                var next: [String: MKMultiPolyline] = [:]
                var revisions: [String: UUID] = [:]
                var previous: MKMultiPolyline?
                let groups = snapshot.referenceDrawingGroups.map { ("reference:" + $0.id, $0, LegacyMapPolylineKind.reference) }
                    + snapshot.recordedDrawingGroups.map { ("recorded:" + $0.id, $0, $0.isVideo ? .video : .recorded) }
                for (id, group, kind) in groups {
                    let line: MKMultiPolyline
                    if drawingRevisions[id] == group.revision, let cached = routeOverlays[id] { line = cached }
                    else {
                        let parts = group.segments.filter { $0.count > 1 }
                        guard !parts.isEmpty else { continue }
                        line = MKMultiPolyline(parts.map { MKPolyline(coordinates: $0, count: $0.count) })
                        line.title = kind.rawValue
                        if let previous { mapView.insertOverlay(line, above: previous) }
                        else { mapView.insertOverlay(line, at: 0, level: .aboveLabels) }
                    }
                    next[id] = line; revisions[id] = group.revision; previous = line
                }
                let retained = Set(next.values.map(ObjectIdentifier.init))
                mapView.removeOverlays(routeOverlays.values.filter { !retained.contains(ObjectIdentifier($0)) })
                routeOverlays = next; drawingRevisions = revisions; overlaySignature = [:]
                if themeChanged {
                    for line in next.values {
                        if let renderer = mapView.renderer(for: line) as? MKOverlayPathRenderer {
                            style(renderer, for: line); renderer.setNeedsDisplay()
                        }
                    }
                }
                return
            }
            drawingRevisions = [:]
            preparedRecordedRevisions = []; preparedReferenceRevisions = []
            var segments = snapshot.referenceSegments.enumerated().filter { $0.element.count > 1 }
                .map { (id: "reference:\($0.offset)", kind: LegacyMapPolylineKind.reference, coordinates: $0.element) }
            if snapshot.recordedSections.isEmpty {
                segments += snapshot.routeSegments.enumerated().filter { $0.element.count > 1 }
                    .map { (id: "recorded:\($0.offset)", kind: LegacyMapPolylineKind.recorded, coordinates: $0.element) }
            } else {
                segments += snapshot.recordedSections.map {
                    (id: "section:" + $0.id, kind: $0.recordingID == nil ? .recorded : .video, coordinates: $0.coordinates)
                }
            }
            // Preserve individual lines (including gaps) inside a bounded batch.
            // Group by SOURCE chunk so late video receipts do not shift all later
            // batches. Only the changed batch receives a new native renderer.
            var grouped: [String: (kind: LegacyMapPolylineKind, parts: [[CLLocationCoordinate2D]])] = [:]
            var order: [String] = []
            for segment in segments {
                let components = segment.id.split(separator: ":")
                let sourceIndex = components.count > 1 ? Int(components[1]) ?? 0 : 0
                let id = segments.count > 1000
                    ? "\(components.first ?? "route"):\(sourceIndex / 16):\(segment.kind.rawValue)" : segment.id
                if grouped[id] == nil { order.append(id); grouped[id] = (segment.kind, []) }
                grouped[id]!.parts.append(segment.coordinates)
            }
            var nextSignatures: [String: [LegacyMapPolylineSignature]] = [:]
            var nextOverlays: [String: MKMultiPolyline] = [:]
            var previous: MKMultiPolyline?
            for id in order {
                let group = grouped[id]!
                let signature = group.parts.map { LegacyMapPolylineSignature(kind: group.kind, coordinates: $0) }
                nextSignatures[id] = signature
                let polyline: MKMultiPolyline
                if overlaySignature[id] == signature, let retained = routeOverlays[id] {
                    polyline = retained
                } else {
                    polyline = MKMultiPolyline(group.parts.map { MKPolyline(coordinates: $0, count: $0.count) })
                    polyline.title = group.kind.rawValue
                    if let previous { mapView.insertOverlay(polyline, above: previous) }
                    else { mapView.insertOverlay(polyline, at: 0, level: .aboveLabels) }
                }
                nextOverlays[id] = polyline
                previous = polyline
            }
            let retained = Set(nextOverlays.values.map(ObjectIdentifier.init))
            mapView.removeOverlays(routeOverlays.values.filter { !retained.contains(ObjectIdentifier($0)) })
            routeOverlays = nextOverlays
            overlaySignature = nextSignatures

            if themeChanged {
                for overlay in mapView.overlays {
                    guard let renderer = mapView.renderer(for: overlay) as? MKOverlayPathRenderer else { continue }
                    style(renderer, for: overlay)
                    renderer.setNeedsDisplay()
                }
            }
        }

        private func update(
            _ annotation: LegacyMapAnnotation,
            payload: LegacyMapAnnotation.Payload,
            in mapView: MKMapView
        ) {
            if case .guide(let previous) = annotation.payload,
               case .guide(let current) = payload, previous == current { return }
            if case .reference(let previous) = annotation.payload,
               case .reference(let current) = payload, previous == current { return }
            let coordinate = payload.coordinate
            if annotation.coordinate.latitude != coordinate.latitude
                || annotation.coordinate.longitude != coordinate.longitude {
                annotation.coordinate = coordinate
            }
            annotation.payload = payload
            if case .reference(let marker) = payload,
               let view = mapView.view(for: annotation) as? LegacyReferenceMarkerAnnotationView {
                view.configure(referenceMarkerLayout.presentation(for: marker),
                               showsLabel: referenceMarkerLayout.labeledIDs.contains(marker.id), heading: referenceMarkerLayout.heading)
                return
            }
            guard let annotationView = mapView.view(for: annotation) as? LegacyMapAnnotationView else { return }
            configure(annotationView, for: annotation)
        }

        func apply(_ command: RouteMapCameraCommand, to mapView: MKMapView) {
            guard lastCommandID != command.id else { return }
            lastCommandID = command.id
            if containsActiveGesture(in: mapView) {
                // Discard any location-follow command created while the user is
                // pinching, panning, or rotating. The next accepted location
                // update will use the final user-selected camera instead.
                changeWasUserInitiated = true
                return
            }
            changeWasUserInitiated = false
            switch command.target {
            case .region(let region):
                mapView.setRegion(region, animated: true)
            case .camera(let state):
                let camera = MKMapCamera(
                    lookingAtCenter: state.center,
                    fromDistance: state.distance,
                    pitch: state.pitch,
                    heading: state.heading
                )
                mapView.setCamera(camera, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            changeWasUserInitiated = changeWasUserInitiated || containsActiveGesture(in: mapView)
        }

        @objc func mapGestureChanged(_ gestureRecognizer: UIGestureRecognizer) {
            if gestureRecognizer.state == .began || gestureRecognizer.state == .changed {
                changeWasUserInitiated = true
            }
        }

        func observeGestures(in view: UIView) {
            for gestureRecognizer in view.gestureRecognizers ?? [] {
                let identifier = ObjectIdentifier(gestureRecognizer)
                guard observedGestureRecognizers.insert(identifier).inserted else { continue }
                gestureRecognizer.addTarget(self, action: #selector(mapGestureChanged(_:)))
            }
            view.subviews.forEach(observeGestures(in:))
        }

        private func containsActiveGesture(in view: UIView) -> Bool {
            if view.gestureRecognizers?.contains(where: {
                $0.state == .began || $0.state == .changed
            }) == true {
                return true
            }
            return view.subviews.contains(where: containsActiveGesture(in:))
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
#if DEBUG
            let began = CACurrentMediaTime()
            defer { panProbe?.recordLayout(seconds: CACurrentMediaTime() - began) }
#endif
            referenceMarkerLayout.size = mapView.bounds.size
            updateReferenceMarkerLayout(in: mapView)
            updateGuideVisibility(in: mapView)
        }

        private func updateGuideVisibility(in map: MKMapView) {
            let visible = RouteGuideMapVisibility.showsDetails(distance: map.camera.centerCoordinateDistance, wasVisible: showsGuideDetails)
            guard visible != showsGuideDetails else { return }
            showsGuideDetails = visible
            for annotation in annotationsByKey.values {
                guard case .guide = annotation.payload, let view = map.view(for: annotation) as? LegacyMapAnnotationView else { continue }
                configure(view, for: annotation)
            }
        }

        private func updateReferenceMarkerLayout(in map: MKMapView) {
            let previousRevision = referenceMarkerLayout.presentationRevision
            guard referenceMarkerLayout.update(markers: referenceMarkers, heading: map.camera.heading,
                                               project: { map.convert($0, toPointTo: map) }) else { return }
            for marker in referenceMarkers {
                guard let annotation = annotationsByKey[.reference(marker.id)],
                      let view = map.view(for: annotation) as? LegacyReferenceMarkerAnnotationView else { continue }
                if previousRevision != referenceMarkerLayout.presentationRevision {
                    view.configure(referenceMarkerLayout.presentation(for: marker),
                                   showsLabel: referenceMarkerLayout.labeledIDs.contains(marker.id), heading: referenceMarkerLayout.heading)
                } else {
                    view.update(showsLabel: referenceMarkerLayout.labeledIDs.contains(marker.id), heading: referenceMarkerLayout.heading)
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
#if DEBUG
            if panProbe?.isRunning == true { return }
#endif
            let camera = mapView.camera
            let state = RouteCameraState(
                center: camera.centerCoordinate,
                distance: camera.centerCoordinateDistance,
                heading: camera.heading,
                pitch: camera.pitch
            )
            let positionedByUser = changeWasUserInitiated
#if DEBUG
            cameraProbe?.accessibilityValue = String(format: "%.7f,%.7f", state.center.latitude, state.center.longitude)
            cameraProbe?.accessibilityLabel = String(
                format: "camera-span:%.7f,%.7f",
                mapView.region.span.latitudeDelta,
                mapView.region.span.longitudeDelta
            )
#endif
            onCameraChanged(state, mapView.region, positionedByUser)
            onCameraSettled(state, mapView.region, positionedByUser)
#if DEBUG
            updateVideoProbe(in: mapView)
#endif
            changeWasUserInitiated = false
        }

        @objc private func showAllVideos() -> Bool {
            let ids = Array(Set(recordedSections.compactMap(\.recordingID)))
            guard !ids.isEmpty else { return false }
            onVideoSelection?(ids)
            return true
        }
#if DEBUG
        private func updateVideoProbe(in map: MKMapView) {
            guard ProcessInfo.processInfo.arguments.contains("--ui-video-hit-probe") else { return }
            guard let section = recordedSections.last(where: { $0.recordingID != nil }), let coordinate = section.coordinates.dropFirst(section.coordinates.count / 2).first else {
                videoProbe?.removeFromSuperview(); return
            }
            let probe: UIView
            if let existing = videoProbe { probe = existing }
            else {
                probe = UIView(); probe.isAccessibilityElement = true
                probe.accessibilityIdentifier = "map.video-hit-target"
                probe.accessibilityLabel = "video-path"
                probe.isUserInteractionEnabled = false
                map.addSubview(probe); videoProbe = probe
            }
            let point = map.convert(coordinate, toPointTo: map)
            probe.frame = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        }
#endif

        @objc func videoTapped(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended, let map = tap.view as? MKMapView else { return }
            let location = tap.location(in: map)
            if let annotation = annotationsByKey.values.first(where: { annotation in
                guard case .guide = annotation.payload else { return false }
                let position = map.convert(annotation.coordinate, toPointTo: map)
                return hypot(position.x + 44 - location.x, position.y - 22 - location.y) <= 22
            }), case .guide(let point) = annotation.payload {
                onGuideSelection?(point.id)
                return
            }
            let ids = VideoRouteHitTest.recordings(at: tap.location(in: map), sections: recordedSections) { map.convert($0, toPointTo: map) }
            if !ids.isEmpty { onVideoSelection?(ids) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKMultiPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolylineRenderer(multiPolyline: polyline)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            style(renderer, for: overlay)
            return renderer
        }

        private func style(_ renderer: MKOverlayPathRenderer, for overlay: MKOverlay) {
            if overlay.title == LegacyMapPolylineKind.reference.rawValue {
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.92)
                renderer.lineWidth = 3.25
            } else {
                renderer.strokeColor = overlay.title == LegacyMapPolylineKind.video.rawValue
                    ? UIColor(currentTheme.videoRouteAccent) : UIColor(currentTheme.accent).withAlphaComponent(0.98)
                renderer.lineWidth = 7
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? LegacyMapAnnotation else { return nil }
            if case .reference(let marker) = annotation.payload {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "reference-distance") as? LegacyReferenceMarkerAnnotationView)
                    ?? LegacyReferenceMarkerAnnotationView(annotation: annotation, reuseIdentifier: "reference-distance")
                view.annotation = annotation
                view.isUserInteractionEnabled = false
                view.configure(referenceMarkerLayout.presentation(for: marker),
                               showsLabel: referenceMarkerLayout.labeledIDs.contains(marker.id), heading: referenceMarkerLayout.heading)
                return view
            }
            let annotationView = LegacyMapAnnotationView(annotation: annotation, reuseIdentifier: nil)
            configure(annotationView, for: annotation)
            return annotationView
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? LegacyMapAnnotation,
                  case .guide(let point) = annotation.payload else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            onGuideSelection?(point.id)
        }

        private func configure(_ annotationView: LegacyMapAnnotationView, for annotation: LegacyMapAnnotation) {
            if case .guide(let point) = annotation.payload {
                annotationView.hostController?.view.removeFromSuperview()
                annotationView.hostController = nil
                let details = showsGuideDetails
                annotationView.onTraitsChange = { [weak annotationView] in
                    guard let annotationView else { return }
                    annotationView.image = RouteGuideMarkerImage.image(for: point, details: details, traits: annotationView.traitCollection)
                }
                annotationView.onTraitsChange?()
                annotationView.bounds = CGRect(x: 0, y: 0, width: 66, height: 44)
                annotationView.centerOffset = CGPoint(x: 33, y: -22)
                annotationView.isAccessibilityElement = true
                annotationView.accessibilityIdentifier = "map.guide-point.\(point.id)"
                annotationView.accessibilityLabel = point.title
                annotationView.accessibilityTraits = .button
                annotationView.isEnabled = false
                annotationView.onActivate = { [weak self] in self?.onGuideSelection?(point.id) }
                annotationView.zPriority = .max
                annotationView.displayPriority = .required
                annotationView.collisionMode = .circle
                return
            }
            let rootView: AnyView
            let size: CGSize
            switch annotation.payload {
            case .guide: return // Configured as a cached native bitmap above.
            case .reference(let marker):
                rootView = AnyView(ReferenceRouteMarkerView(marker: marker, layout: referenceMarkerLayout).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom))
                size = CGSize(width: referenceMarkerLayout.presentation(for: marker).labelWidth, height: 36)
                annotationView.accessibilityIdentifier = "map.reference-marker.\(marker.id)"
                annotationView.accessibilityLabel = referenceMarkerLayout.presentation(for: marker).accessibilityLabel
            case .event(let marker, let offset, let theme):
                rootView = AnyView(RouteEventMarkerView(marker: marker, visualOffset: offset, theme: theme))
                size = CGSize(width: 70, height: 70)
                annotationView.accessibilityIdentifier = "map.event.\(marker.kind.rawValue)"
                annotationView.accessibilityLabel = accessibilityLabel(for: marker.kind)
            case .current(_, let theme, let course, let mapHeading, let state):
                rootView = AnyView(CurrentLocationMarker(theme: theme, course: course, mapHeading: mapHeading, state: state))
                size = CGSize(width: 54, height: 54)
                annotationView.accessibilityIdentifier = "map.current-location"
                annotationView.accessibilityLabel = L10n.tr("map_current_location")
            }
            let host: UIHostingController<AnyView>
            if let existingHost = annotationView.hostController {
                host = existingHost
                host.rootView = rootView
            } else {
                host = UIHostingController(rootView: rootView)
                host.view.backgroundColor = .clear
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.view.accessibilityElementsHidden = true
                annotationView.addSubview(host.view)
                annotationView.hostController = host
            }
            // MapKit owns the annotation's center. Set its size before the
            // flexible hosting view, otherwise autoresizing adds the size delta
            // a second time and moves the tick away from its real coordinate.
            annotationView.bounds = CGRect(origin: .zero, size: size)
            host.view.frame = annotationView.bounds
            annotationView.isAccessibilityElement = true
            annotationView.accessibilityTraits = .image
            if case .reference = annotation.payload {
                annotationView.centerOffset = CGPoint(x: 0, y: -size.height / 2)
                annotationView.displayPriority = .required
                annotationView.collisionMode = .rectangle
            } else {
                annotationView.centerOffset = .zero
                annotationView.displayPriority = .required
            }
        }

        private func accessibilityLabel(for kind: RouteEventKind) -> String {
            switch kind {
            case .start: L10n.tr("route_start_marker")
            case .pause: L10n.tr("trip_pause")
            case .resume: L10n.tr("trip_resume")
            case .finish: L10n.tr("route_end_marker")
            }
        }
    }
}

#if DEBUG
/// UI-test-only native projection: SwiftUI MapReader may not resolve a coordinate
/// during initial sheet layout. Tests still tap the real rendered line underneath.
private struct NativeVideoHitProbe: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) { view.coordinate = coordinate; view.updatePosition() }
    final class ProbeView: UIView {
        var coordinate = CLLocationCoordinate2D()
        private let target = UIView()
        private var timer: Timer?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            target.isAccessibilityElement = true
            target.accessibilityIdentifier = "map.video-hit-target"
            target.accessibilityLabel = "video-path"
            addSubview(target)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate(); timer = nil
            if window != nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.updatePosition() }
            }
        }
        override func layoutSubviews() { super.layoutSubviews(); updatePosition() }
        func updatePosition() {
            func findMap(_ view: UIView) -> MKMapView? {
                if let map = view as? MKMapView { return map }
                for child in view.subviews where child !== self {
                    if let map = findMap(child) { return map }
                }
                return nil
            }
            var ancestor = superview
            while let parent = ancestor {
                if let map = findMap(parent) {
                    let point = map.convert(map.convert(coordinate, toPointTo: map), to: self)
                    target.frame = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
                    return
                }
                ancestor = parent.superview
            }
        }
        deinit { timer?.invalidate() }
    }
}

private final class MapCameraDebugState: ObservableObject {
    @Published var span = RouteMapGeometry.fallbackRegion.span
    @Published var center = RouteMapGeometry.fallbackRegion.center
}

private struct MapCameraDebugProbe: View {
    @ObservedObject var state: MapCameraDebugState

    var body: some View {
        Text(
            String(
                format: "camera-span:%.7f,%.7f",
                state.span.latitudeDelta,
                state.span.longitudeDelta
            ) + (ProcessInfo.processInfo.arguments.contains("--ui-map-free-browse-probe")
                ? String(format: ";center:%.7f,%.7f", state.center.latitude, state.center.longitude) : "")
        )
            .font(.system(size: 1))
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("map.camera-span")
            .allowsHitTesting(false)
    }
}
#endif

/// MapKit moves these lightweight native views during gestures. The static badge
/// is cached at the screen's native scale; only its tick changes when rotating.
final class LegacyReferenceMarkerAnnotationView: MKAnnotationView {
    private let artwork = ReferenceMarkerArtworkView()
    var coordinateAnchor: CGPoint { CGPoint(x: bounds.midX, y: bounds.maxY - 4) }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        artwork.isUserInteractionEnabled = false
        artwork.isAccessibilityElement = false
        addSubview(artwork)
        isAccessibilityElement = true
        accessibilityTraits = .image
        displayPriority = .required
        collisionMode = .rectangle
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ presentation: ReferenceMarkerPresentation, showsLabel: Bool, heading: Double) {
        bounds = CGRect(x: 0, y: 0, width: presentation.labelWidth, height: presentation.canvasHeight)
        artwork.frame = bounds
        centerOffset = CGPoint(x: 0, y: bounds.midY - coordinateAnchor.y)
        accessibilityIdentifier = "map.reference-marker.\(presentation.marker.id)"
        accessibilityLabel = presentation.accessibilityLabel
        artwork.configure(presentation)
        update(showsLabel: showsLabel, heading: heading)
    }

    func update(showsLabel: Bool, heading: Double) {
        artwork.update(showsLabel: showsLabel, heading: heading)
    }
}

private final class ReferenceMarkerArtworkView: UIView {
    private var presentation: ReferenceMarkerPresentation?
    private var badge: UIImage?
    private var showsLabel = true
    private var heading: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ presentation: ReferenceMarkerPresentation) {
        guard self.presentation?.marker != presentation.marker
            || self.presentation?.distanceLabel != presentation.distanceLabel
            || self.presentation?.fontSize != presentation.fontSize
            || self.presentation?.isRTL != presentation.isRTL else { return }
        self.presentation = presentation
        badge = nil
        setNeedsDisplay()
    }

    func update(showsLabel: Bool, heading: Double) {
        let visible = presentation?.marker.kind != .distance || showsLabel
        guard self.showsLabel != visible || self.heading != heading else { return }
        self.showsLabel = visible
        self.heading = heading
        setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
            || traitCollection.displayScale != previousTraitCollection?.displayScale {
            badge = nil
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let presentation else { return }
        let marker = presentation.marker
        let tint = marker.kind == .start ? UIColor.systemGreen : .systemBlue
        let anchor = CGPoint(x: bounds.midX, y: bounds.maxY - 4)
        if showsLabel {
            if badge == nil { badge = makeBadge(presentation, tint: tint) }
            if let badge {
                badge.draw(at: CGPoint(x: anchor.x + presentation.labelOffset - badge.size.width / 2,
                                       y: anchor.y - 8 - badge.size.height))
            }
            if marker.kind != .distance {
                let connector = UIBezierPath()
                connector.move(to: CGPoint(x: anchor.x + marker.horizontalOffset, y: anchor.y - 8))
                connector.addLine(to: anchor)
                tint.withAlphaComponent(0.65).setStroke()
                connector.lineWidth = 1
                connector.stroke()
            }
        }
        let angle = (marker.course - heading) * .pi / 180
        let dx = 3 * cos(angle), dy = 3 * sin(angle)
        let tick = UIBezierPath()
        tick.move(to: CGPoint(x: anchor.x - dx, y: anchor.y - dy))
        tick.addLine(to: CGPoint(x: anchor.x + dx, y: anchor.y + dy))
        UIColor.systemBackground.setStroke()
        tick.lineWidth = 3.5
        tick.stroke()
        tint.setStroke()
        tick.lineWidth = 1.5
        tick.lineCapStyle = .round
        tick.stroke()
    }

    private func makeBadge(_ presentation: ReferenceMarkerPresentation, tint: UIColor) -> UIImage {
        if let number = presentation.numberImage { return number }
        let base = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let font = UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 10)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let text = presentation.distanceLabel as NSString
        let textSize = text.size(withAttributes: attributes)
        let iconWidth: CGFloat = presentation.marker.kind == .distance ? 0 : 15
        let height = max(textSize.height, iconWidth == 0 ? 0 : 12) + 6
        let size = CGSize(width: textSize.width + iconWidth + 10, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = contentScaleFactor
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let capsule = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: height / 2)
            UIColor.systemBackground.setFill(); capsule.fill()
            tint.withAlphaComponent(0.5).setStroke(); capsule.lineWidth = 1; capsule.stroke()
            text.draw(at: CGPoint(x: 5 + (presentation.isRTL ? 0 : iconWidth), y: (height - textSize.height) / 2), withAttributes: attributes)
            let iconRect = CGRect(x: presentation.isRTL ? size.width - 17 : 5, y: (height - 12) / 2, width: 12, height: 12)
            if presentation.marker.kind == .start {
                UIImage(systemName: "flag.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))?
                    .withTintColor(tint, renderingMode: .alwaysOriginal).draw(in: iconRect)
            } else if presentation.marker.kind == .finish {
                // Same vector geometry as CheckeredFlagIcon, including iOS 15.
                let cg = context.cgContext
                cg.saveGState(); cg.translateBy(x: iconRect.minX, y: iconRect.minY)
                let cloth = CGRect(x: 12 * 0.2, y: 12 * 0.1, width: 12 * 0.72, height: 12 * 0.55)
                cg.setFillColor(UIColor.white.cgColor); cg.fill(cloth)
                cg.setFillColor(UIColor.black.cgColor)
                cg.fill(CGRect(x: 12 * 0.12, y: 12 * 0.08, width: 12 * 0.08, height: 12 * 0.86))
                for row in 0..<3 {
                    for column in 0..<4 where (row + column).isMultiple(of: 2) {
                        cg.fill(CGRect(x: cloth.minX + CGFloat(column) * cloth.width / 4,
                                       y: cloth.minY + CGFloat(row) * cloth.height / 3,
                                       width: cloth.width / 4, height: cloth.height / 3))
                    }
                }
                cg.setStrokeColor(UIColor.black.cgColor); cg.setLineWidth(12 * 0.055); cg.stroke(cloth)
                cg.restoreGState()
            }
        }
    }
}

private final class LegacyMapAnnotationView: MKAnnotationView {
    var onActivate: (() -> Void)?
    override var accessibilityActivationPoint: CGPoint {
        get {
            guard onActivate != nil else { return super.accessibilityActivationPoint }
            return UIAccessibility.convertToScreenCoordinates(
                CGRect(x: bounds.maxX - 22, y: bounds.midY, width: 0, height: 0), in: self).origin
        }
        set { super.accessibilityActivationPoint = newValue }
    }
    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }
    var hostController: UIHostingController<AnyView>?
    var onTraitsChange: (() -> Void)?

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { onTraitsChange?() }
    }

    override func prepareForReuse() {
        hostController?.view.removeFromSuperview()
        hostController = nil
        onActivate = nil
        onTraitsChange = nil
        image = nil
        super.prepareForReuse()
    }
}

enum LegacyMapAnnotationKey: Hashable {
    case guide(String)
    case reference(String)
    case event(String)
    case currentLocation
}

struct LegacyMapAnnotationReconciliation: Equatable {
    let retained: Set<LegacyMapAnnotationKey>
    let added: Set<LegacyMapAnnotationKey>
    let removed: Set<LegacyMapAnnotationKey>

    static func make(
        existing: Set<LegacyMapAnnotationKey>,
        desired: Set<LegacyMapAnnotationKey>
    ) -> LegacyMapAnnotationReconciliation {
        LegacyMapAnnotationReconciliation(
            retained: existing.intersection(desired),
            added: desired.subtracting(existing),
            removed: existing.subtracting(desired)
        )
    }
}

private enum LegacyMapPolylineKind: String {
    case reference
    case recorded
    case video
}

private struct LegacyMapCoordinateSignature: Equatable {
    let latitude: UInt64
    let longitude: UInt64

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude.bitPattern
        longitude = coordinate.longitude.bitPattern
    }
}

private struct LegacyMapPolylineSignature: Equatable {
    let kind: LegacyMapPolylineKind
    let coordinates: [LegacyMapCoordinateSignature]

    init(kind: LegacyMapPolylineKind, coordinates: [CLLocationCoordinate2D]) {
        self.kind = kind
        self.coordinates = coordinates.map(LegacyMapCoordinateSignature.init)
    }
}

private final class LegacyMapAnnotation: NSObject, MKAnnotation, MLNAnnotation {
    enum Payload {
        case guide(RouteGuideMapPoint)
        case reference(ReferenceRouteMarker)
        case event(RouteEventMarker, CGSize, SpeedTheme)
        case current(CLLocationCoordinate2D, SpeedTheme, CLLocationDirection, CLLocationDirection, TripState)

        var coordinate: CLLocationCoordinate2D {
            switch self {
            case .guide(let point): point.coordinate
            case .reference(let marker): marker.coordinate
            case .event(let marker, _, _): marker.coordinate
            case .current(let coordinate, _, _, _, _): coordinate
            }
        }
    }

    dynamic var coordinate: CLLocationCoordinate2D
    let key: LegacyMapAnnotationKey
    var payload: Payload

    init(key: LegacyMapAnnotationKey, payload: Payload) {
        self.key = key
        coordinate = payload.coordinate
        self.payload = payload
    }
}

// Observe persisted disclosure inside the panel; clock ticks remain isolated.
private struct ExpandedMapPanel<Controls: View>: View {
    @ObservedObject var settings: AppSettings
    let speed: String
    let duration: String
    let distance: String
    let averageSpeed: String
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            controls()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .overlay {
                    if settings.fullscreenMapShowsClock {
                        ExpandedMapClock()
                            .padding(.horizontal, 60)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            ExpandedRouteMetricsBar(speed: speed, duration: duration, distance: distance,
                averageSpeed: averageSpeed, showsClock: $settings.fullscreenMapShowsClock)
                .frame(maxWidth: .infinity)
        }
#if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--debug-map-clock") { settings.fullscreenMapShowsClock = true }
        }
#endif
    }
}

private struct ExpandedMapClock: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let fontSize = Self.fittedFontSize(in: geometry.size)
            // Only the clock ticks; sizing comes from the fixed space beside the controls.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, formatter: Self.clockFormatter)
                    .font(.system(size: fontSize, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .shadow(color: haloColor, radius: 1, x: -1, y: 0)
                    .shadow(color: haloColor, radius: 1, x: 1, y: 0)
                    .shadow(color: haloColor, radius: 1, x: 0, y: -1)
                    .shadow(color: haloColor, radius: 1, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityLabel(L10n.tr("map_current_time"))
                    .accessibilityValue(Self.clockFormatter.string(from: context.date))
                    .accessibilityIdentifier("map.fullscreen.clock")
            }
        }
    }

    private static func fittedFontSize(in size: CGSize) -> CGFloat {
        // Measure the same rounded monospaced font, reserving room for the halo.
        // Every HH:mm value has equal width, so minute changes cannot resize it.
        let base = UIFont.monospacedDigitSystemFont(ofSize: 100, weight: .medium)
        let font = UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 100)
        let textWidth = ("00:00" as NSString).size(withAttributes: [.font: font]).width
        let widthScale = max(1, size.width - 10) / textWidth
        let heightScale = max(1, size.height - 10) / font.lineHeight
        return 100 * min(widthScale, heightScale)
    }

    private var haloColor: Color {
        (colorScheme == .dark ? Color.black : Color.white).opacity(0.85)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct ExpandedRouteMetricsBar: View {
    let speed: String
    let duration: String
    let distance: String
    let averageSpeed: String
    @Binding var showsClock: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            Color.clear
                .frame(height: 16)
                .overlay {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            showsClock.toggle()
                        }
                    } label: {
                        Image(systemName: showsClock ? "chevron.down" : "chevron.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("map_current_time"))
                    .accessibilityValue(L10n.tr(showsClock ? "common_on" : "common_off"))
                    .accessibilityIdentifier("map.fullscreen.clock-toggle")
                }
            metrics
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.fullscreen.metrics")
    }

    private var metrics: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    speedMetric
                    Divider()
                    durationMetric
                    Divider()
                    distanceMetric
                    Divider()
                    averageMetric(averageSpeed)
                }
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        speedMetric
                        Divider().frame(height: 38)
                        averageMetric(averageSpeed)
                    }
                    Divider().padding(.horizontal, 14)
                    HStack(spacing: 0) {
                        durationMetric
                        Divider().frame(height: 38)
                        distanceMetric
                    }
                }
            }
        }
    }

    private func averageMetric(_ value: String) -> some View {
        ExpandedRouteMetric(title: L10n.tr("metric_average_speed"), value: value,
                            accessibilityIdentifier: "map.fullscreen.average-speed")
    }

    private var speedMetric: some View {
        ExpandedRouteMetric(
            title: L10n.tr("accessibility_speedometer"),
            value: speed,
            accessibilityIdentifier: "map.fullscreen.speed"
        )
    }

    private var durationMetric: some View {
        ExpandedRouteMetric(
            title: L10n.tr("metric_duration"),
            value: duration,
            accessibilityIdentifier: "map.fullscreen.duration"
        )
    }

    private var distanceMetric: some View {
        ExpandedRouteMetric(
            title: L10n.tr("metric_distance"),
            value: distance,
            accessibilityIdentifier: "map.fullscreen.distance"
        )
    }
}

private struct ExpandedRouteMetric: View {
    let title: String
    let value: String
    let accessibilityIdentifier: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .allowsTightening(true)
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }
                .padding(.horizontal, 14)
            } else {
                VStack(spacing: 3) {
                    Text(value)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 62 : 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct LiveRouteSpeedCard: View {
    let value: String
    let unit: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesRegularWidthLayout: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(alignment: usesRegularWidthLayout ? .center : .leading, spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: usesRegularWidthLayout ? .center : .leading, spacing: usesRegularWidthLayout ? -10 : -6) {
                Text(value)
                    .font(.system(size: usesRegularWidthLayout ? 88 : 60, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                Text(unit)
                    .font(usesRegularWidthLayout ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.leading, usesRegularWidthLayout ? 0 : 3)
            }

            Spacer(minLength: 0)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: usesRegularWidthLayout ? .center : .leading
        )
        .padding(.horizontal, 14)
        .padding(.vertical, usesRegularWidthLayout ? 12 : 10)
        .background(cardBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("accessibility_speedometer"))
        .accessibilityValue("\(value) \(unit)")
        .accessibilityIdentifier("map.speed")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous)
            .fill(AppPalette.raisedCard(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct LiveRouteSummaryCard: View {
    let duration: String
    let distance: String
    let averageSpeed: String
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            LiveRouteSummaryRow(
                title: L10n.tr("metric_duration"),
                value: duration,
                systemName: "timer",
                accent: accent,
                accessibilityIdentifier: "map.duration"
            )

            Divider()

            LiveRouteSummaryRow(
                title: L10n.tr("metric_distance"),
                value: distance,
                systemName: "point.topleft.down.to.point.bottomright.curvepath",
                accent: accent,
                accessibilityIdentifier: "map.distance"
            )

            Divider()
            LiveRouteSummaryRow(
                title: L10n.tr("metric_average_speed"),
                value: averageSpeed,
                systemName: "speedometer",
                accent: accent,
                accessibilityIdentifier: "map.average-speed"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(cardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.trip-summary")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous)
            .fill(AppPalette.raisedCard(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct LiveRouteSummaryRow: View {
    let title: String
    let value: String
    let systemName: String
    let accent: Color
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: PlatformSymbol.name(systemName))
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct RouteEventMarkerView: View {
    let marker: RouteEventMarker
    let visualOffset: CGSize
    let theme: SpeedTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if visualOffset != .zero {
                Path { path in
                    path.move(to: CGPoint(x: 35, y: 35))
                    path.addLine(to: CGPoint(x: 35 + visualOffset.width, y: 35 + visualOffset.height))
                }
                .stroke(Color.primary.opacity(0.50), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                Circle()
                    .fill(Color.primary.opacity(0.72))
                    .frame(width: 5, height: 5)
                    .position(x: 35, y: 35)
            }

            Group {
                if marker.kind == .finish {
                    CheckeredFlagIcon().frame(width: 14, height: 14)
                } else {
                    Image(systemName: PlatformSymbol.name(systemName))
                        .font(.system(size: 11, weight: .black))
                }
            }
                .foregroundStyle(foregroundColor)
                .frame(width: 26, height: 26)
                .background(backgroundColor, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.30), radius: 3, y: 1.5)
                .position(x: 35 + visualOffset.width, y: 35 + visualOffset.height)
        }
        .frame(width: 70, height: 70)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("map.event.\(marker.kind.rawValue)")
    }

    private var systemName: String {
        switch marker.kind {
        case .start: "flag.fill"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .finish: "flag.checkered"
        }
    }

    private var backgroundColor: Color {
        switch marker.kind {
        case .start: .green
        case .pause: theme.secondary
        case .resume: .blue
        case .finish: theme.accent
        }
    }

    private var foregroundColor: Color {
        marker.kind == .finish ? AppPalette.ink : .white
    }

    private var accessibilityLabel: String {
        switch marker.kind {
        case .start: L10n.tr("route_start_marker")
        case .pause: L10n.tr("trip_pause")
        case .resume: L10n.tr("trip_resume")
        case .finish: L10n.tr("route_end_marker")
        }
    }
}

enum RouteMapCameraPolicy {
    /// Automatic recentering retains the commanded zoom. Camera callbacks may
    /// still describe an earlier animation frame and must not feed that scale
    /// back into the next follow command.
    static func followCamera(
        userCamera: RouteCameraState?,
        command: RouteMapCameraCommand,
        observedCamera: RouteCameraState?
    ) -> RouteCameraState? {
        if let userCamera, userCamera.isUsable { return userCamera }
        if case .camera(let camera) = command.target, camera.isUsable { return camera }
        return observedCamera.flatMap { $0.isUsable ? $0 : nil }
    }

    static let followAnimationDuration: TimeInterval = 0.9
    static let userInteractionSettlingInterval: TimeInterval = 1.0

    static func shouldApplyAutomaticFollow(
        lastUserCameraChange: Date?,
        now: Date
    ) -> Bool {
        guard let lastUserCameraChange else { return true }
        return now.timeIntervalSince(lastUserCameraChange) >= userInteractionSettlingInterval
    }

    static func shouldAutomaticallyFit(
        hasCoordinates: Bool,
        userHasAdjustedCamera: Bool,
        positionIsUserControlled: Bool,
        tripState: TripState
    ) -> Bool {
        guard hasCoordinates else { return false }
        // Trip state is deliberately not a condition: a user's camera remains
        // authoritative while recording, paused, and after the trip is idle.
        _ = tripState
        return !userHasAdjustedCamera && !positionIsUserControlled
    }

    static func followCenter(
        location: CLLocationCoordinate2D,
        direction: CLLocationDirection?,
        cameraDistance: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        guard let direction, direction.isFinite, direction >= 0 else { return location }
        let lookAheadDistance = min(max(cameraDistance * 0.16, 18), 220)
        return RouteMapGeometry.coordinate(
            from: location,
            distance: lookAheadDistance,
            heading: direction
        )
    }

    static func followedCamera(
        preserving camera: RouteCameraState,
        location: CLLocationCoordinate2D,
        direction: CLLocationDirection?
    ) -> RouteCameraState {
        RouteCameraState(
            center: followCenter(
                location: location,
                direction: direction,
                cameraDistance: camera.distance
            ),
            distance: camera.distance,
            heading: camera.heading,
            pitch: camera.pitch
        )
    }
}

private struct CurrentLocationMarker: View {
    let theme: SpeedTheme
    let course: CLLocationDirection
    let mapHeading: CLLocationDirection
    let state: TripState

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.accent.opacity(state == .paused ? 0.18 : 0.28))
                .frame(width: 50, height: 50)

            Circle()
                .fill(AppPalette.ink)
                .frame(width: 38, height: 38)
                .overlay(Circle().stroke(.white, lineWidth: 3))

            Image(systemName: PlatformSymbol.name("location.north.fill"))
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(state == .paused ? Color.gray : theme.inkSurfaceAccent)
                .rotationEffect(.degrees(course - mapHeading))
        }
        .shadow(color: .black.opacity(0.42), radius: 7, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("map_current_location"))
        .accessibilityIdentifier("map.current-location")
    }
}

enum RouteMapGeometry {
    static let fallbackRegion: MKCoordinateRegion = {
#if DEBUG
        if let region = ScreenshotCityFixture.region { return region }
#endif
        return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.9023, longitude: 27.5619),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
        )
    }()

    static func region(fitting coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else { return fallbackRegion }

        let bounds = coordinates.dropFirst().reduce(
            (minLatitude: first.latitude, maxLatitude: first.latitude, minLongitude: first.longitude, maxLongitude: first.longitude)
        ) { bounds, coordinate in
            (
                min(bounds.minLatitude, coordinate.latitude),
                max(bounds.maxLatitude, coordinate.latitude),
                min(bounds.minLongitude, coordinate.longitude),
                max(bounds.maxLongitude, coordinate.longitude)
            )
        }

        let latitudeDelta = max((bounds.maxLatitude - bounds.minLatitude) * 1.55, 0.006)
        let longitudeDelta = max((bounds.maxLongitude - bounds.minLongitude) * 1.55, 0.006)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (bounds.minLatitude + bounds.maxLatitude) / 2,
                longitude: (bounds.minLongitude + bounds.maxLongitude) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    static func heading(for coordinates: [CLLocationCoordinate2D]) -> CLLocationDirection {
        guard coordinates.count > 1,
              let previous = coordinates.dropLast().last,
              let latest = coordinates.last else { return 0 }

        let previousLatitude = previous.latitude * .pi / 180
        let latestLatitude = latest.latitude * .pi / 180
        let longitudeDelta = (latest.longitude - previous.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latestLatitude)
        let x = cos(previousLatitude) * sin(latestLatitude)
            - sin(previousLatitude) * cos(latestLatitude) * cos(longitudeDelta)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func coordinate(
        from coordinate: CLLocationCoordinate2D,
        distance: CLLocationDistance,
        heading: CLLocationDirection
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let angularDistance = distance / earthRadius
        let bearing = heading * .pi / 180
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let destinationLatitude = asin(
            sin(latitude) * cos(angularDistance)
                + cos(latitude) * sin(angularDistance) * cos(bearing)
        )
        let destinationLongitude = longitude + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(destinationLatitude)
        )
        return CLLocationCoordinate2D(
            latitude: destinationLatitude * 180 / .pi,
            longitude: destinationLongitude * 180 / .pi
        )
    }

    static func heading(
        along segments: [[CLLocationCoordinate2D]],
        nearestTo coordinate: CLLocationCoordinate2D,
        preferredDirection: CLLocationDirection?
    ) -> CLLocationDirection? {
        let candidates = segments.flatMap { segment in
            zip(segment, segment.dropFirst()).map { start, end in
                (start: start, end: end)
            }
        }
        guard let nearest = candidates.min(by: {
            midpointDistance(from: coordinate, to: $0) < midpointDistance(from: coordinate, to: $1)
        }) else { return nil }

        let routeHeading = heading(for: [nearest.start, nearest.end])
        guard let preferredDirection, preferredDirection >= 0 else { return routeHeading }
        let reverseHeading = (routeHeading + 180).truncatingRemainder(dividingBy: 360)
        return angularDifference(routeHeading, preferredDirection) <= angularDifference(reverseHeading, preferredDirection)
            ? routeHeading
            : reverseHeading
    }

    private static func midpointDistance(
        from coordinate: CLLocationCoordinate2D,
        to segment: (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)
    ) -> CLLocationDistance {
        let midpoint = CLLocationCoordinate2D(
            latitude: (segment.start.latitude + segment.end.latitude) / 2,
            longitude: (segment.start.longitude + segment.end.longitude) / 2
        )
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: midpoint.latitude, longitude: midpoint.longitude))
    }

    private static func angularDifference(_ first: CLLocationDirection, _ second: CLLocationDirection) -> Double {
        let difference = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}

// Small, passive labels sit above a short tick anchored to the real route.
// Kilometer labels stay upright and the imported blue line remains continuous.
private struct ReferenceRouteMarkerView: View {
    let marker: ReferenceRouteMarker
    @ObservedObject var layout: ReferenceMarkerLayoutState

    var body: some View {
        let presentation = layout.presentation(for: marker)
        let tint: Color = marker.kind == .start ? .green : .blue
        let showsLabel = marker.kind != .distance || layout.labeledIDs.contains(marker.id)
        let anchor = CGPoint(x: presentation.labelWidth / 2, y: presentation.canvasHeight - 4)
        let angle = (marker.course - layout.heading) * .pi / 180
        let dx = 3 * cos(angle), dy = 3 * sin(angle)
        // Keep visibility in SwiftUI: modern MapKit can snapshot a representable's
        // initial UIKit drawing and miss later setNeedsDisplay-only changes.
        ZStack(alignment: .topLeading) {
            Group {
                if let number = presentation.numberImage {
                    Image(uiImage: number)
                } else {
                    HStack(spacing: 3) {
                        if marker.kind == .start { Image(systemName: "flag.fill") }
                        else { CheckeredFlagIcon().frame(width: 12, height: 12) }
                        Text(presentation.distanceLabel).monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Color(uiColor: .systemBackground), in: Capsule())
                    .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
                    .environment(\.layoutDirection, presentation.isRTL ? .rightToLeft : .leftToRight)
                }
            }
            .fixedSize()
            .position(x: anchor.x + presentation.labelOffset, y: anchor.y - 8 - presentation.labelHeight / 2)
            .opacity(showsLabel ? 1 : 0)
            if marker.kind != .distance {
                Path { path in
                    path.move(to: CGPoint(x: anchor.x + presentation.labelOffset, y: anchor.y - 8))
                    path.addLine(to: anchor)
                }.stroke(tint.opacity(0.65), lineWidth: 1)
            }
            let tick = Path { path in
                path.move(to: CGPoint(x: anchor.x - dx, y: anchor.y - dy))
                path.addLine(to: CGPoint(x: anchor.x + dx, y: anchor.y + dy))
            }
            tick.stroke(Color(uiColor: .systemBackground), lineWidth: 3.5)
            tick.stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: presentation.labelWidth, height: presentation.canvasHeight)
        // Map projection uses physical coordinates even when surrounding controls are RTL.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("map.reference-marker.\(marker.id)")
    }
}

/// Locale-dependent text and label bounds are prepared once, never during a pan.
struct ReferenceMarkerPresentation {
    let marker: ReferenceRouteMarker
    let distanceLabel: String
    let accessibilityLabel: String
    let labelWidth: CGFloat
    let isRTL: Bool
    let fontSize: CGFloat
    let labelOffset: CGFloat
    let numberImage: UIImage?
    var labelHeight: CGFloat { numberImage?.size.height ?? 20 }
    var canvasHeight: CGFloat { marker.kind == .distance ? labelHeight + 12 : 44 }

    init(marker: ReferenceRouteMarker, size: RouteDistanceLabelSize = .two) {
        self.marker = marker
        isRTL = AppLanguage.all.first(where: { $0.id == AppLanguage.normalized(L10n.locale.identifier) })?.isRTL ?? false
        let formatter = MeasurementFormatter()
        formatter.locale = L10n.locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = marker.kind == .finish ? 1 : 0
        let measurement = formatter.string(from: Measurement(value: marker.meters / 1_000, unit: UnitLength.kilometers))
        distanceLabel = marker.kind == .distance
            ? Int(marker.meters / 1_000).formatted(.number.locale(L10n.locale)) : measurement
        switch marker.kind {
        case .start: accessibilityLabel = L10n.tr("route_start_marker") + ", " + distanceLabel
        case .finish: accessibilityLabel = L10n.tr("route_end_marker") + ", " + distanceLabel
        case .distance: accessibilityLabel = measurement
        }
        fontSize = marker.kind == .distance ? size.fontSize : 10
        if marker.kind == .distance {
            let base = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            let font = UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: fontSize)
            // Rasterize only when content, locale or size changes, never on a camera frame.
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                .foregroundColor: UIColor(red: 0.02, green: 0.30, blue: 0.78, alpha: 1),
                .strokeColor: UIColor.white, .strokeWidth: -8]
            let text = distanceLabel as NSString
            let measured = text.size(withAttributes: attributes)
            let padding = ceil(fontSize * 0.08)
            let imageSize = CGSize(width: ceil(measured.width) + padding * 2, height: ceil(measured.height) + padding * 2)
            numberImage = UIGraphicsImageRenderer(size: imageSize).image { _ in
                let origin = CGPoint(x: padding, y: padding)
                text.draw(at: origin, withAttributes: attributes)
                // Refill after the halo so the white stroke never thins the blue glyph.
                text.draw(at: origin, withAttributes: [.font: font, .foregroundColor: attributes[.foregroundColor]!])
            }
            labelOffset = imageSize.width / 2 + 5
            labelWidth = max(34, imageSize.width) + labelOffset * 2
        } else {
            numberImage = nil
            labelOffset = marker.horizontalOffset
            labelWidth = CGFloat(max(34, distanceLabel.count * 7 + 24)) + abs(marker.horizontalOffset) * 2
        }
    }
}

struct ReferenceMarkerPresentationCache {
    private var markers: [ReferenceRouteMarker] = []
    private var localeID = ""
    private var labelSize: RouteDistanceLabelSize?
    private(set) var ordered: [ReferenceMarkerPresentation] = []
    private(set) var byID: [String: ReferenceMarkerPresentation] = [:]

    @discardableResult
    mutating func prepare(markers: [ReferenceRouteMarker], localeID: String = L10n.locale.identifier, size: RouteDistanceLabelSize = .two) -> Bool {
        guard self.markers != markers || self.localeID != localeID || labelSize != size else { return false }
        self.markers = markers
        self.localeID = localeID
        labelSize = size
        let presentations = markers.map { ReferenceMarkerPresentation(marker: $0, size: size) }
        ordered = presentations.filter { $0.marker.kind != .distance } + presentations.filter { $0.marker.kind == .distance }
        byID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.marker.id, $0) })
        return true
    }
}

/// Only leaf annotation views observe this state. Camera frames never republish
/// the map surface or its route geometry just to lay out kilometer labels.
final class ReferenceMarkerLayoutState: ObservableObject {
    @Published private(set) var labeledIDs: Set<String> = []
    @Published private(set) var heading: Double = 0
    var size = CGSize(width: 375, height: 450)
    var distanceLabelSize: RouteDistanceLabelSize = .two
    private var cache = ReferenceMarkerPresentationCache()
    private(set) var presentationRevision = 0

    func presentation(for marker: ReferenceRouteMarker) -> ReferenceMarkerPresentation {
        cache.byID[marker.id] ?? ReferenceMarkerPresentation(marker: marker, size: distanceLabelSize)
    }

    struct PreparedLayout {
        let labeledIDs: Set<String>
        let heading: Double
        let presentationChanged: Bool
    }

    /// All projection calls are synchronous; the result contains only values and
    /// may safely be published after the native camera callback has returned.
    func prepare(markers: [ReferenceRouteMarker], heading: Double,
                 project: (CLLocationCoordinate2D) -> CGPoint?) -> PreparedLayout {
        let changed = cache.prepare(markers: markers, size: distanceLabelSize)
        if changed { presentationRevision += 1 }
        return PreparedLayout(
            labeledIDs: ReferenceMarkerLabelLayout.visibleIDs(presentations: cache.ordered, size: size, project: project),
            heading: heading, presentationChanged: changed)
    }

    @discardableResult
    func apply(_ layout: PreparedLayout) -> Bool {
        if layout.presentationChanged { objectWillChange.send() }
        var changed = layout.presentationChanged
        if abs(heading - layout.heading) > 0.5 { heading = layout.heading; changed = true }
        if layout.labeledIDs != labeledIDs { labeledIDs = layout.labeledIDs; changed = true }
        return changed
    }

    @discardableResult
    func update(markers: [ReferenceRouteMarker], heading: Double, project: (CLLocationCoordinate2D) -> CGPoint?) -> Bool {
        apply(prepare(markers: markers, heading: heading, project: project))
    }
}

enum ReferenceMarkerLabelLayout {
    static func visibleIDs(markers: [ReferenceRouteMarker], size: CGSize,
                           project: (CLLocationCoordinate2D) -> CGPoint?) -> Set<String> {
        var cache = ReferenceMarkerPresentationCache()
        cache.prepare(markers: markers)
        return visibleIDs(presentations: cache.ordered, size: size, project: project)
    }

    static func visibleIDs(presentations: [ReferenceMarkerPresentation], size: CGSize,
                           project: (CLLocationCoordinate2D) -> CGPoint?) -> Set<String> {
        guard size.width > 0, size.height > 0 else { return [] }
        var occupied: [CGRect] = []
        var result: Set<String> = []
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        // Endpoints have priority; remaining labels are spaced in route order.
        for presentation in presentations {
            let marker = presentation.marker
            guard let point = project(marker.coordinate), point.x.isFinite, point.y.isFinite,
                  viewport.contains(point) else { continue }
            let x = point.x, y = point.y
            let width = presentation.labelWidth - 2 * abs(presentation.labelOffset)
            let frame = CGRect(x: x + presentation.labelOffset - width / 2, y: y - 8 - presentation.labelHeight, width: width, height: presentation.labelHeight).insetBy(dx: -3, dy: -3)
            if marker.kind != .distance || !occupied.contains(where: { $0.intersects(frame) }) {
                result.insert(marker.id)
                occupied.append(frame)
            }
        }
        return result
    }
}

#if DEBUG
/// Opt-in physical-device benchmark. Uses the already selected route, without
/// seeding fixtures, changing preferences, recording or writing the route library.
private final class MapPanPerformanceProbe: NSObject {
    private static var lifecyclePanOwner: UUID?
    private let instanceID = UUID()
    private weak var map: MKMapView?
    private weak var vectorMap: MLNMapView?
    private var initialVectorCamera: MLNMapCamera?
    private var link: CADisplayLink?
    private var initialCamera: MKMapCamera?
    private var started: CFTimeInterval = 0
    private var previous: CFTimeInterval = 0
    private var frames: [Double] = []
    private var layouts: [Double] = []
    private var renders: [Double] = []
    private var sdkFrames: [Double] = []
    private var previousSDKFrame: CFTimeInterval = 0
    private var initialCPU: Double = 0
    private var initialFootprint: UInt64 = 0
    private var nativeShapeUpdates = 0
    private var peakFootprint: UInt64 = 0
    private var lastMemorySample: CFTimeInterval = 0
    private(set) var isRunning = false
    private var iteration = 0
    private var cancelled = false
    private var repetitions: Int {
        let arg = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--debug-map-pan-iterations=") }
        return min(6, max(1, arg.flatMap { Int($0.split(separator: "=").last ?? "") } ?? 1))
    }
    private var warmup: Double {
        let arg = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--debug-map-pan-warmup=") }
        return min(120, max(5, arg.flatMap { Double($0.split(separator: "=").last ?? "") } ?? 5))
    }

    init(map: MKMapView) {
        self.map = map
        super.init()
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { [weak self] in self?.begin() }
    }

    init(map: MLNMapView) {
        vectorMap = map
        super.init()
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { [weak self] in self?.begin() }
    }

    private func begin() {
        guard !cancelled, (map?.window ?? vectorMap?.window) != nil else { return }
        // A lifecycle run recreates the native map. Only its first visible map
        // owns automatic pans; later maps must not restart the workload or
        // overwrite the initial samples. The token retains no map objects.
        if ProcessInfo.processInfo.arguments.contains("--debug-map-cycle-probe") {
            if Self.lifecyclePanOwner == nil { Self.lifecyclePanOwner = instanceID }
            guard Self.lifecyclePanOwner == instanceID else { return }
        }
        iteration += 1; started = 0; previous = 0; previousSDKFrame = 0
        frames = []; layouts = []; renders = []; sdkFrames = []; nativeShapeUpdates = 0
        initialCPU = OSMDeviceMemory.cpuSeconds()
        initialFootprint = OSMDeviceMemory.footprint(); peakFootprint = initialFootprint; lastMemorySample = 0
        initialCamera = map?.camera.copy() as? MKMapCamera
        initialVectorCamera = vectorMap?.camera.copy() as? MLNMapCamera
        isRunning = true
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func recordRender(seconds: Double) {
        if isRunning { renders.append(seconds * 1_000) }
    }

    func recordNativeShapeUpdate() { if isRunning { nativeShapeUpdates += 1 } }

    func recordSDKFrame() {
        guard isRunning else { return }
        let now = CACurrentMediaTime()
        if started > 0, now - started > 2, previousSDKFrame > 0 { sdkFrames.append((now - previousSDKFrame) * 1_000) }
        previousSDKFrame = now
    }

    func recordLayout(seconds: Double) {
        if isRunning { layouts.append(seconds * 1_000) }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard (map?.window ?? vectorMap?.window) != nil else { finish(); return }
        if started == 0 { started = link.timestamp; previous = link.timestamp }
        let elapsed = link.timestamp - started
        if elapsed - lastMemorySample >= 1 {
            peakFootprint = max(peakFootprint, OSMDeviceMemory.footprint()); lastMemorySample = elapsed
        }
        if elapsed > 2 { frames.append((link.timestamp - previous) * 1_000) }
        previous = link.timestamp
        guard elapsed < 14 else { finish(); return }
        // Identical world-space trajectory for the two native renderers.
        let phase = elapsed * .pi / 3
        if let map, let initialCamera {
            let camera = initialCamera.copy() as! MKMapCamera
            camera.centerCoordinate.latitude += sin(phase) * 0.12
            camera.centerCoordinate.longitude += cos(phase) * 0.10
            camera.centerCoordinateDistance *= 0.65 + 0.15 * cos(phase)
            camera.heading = elapsed < 7 ? initialCamera.heading : initialCamera.heading + 25 * sin(phase)
            map.setCamera(camera, animated: false)
        } else if let vectorMap, let initialVectorCamera {
            let camera = initialVectorCamera.copy() as! MLNMapCamera
            camera.centerCoordinate.latitude += sin(phase) * 0.12
            camera.centerCoordinate.longitude += cos(phase) * 0.10
            camera.viewingDistance *= 0.65 + 0.15 * cos(phase)
            camera.heading = elapsed < 7 ? initialVectorCamera.heading : initialVectorCamera.heading + 25 * sin(phase)
            vectorMap.setCamera(camera, animated: false)
        }
    }

    func cancel() { cancelled = true; finish() }

    func finish() {
        link?.invalidate(); link = nil
        guard isRunning else { return }
        if let initialCamera { map?.setCamera(initialCamera, animated: false) }
        if let initialVectorCamera { vectorMap?.setCamera(initialVectorCamera, animated: false) }
        isRunning = false
        func stats(_ samples: [Double]) -> [String: Double] {
            let ordered = samples.sorted()
            guard !ordered.isEmpty else { return [:] }
            return ["count": Double(ordered.count), "mean_ms": ordered.reduce(0,+) / Double(ordered.count),
                    "p95_ms": ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))],
                    "max_ms": ordered.last!]
        }
        let result: [String: Any] = ["os": UIDevice.current.systemVersion,
            "renderer": vectorMap == nil ? "apple" : "openStreetMap",
            "iteration": iteration, "warmup_seconds": warmup,
            "cpu_seconds": OSMDeviceMemory.cpuSeconds() - initialCPU,
            "footprint_start": initialFootprint, "footprint_peak": peakFootprint,
            "footprint_end": OSMDeviceMemory.footprint(),
            "initial_distance": initialCamera?.centerCoordinateDistance ?? initialVectorCamera?.viewingDistance ?? 0,
            "network_style": OSMMapStyle.permitsNetwork,
            "osm_lifetimes": OSMMapLifetimeProbe.counts,
            "sdk_frame_intervals": stats(sdkFrames),
            "native_shape_updates": nativeShapeUpdates,
            "sdk_preferred_fps": vectorMap?.preferredFramesPerSecond ?? 0,
            "finished_at": ISO8601DateFormatter().string(from: Date()),
            "frame_intervals": stats(frames), "marker_layout": stats(layouts), "map_render": stats(renders),
            "overlays": map?.overlays.count ?? vectorMap?.style?.sources.count ?? 0, "annotations": map?.annotations.count ?? vectorMap?.annotations?.count ?? 0,
            "frames_over_33ms": frames.filter { $0 > 33.4 }.count,
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-pan-profile.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            if repetitions > 1 {
                try? data.write(to: url.deletingLastPathComponent().appendingPathComponent("map-pan-profile-\(iteration).json"), options: .atomic)
            }
        }
        if !cancelled, iteration < repetitions {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.begin() }
        }
    }
}
#endif

#if DEBUG
/// Opt-in isolated stress surface: reuses the shipping renderers and recorder,
/// but never changes the user's route library, entitlement, or preferences.
struct LongRecordingProbeView: View {
    @ObservedObject private var probe = LongRecordingProbeState.shared
    var body: some View {
        Group {
            if let recorder = probe.recorder {
                LongRecordingProbeReadyView(recorder: recorder, points: probe.guidePoints)
            } else { ProgressView("Preparing 1,000 km replay…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(UIColor.systemBackground)) }
        }
        .onAppear { LongRecordingProbe.startIfRequested() }
    }
}

/// Observe the recorder itself while loading. Observing only the shared holder
/// left places-off replays on the spinner: no guide publication refreshed it.
private struct LongRecordingProbeReadyView: View {
    @ObservedObject var recorder: TripRecorder
    let points: [RouteGuidePoint]
    var body: some View {
        Group {
            if !recorder.isLoadingRecovery, recorder.state != .idle {
                LongRecordingProbeMap(recorder: recorder, points: points)
            } else {
                ProgressView("Preparing 1,000 km replay…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground))
            }
        }
    }
}

private struct LongRecordingProbeMap: View {
    @ObservedObject var recorder: TripRecorder
    let points: [RouteGuidePoint]
    @State private var selected: RouteGuidePoint?
    @State private var expanded = false
    @State private var mapVisible = true
    @State private var cycleFullscreen = false
    @State private var cycleEvents: [[String: Any]] = []
    @State private var panIteration = 0
    @State private var places = !ProcessInfo.processInfo.arguments.contains("--debug-map-guides-off")
    @State private var command = RouteMapCameraCommand(target: .region(MKCoordinateRegion(
        center: ThousandKilometerFixture.coordinate(90_000), span: .init(latitudeDelta: 0.3, longitudeDelta: 0.3))))
    var body: some View {
        VStack {
            Text("1,000 km replay · \(recorder.points.count) points").font(.headline).accessibilityIdentifier("probe.point-count")
            HStack {
                Toggle("Places (1,000)", isOn: $places)
                Button(expanded ? "Normal" : "Full screen") { expanded.toggle() }
            }.padding(.horizontal)
            HStack {
                Button("Pan test") { panIteration += 1 }
                Button("Photo close-up") { command = RouteMapCameraCommand(target: .region(MKCoordinateRegion(center: ThousandKilometerFixture.coordinate(496 * 180), span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03)))) }
                Button("Overview") { command = RouteMapCameraCommand(target: .region(MKCoordinateRegion(center: ThousandKilometerFixture.coordinate(90_000), span: .init(latitudeDelta: 10, longitudeDelta: 2)))) }
            }.padding(.horizontal)
            if mapVisible {
                mapSurface.id(panIteration)
                    .accessibilityIdentifier("probe.route-map")
                    .frame(maxHeight: expanded ? .infinity : 460)
            }

            if !expanded { Spacer() }
        }
        .background(Color(UIColor.systemBackground))
        .sheet(item: $selected) { RouteGuidePointSheet(point: $0) }
        .fullScreenCover(isPresented: $cycleFullscreen) {
            VStack { Button("Close probe map") { cycleFullscreen = false }; mapSurface }
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--debug-map-cycle-probe") else { return }
            do {
                // Keep lifecycle transitions outside all three pan windows.
                let delay: UInt64 = ProcessInfo.processInfo.arguments.contains("--debug-map-pan-probe") ? 180 : 60
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                for cycle in 1...10 {
                    cycleFullscreen = true
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    recordCycle(cycle, phase: "fullscreen")
                    cycleFullscreen = false
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    selected = points.first { !($0.photos ?? []).isEmpty }
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    recordCycle(cycle, phase: "photo")
                    selected = nil
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    mapVisible = false
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    recordCycle(cycle, phase: "closed")
                    mapVisible = true
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    recordCycle(cycle, phase: "restored")
                    try await Task.sleep(nanoseconds: 80_000_000_000)
                }
                recordCycle(10, phase: "complete")
            } catch { recordCycle(0, phase: "cancelled") }
        }
    }
    private var mapSurface: some View {
            PlatformRouteMapSurface(snapshot: RouteMapSnapshot(routeSegments: recorder.displayPath.segments,
                referenceSegments: [], eventMarkers: recorder.mapEventMarkers, markerOffsets: [:],
                currentCoordinate: recorder.points.last?.coordinate, currentCourse: 0, currentState: recorder.state,
                theme: .lime, mapProvider: LongRecordingProbe.mapProvider, sourcePointCount: recorder.points.count,
                guidePoints: places ? points.map(RouteGuideMapPoint.init) : [],
                onGuideSelection: { id in selected = points.first { $0.id == id } },
                recordedSections: recorder.videoDisplay.sections,
                recordedDrawingGroups: recorder.videoDisplay.sections.isEmpty ? recorder.displayPath.drawingGroups : recorder.videoDisplay.drawingGroups), cameraCommand: command,
                onCameraChanged: { _, _, _ in }, onCameraSettled: { _, _, _ in })
    }
    private func recordCycle(_ cycle: Int, phase: String) {
        cycleEvents.append(["cycle": cycle, "phase": phase,
            "at": ISO8601DateFormatter().string(from: Date()),
            "footprint_bytes": OSMDeviceMemory.footprint(), "cpu_seconds": OSMDeviceMemory.cpuSeconds(),
            "lifetimes": OSMMapLifetimeProbe.counts])
        let report: [String: Any] = ["synthetic_replay": true, "events": cycleEvents]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("map-cycle-probe.json"), options: .atomic)
        }
    }
}
#endif

struct VectorRouteMapSurface: UIViewRepresentable {
    @Environment(\.mapControlsTopInset) private var mapControlsTopInset
    @Environment(\.mapScaleTopInset) private var mapScaleTopInset
    let snapshot: RouteMapSnapshot
    let cameraCommand: RouteMapCameraCommand
    let languageID: String
    var frozenStyleURL: URL? = nil
    let onCameraChanged: (RouteCameraState, MKCoordinateRegion, Bool) -> Void
    let onCameraSettled: (RouteCameraState, MKCoordinateRegion, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MLNMapView {
        _ = OfflineMapStore.shared
        let map = SpiderRouteOSMMapView(frame: .zero, styleURL: frozenStyleURL ?? (try? OSMMapStyle.url(languageID: languageID, permitsNetwork: OSMMapStyle.permitsNetwork)))
        map.delegate = context.coordinator
        let coordinator = context.coordinator
#if DEBUG
        OSMMapLifetimeProbe.register(map: map, coordinator: coordinator)
        coordinator.offlineLabelProbe.install(in: map)
#endif
        map.onFirstLayout = { [weak map, weak coordinator] in
            guard let map, let coordinator, let command = coordinator.pendingCommand else { return }
            coordinator.apply(command, in: map)
        }
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true // The shared visible attribution links cover both map layouts.
        map.showsScale = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false; tap.delegate = context.coordinator
        for gesture in map.gestureRecognizers ?? [] {
            if let doubleTap = gesture as? UITapGestureRecognizer, doubleTap.numberOfTapsRequired > 1 { tap.require(toFail: doubleTap) }
        }
        map.addGestureRecognizer(tap)
#if DEBUG
        let probe = UIView(frame: .init(x: 0, y: 0, width: 1, height: 1))
        probe.isAccessibilityElement = true; probe.isUserInteractionEnabled = false
        probe.accessibilityIdentifier = "map.camera-span"
        map.addSubview(probe); context.coordinator.cameraProbe = probe
#endif
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        map.scaleBarMargins = CGPoint(x: 16, y: mapScaleTopInset > 0 ? mapScaleTopInset : 8)
        map.compassViewMargins = CGPoint(x: 16, y: mapControlsTopInset > 0 ? 68 : 8)
        let coordinator = context.coordinator
        coordinator.onCameraChanged = onCameraChanged; coordinator.onCameraSettled = onCameraSettled
        coordinator.snapshot = snapshot
        let url = frozenStyleURL ?? (try? OSMMapStyle.url(languageID: languageID, permitsNetwork: OSMMapStyle.permitsNetwork))
        if map.styleURL != url { map.styleURL = url }
        coordinator.render(in: map)
        coordinator.apply(cameraCommand, in: map)
#if DEBUG
        if !coordinator.focusedOfflineQA, ProcessInfo.processInfo.arguments.contains("--ui-selected-offline-bounds"),
           let entry = OfflineMapStore.shared.entries.first(where: { $0.id == OfflineMapStore.shared.selectedID && $0.state == .complete }) {
            coordinator.focusedOfflineQA = true
            map.setVisibleCoordinateBounds(entry.metadata.bounds, animated: false)
        }
#endif
    }
    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        map.delegate = nil
#if DEBUG
        coordinator.stopPanProbe()
#endif
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
#if DEBUG
        let offlineLabelProbe = OSMRenderedLabelsProbe()
        var focusedOfflineQA = false
#endif
        var snapshot: RouteMapSnapshot?
        var onCameraChanged: ((RouteCameraState, MKCoordinateRegion, Bool) -> Void)?
        var onCameraSettled: ((RouteCameraState, MKCoordinateRegion, Bool) -> Void)?
        private var lastCommandID: UUID?
        var pendingCommand: RouteMapCameraCommand?
        private var revisions: [String: UUID] = [:]
        private var fallbackSignatures: [String: [LegacyMapPolylineSignature]] = [:]
        private var sourceIDs = Set<String>()
        private var annotations: [LegacyMapAnnotationKey: LegacyMapAnnotation] = [:]
        private var inputs: (guides: [RouteGuideMapPoint], references: [ReferenceRouteMarker], events: [RouteEventMarker], offsets: [String: CGSize], theme: SpeedTheme)?
        private let referenceLayout = ReferenceMarkerLayoutState()
        private var guideDetails = false
        private var latestTheme: SpeedTheme?
#if DEBUG
        weak var cameraProbe: UIView?
        weak var videoProbe: UIView?
        private weak var lifetimeProbe: UIView?
        private var panProbe: MapPanPerformanceProbe?
        func stopPanProbe() { panProbe?.cancel(); panProbe = nil }
        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) { panProbe?.recordSDKFrame() }
#endif
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            revisions = [:]; fallbackSignatures = [:]; sourceIDs = []; latestTheme = nil
            render(in: mapView)
        }
        func render(in map: MLNMapView) {
#if DEBUG
            let renderStarted = CACurrentMediaTime()
            defer { panProbe?.recordRender(seconds: CACurrentMediaTime() - renderStarted) }
            if panProbe == nil, ProcessInfo.processInfo.arguments.contains("--debug-map-pan-probe") {
                panProbe = MapPanPerformanceProbe(map: map)
            }
#endif
            guard let snapshot else { return }
            if let style = map.style { renderLines(snapshot, style: style) }
            referenceLayout.size = map.bounds.size
            updateReferenceLayout(snapshot, in: map)
            let sizeChanged = renderedDistanceLabelSize != snapshot.distanceLabelSize
            renderedDistanceLabelSize = snapshot.distanceLabelSize
            let changed = sizeChanged || inputs == nil || inputs!.guides != snapshot.guidePoints || inputs!.references != snapshot.referenceMarkers
                || inputs!.events != snapshot.eventMarkers || inputs!.offsets != snapshot.markerOffsets || inputs!.theme != snapshot.theme
            if changed {
                inputs = (snapshot.guidePoints, snapshot.referenceMarkers, snapshot.eventMarkers, snapshot.markerOffsets, snapshot.theme)
                var desired: [LegacyMapAnnotationKey: LegacyMapAnnotation.Payload] = [:]
                for marker in snapshot.eventMarkers { desired[.event(marker.id)] = .event(marker, snapshot.markerOffsets[marker.id] ?? .zero, snapshot.theme) }
                for marker in snapshot.referenceMarkers { desired[.reference(marker.id)] = .reference(marker) }
                for point in snapshot.guidePoints { desired[.guide(point.id)] = .guide(point) }
                if let coordinate = snapshot.currentCoordinate { desired[.currentLocation] = .current(coordinate, snapshot.theme, snapshot.currentCourse, map.direction, snapshot.currentState) }
                let plan = LegacyMapAnnotationReconciliation.make(existing: Set(annotations.keys), desired: Set(desired.keys))
                for key in plan.removed { if let old = annotations.removeValue(forKey: key) { map.removeAnnotation(old) } }
                for key in plan.retained { update(annotations[key]!, payload: desired[key]!, map: map) }
                let added = plan.added.map { key -> LegacyMapAnnotation in
                    let annotation = LegacyMapAnnotation(key: key, payload: desired[key]!); annotations[key] = annotation; return annotation
                }
                map.addAnnotations(added)
            } else if let coordinate = snapshot.currentCoordinate {
                let payload = LegacyMapAnnotation.Payload.current(coordinate, snapshot.theme, snapshot.currentCourse, map.direction, snapshot.currentState)
                if let old = annotations[.currentLocation] { update(old, payload: payload, map: map) }
                else { let new = LegacyMapAnnotation(key: .currentLocation, payload: payload); annotations[.currentLocation] = new; map.addAnnotation(new) }
            } else if let old = annotations.removeValue(forKey: .currentLocation) { map.removeAnnotation(old) }
            map.accessibilityCustomActions = snapshot.recordedSections.contains { $0.recordingID != nil }
                ? [UIAccessibilityCustomAction(name: L10n.tr("video_route_title"), target: self, selector: #selector(showAllVideos))] : []
#if DEBUG
            updateProbes(in: map)
#endif
        }

        private var renderedDistanceLabelSize: RouteDistanceLabelSize?
        private var pendingReferenceLayout: ReferenceMarkerLayoutState.PreparedLayout?
        private var publishingReferenceLayout = false
        private func updateReferenceLayout(_ snapshot: RouteMapSnapshot, in map: MLNMapView) {
            referenceLayout.distanceLabelSize = snapshot.distanceLabelSize
            pendingReferenceLayout = referenceLayout.prepare(markers: snapshot.referenceMarkers, heading: map.direction, project: { map.convert($0, toPointTo: map) })
            guard !publishingReferenceLayout else { return }
            publishingReferenceLayout = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publishingReferenceLayout = false
                if let layout = self.pendingReferenceLayout { self.pendingReferenceLayout = nil; self.referenceLayout.apply(layout) }
            }
        }

        private func renderLines(_ snapshot: RouteMapSnapshot, style: MLNStyle) {
            var desired = Set<String>()
            var groups: [(String, [[CLLocationCoordinate2D]], UUID?, LegacyMapPolylineKind)] = []
            if !snapshot.referenceDrawingGroups.isEmpty {
                groups += snapshot.referenceDrawingGroups.map { ("reference-" + $0.id, $0.segments, $0.revision, .reference) }
            } else { groups += snapshot.referenceSegments.enumerated().map { ("reference-\($0.offset)", [$0.element], nil, .reference) } }
            if !snapshot.recordedDrawingGroups.isEmpty {
                groups += snapshot.recordedDrawingGroups.map { ("recorded-" + $0.id, $0.segments, $0.revision, $0.isVideo ? .video : .recorded) }
            } else if !snapshot.recordedSections.isEmpty {
                groups += snapshot.recordedSections.map { ("section-" + $0.id, [$0.coordinates], nil, $0.recordingID == nil ? .recorded : .video) }
            } else { groups += snapshot.routeSegments.enumerated().map { ("route-\($0.offset)", [$0.element], nil, .recorded) } }
            for (key, segments, revision, kind) in groups {
                let id = "spiderroute-" + key
                desired.insert(id)
                let unchanged: Bool
                if let revision { unchanged = revisions[id] == revision; revisions[id] = revision }
                else {
                    let signatures = segments.map { LegacyMapPolylineSignature(kind: kind, coordinates: $0) }
                    unchanged = fallbackSignatures[id] == signatures; fallbackSignatures[id] = signatures
                }
                if !unchanged || !sourceIDs.contains(id) {
                    let lines = segments.filter { $0.count > 1 }.map { MLNPolyline(coordinates: $0, count: UInt($0.count)) }
                    let shape = MLNShapeCollection(shapes: lines)
                    if let source = style.source(withIdentifier: id) as? MLNShapeSource { source.shape = shape }
                    else {
                        let source = MLNShapeSource(identifier: id, shape: shape, options: [.lineDistanceMetrics: false])
                        style.addSource(source)
                        let layer = MLNLineStyleLayer(identifier: id, source: source)
                        layer.lineCap = NSExpression(forConstantValue: "round"); layer.lineJoin = NSExpression(forConstantValue: "round")
                        style.addLayer(layer)
                    }
                    sourceIDs.insert(id)
#if DEBUG
                    panProbe?.recordNativeShapeUpdate()
#endif
                }
                if !unchanged || latestTheme != snapshot.theme,
                   let layer = style.layer(withIdentifier: id) as? MLNLineStyleLayer {
                    let color = kind == .reference ? UIColor.systemBlue.withAlphaComponent(0.92)
                        : kind == .video ? UIColor(snapshot.theme.videoRouteAccent) : UIColor(snapshot.theme.accent).withAlphaComponent(0.98)
                    layer.lineColor = NSExpression(forConstantValue: color)
                    layer.lineWidth = NSExpression(forConstantValue: kind == .reference ? 3.25 : 7.0)
                }
            }
            for id in sourceIDs.subtracting(desired) {
                if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: id) { style.removeSource(source) }
                revisions[id] = nil; fallbackSignatures[id] = nil
            }
            sourceIDs = desired; latestTheme = snapshot.theme
        }

        private func update(_ annotation: LegacyMapAnnotation, payload: LegacyMapAnnotation.Payload, map: MLNMapView) {
            let coordinate = payload.coordinate
            if annotation.coordinate.latitude != coordinate.latitude || annotation.coordinate.longitude != coordinate.longitude { annotation.coordinate = coordinate }
            annotation.payload = payload
            if let view = map.view(for: annotation) as? VectorMapAnnotationView { configure(view, annotation: annotation, map: map) }
        }
        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let annotation = annotation as? LegacyMapAnnotation, case .guide(let point) = annotation.payload else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            snapshot?.onGuideSelection?(point.id)
        }
        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let annotation = annotation as? LegacyMapAnnotation else { return nil }
            let reuseID: String
            switch annotation.payload { case .guide: reuseID = "guide"; case .reference: reuseID = "reference"; case .event: reuseID = "event"; case .current: reuseID = "current" }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? VectorMapAnnotationView) ?? VectorMapAnnotationView(reuseIdentifier: reuseID)
            configure(view, annotation: annotation, map: mapView)
            return view
        }
        private func configure(_ view: VectorMapAnnotationView, annotation: LegacyMapAnnotation, map: MLNMapView) {
            // Coordinate movement is handled by the SDK. A pan without a change
            // in heading must not rebuild or relayout the same SwiftUI marker.
            if case .current(_, let theme, let course, _, let state) = annotation.payload,
               view.currentAppearance == VectorCurrentMarkerAppearance(theme: theme, course: course, heading: map.direction, state: state) {
                return
            }
            view.scalesWithViewingDistance = false
            var size = CGSize(width: 70, height: 70)
            var content: AnyView?
            view.centerOffset = .zero
            view.onActivate = nil; view.onTraitsChange = nil; view.accessibilityTraits = .image
            switch annotation.payload {
            case .guide(let point):
                size = .init(width: 66, height: 44); view.centerOffset = .init(dx: 33, dy: -22)
                let details = guideDetails
                view.onTraitsChange = { [weak view] in
                    guard let view else { return }
                    view.setImage(RouteGuideMarkerImage.image(for: point, details: details, traits: view.traitCollection))
                }
                view.onTraitsChange?()
                view.accessibilityIdentifier = "map.guide-point.\(point.id)"; view.accessibilityLabel = point.title
                view.accessibilityTraits = .button
                view.onActivate = { [weak self] in self?.snapshot?.onGuideSelection?(point.id) }
            case .reference(let marker):
                content = AnyView(ReferenceRouteMarkerView(marker: marker, layout: referenceLayout))
                let presentation = referenceLayout.presentation(for: marker)
                size = .init(width: presentation.labelWidth, height: presentation.canvasHeight)
                view.centerOffset = .init(dx: 0, dy: 4 - size.height / 2)
                view.accessibilityIdentifier = "map.reference-marker.\(marker.id)"
                view.accessibilityLabel = referenceLayout.presentation(for: marker).accessibilityLabel
            case .event(let marker, let offset, let theme):
                content = AnyView(RouteEventMarkerView(marker: marker, visualOffset: offset, theme: theme))
                view.accessibilityIdentifier = "map.event.\(marker.kind.rawValue)"
                view.accessibilityLabel = L10n.tr(marker.kind == .start ? "route_start_marker" : marker.kind == .finish ? "route_end_marker" : marker.kind == .pause ? "trip_pause" : "trip_resume")
            case .current(_, let theme, let course, _, let state):
                let appearance = VectorCurrentMarkerAppearance(theme: theme, course: course, heading: map.direction, state: state)
                if view.currentAppearance != appearance {
                    view.currentAppearance = appearance
                    content = AnyView(CurrentLocationMarker(theme: theme, course: course, mapHeading: map.direction, state: state))
                }
                size = .init(width: 54, height: 54)
                view.accessibilityIdentifier = "map.current-location"; view.accessibilityLabel = L10n.tr("map_current_location")
            }
            view.bounds = .init(origin: .zero, size: size)
            if let content { view.setContent(content) }
            view.layoutContents(); view.isAccessibilityElement = true
        }
        func apply(_ command: RouteMapCameraCommand, in map: MLNMapView) {
            guard lastCommandID != command.id else { return }
            guard map.bounds.width > 0, map.bounds.height > 0 else { pendingCommand = command; return }
            pendingCommand = nil
            guard !(map.gestureRecognizers ?? []).contains(where: { $0.state == .began || $0.state == .changed }) else { return }
            lastCommandID = command.id
            switch command.target {
            case .region(let region):
                let bounds = MLNCoordinateBounds(sw: .init(latitude: region.center.latitude - region.span.latitudeDelta / 2, longitude: region.center.longitude - region.span.longitudeDelta / 2), ne: .init(latitude: region.center.latitude + region.span.latitudeDelta / 2, longitude: region.center.longitude + region.span.longitudeDelta / 2))
                map.setVisibleCoordinateBounds(bounds, animated: false)
            case .camera(let state): map.setCamera(MLNMapCamera(lookingAtCenter: state.center, acrossDistance: state.distance, pitch: state.pitch, heading: state.heading), animated: true)
            }
        }
        func mapViewRegionIsChanging(_ mapView: MLNMapView) { publishCamera(mapView, settled: false, user: activeGesture(in: mapView)) }
        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            publishCamera(mapView, settled: true, user: !reason.intersection([.gesturePan, .gesturePinch, .gestureRotate, .gestureTilt, .gestureZoomIn, .gestureZoomOut]).isEmpty)
        }
        private func activeGesture(in map: MLNMapView) -> Bool { (map.gestureRecognizers ?? []).contains { $0.state == .began || $0.state == .changed } }
        private func publishCamera(_ map: MLNMapView, settled: Bool, user: Bool) {
#if DEBUG
            let layoutStarted = CACurrentMediaTime()
            defer { panProbe?.recordLayout(seconds: CACurrentMediaTime() - layoutStarted) }
#endif
            let camera = map.camera, bounds = map.visibleCoordinateBounds
            let state = RouteCameraState(center: camera.centerCoordinate, distance: camera.viewingDistance, heading: camera.heading, pitch: camera.pitch)
            let region = MKCoordinateRegion(center: map.centerCoordinate, span: .init(latitudeDelta: bounds.ne.latitude - bounds.sw.latitude, longitudeDelta: abs(bounds.ne.longitude - bounds.sw.longitude)))
            referenceLayout.size = map.bounds.size
            if let snapshot { updateReferenceLayout(snapshot, in: map) }
            let details = RouteGuideMapVisibility.showsDetails(distance: state.distance, wasVisible: guideDetails)
            if details != guideDetails {
                guideDetails = details
                for annotation in annotations.values {
                    if case .guide = annotation.payload, let view = map.view(for: annotation) as? VectorMapAnnotationView { configure(view, annotation: annotation, map: map) }
                }
            }
            if let arrow = annotations[.currentLocation], let view = map.view(for: arrow) as? VectorMapAnnotationView {
                configure(view, annotation: arrow, map: map)
            }
            onCameraChanged?(state, region, user)
            if settled { OfflineMapStore.shared.lastRegion = region; onCameraSettled?(state, region, user) }
#if DEBUG
            updateProbes(in: map)
#endif
        }
        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let map = tap.view as? MLNMapView, tap.state == .ended, let snapshot else { return }
            let point = tap.location(in: map)
            for annotation in annotations.values {
                guard case .guide(let guide) = annotation.payload else { continue }
                let target = map.convert(guide.coordinate, toPointTo: map)
                if let view = map.view(for: annotation), view.convert(view.bounds, to: map).contains(point) {
                    snapshot.onGuideSelection?(guide.id); return
                }
                if hypot(target.x + 33 - point.x, target.y - 22 - point.y) <= 22 { snapshot.onGuideSelection?(guide.id); return }
            }
            let ids = VideoRouteHitTest.recordings(at: point, sections: snapshot.recordedSections) { map.convert($0, toPointTo: map) }
            if !ids.isEmpty { snapshot.onVideoSelection?(ids) }
        }
        @objc private func showAllVideos() -> Bool {
            let ids = Array(Set(snapshot?.recordedSections.compactMap(\.recordingID) ?? []))
            guard !ids.isEmpty else { return false }; snapshot?.onVideoSelection?(ids); return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
#if DEBUG
        private func updateProbes(in map: MLNMapView) {
            if OSMMapLifetimeProbe.enabled, lifetimeProbe == nil {
                let probe = OSMMapLifetimeAccessibilityProbe(frame: .init(x: 0, y: 0, width: 1, height: 1))
                probe.isAccessibilityElement = true; probe.isUserInteractionEnabled = false
                probe.accessibilityIdentifier = "map.osm-lifetimes"
                map.addSubview(probe); lifetimeProbe = probe
            }
            let bounds = map.visibleCoordinateBounds
            cameraProbe?.accessibilityLabel = String(format: "camera-span:%.7f,%.7f", bounds.ne.latitude - bounds.sw.latitude, abs(bounds.ne.longitude - bounds.sw.longitude))
            cameraProbe?.accessibilityValue = String(format: "%.7f,%.7f", map.centerCoordinate.latitude, map.centerCoordinate.longitude)
            guard ProcessInfo.processInfo.arguments.contains("--ui-video-hit-probe") else { return }
            guard let section = snapshot?.recordedSections.last(where: { $0.recordingID != nil }), let coordinate = section.coordinates.dropFirst(section.coordinates.count / 2).first else { videoProbe?.removeFromSuperview(); return }
            let probe: UIView
            if let old = videoProbe { probe = old } else {
                probe = UIView(); probe.isAccessibilityElement = true; probe.isUserInteractionEnabled = false
                probe.accessibilityIdentifier = "map.video-hit-target"; probe.accessibilityLabel = "video-path"
                map.addSubview(probe); videoProbe = probe
            }
            let point = map.convert(coordinate, toPointTo: map); probe.frame = .init(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        }
#endif
    }
}

private struct VectorCurrentMarkerAppearance: Equatable {
    let theme: SpeedTheme
    let course: CLLocationDirection
    let heading: CLLocationDirection
    let state: TripState
}

private final class VectorMapAnnotationView: MLNAnnotationView {
    var currentAppearance: VectorCurrentMarkerAppearance?
    private var host: UIHostingController<AnyView>?
    private let imageView = UIImageView()
    var onActivate: (() -> Void)?
    var onTraitsChange: (() -> Void)?
    // The SDK returns the annotation's parent-relative frame. Accessibility
    // requires screen coordinates, including the normal map's card offset.
    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(bounds, in: self) }
        set { super.accessibilityFrame = newValue }
    }
    override var accessibilityActivationPoint: CGPoint {
        get {
            guard onActivate != nil else { return super.accessibilityActivationPoint }
            return UIAccessibility.convertToScreenCoordinates(
                CGRect(x: bounds.maxX - 22, y: bounds.midY, width: 0, height: 0), in: self).origin
        }
        set { super.accessibilityActivationPoint = newValue }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { onTraitsChange?() }
    }
    func setImage(_ image: UIImage) { host?.view.removeFromSuperview(); host = nil; imageView.image = image; if imageView.superview == nil { addSubview(imageView) } }
    func setContent(_ content: AnyView) {
        imageView.removeFromSuperview()
        if let host { host.rootView = content } else {
            let controller = UIHostingController(rootView: content); controller.view.backgroundColor = .clear
            controller.view.accessibilityElementsHidden = true; addSubview(controller.view); host = controller
        }
    }
    func layoutContents() { imageView.frame = bounds; host?.view.frame = bounds }
    override func accessibilityActivate() -> Bool { if let onActivate { onActivate(); return true }; return super.accessibilityActivate() }
    override func prepareForReuse() { currentAppearance = nil; host?.view.removeFromSuperview(); host = nil; imageView.removeFromSuperview(); onActivate = nil; onTraitsChange = nil; super.prepareForReuse() }
}
