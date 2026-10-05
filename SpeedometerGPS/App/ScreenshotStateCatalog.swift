import Foundation
import SwiftUI

#if DEBUG
enum ScreenshotState: String, CaseIterable {
    case cameraPhotos = "camera.photos"
    case cameraSetup = "camera.setup"
    case cameraSearching = "camera.searching"
    case cameraConnecting = "camera.connecting"
    case cameraPairingWaiting = "camera.pairing-waiting"
    case mapCameraSearching = "map.camera-searching"
    case cameraReady = "camera.ready"
    case cameraPairing = "camera.pairing"
    case cameraBlack = "camera.black"
    case cameraExit = "camera.exit"
    case settingsCamera = "settings.camera"
    case settingsCameraButtons = "settings.camera-buttons"
    case cameraButtonLearning = "camera.button-learning"
    case mapCameraFullscreenReady = "map.camera-fullscreen-ready"
    case mapCameraFullscreenRecording = "map.camera-fullscreen-recording"
    case mapCameraInfo = "map.camera-info"
    case mapCameraReference = "map.camera-reference"
    case mapCameraReady = "map.camera-ready"
    case mapCameraRecording = "map.camera-recording"
    case mapCameraStarting = "map.camera-starting"
    case mapCameraSaving = "map.camera-saving"
    case mapCameraError = "map.camera-error"
    case mapCameraOffline = "map.camera-offline"
    case loader = "loader"
    case welcomeRoute = "welcome.route"
    case welcomeDisplayNumber = "welcome.display.number"
    case welcomeDisplaySwipe = "welcome.display.swipe"
    case welcomeDisplayGauge = "welcome.display.gauge"
    case welcomeRides = "welcome.rides"
    case speedIdle = "speed.idle"
    case speedGauge = "speed.gauge"
    case speedRecording = "speed.recording"
    case speedFinishConfirmation = "speed.finish-confirmation"
    case tripRecovery = "trip.recovery"
    case speedAlert = "speed.alert"
    case referenceRouteImportConfirmation = "reference-route.import-confirmation"
    case mapGuide = "map.guide"
    case mapGuidePoint = "map.guide-point"
    case mapGuideLibrary = "map.guide-library"
    case mapGuideFullscreen = "map.guide-fullscreen"
    case mapGuideReplace = "map.guide-replace"
    case mapReferenceRoute = "map.reference-route"
    case mapReferenceRouteMenu = "map.reference-route-menu"
    case mapReferenceRouteFullscreenMenu = "map.reference-route-fullscreen-menu"
    case mapVideoSections = "map.video-sections"
    case mapVideoSectionsFullscreen = "map.video-sections-fullscreen"
    case mapVideoInfo = "map.video-info"
    case tripsVideoSections = "trips.video-sections"
    case mapRouteProgress = "map.route-progress"
    case mapRouteProgressFullscreen = "map.route-progress-fullscreen"
    case mapRoute = "map.route"
    case mapRouteFullscreen = "map.route-fullscreen"
    case mapRouteOnePause = "map.route-one-pause"
    case mapRouteMultiplePauses = "map.route-multiple-pauses"
    case mapFollowDisableConfirmation = "map.follow-disable-confirmation"
    case mapFinishConfirmation = "map.finish-confirmation"
    case tripsEmpty = "trips.empty"
    case tripsPopulated = "trips.populated"
    case tripsDeleteConfirmation = "trips.delete-confirmation"
    case tripsDetail = "trips.detail"
    case tripsExport = "trips.export"
    case tripsExportPreparing = "trips.export-preparing"
    case settingsMapProvider = "settings.map-provider"
    case settingsOfflineMaps = "settings.offline-maps"
    case mapRegions = "map.regions"
    case mapProvinces = "map.provinces"
    case mapDownload = "map.download"
    case mapDownloadLanguages = "map.download-languages"
    case settingsMain = "settings.main"
    case settingsBottomNavigation = "settings.bottom-navigation"
    case settingsLanguages = "settings.languages"
    case settingsSpeedAlert = "settings.speed-alert"
    case settingsSpeedColors = "settings.speed-colors"
    case settingsSpeedColorsResetConfirmation = "settings.speed-colors-reset-confirmation"
    case settingsReferenceRoutes = "settings.reference-routes"
    case settingsReferenceRouteRename = "settings.reference-route-rename"
    case settingsReferenceRouteDeleteConfirmation = "settings.reference-route-delete-confirmation"
    case settingsResetConfirmation = "settings.reset-confirmation"
    case settingsHistoryConfirmation = "settings.history-confirmation"
    case paywallLifetime = "paywall.lifetime"
    case paywallTrial = "paywall.trial"
    case paywallCold = "paywall.cold"
    case paywallLoading = "paywall.loading"
    case paywallPurchasing = "paywall.purchasing"
    case paywallPending = "paywall.pending"
    case paywallFailure = "paywall.failure"
    case paywallRestored = "paywall.restored"

    static var requested: ScreenshotState? {
        let prefix = "--ui-screen="
        guard let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) else { return nil }
        return ScreenshotState(rawValue: String(raw))
    }

    var welcomePage: Int? {
        switch self {
        case .welcomeRoute: 0
        case .welcomeDisplayNumber, .welcomeDisplaySwipe, .welcomeDisplayGauge: 1
        case .welcomeRides: 2
        default: nil
        }
    }

    var welcomeDisplayPreviewElapsed: TimeInterval? {
        switch self {
        case .welcomeDisplayNumber: 0.6
        case .welcomeDisplaySwipe: 1.65
        case .welcomeDisplayGauge: 3.0
        default: nil
        }
    }

    var usesMockRoute: Bool { isMapRoute || self == .mapFinishConfirmation || usesMockTrips }
    var isMapScreen: Bool {
        rawValue.hasPrefix("map.guide") || rawValue.hasPrefix("map.camera-") || isMapRoute || self == .referenceRouteImportConfirmation || self == .mapReferenceRoute || self == .mapReferenceRouteMenu
            || self == .mapReferenceRouteFullscreenMenu
    }
    var isMapRoute: Bool {
        self == .mapVideoSections || self == .mapVideoSectionsFullscreen || self == .mapVideoInfo || self == .mapRouteProgress || self == .mapRouteProgressFullscreen || self == .mapRoute || self == .mapRouteFullscreen || self == .mapRouteOnePause || self == .mapRouteMultiplePauses
            || self == .mapFollowDisableConfirmation
    }
    var usesMockTrips: Bool { self == .tripsVideoSections || self == .tripsPopulated || self == .tripsDeleteConfirmation || self == .tripsDetail || self == .tripsExport || self == .tripsExportPreparing }
    var opensTripDetail: Bool { self == .tripsVideoSections || self == .tripsDetail || self == .tripsExport || self == .tripsExportPreparing }
    var opensSettings: Bool {
        self == .settingsCamera || self == .settingsCameraButtons || self == .cameraButtonLearning || self == .settingsMain || self == .settingsMapProvider || self == .settingsOfflineMaps || self == .mapRegions || self == .mapProvinces || self == .mapDownload || self == .mapDownloadLanguages || self == .settingsBottomNavigation || self == .settingsLanguages || self == .settingsSpeedAlert || self == .settingsSpeedColors || self == .settingsSpeedColorsResetConfirmation
            || self == .settingsReferenceRoutes || self == .settingsReferenceRouteRename || self == .settingsReferenceRouteDeleteConfirmation
            || self == .settingsResetConfirmation || self == .settingsHistoryConfirmation
    }
    var paywallPreview: PaywallPreviewState? {
        switch self {
        case .paywallLifetime: .lifetime
        case .paywallTrial: .normal
        case .paywallLoading: .loading
        case .paywallPurchasing: .purchasing
        case .paywallPending: .pending
        case .paywallFailure: .failure
        case .paywallRestored: .restored
        default: nil
        }
    }

    var opensPaywall: Bool {
        self == .paywallCold || paywallPreview != nil
    }
}
#else
enum ScreenshotState {
    static var requested: ScreenshotState? { nil }
    var usesMockRoute: Bool { false }
    var isMapScreen: Bool { false }
}
#endif

enum LaunchConfiguration {
#if DEBUG
    private static let debugPaidModeKey = "speedometer_debug_paid_mode"
#endif

    static func apply() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if ScreenshotState.requested != nil {
            let size = value(after: "--ui-distance-label-size=", in: arguments).flatMap(Int.init)
                .flatMap(RouteDistanceLabelSize.init(rawValue:)) ?? .two
            UserDefaults.standard.set(size.rawValue, forKey: "route_distance_label_size")
        }
        if let raw = value(after: "--ui-map-provider=", in: arguments), let provider = MapProvider(rawValue: raw) {
            UserDefaults.standard.set(provider.rawValue, forKey: "map_provider")
        }
        if let raw = value(after: "--ui-map-language=", in: arguments) {
            UserDefaults.standard.set(AppLanguage.normalized(raw), forKey: "map_language")
            UserDefaults.standard.removeObject(forKey: "selected_offline_map")
        }
        if ScreenshotState.requested != nil {
            let routeTheme = value(after: "--ui-route-theme=", in: arguments).flatMap(SpeedTheme.init(rawValue:)) ?? .lime
            UserDefaults.standard.set(routeTheme.rawValue, forKey: "speed_theme")
            UserDefaults.standard.set(60, forKey: "maximum_speed")
            UserDefaults.standard.set(false, forKey: "speed_alert_enabled")
            UserDefaults.standard.set(25 / 3.6, forKey: "speed_alert_limit_mps")
            // Deterministic UI runs must never inherit a real or earlier mock active trip.
            ActiveTripCheckpointStore().clear()
            UserDefaults.standard.set(BottomNavigationItem.defaultOrder.map(\.rawValue), forKey: "bottom_navigation_order")
            UserDefaults.standard.set(true, forKey: "follow_location_on_map")
        }
        // Load and acknowledge the requested campaign city even on non-map states.
        _ = ScreenshotCityFixture.current
        if let locale = value(after: "--ui-locale=", in: arguments) {
            UserDefaults.standard.set(AppLanguage.normalized(locale), forKey: "app_language_preference")
        }
        if let tabOrder = value(after: "--ui-tab-order=", in: arguments) {
            let requestedItems = tabOrder.split(separator: ",").map(String.init)
            UserDefaults.standard.set(BottomNavigationItem.normalized(requestedItems).map(\.rawValue), forKey: "bottom_navigation_order")
        }
        if ScreenshotState.requested == .speedGauge {
            UserDefaults.standard.set(SpeedDashboardStyle.gauge.rawValue, forKey: "speed_dashboard_style")
        } else if ScreenshotState.requested == .speedIdle || ScreenshotState.requested == .speedRecording || ScreenshotState.requested == .speedFinishConfirmation || ScreenshotState.requested == .speedAlert {
            UserDefaults.standard.set(SpeedDashboardStyle.number.rawValue, forKey: "speed_dashboard_style")
        }
        if arguments.contains("--ui-debug-paid") {
            UserDefaults.standard.set(true, forKey: debugPaidModeKey)
        } else if ScreenshotState.requested != nil {
            UserDefaults.standard.removeObject(forKey: debugPaidModeKey)
        }
#endif
    }

    static var requestedScheme: ColorScheme? {
#if DEBUG
        guard let raw = value(after: "--ui-scheme=", in: ProcessInfo.processInfo.arguments) else { return nil }
        return raw == "dark" ? .dark : .light
#else
        return nil
#endif
    }

    private static func value(after prefix: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }
}
