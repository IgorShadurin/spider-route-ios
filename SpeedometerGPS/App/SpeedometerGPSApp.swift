import SwiftUI
import UIKit

enum ScreenWakePolicy {
    static func shouldDisableIdleTimer(for scenePhase: ScenePhase) -> Bool {
        scenePhase == .active
    }

    @MainActor
    static func apply(for scenePhase: ScenePhase, application: UIApplication? = nil) {
        let application = application ?? .shared
        application.isIdleTimerDisabled = shouldDisableIdleTimer(for: scenePhase)
    }
}

final class SpeedometerGPSAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // This explicit lifecycle entry point lets Core Location recreate the
        // background run loop used by CLLocationUpdate on iOS 17+. A saved
        // checkpoint remains paused until the recovery modal's Continue action.
        true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

@main
struct SpeedometerGPSApp: App {
    @UIApplicationDelegateAdaptor(SpeedometerGPSAppDelegate.self) private var appDelegate
    @StateObject private var languageManager: LanguageManager
    @StateObject private var location: LocationMotionService
    @StateObject private var recorder: TripRecorder
    @StateObject private var settings: AppSettings
    @StateObject private var routes: RouteArchiveStore
    @StateObject private var referenceRoute: ReferenceRouteStore
    @StateObject private var incomingReferenceRoute: IncomingReferenceRouteCoordinator
    @StateObject private var subscription: SubscriptionStore
    @StateObject private var remoteCamera: RemoteCameraController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LaunchConfiguration.apply()
        _languageManager = StateObject(wrappedValue: LanguageManager())
        _location = StateObject(wrappedValue: LocationMotionService())
        _recorder = StateObject(wrappedValue: TripRecorder())
        _settings = StateObject(wrappedValue: AppSettings())
#if DEBUG && targetEnvironment(simulator)
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-startup-cloud-delay=") }),
           let delay = Double(argument.split(separator: "=").last ?? ""), delay.isFinite {
            _routes = StateObject(wrappedValue: RouteArchiveStore(cloudContainerURL: { _ in
                Thread.sleep(forTimeInterval: min(60, max(0, delay)))
                return nil
            }))
        } else {
            _routes = StateObject(wrappedValue: RouteArchiveStore())
        }
#else
        _routes = StateObject(wrappedValue: RouteArchiveStore())
#endif
        _referenceRoute = StateObject(wrappedValue: ReferenceRouteStore(loadInBackground: true))
        _incomingReferenceRoute = StateObject(wrappedValue: IncomingReferenceRouteCoordinator())
        _subscription = StateObject(wrappedValue: SubscriptionStore())
        _remoteCamera = StateObject(wrappedValue: RemoteCameraController())
    }

    @ViewBuilder
    private var loadedContent: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-osm-device-regions") {
            OSMDeviceRegionProbeView()
        } else if ProcessInfo.processInfo.arguments.contains("--ui-clear-ambient-map-cache") {
            OfflineMapCacheCleanupView()
        } else if ProcessInfo.processInfo.arguments.contains("--debug-route-1000km") || ProcessInfo.processInfo.arguments.contains("--debug-route-20h") {
            // A benchmark replaces the surface so hidden welcome/map animations
            // cannot contaminate timing or receive input behind the fixture.
            LongRecordingProbeView()
        } else {
            AppRootView(location: location, recorder: recorder, settings: settings, routes: routes, referenceRoute: referenceRoute, incomingReferenceRoute: incomingReferenceRoute, subscription: subscription, languageManager: languageManager)
        }
#else
        AppRootView(location: location, recorder: recorder, settings: settings, routes: routes, referenceRoute: referenceRoute, incomingReferenceRoute: incomingReferenceRoute, subscription: subscription, languageManager: languageManager)
#endif
    }

    var body: some Scene {
        WindowGroup {
            loadedContent
                .tint(AppPalette.brandAccent)
                // Native Form label icons still resolve the older accent role.
                .accentColor(AppPalette.brandAccent)
                .environmentObject(remoteCamera)
                .environmentObject(routes)
                .environmentObject(remoteCamera.externalInput)
                .environment(\.locale, languageManager.locale)
                .environment(\.layoutDirection, languageManager.selected.isRTL ? .rightToLeft : .leftToRight)
                .preferredColorScheme(LaunchConfiguration.requestedScheme ?? settings.appearance.colorScheme)
                .id(languageManager.selected.id)
                .onAppear {
                    ScreenWakePolicy.apply(for: scenePhase)
                    remoteCamera.sceneChanged(scenePhase)
                }
                .onReceive(remoteCamera.$videoReceipts) { receipts in
                    recorder.observeCameraReceipts(receipts)
                    routes.updateVideoReceipts(receipts, syncWithICloud: settings.syncWithICloud)
                }
                .onOpenURL { url in
                    incomingReferenceRoute.receive(url)
                }
        }
        .onChange(of: scenePhase) { newPhase in
            ScreenWakePolicy.apply(for: newPhase)
            remoteCamera.sceneChanged(newPhase)
            if newPhase != .active {
                recorder.checkpointForLifecycle()
                routes.checkpointForLifecycle()
                referenceRoute.checkpointForLifecycle()
#if DEBUG
                LongRecordingProbe.checkpointForLifecycle()
#endif
            }
        }
    }
}
