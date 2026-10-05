import CoreLocation
import SwiftUI
import UIKit

struct MainShellView: View {
    @State private var isSavingTrip = false
    @State private var showingTripSaveError = false
    enum Tab: String, CaseIterable { case map, speed, trips, camera }

    struct InitialNavigationState: Equatable {
        let tab: Tab
        let showsPaywall: Bool
    }

    @ObservedObject var location: LocationMotionService
    @ObservedObject var recorder: TripRecorder
    @ObservedObject var settings: AppSettings
    @ObservedObject var routes: RouteArchiveStore
    @ObservedObject var referenceRoute: ReferenceRouteStore
    @ObservedObject var incomingReferenceRoute: IncomingReferenceRouteCoordinator
    @ObservedObject var subscription: SubscriptionStore
    @ObservedObject var languageManager: LanguageManager
    @EnvironmentObject private var remoteCamera: RemoteCameraController
    @StateObject private var speedAlertController = SpeedAlertController()
    let startsWithPaywall: Bool
    let onInitialPaywallClosed: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var tab: Tab
    @State private var showingSettings: Bool
    @State private var showingPaywall: Bool
    @State private var showingFinishConfirmation: Bool
    @State private var pendingTripDeletion: TripRecord?
    @State private var hiddenTripIDs: Set<UUID> = []
    @State private var showingIncomingRouteError = false
    @State private var showingHUD = false
    @State private var presentsHUDAfterPaywall = false

    init(location: LocationMotionService, recorder: TripRecorder, settings: AppSettings, routes: RouteArchiveStore, referenceRoute: ReferenceRouteStore, incomingReferenceRoute: IncomingReferenceRouteCoordinator, subscription: SubscriptionStore, languageManager: LanguageManager, startsWithPaywall: Bool, onInitialPaywallClosed: @escaping () -> Void) {
        self.location = location
        self.recorder = recorder
        self.settings = settings
        self.routes = routes
        self.referenceRoute = referenceRoute
        self.incomingReferenceRoute = incomingReferenceRoute
        self.subscription = subscription
        self.languageManager = languageManager
        self.startsWithPaywall = startsWithPaywall
        self.onInitialPaywallClosed = onInitialPaywallClosed
        let initialNavigation = Self.initialNavigationState(
            order: settings.bottomNavigationOrder,
            isEntitled: subscription.isEntitled,
            startsWithPaywall: startsWithPaywall
        )
#if DEBUG
        let requested = ScreenshotState.requested
        _tab = State(initialValue: requested.map { state in
            if state.rawValue.hasPrefix("camera.") { return .camera }
            if state.isMapScreen || state == .mapFinishConfirmation || state.opensSettings || state.opensPaywall { return .map }
            if state.usesMockTrips || state == .tripsEmpty { return .trips }
            return .speed
        } ?? ((ProcessInfo.processInfo.arguments.contains("--debug-map-pan-probe") || ProcessInfo.processInfo.arguments.contains("--debug-map-free-browse-probe") || ProcessInfo.processInfo.arguments.contains("--debug-map-expanded")) ? .map : initialNavigation.tab))
        _showingSettings = State(initialValue: requested?.opensSettings == true || ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--debug-settings=") })
        _showingPaywall = State(initialValue: requested == nil ? initialNavigation.showsPaywall : startsWithPaywall || requested?.opensPaywall == true)
        _showingFinishConfirmation = State(initialValue: requested == .speedFinishConfirmation || requested == .mapFinishConfirmation)
        _pendingTripDeletion = State(initialValue: requested == .tripsDeleteConfirmation ? TripsView.mockTrip : nil)
#else
        _tab = State(initialValue: initialNavigation.tab)
        _showingSettings = State(initialValue: false)
        _showingPaywall = State(initialValue: initialNavigation.showsPaywall)
        _showingFinishConfirmation = State(initialValue: false)
        _pendingTripDeletion = State(initialValue: nil)
#endif
    }

    var body: some View {
        ZStack {
            AppPalette.canvas(colorScheme).ignoresSafeArea()
            VStack(spacing: 10) {
                header
                Group {
                    switch tab {
                    case .speed:
                        SpeedDashboardView(location: location, recorder: recorder, settings: settings, routes: routes, subscription: subscription, mockMetersPerSecond: screenshotSpeedOverride, onShowPaywall: { showingPaywall = true }, onRequestFinish: { showingFinishConfirmation = true })
                    case .map:
                        RouteMapView(
                            recorder: recorder,
                            location: location,
                            routes: routes,
                            referenceRoute: referenceRoute,
                            settings: settings,
                            subscription: subscription,
                            onShowPaywall: { showingPaywall = true },
                            onRequestFinish: { showingFinishConfirmation = true }
                        )
                    case .camera:
                        RemoteCameraTabView()
                    case .trips:
                        TripsView(
                            routes: routes,
                            settings: settings,
                            hiddenTripIDs: hiddenTripIDs,
                            onRequestDelete: { pendingTripDeletion = $0 }
                        )
                    }
                }
                .frame(maxHeight: .infinity)
                tabBar
            }
            .padding(.top, 4)

            if showingFinishConfirmation {
                DestructiveConfirmationModal(
                    title: L10n.tr("trip_finish_confirmation_title"),
                    message: L10n.tr("trip_finish_confirmation_message"),
                    confirmLabel: L10n.tr("trip_finish"),
                    confirmRole: .primary,
                    systemName: "flag.checkered",
                    onCancel: { showingFinishConfirmation = false },
                    onConfirm: finishTrip
                )
                .accessibilityIdentifier("trip.finish.confirmation")
            }

            if pendingTripDeletion != nil {
                DestructiveConfirmationModal(
                    title: L10n.tr("trip_delete_confirmation_title"),
                    message: L10n.tr("trip_delete_confirmation_message"),
                    confirmLabel: L10n.tr("common_delete"),
                    systemName: "trash.fill",
                    onCancel: { pendingTripDeletion = nil },
                    onConfirm: confirmTripDeletion
                )
                .accessibilityIdentifier("trip.delete.confirmation")
            }

            if let checkpoint = recorder.pendingRecovery {
                TripRecoveryModal(
                    checkpoint: checkpoint,
                    distance: recorder.recoveryDistance,
                    settings: settings,
                    onDiscard: discardRecoveredTrip,
                    onContinue: continueRecoveredTrip
                )
                .disabled(routes.isLoading)
            }

            if referenceRoute.isImporting {
                Color.black.opacity(0.2).ignoresSafeArea()
                ProgressView().padding(24).background(.regularMaterial)
            }

            if let incomingURL = incomingReferenceRoute.currentURL, !referenceRoute.isImporting {
                RouteNameEditorModal(
                    title: L10n.tr("reference_route_import"),
                    message: L10n.tr("reference_routes_formats_footer"),
                    sourceFileName: incomingURL.lastPathComponent,
                    name: $incomingReferenceRoute.currentName,
                    confirmLabel: L10n.tr("common_import"),
                    systemName: "doc.badge.plus",
                    accessibilityName: "reference-route.import.confirmation",
                    onCancel: incomingReferenceRoute.cancelCurrent,
                    onConfirm: confirmIncomingRouteImport
                )
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                settings: settings,
                routes: routes,
                referenceRoutes: referenceRoute,
                location: location,
                subscription: subscription,
                languageManager: languageManager,
                onUpgrade: {
                    showingSettings = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        showingPaywall = true
                    }
                },
                onTestSpeedAlert: speedAlertController.playPreview
            )
            .platformLargeSheetPresentation()
        }
        .sheet(isPresented: $showingPaywall, onDismiss: paywallClosed) {
            PaywallView(subscription: subscription, onClose: { showingPaywall = false }, previewState: paywallPreview)
                .environment(\.layoutDirection, languageManager.selected.isRTL ? .rightToLeft : .leftToRight)
                .modifier(PaywallSheetSizing(usesContentSizedSheet: horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad))
        }
        .fullScreenCover(isPresented: $showingHUD) {
            HUDView(location: location, settings: settings)
        }
        .fullScreenCover(isPresented: $remoteCamera.blackScreen) {
            RemoteCameraBlackView()
        }
        .onChange(of: remoteCamera.showsCamera) { visible in
            if !visible && tab == .camera { tab = .map }
        }
        .alert(L10n.tr("reference_route_import_failed_title"), isPresented: $showingIncomingRouteError) {
            Button(L10n.tr("common_ok"), role: .cancel) {}
        } message: {
            Text(L10n.tr("reference_route_import_failed_message"))
        }
        .onReceive(incomingReferenceRoute.$pendingURLs) { pendingURLs in
            guard !pendingURLs.isEmpty else { return }
            showingSettings = false
            showingPaywall = false
        }
        .onReceive(location.$latestLocation.compactMap { $0 }) { latestLocation in
            recorder.add(latestLocation)
            speedAlertController.process(
                speedMetersPerSecond: max(0, latestLocation.speed),
                limitMetersPerSecond: settings.speedAlertLimitMetersPerSecond,
                isEnabled: settings.speedAlertEnabled
            )
        }
        .onChange(of: remoteCamera.armed) { armed in
            location.setCameraStandby(armed)
        }
        .onChange(of: recorder.state) { newState in
            location.setTripTrackingActive(newState == .recording)
        }
        .disabled(isSavingTrip)
        .overlay { if isSavingTrip { ProgressView().padding(24).background(.regularMaterial) } }
        .alert(L10n.tr("trip_finish"), isPresented: $showingTripSaveError) {
            Button(L10n.tr("common_ok"), role: .cancel) {}
        } message: { Text(L10n.tr("route_export_failed_body")) }
        .task {
            await recorder.waitForRecoveryLoad()
            // Retire an already saved local checkpoint without waiting for iCloud.
            await recorder.retireAlreadyArchivedRecovery(in: routes.trips)
            await routes.waitForLoad()
            await recorder.retireAlreadyArchivedRecovery(in: routes.trips)
            await referenceRoute.waitForLoad()
            prepareScreenshotState()
        }
        .task {
#if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--debug-route-1000km") {
                await LongRecordingProbe.runIfRequested()
            }
#endif
        }
    }

    private func finishTrip() {
        guard !isSavingTrip else { return }
        showingFinishConfirmation = false
        isSavingTrip = true
        if recorder.state == .recording { recorder.togglePause() }
        Task {
            let protection = BackgroundPersistenceTask(name: "Finish route")
            defer { isSavingTrip = false; protection.finish() }
            await recorder.awaitCheckpointWrites()
            guard let trip = recorder.finishedRecord(activity: location.activityKey) else { return }
            if await routes.saveFinishedTrip(trip, syncWithICloud: settings.syncWithICloud) {
                await recorder.completeFinishedTrip()
            } else { showingTripSaveError = true }
        }
    }

    private func continueRecoveredTrip() {
        recorder.continueRecoveredTrip()
        location.setTripTrackingActive(recorder.state == .recording)
    }

    private func discardRecoveredTrip() {
        recorder.discardRecoveredTrip()
        location.setTripTrackingActive(false)
    }

    private func confirmTripDeletion() {
        guard !routes.isLoading, let trip = pendingTripDeletion else { return }
        hiddenTripIDs.insert(trip.id)
        routes.delete(trip, syncWithICloud: settings.syncWithICloud)
        pendingTripDeletion = nil
    }

    private func confirmIncomingRouteImport() {
        Task {
            do {
                try await incomingReferenceRoute.importCurrentInBackground(into: referenceRoute)
                tab = .map
            } catch { showingIncomingRouteError = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L10n.tr("tab_\(tab.rawValue)_title"))
                .font(AppTypography.screenTitle)
                .lineLimit(1)
            Spacer()
            if settings.hudEnabled {
                CircularIconButton(systemName: "rectangle.inset.filled.and.person.filled", accessibilityLabel: L10n.tr("paywall_benefit_hud"), tint: AppPalette.brandAccent) { showHUD() }
                    .accessibilityIdentifier("header.hud")
            }
            CircularIconButton(
                systemName: colorScheme == .light ? "moon.fill" : "sun.max.fill",
                accessibilityLabel: L10n.tr("settings_color_theme"),
                tint: AppPalette.brandAccent
            ) {
                settings.appearance = colorScheme == .dark ? .light : .dark
            }
            .accessibilityIdentifier("header.appearance.\(colorScheme == .dark ? "dark" : "light")")
            CircularIconButton(systemName: "gearshape.fill", accessibilityLabel: L10n.tr("settings_title"), tint: AppPalette.brandAccent) { showingSettings = true }
                .accessibilityIdentifier("header.settings")
        }
        .padding(.horizontal, 18)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(settings.bottomNavigationOrder) { item in
                bottomNavigationButton(item)
            }
            if remoteCamera.showsCamera { tabButton(.camera, symbol: "video.fill") }
        }
        .padding(6)
        .background(AppPalette.card(colorScheme), in: Capsule())
        .overlay(Capsule().strokeBorder(AppPalette.controlOutline(colorScheme), lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func bottomNavigationButton(_ item: BottomNavigationItem) -> some View {
        switch item {
        case .speed:
            tabButton(.speed, symbol: item.symbolName)
        case .map:
            tabButton(.map, symbol: item.symbolName)
        case .trips:
            tabButton(.trips, symbol: item.symbolName)
        }
    }

    private func tabButton(_ item: Tab, symbol: String) -> some View {
        let isSelected = tab == item

        return Button { tab = item } label: {
            VStack(spacing: 3) {
                Image(systemName: PlatformSymbol.name(symbol)).font(.subheadline.weight(.bold))
                Text(L10n.tr("tab_\(item.rawValue)"))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? AppPalette.charcoal : .secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                isSelected
                    ? AppPalette.primaryAction
                    : Color.clear,
                in: Capsule()
            )
            .overlay {
                if isSelected {
                    Capsule().strokeBorder(AppPalette.actionOutline, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(item.rawValue)")
    }

    private var screenshotSpeedOverride: Double? {
#if DEBUG
        if ScreenshotState.requested == .speedAlert { return 32 / 3.6 }
        if ScreenshotState.requested == .speedIdle || ScreenshotState.requested == .speedGauge || ScreenshotState.requested == .speedRecording || ScreenshotState.requested == .speedFinishConfirmation { return 24 / 3.6 }
#endif
        return nil
    }

    private func showHUD() {
        guard settings.hudEnabled else { return }
        guard subscription.isEntitled else {
            presentsHUDAfterPaywall = true
            showingPaywall = true
            return
        }
        showingHUD = true
    }

    private func paywallClosed() {
        if startsWithPaywall {
            onInitialPaywallClosed()
        }
        defer { presentsHUDAfterPaywall = false }
        if presentsHUDAfterPaywall, settings.hudEnabled, subscription.isEntitled {
            showingHUD = true
        }
    }

    static func initialNavigationState(
        order: [BottomNavigationItem],
        isEntitled: Bool,
        startsWithPaywall: Bool
    ) -> InitialNavigationState {
        let firstItem = BottomNavigationItem.normalized(order.map(\.rawValue)).first ?? .map
        let fallbackTab: Tab
        switch firstItem {
        case .speed: fallbackTab = .speed
        case .map: fallbackTab = .map
        case .trips: fallbackTab = .trips
        }
        return InitialNavigationState(tab: fallbackTab, showsPaywall: startsWithPaywall)
    }

    private var paywallPreview: PaywallPreviewState? {
#if DEBUG
        ScreenshotState.requested?.paywallPreview
#else
        nil
#endif
    }

    private func prepareScreenshotState() {
#if DEBUG
        remoteCamera.applyFixture(ScreenshotState.requested)
        if ScreenshotState.requested == .speedGauge {
            settings.speedDashboardStyle = .gauge
        } else if ScreenshotState.requested == .speedIdle || ScreenshotState.requested == .speedRecording || ScreenshotState.requested == .speedFinishConfirmation || ScreenshotState.requested == .speedAlert {
            settings.speedDashboardStyle = .number
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-long-route"), recorder.state == .idle {
            recorder.installLongRideFixture()
        }
        if ScreenshotState.requested == .tripRecovery {
            recorder.installMockRecoveryCheckpoint()
        }
        if (ScreenshotState.requested == .speedRecording || ScreenshotState.requested == .speedFinishConfirmation || ScreenshotState.requested?.isMapRoute == true || ScreenshotState.requested == .mapFinishConfirmation), recorder.state == .idle {
            if let fixture = ScreenshotCityFixture.current {
                let points = fixture.trackPoints
                let shift = Date().timeIntervalSince(points.last!.timestamp)
                recorder.start(now: points.first!.timestamp.addingTimeInterval(shift))
                for point in points {
                    recorder.add(CLLocation(coordinate: point.coordinate, altitude: point.altitude,
                        horizontalAccuracy: 5, verticalAccuracy: 6, course: -1, speed: point.metersPerSecond,
                        timestamp: point.timestamp.addingTimeInterval(shift)))
                }
            } else {
            recorder.start(now: Date().addingTimeInterval(-143))
            let segmentStarts: Set<Int>
            switch ScreenshotState.requested {
            case .mapRouteOnePause: segmentStarts = [4]
            case .mapRouteMultiplePauses: segmentStarts = [3, 5]
            default: segmentStarts = []
            }
            for (index, coordinate) in RouteMapView.mockRoute.enumerated() {
                if segmentStarts.contains(index) {
                    recorder.togglePause(now: Date().addingTimeInterval(Double(index) * 18 - 122))
                    recorder.togglePause(now: Date().addingTimeInterval(Double(index) * 18 - 121))
                }
                recorder.add(CLLocation(coordinate: coordinate, altitude: 214, horizontalAccuracy: 5, verticalAccuracy: 6, course: 32, speed: 5 + Double(index) * 0.25, timestamp: Date().addingTimeInterval(Double(index) * 18 - 120)))
            }
        }
        }
        if [.mapVideoSections, .mapVideoSectionsFullscreen, .mapVideoInfo].contains(ScreenshotState.requested) {
            recorder.installVideoFixture()
        }
        if ScreenshotState.requested == .speedAlert || ScreenshotState.requested == .settingsSpeedAlert {
            settings.speedAlertEnabled = true
            settings.speedAlertLimitMetersPerSecond = 30 / 3.6
        }
#endif
    }
}

private struct PaywallSheetSizing: ViewModifier {
    let usesContentSizedSheet: Bool
    func body(content: Content) -> some View {
        content.platformFixedSheetHeight(700, enabled: usesContentSizedSheet)
    }
}
