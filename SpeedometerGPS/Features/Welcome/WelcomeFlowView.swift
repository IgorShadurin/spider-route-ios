import SwiftUI

enum WelcomeFlowPage: Int, CaseIterable {
    case route
    case display
    case rides
}

struct WelcomeFlowView: View {
    let initialPage: Int
    let numberStyle: SpeedNumberStyle
    let displayPreviewElapsed: TimeInterval?
    let onComplete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: Int

    init(
        initialPage: Int = 0,
        numberStyle: SpeedNumberStyle = .digital,
        displayPreviewElapsed: TimeInterval? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.initialPage = initialPage
        self.numberStyle = numberStyle
        self.displayPreviewElapsed = displayPreviewElapsed
        self.onComplete = onComplete
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                Group {
                    switch page {
                    case 0: routePage
                    case 1: displayPage
                    default: ridesPage
                    }
                }
                .id(page)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(
                    maxWidth: horizontalSizeClass == .regular
                        ? 900
                        : 620,
                    maxHeight: .infinity
                )
                .frame(maxWidth: .infinity)

                VStack(spacing: 15) {
                    HStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule()
                                .fill(index == page ? AppPalette.brandAccent : Color.secondary.opacity(0.25))
                                .frame(width: index == page ? 24 : 8, height: 8)
                        }
                    }
                    CapsuleActionButton(action: advance) {
                        Text(L10n.tr(page == 2 ? "welcome_explore" : "common_continue"))
                    }
                    .accessibilityIdentifier("welcome.continue")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 16))
            }
            .background(AppPalette.canvas(colorScheme).ignoresSafeArea())
        }
        .accessibilityIdentifier("screen.welcome")
    }

    private var routePage: some View {
        WelcomePage(title: L10n.tr("welcome_route_title"), titleColor: .primary) {
            RouteDemoView(theme: .lime, isReducedMotion: reduceMotion)
                .frame(maxWidth: horizontalSizeClass == .regular ? 780 : 420)
        }
    }

    private var displayPage: some View {
        WelcomePage(title: L10n.tr("welcome_speed_title"), titleColor: .primary) {
            WelcomeDisplayDemoView(
                numberStyle: numberStyle,
                isReducedMotion: reduceMotion,
                previewElapsed: displayPreviewElapsed
            )
                .frame(maxWidth: horizontalSizeClass == .regular ? 860 : 480)
                .accessibilityIdentifier("welcome.display.demo")
        }
    }

    private var ridesPage: some View {
        WelcomePage(title: L10n.tr("welcome_rides_title"), titleColor: .primary) {
            RideHistoryDemoView(isReducedMotion: reduceMotion)
                .frame(maxWidth: horizontalSizeClass == .regular ? 780 : 480)
        }
    }

    private func advance() {
        if page == 2 { onComplete() }
        else { withAnimation(.easeInOut(duration: 0.28)) { page += 1 } }
    }
}

private struct WelcomeDisplayDemoView: View {
    let numberStyle: SpeedNumberStyle
    let isReducedMotion: Bool
    let previewElapsed: TimeInterval?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date()

    var body: some View {
        GeometryReader { proxy in
            TimelineView(
                .animation(minimumInterval: 1.0 / 60.0, paused: isReducedMotion || previewElapsed != nil || scenePhase != .active)
            ) { context in
                let snapshot = WelcomeStoryTiming.displaySnapshot(
                    at: previewElapsed ?? context.date.timeIntervalSince(start),
                    reducedMotion: isReducedMotion
                )

                Group {
                    if isReducedMotion {
                        reducedMotionStage(speed: snapshot.speed, size: proxy.size)
                    } else {
                        animatedStage(snapshot: snapshot, size: proxy.size)
                    }
                }
            }
        }
        .aspectRatio(0.82, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("settings_speed_number_style"))
    }

    private func animatedStage(snapshot: WelcomeDisplaySnapshot, size: CGSize) -> some View {
        ZStack {
            AppPalette.card(colorScheme)

            standaloneNumber(
                speed: snapshot.speed,
                unitOpacity: pageVisibility(snapshot.pageOffset, page: 0)
            )
                .frame(width: size.width, height: size.height)
                .clipped()
                .offset(x: -snapshot.pageOffset * size.width)

            fullGauge(speed: snapshot.speed)
                .frame(width: size.width, height: size.height)
                .clipped()
                .offset(x: (1 - snapshot.pageOffset) * size.width)

            standaloneNumber(
                speed: snapshot.speed,
                unitOpacity: pageVisibility(snapshot.pageOffset, page: 2)
            )
                .frame(width: size.width, height: size.height)
                .clipped()
                .offset(x: (2 - snapshot.pageOffset) * size.width)
        }
        .clipped()
    }

    private func reducedMotionStage(speed: Double, size: CGSize) -> some View {
        VStack(spacing: 10) {
            standaloneNumber(speed: speed, unitOpacity: 1)
                .frame(height: size.height * 0.34)
            fullGauge(speed: speed)
                .frame(height: size.height * 0.56)
        }
        .padding(14)
        .frame(width: size.width, height: size.height)
        .background(AppPalette.card(colorScheme))
    }

    private func standaloneNumber(speed: Double, unitOpacity: Double) -> some View {
        let color: Color = colorScheme == .dark ? AppPalette.digitalGreen : .black
        return VStack(spacing: 10) {
            SpeedNumberView(
                text: Int(speed.rounded()).formatted(),
                style: numberStyle,
                modernColor: color,
                digitalActiveColor: color,
                digitalInactiveColor: color.opacity(colorScheme == .dark ? 0.10 : 0.025)
            )
            .frame(maxWidth: 760, maxHeight: 500)
            .accessibilityIdentifier("welcome.display.number")

            Text("km/h")
                .font(AppTypography.screenTitle)
                .foregroundStyle(color)
                .opacity(unitOpacity)
        }
        .padding(24)
    }

    private func pageVisibility(_ offset: Double, page: Double) -> Double {
        max(0, 1 - abs(offset - page) * 2)
    }

    private func fullGauge(speed: Double) -> some View {
        SpeedometerGauge(
            speed: speed,
            maximum: 60,
            unit: "km/h",
            theme: .lime,
            numberStyle: numberStyle
        )
        .padding(20)
        .accessibilityIdentifier("welcome.display.gauge")
    }
}

private struct WelcomePage<Content: View>: View {
    let title: String
    let titleColor: Color
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(AppTypography.welcomeTitle)
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.84)
                .padding(.horizontal, 20)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct RouteDemoView: View {
    private var previewElapsed: TimeInterval? {
#if DEBUG
        if ScreenshotState.requested == .welcomeRoute && !ProcessInfo.processInfo.arguments.contains("--ui-animate-welcome") { return 3.2 }
#endif
        return nil
    }

    let theme: SpeedTheme
    let isReducedMotion: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date()

    var body: some View {
        GeometryReader { proxy in
            let mapSize = CGSize(width: proxy.size.width, height: proxy.size.width * 1000 / 1267)
            let layout = WelcomeRouteGeometry.layout(in: mapSize)
            let path = Path { path in path.addLines(layout.points) }
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isReducedMotion || scenePhase != .active || previewElapsed != nil)) { context in
                let snapshot = WelcomeStoryTiming.routeSnapshot(
                    at: previewElapsed ?? context.date.timeIntervalSince(start), reducedMotion: isReducedMotion)
                VStack(spacing: 12) {
                    WelcomeRouteStage(layout: layout, path: path, snapshot: snapshot)
                        .frame(width: mapSize.width, height: mapSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    HStack(spacing: 10) {
                        MetricCard(title: L10n.tr("metric_distance"),
                                   value: SpeedFormatter.distance(snapshot.progress * 1240),
                                   systemName: "point.topleft.down.to.point.bottomright.curvepath", accent: theme.accent)
                        MetricCard(title: L10n.tr("tab_speed"),
                                   value: "\(Int(snapshot.speed.rounded()).formatted()) km/h",
                                   systemName: "bicycle", accent: theme.accent)
                    }
                }
            }
        }
        .aspectRatio(0.82, contentMode: .fit)
        .padding(.horizontal, 12)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("welcome_route_accessibility"))
    }
}

private struct WelcomeRouteStage: View {
    let layout: WelcomeRouteLayout
    let path: Path
    let snapshot: WelcomeRouteSnapshot

    var body: some View {
        let position = layout.position(at: snapshot.progress)
        ZStack {
            WelcomeMapBackdrop()
            path.stroke(AppPalette.forest.opacity(0.7), style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
            path.stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            path.trimmedPath(from: 0, to: snapshot.progress)
                .stroke(AppPalette.primaryAction, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .opacity(snapshot.opacity)
            ZStack {
                Circle().fill(AppPalette.forest)
                    .overlay(Circle().stroke(AppPalette.primaryAction, lineWidth: 3))
                Image(systemName: "location.north.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.radians(position.heading + .pi / 2))
            }
            .frame(width: 40, height: 40)
            .position(position.point)
            .opacity(snapshot.opacity)
        }
        .clipped()
    }
}

private struct RideHistoryDemoView: View {
    let isReducedMotion: Bool
    @State private var revealed = false

    var body: some View {
        GeometryReader { proxy in
            let mapSize = CGSize(width: proxy.size.width, height: proxy.size.width * 1000 / 1267)
            let layout = WelcomeRouteGeometry.layout(in: mapSize)
            let path = Path { $0.addLines(layout.points) }
            let reveal = isReducedMotion || revealed ? 1.0 : 0.0
            Group {
                VStack(spacing: 16) {
                    WelcomeRouteStage(layout: layout, path: path,
                                      snapshot: WelcomeRouteSnapshot(progress: 1, opacity: 1, speed: 0))
                        .frame(width: mapSize.width, height: mapSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    TripRow(trip: Self.ride, unit: .kilometersPerHour, onSelect: {})
                        .allowsHitTesting(false)
                        .opacity(reveal)
                        .offset(y: (1 - reveal) * 14)
                    HStack(spacing: 10) {
                        MetricCard(title: L10n.tr("metric_distance"), value: SpeedFormatter.distance(Self.ride.distance),
                                   systemName: "bicycle", accent: AppPalette.brandAccent)
                        MetricCard(title: L10n.tr("metric_duration"), value: SpeedFormatter.duration(Self.ride.duration),
                                   systemName: "timer", accent: AppPalette.brandAccent)
                    }
                }
            }
        }
        .aspectRatio(0.82, contentMode: .fit)
        .padding(.horizontal, 12)
        .accessibilityIdentifier("welcome.rides.demo")
        .onAppear {
            withAnimation(isReducedMotion ? nil : .easeOut(duration: 0.8)) { revealed = true }
        }
    }

    private static let ride: TripRecord = {
        let date = Date(timeIntervalSince1970: 1_790_057_400)
        return TripRecord(id: UUID(uuidString: "2534E537-612A-4A6E-82A5-694F687BB31E")!, startedAt: date, endedAt: date.addingTimeInterval(1200),
            points: RouteMapView.mockRoute.enumerated().map { index, point in
                TrackPoint(latitude: point.latitude, longitude: point.longitude, altitude: 20,
                    metersPerSecond: 6, timestamp: date.addingTimeInterval(Double(index) * 150))
            }, activity: "activity_cycling")
    }()
}

private struct WelcomeMapBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            Image("WelcomeLondonMap")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    Text(verbatim: "© OpenStreetMap contributors")
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.68), in: Capsule())
                        .padding(12)
                }
        }
        .accessibilityHidden(true)
    }
}
