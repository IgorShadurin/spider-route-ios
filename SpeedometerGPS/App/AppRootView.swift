import SwiftUI

struct AppRootView: View {
    private enum Stage: Equatable { case loader, welcome, main }

    @ObservedObject var location: LocationMotionService
    @ObservedObject var recorder: TripRecorder
    @ObservedObject var settings: AppSettings
    @ObservedObject var routes: RouteArchiveStore
    @ObservedObject var referenceRoute: ReferenceRouteStore
    @ObservedObject var incomingReferenceRoute: IncomingReferenceRouteCoordinator
    @ObservedObject var subscription: SubscriptionStore
    @ObservedObject var languageManager: LanguageManager

    @State private var stage: Stage
    @State private var startsWithPaywall = false
    @State private var initialLibrariesReady = false

    init(location: LocationMotionService, recorder: TripRecorder, settings: AppSettings, routes: RouteArchiveStore, referenceRoute: ReferenceRouteStore, incomingReferenceRoute: IncomingReferenceRouteCoordinator, subscription: SubscriptionStore, languageManager: LanguageManager) {
        self.location = location
        self.recorder = recorder
        self.settings = settings
        self.routes = routes
        self.referenceRoute = referenceRoute
        self.incomingReferenceRoute = incomingReferenceRoute
        self.subscription = subscription
        self.languageManager = languageManager
#if DEBUG
        if ScreenshotState.requested == .loader { _stage = State(initialValue: .loader) }
        else if ScreenshotState.requested?.welcomePage != nil { _stage = State(initialValue: .welcome) }
        else if ScreenshotState.requested != nil { _stage = State(initialValue: .main) }
        else { _stage = State(initialValue: WelcomePresentationStore.shouldPresentOnLaunch ? .loader : .main) }
#else
        _stage = State(initialValue: WelcomePresentationStore.shouldPresentOnLaunch ? .loader : .main)
#endif
    }

    var body: some View {
        Group {
            switch stage {
            case .loader:
                LaunchLoaderView(numberStyle: settings.speedNumberStyle)
            case .welcome:
                WelcomeFlowView(
                    initialPage: welcomePage,
                    numberStyle: settings.speedNumberStyle,
                    displayPreviewElapsed: welcomeDisplayPreviewElapsed
                ) { completeWelcome() }
            case .main:
                if !initialLibrariesReady && (recorder.isLoadingRecovery || routes.isLoadingLocal || referenceRoute.isLoading) {
                    LaunchLoaderView(numberStyle: settings.speedNumberStyle)
                } else {
                    // Preserve the selected route's initial camera. Later cloud
                    // reloads never reconstruct navigation or the live map.
                    MainShellView(location: location, recorder: recorder, settings: settings, routes: routes, referenceRoute: referenceRoute, incomingReferenceRoute: incomingReferenceRoute, subscription: subscription, languageManager: languageManager, startsWithPaywall: startsWithPaywall, onInitialPaywallClosed: finishInitialPaywall)
                        .onAppear {
                            initialLibrariesReady = true
                            requestAccessForReturningLaunch()
                        }
                }
            }
        }
        .task { advanceAfterLoaderIfNeeded() }
    }

    private var welcomePage: Int {
#if DEBUG
        ScreenshotState.requested?.welcomePage ?? 0
#else
        0
#endif
    }

    private var welcomeDisplayPreviewElapsed: TimeInterval? {
#if DEBUG
        ScreenshotState.requested?.welcomeDisplayPreviewElapsed
#else
        nil
#endif
    }

    private func requestAccessForReturningLaunch() {
#if DEBUG
        guard ScreenshotState.requested == nil else { return }
#endif
        if !WelcomePresentationStore.shouldPresentOnLaunch { location.requestAccessInOrder() }
    }

    private func advanceAfterLoaderIfNeeded() {
        guard stage == .loader else { return }
#if DEBUG
        if ScreenshotState.requested == .loader { return }
#endif
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(WelcomeStoryTiming.loaderDuration * 1_000_000_000))
            withAnimation(.easeInOut(duration: 0.28)) {
                stage = WelcomePresentationStore.shouldPresentOnLaunch ? .welcome : .main
            }
        }
    }

    private func completeWelcome() {
        startsWithPaywall = true
        withAnimation(.easeInOut(duration: 0.25)) { stage = .main }
    }

    private func finishInitialPaywall() {
        WelcomePresentationStore.markDismissed()
        startsWithPaywall = false
        location.requestAccessInOrder()
    }
}
