import CoreLocation
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var routes: RouteArchiveStore
    @ObservedObject var referenceRoutes: ReferenceRouteStore
    @ObservedObject var location: LocationMotionService
    @ObservedObject var subscription: SubscriptionStore
    @ObservedObject var languageManager: LanguageManager
    let onUpgrade: () -> Void
    let onTestSpeedAlert: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: ConfirmationKind?
    @State private var showingLanguages = false
    @State private var showingSpeedAlert = false
    @State private var showingSpeedColors = false
    @State private var showingReferenceRoutes = false
    @State private var showingMapProvider = false
    @State private var showingOfflineMaps = false
    @State private var showingBottomNavigation = false
    @State private var showingRemoteCamera = false
    @State private var offerCodeRedemptionFailed = false

    private enum ConfirmationKind {
        case reset, clearHistory
#if DEBUG
        case debugReset(DebugResetAction)
#endif
    }
#if DEBUG
    private enum DebugResetAction {
        case switchAccess
        case resetFree
        case resetWelcome
        case resetAll

        var title: String {
            switch self {
            case .switchAccess: "Change debug access?"
            case .resetFree: "Reset debug access to Free?"
            case .resetWelcome: "Show welcome flow again?"
            case .resetAll: "Reset all debug state?"
            }
        }

        var message: String {
            switch self {
            case .switchAccess:
                "Changes only the persisted debug entitlement for this build."
            case .resetFree:
                "Removes the persisted debug entitlement. App settings and trips are kept."
            case .resetWelcome:
                "Shows onboarding on the next launch without interrupting this screen."
            case .resetAll:
                "Removes the persisted debug entitlement and shows onboarding on the next launch. App settings and trips are kept."
            }
        }

        var confirmLabel: String {
            switch self {
            case .switchAccess: "Switch Access"
            case .resetFree: "Reset Free"
            case .resetWelcome: "Reset Welcome"
            case .resetAll: "Reset All"
            }
        }

        var systemName: String {
            switch self {
            case .switchAccess: "person.badge.key.fill"
            case .resetFree, .resetWelcome, .resetAll: "arrow.counterclockwise"
            }
        }

        var confirmRole: CapsuleActionRole {
            switch self {
            case .switchAccess: .primary
            case .resetFree, .resetWelcome, .resetAll: .destructive
            }
        }
    }
#endif
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let privacyURL = URL(string: "https://spiderroute.com/ios/privacy")!

    var body: some View {
        PlatformNavigationContainer {
            ScrollViewReader { scrollProxy in
                List {
                    referenceRoutesSection
                    mapSection
                    offlineMapsSection
                    Section(L10n.tr("rc_title")) {
                        Button { showingRemoteCamera = true } label: {
                            SettingsNavigationRow(title: L10n.tr("rc_title"), systemName: "video.fill")
                        }.buttonStyle(.plain).accessibilityIdentifier("settings.remote-camera")
                    }
                    accessSection
                    Section {
                        Toggle(L10n.tr("paywall_benefit_hud"), isOn: $settings.hudEnabled)
                            .accessibilityIdentifier("settings.hud-enabled")
                    }
                    speedColorsSection
                    unitsSection
                    alertsSection
                    displaySection
                    bottomNavigationSection
                    dataSection
                    permissionsSection
                    legalSection
                    aboutSection
#if DEBUG
                    // Production-like deterministic captures must not include engineering controls.
                    if ScreenshotState.requested == nil && !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--debug-settings=") }) {
                        debugToolsSection
                    }
#endif
                }
                .onAppear {
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--debug-settings=about") {
                        DispatchQueue.main.async { scrollProxy.scrollTo("settings.about", anchor: .bottom) }
                    }
#endif
                }
                .navigationTitle(L10n.tr("settings_title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("common_done")) { dismiss() }
                    }
                }
                .background(settingsNavigationLinks)
                .overlay { confirmationOverlay }
            }
        }
        .tint(AppPalette.brandAccent)
        .environment(\.layoutDirection, languageManager.selected.isRTL ? .rightToLeft : .leftToRight)
        .accessibilityIdentifier("screen.settings")
        .onAppear {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--debug-settings=offline") { showingOfflineMaps = true }
            switch ScreenshotState.requested {
            case .settingsCamera, .settingsCameraButtons, .cameraButtonLearning: showingRemoteCamera = true
            case .settingsMapProvider: showingMapProvider = true
            case .settingsOfflineMaps, .mapRegions, .mapProvinces, .mapDownload, .mapDownloadLanguages: showingOfflineMaps = true
            case .settingsLanguages: showingLanguages = true
            case .settingsSpeedAlert: showingSpeedAlert = true
            case .settingsSpeedColors, .settingsSpeedColorsResetConfirmation: showingSpeedColors = true
            case .settingsReferenceRoutes, .settingsReferenceRouteRename, .settingsReferenceRouteDeleteConfirmation:
                showingReferenceRoutes = true
            case .settingsBottomNavigation: showingBottomNavigation = true
            case .settingsResetConfirmation: confirmation = .reset
            case .settingsHistoryConfirmation: confirmation = .clearHistory
            default: break
            }
#endif
        }
    }

    private var settingsNavigationLinks: some View {
        Group {
            NavigationLink(destination: OfflineMapsSettingsView(settings: settings), isActive: $showingOfflineMaps, label: EmptyView.init)
            NavigationLink(destination: MapProviderSettingsView(settings: settings),
                           isActive: $showingMapProvider, label: EmptyView.init)
            NavigationLink(
                destination: RemoteCameraSettingsView(),
                isActive: $showingRemoteCamera,
                label: EmptyView.init
            )
            NavigationLink(
                destination: LanguagePickerView(languageManager: languageManager),
                isActive: $showingLanguages,
                label: EmptyView.init
            )
            NavigationLink(
                destination: SpeedAlertSettingsView(settings: settings, onTestSound: onTestSpeedAlert),
                isActive: $showingSpeedAlert,
                label: EmptyView.init
            )
            NavigationLink(
                destination: SpeedColorsSettingsView(settings: settings),
                isActive: $showingSpeedColors,
                label: EmptyView.init
            )
            NavigationLink(
                destination: ReferenceRoutesSettingsView(store: referenceRoutes),
                isActive: $showingReferenceRoutes,
                label: EmptyView.init
            )
            NavigationLink(
                destination: BottomNavigationSettingsView(settings: settings),
                isActive: $showingBottomNavigation,
                label: EmptyView.init
            )
        }
        .hidden()
    }

    private var alertsSection: some View {
        Section(L10n.tr("settings_alerts")) {
            Button { showingSpeedAlert = true } label: {
                SettingsNavigationRow(
                    title: L10n.tr("settings_speed_alert"),
                    systemName: "speaker.wave.2.fill",
                    detail: speedAlertStatus
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.speed-alert")
        }
    }

    private var offlineMapsSection: some View {
        Section {
            Button { showingOfflineMaps = true } label: {
                SettingsNavigationRow(title: L10n.tr("offline_manage"), systemName: "arrow.down.circle", detail: "")
            }.buttonStyle(.plain).accessibilityIdentifier("settings.offline-maps")
        } header: { Text(L10n.tr("offline_maps")) }
    }

    private var mapSection: some View {
        Section {
            Button { showingMapProvider = true } label: {
                SettingsNavigationRow(title: L10n.tr("settings_map_provider"), systemName: "map",
                                      detail: settings.mapProvider.displayName)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.map-provider")
            Picker(L10n.tr("map_distance_label_size"), selection: $settings.distanceLabelSize) {
                ForEach(RouteDistanceLabelSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.map.distance-label-size")
            Toggle(L10n.tr("map_follow_location"), isOn: $settings.followLocationOnMap)
                .accessibilityIdentifier("settings.map.follow-location")
        } header: {
            Text(L10n.tr("settings_map"))
        } footer: {
            Text(L10n.tr("map_follow_location_footer"))
        }
    }

    private var accessSection: some View {
        Section {
            if subscription.isEntitled {
                Button(action: restore) { Label(L10n.tr("paywall_restore"), systemImage: PlatformSymbol.name("arrow.clockwise")) }
            } else {
                Button(action: onUpgrade) { Label(L10n.tr("settings_upgrade"), systemImage: PlatformSymbol.name("arrow.up.circle.fill")) }
                Button(action: restore) { Label(L10n.tr("paywall_restore"), systemImage: PlatformSymbol.name("arrow.clockwise")) }
            }
            Button(action: redeemOfferCode) {
                Label(L10n.tr("settings_redeem_offer_code"), systemImage: PlatformSymbol.name("giftcard"))
            }
            .disabled(subscription.blocksConflictingActions)
            .accessibilityIdentifier("settings.redeem-offer-code")

            if offerCodeRedemptionFailed {
                Label(L10n.tr("paywall_error_purchase"), systemImage: PlatformSymbol.name("exclamationmark.triangle.fill"))
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.redeem-offer-code.error")
            }
        } header: {
            Text(L10n.tr("settings_access"))
        } footer: {
            Text(L10n.tr(subscription.isEntitled ? "settings_access_plus" : "settings_access_free"))
        }
    }

    private var unitsSection: some View {
        Section(L10n.tr("settings_units")) {
            Picker(L10n.tr("settings_speed_unit"), selection: $settings.unit) {
                ForEach(SpeedUnit.allCases) { unit in Text(unit.localizedName).tag(unit) }
            }
            HStack {
                Text(L10n.tr("settings_maximum_speed"))
                Spacer()
                Text("\(Int(settings.maximumSpeed)) \(settings.unit.rawValue)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $settings.maximumSpeed, in: 60...500, step: 10)
                .accessibilityLabel(L10n.tr("settings_maximum_speed"))
        }
    }

    private var speedColorsSection: some View {
        Section {
            Button { showingSpeedColors = true } label: {
                SettingsNavigationRow(
                    title: L10n.tr("settings_speed_colors"),
                    systemName: "paintpalette.fill"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.speed-colors")
        }
    }

    private var displaySection: some View {
        Section(L10n.tr("settings_display")) {
            if #available(iOS 16.0, *) {
                Picker(L10n.tr("settings_speed_number_style"), selection: $settings.speedNumberStyle) {
                    ForEach(SpeedNumberStyle.allCases) { style in
                        Text(style.localizedName)
                            .tag(style)
                            .accessibilityIdentifier("settings.speed-number-style.option.\(style.rawValue)")
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.speed-number-style")
            } else {
                Menu {
                    ForEach(SpeedNumberStyle.allCases) { style in
                        Button {
                            settings.speedNumberStyle = style
                        } label: {
                            Text(style.localizedName)
                        }
                        .accessibilityIdentifier("settings.speed-number-style.option.\(style.rawValue)")
                    }
                } label: {
                    HStack {
                        Text(L10n.tr("settings_speed_number_style"))
                        Spacer()
                        Text(settings.speedNumberStyle.localizedName)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("settings.speed-number-style")
            }
            Picker(L10n.tr("settings_color_theme"), selection: $settings.theme) {
                ForEach(SpeedTheme.allCases) { theme in Text(theme.localizedName).tag(theme) }
            }
            Toggle(L10n.tr("settings_decimal_speed"), isOn: $settings.showDecimal)
            Toggle(L10n.tr("settings_gps_strength"), isOn: $settings.showGPSStrength)
            Button { confirmation = .reset } label: { Text(L10n.tr("settings_reset")) }
        }
    }

    private var bottomNavigationSection: some View {
        Section {
            Button { showingBottomNavigation = true } label: {
                SettingsNavigationRow(
                    title: L10n.tr("settings_bottom_navigation"),
                    systemName: "rectangle.bottomthird.inset.filled"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.bottom-navigation")
        }
    }

    private var dataSection: some View {
        Section(L10n.tr("settings_data")) {
            Toggle(L10n.tr("settings_icloud_sync"), isOn: $settings.syncWithICloud)
            Label(L10n.tr(routes.storageStatusKey), systemImage: PlatformSymbol.name("icloud"))
                .foregroundStyle(.secondary)
            Button(role: .destructive) { confirmation = .clearHistory } label: { Text(L10n.tr("settings_clear_history")) }
                .disabled(routes.isLoading)
        }
    }

    private var referenceRoutesSection: some View {
        Section {
            Button { showingReferenceRoutes = true } label: {
                SettingsNavigationRow(
                    title: L10n.tr("settings_reference_routes"),
                    systemName: "map",
                    detail: referenceRoutes.routes.count.formatted()
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.reference-routes")
        }
    }

    private var permissionsSection: some View {
        Section(L10n.tr("settings_permissions")) {
            HStack {
                Label(L10n.tr("settings_location"), systemImage: PlatformSymbol.name("location"))
                Spacer()
                Text(locationStatus).foregroundStyle(.secondary)
            }
            HStack {
                Label(L10n.tr("settings_motion"), systemImage: PlatformSymbol.name("figure.walk.motion"))
                Spacer()
                Text(L10n.tr(location.isMotionAuthorized ? "permission_allowed" : "permission_not_allowed")).foregroundStyle(.secondary)
            }
        }
    }

    private var legalSection: some View {
        Section(L10n.tr("settings_legal")) {
            Link(destination: privacyURL) { Label(L10n.tr("paywall_privacy"), systemImage: PlatformSymbol.name("hand.raised")) }
            Link(destination: termsURL) { Label(L10n.tr("paywall_terms"), systemImage: PlatformSymbol.name("doc.text")) }
        }
    }

    private var aboutSection: some View {
        Section {
            Button { showingLanguages = true } label: {
                HStack {
                    Label(L10n.tr("settings_language"), systemImage: PlatformSymbol.name("globe"))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer()
                    Text(languageManager.selected.nativeName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("settings.language.value")
                    Image(systemName: PlatformSymbol.name("chevron.forward")).font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack {
                Label(L10n.tr("settings_version"), systemImage: PlatformSymbol.name("info.circle"))
                Spacer()
                Text(version).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.version")
            .id("settings.about")
        }
    }

#if DEBUG
    private var debugToolsSection: some View {
        Section {
            Button { confirmation = .debugReset(.switchAccess) } label: {
                Label(subscription.debugPaidModeEnabled ? "Switch to Free" : "Switch to Paid", systemImage: PlatformSymbol.name("person.badge.key.fill"))
            }
            .accessibilityIdentifier("settings.debug.switch-access")

            Button(role: .destructive) { confirmation = .debugReset(.resetFree) } label: {
                Label("Reset Free", systemImage: PlatformSymbol.name("arrow.counterclockwise"))
            }
            .accessibilityIdentifier("settings.debug.reset-free")

            Button(role: .destructive) { confirmation = .debugReset(.resetWelcome) } label: {
                Label("Reset Welcome", systemImage: PlatformSymbol.name("arrow.counterclockwise"))
            }
            .accessibilityIdentifier("settings.debug.reset-welcome")

            Button(role: .destructive) { confirmation = .debugReset(.resetAll) } label: {
                Label("Reset All", systemImage: PlatformSymbol.name("arrow.counterclockwise"))
            }
            .accessibilityIdentifier("settings.debug.reset-all")
        } header: {
            Text("Debug")
        } footer: {
            Text("Debug builds only. Each action asks for confirmation before changing stored state.")
        }
    }
#endif

    @ViewBuilder private var confirmationOverlay: some View {
        switch confirmation {
        case .reset:
            DestructiveConfirmationModal(title: L10n.tr("reset_title"), message: L10n.tr("reset_message"), confirmLabel: L10n.tr("settings_reset"), onCancel: { confirmation = nil }) {
                settings.reset(); OfflineMapStore.shared.selectedID = nil; confirmation = nil
            }
            .accessibilityIdentifier("settings.reset.confirmation")
        case .clearHistory:
            DestructiveConfirmationModal(title: L10n.tr("clear_history_title"), message: L10n.tr("clear_history_message"), confirmLabel: L10n.tr("settings_clear"), onCancel: { confirmation = nil }) {
                routes.clear(syncWithICloud: settings.syncWithICloud); confirmation = nil
            }
            .accessibilityIdentifier("settings.clear.confirmation")
#if DEBUG
        case .debugReset(let action):
            DestructiveConfirmationModal(
                title: action.title,
                message: action.message,
                confirmLabel: action.confirmLabel,
                confirmRole: action.confirmRole,
                systemName: action.systemName,
                onCancel: { confirmation = nil },
                onConfirm: {
                    performDebugReset(action)
                    confirmation = nil
                }
            )
            .accessibilityIdentifier("settings.debug-reset.confirmation")
#endif
        case nil:
            EmptyView()
        }
    }

#if DEBUG
    private func performDebugReset(_ action: DebugResetAction) {
        switch action {
        case .switchAccess:
            subscription.toggleDebugAccessMode()
        case .resetFree:
            subscription.resetDebugFreeMode()
        case .resetWelcome:
            WelcomePresentationStore.reset()
        case .resetAll:
            subscription.resetDebugFreeMode()
            WelcomePresentationStore.reset()
        }
    }
#endif

    private var locationStatus: String {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: L10n.tr("permission_allowed")
        case .denied, .restricted: L10n.tr("permission_not_allowed")
        case .notDetermined: L10n.tr("permission_not_asked")
        @unknown default: L10n.tr("permission_not_asked")
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var speedAlertStatus: String {
        guard settings.speedAlertEnabled else { return L10n.tr("settings_speed_alert_off") }
        let limit = settings.unit.value(fromMetersPerSecond: settings.speedAlertLimitMetersPerSecond)
        return L10n.format("settings_speed_alert_on_format", Int(limit.rounded()), settings.unit.rawValue)
    }

    private func restore() { Task { _ = await subscription.restore() } }

    private func redeemOfferCode() {
        offerCodeRedemptionFailed = false
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            offerCodeRedemptionFailed = true
            return
        }

        Task {
            let outcome = await subscription.redeemOfferCode(in: scene)
            offerCodeRedemptionFailed = outcome == .failed
        }
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let systemName: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: PlatformSymbol.name(systemName))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .monospacedDigit()
            }
            Image(systemName: PlatformSymbol.name("chevron.forward"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct SpeedColorsSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showingResetConfirmation = false

    var body: some View {
        List {
            appearanceSection(
                titleKey: "settings_light_mode",
                numberColor: $settings.lightSpeedNumberColor,
                outlineEnabled: $settings.lightSpeedOutlineEnabled,
                outlineColor: $settings.lightSpeedOutlineColor,
                identifier: "light"
            )
            appearanceSection(
                titleKey: "settings_dark_mode",
                numberColor: $settings.darkSpeedNumberColor,
                outlineEnabled: $settings.darkSpeedOutlineEnabled,
                outlineColor: $settings.darkSpeedOutlineColor,
                identifier: "dark"
            )
            Section {
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label(L10n.tr("settings_speed_colors_reset_action"), systemImage: PlatformSymbol.name("arrow.counterclockwise"))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("settings.speed-colors.reset")
            }
        }
        .navigationTitle(L10n.tr("settings_speed_colors"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.settings.speed-colors")
        .overlay {
            if showingResetConfirmation {
                DestructiveConfirmationModal(
                    title: L10n.tr("settings_speed_colors_reset_title"),
                    message: L10n.tr("settings_speed_colors_reset_message"),
                    confirmLabel: L10n.tr("settings_speed_colors_reset_action"),
                    systemName: "arrow.counterclockwise",
                    onCancel: { showingResetConfirmation = false },
                    onConfirm: {
                        settings.resetSpeedColors()
                        showingResetConfirmation = false
                    }
                )
                .accessibilityIdentifier("settings.speed-colors.reset-confirmation")
            }
        }
        .onAppear {
#if DEBUG
            if ScreenshotState.requested == .settingsSpeedColorsResetConfirmation {
                showingResetConfirmation = true
            }
#endif
        }
    }

    private func appearanceSection(
        titleKey: String,
        numberColor: Binding<DisplayColor>,
        outlineEnabled: Binding<Bool>,
        outlineColor: Binding<DisplayColor>,
        identifier: String
    ) -> some View {
        Section {
            ColorPicker(
                L10n.tr("settings_number_color"),
                selection: displayColorBinding(numberColor),
                supportsOpacity: false
            )
            .accessibilityIdentifier("settings.speed-color.\(identifier).number")

            Toggle(L10n.tr("settings_number_outline"), isOn: outlineEnabled)
                .accessibilityIdentifier("settings.speed-color.\(identifier).outline-enabled")

            ColorPicker(
                L10n.tr("settings_outline_color"),
                selection: displayColorBinding(outlineColor),
                supportsOpacity: false
            )
            .disabled(!outlineEnabled.wrappedValue)
            .accessibilityIdentifier("settings.speed-color.\(identifier).outline")
        } header: {
            Text(L10n.tr(titleKey))
        } footer: {
            if identifier == "dark" { Text(L10n.tr("settings_speed_colors_footer")) }
        }
    }

    private func displayColorBinding(_ value: Binding<DisplayColor>) -> Binding<Color> {
        Binding(
            get: { value.wrappedValue.color },
            set: { value.wrappedValue = DisplayColor($0) }
        )
    }
}

private struct BottomNavigationSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var editMode: EditMode = .active

    var body: some View {
        List {
            Section {
                ForEach(Array(settings.bottomNavigationOrder.enumerated()), id: \.element.id) { index, item in
                    Label(item.localizedName, systemImage: PlatformSymbol.name(item.symbolName))
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue("\(index + 1)")
                        .accessibilityIdentifier("settings.bottom-navigation.item.\(item.rawValue)")
                }
                .onMove(perform: settings.moveBottomNavigation)
            } footer: {
                Text(L10n.tr("settings_bottom_navigation_footer"))
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(L10n.tr("settings_bottom_navigation"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.settings.bottom-navigation")
    }
}

private struct SpeedAlertSettingsView: View {
    @ObservedObject var settings: AppSettings
    let onTestSound: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                Toggle(L10n.tr("settings_speed_alert_enabled"), isOn: $settings.speedAlertEnabled)
                    .accessibilityIdentifier("speed-alert.enabled")
            } footer: {
                Text(L10n.tr("settings_speed_alert_footer"))
            }

            if settings.speedAlertEnabled {
                Section(L10n.tr("settings_speed_alert_limit")) {
                    VStack(spacing: 18) {
                        speedLimitSign
                        Slider(value: displayLimitBinding, in: displayRange, step: displayStep)
                            .accessibilityLabel(L10n.tr("settings_speed_alert_limit"))
                            .accessibilityValue("\(Int(displayLimit.rounded())) \(settings.unit.rawValue)")
                    }
                    .padding(.vertical, 10)

                    Button(action: onTestSound) {
                        Label(L10n.tr("settings_test_warning_sound"), systemImage: PlatformSymbol.name("speaker.wave.2.fill"))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("speed-alert.test-sound")
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: settings.speedAlertEnabled)
        .navigationTitle(L10n.tr("settings_speed_alert_title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.speed-alert-settings")
    }

    private var speedLimitSign: some View {
        VStack(spacing: 7) {
            Text(Int(displayLimit.rounded()).formatted())
                .font(.system(size: 54, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 132, height: 132)
                .background(AppPalette.raisedCard(colorScheme), in: Circle())
                .overlay(Circle().stroke(Color.red, lineWidth: 10))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 12, y: 5)

            Text(settings.unit.rawValue)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("settings_speed_alert_limit"))
        .accessibilityValue("\(Int(displayLimit.rounded())) \(settings.unit.rawValue)")
    }

    private var displayLimit: Double {
        settings.unit.value(fromMetersPerSecond: settings.speedAlertLimitMetersPerSecond)
    }

    private var displayLimitBinding: Binding<Double> {
        Binding(
            get: { displayLimit },
            set: { settings.speedAlertLimitMetersPerSecond = settings.unit.metersPerSecond(from: $0) }
        )
    }

    private var displayRange: ClosedRange<Double> {
        switch settings.unit {
        case .kilometersPerHour: 30...300
        case .milesPerHour: 20...190
        case .metersPerSecond: 8...84
        case .knots: 15...165
        }
    }

    private var displayStep: Double {
        settings.unit == .metersPerSecond ? 1 : 5
    }
}

struct LanguagePickerView: View {
    @ObservedObject var languageManager: LanguageManager
    @Environment(\.dismiss) private var dismiss

    private var ordered: [AppLanguage] {
        let preferredIDs = Locale.preferredLanguages.map(AppLanguage.normalized)
        let preferred = preferredIDs.compactMap { id in AppLanguage.all.first(where: { $0.id == id }) }
        let rest = AppLanguage.all.filter { !preferred.contains($0) }.sorted { $0.nativeName.localizedStandardCompare($1.nativeName) == .orderedAscending }
        var seen = Set<String>()
        return (preferred + rest).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        List(ordered) { language in
            Button {
                languageManager.selected = language
                dismiss()
            } label: {
                HStack {
                    Text(language.nativeName).foregroundStyle(.primary)
                    Spacer()
                    if language == languageManager.selected { Image(systemName: PlatformSymbol.name("checkmark")).font(.body.weight(.bold)) }
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .environment(\.defaultMinListRowHeight, 52)
        .navigationTitle(L10n.tr("settings_language"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.languages")
    }
}


private struct MapProviderSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var offlineMaps = OfflineMapStore.shared

    var body: some View {
        List {
            ForEach(MapProvider.allCases) { provider in
                Button { settings.mapProvider = provider } label: {
                    HStack {
                        Text(provider.displayName).foregroundStyle(.primary)
                        Spacer()
                        if settings.mapProvider == provider {
                            Image(systemName: "checkmark").foregroundStyle(AppPalette.brandAccent)
                        }
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.mapProvider == provider ? .isSelected : [])
                .accessibilityIdentifier("settings.map-provider.option.\(provider.rawValue)")
            }
            if settings.mapProvider == .openStreetMap {
                Picker(L10n.tr("offline_language"), selection: Binding(get: { offlineMaps.selectedLanguageID ?? settings.mapLanguageID ?? "" }, set: { settings.mapLanguageID = $0.isEmpty ? nil : $0; OfflineMapStore.shared.selectedID = nil })) {
                    Text(L10n.tr("settings_language")).tag("")
                    ForEach(AppLanguage.all) { language in Text(language.nativeName).tag(language.id) }
                }.accessibilityIdentifier("settings.map-language")
            }
        }
        .navigationTitle(L10n.tr("settings_map_provider"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.settings.map-provider")
    }
}
