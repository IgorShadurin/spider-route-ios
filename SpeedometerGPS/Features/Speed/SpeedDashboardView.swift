import SwiftUI

struct SpeedDashboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var location: LocationMotionService
    @ObservedObject var recorder: TripRecorder
    @ObservedObject var settings: AppSettings
    @ObservedObject var routes: RouteArchiveStore
    @ObservedObject var subscription: SubscriptionStore
    var mockMetersPerSecond: Double? = nil
    let onShowPaywall: () -> Void
    let onRequestFinish: () -> Void

    private var currentMetersPerSecond: Double { mockMetersPerSecond ?? location.metersPerSecond }
    private var displaySpeed: Double { settings.unit.value(fromMetersPerSecond: currentMetersPerSecond) }
    private var maximum: Double { settings.maximumSpeed }
    private var speedLimit: Double { settings.unit.value(fromMetersPerSecond: settings.speedAlertLimitMetersPerSecond) }
    private var signalAccuracy: Double {
#if DEBUG
        if mockMetersPerSecond != nil { return 8 }
#endif
        return location.horizontalAccuracy
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = SpeedDashboardLayout(viewport: proxy.size)
            VStack(spacing: layout.compact ? 10 : 16) {
                signalRow

                speedDisplay(layout: layout)

                Spacer(minLength: 0)

                VStack(spacing: layout.compact ? 8 : 10) {
                    metrics

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
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: 820, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("screen.speed")
    }

    private func speedDisplay(layout: SpeedDashboardLayout) -> some View {
        VStack(spacing: 8) {
            TabView(selection: $settings.speedDashboardStyle) {
                SpeedNumberDashboard(
                    speed: displaySpeed,
                    unit: settings.unit.rawValue,
                    theme: settings.theme,
                    numberStyle: settings.speedNumberStyle,
                    showsDecimal: settings.showDecimal,
                    activeColor: settings.speedNumberColor(for: colorScheme),
                    inactiveColor: settings.speedNumberInactiveColor(for: colorScheme),
                    outlineColor: settings.speedNumberOutlineColor(for: colorScheme)
                )
                .tag(SpeedDashboardStyle.number)

                SpeedometerGauge(
                    speed: displaySpeed,
                    maximum: maximum,
                    unit: settings.unit.rawValue,
                    theme: settings.theme,
                    numberStyle: settings.speedNumberStyle,
                    showsDecimal: settings.showDecimal
                )
                .frame(width: layout.gaugeDiameter, height: layout.gaugeDiameter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("speed.gauge")
                .tag(SpeedDashboardStyle.gauge)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityIdentifier("speed.display.pager")

            HStack(spacing: 7) {
                ForEach(SpeedDashboardStyle.allCases) { style in
                    Capsule()
                        .fill(settings.speedDashboardStyle == style ? AppPalette.brandAccent : Color.secondary.opacity(0.24))
                        .frame(width: settings.speedDashboardStyle == style ? 24 : 7, height: 7)
                        .animation(.easeInOut(duration: 0.2), value: settings.speedDashboardStyle)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(height: layout.speedDisplayHeight)
        .accessibilityValue(settings.speedDashboardStyle.rawValue)
    }

    private var signalRow: some View {
        HStack(spacing: 10) {
            GPSQualityIndicator(horizontalAccuracy: signalAccuracy, accent: AppPalette.brandAccent)
                .opacity(settings.showGPSStrength ? 1 : 0)
            Spacer()
            if settings.speedAlertEnabled {
                SpeedLimitBadge(
                    limit: speedLimit,
                    unit: settings.unit.rawValue,
                    accent: AppPalette.brandAccent,
                    isExceeded: currentMetersPerSecond >= settings.speedAlertLimitMetersPerSecond
                )
                .accessibilityIdentifier("speed.alert.limit")
            }
        }
        .frame(minHeight: 38)
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            MetricCard(title: L10n.tr("metric_distance"), value: SpeedFormatter.distance(recorder.distance), systemName: "point.topleft.down.to.point.bottomright.curvepath", accent: AppPalette.brandAccent)
            MetricCard(title: L10n.tr("metric_duration"), value: SpeedFormatter.duration(recorder.elapsed), systemName: "timer", accent: AppPalette.brandAccent)
            MetricCard(title: L10n.tr("metric_top_speed"), value: SpeedFormatter.number(recorder.topSpeed, unit: settings.unit, decimals: false), systemName: "gauge.with.needle.fill", accent: AppPalette.brandAccent)
        }
    }

}

struct SpeedDashboardLayout: Equatable {
    let compact: Bool
    let gaugeDiameter: CGFloat
    let speedDisplayHeight: CGFloat

    init(viewport: CGSize) {
        compact = viewport.height < 690
        let availableWidth = max(0, viewport.width - 36)
        let wide = viewport.width >= 700
        let maximumDiameter: CGFloat = wide ? 440 : (compact ? 284 : 330)
        gaugeDiameter = min(availableWidth, maximumDiameter)
        speedDisplayHeight = wide ? 500 : (compact ? 326 : 378)
    }
}

enum GPSQuality {
    static func signalLevel(horizontalAccuracy: Double) -> Int {
        guard horizontalAccuracy >= 0 else { return 0 }
        if horizontalAccuracy <= 10 { return 4 }
        if horizontalAccuracy <= 25 { return 3 }
        if horizontalAccuracy <= 50 { return 2 }
        return 1
    }
}

enum GPSNetworkSignalGeometry {
    static let opticalVerticalOffset: CGFloat = -2
}

private struct GPSQualityIndicator: View {
    @Environment(\.colorScheme) private var colorScheme

    let horizontalAccuracy: Double
    let accent: Color

    private var signalLevel: Int {
        GPSQuality.signalLevel(horizontalAccuracy: horizontalAccuracy)
    }

    private var statusColor: Color {
        if signalLevel >= 3 {
            return colorScheme == .dark
                ? AppPalette.digitalGreen
                : Color(red: 0.10, green: 0.48, blue: 0.08)
        }
        if signalLevel > 0 { return accent }
        return .secondary
    }

    private var accessibilityDescription: String {
        L10n.tr(signalLevel >= 3 ? "gps_signal_strong" : "gps_signal_searching")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: PlatformSymbol.name("location.fill"))
                .font(.caption.weight(.bold))
            Text("GPS")
                .font(.caption.weight(.bold))
                .tracking(0.4)
            GPSNetworkSignalView(level: signalLevel, color: statusColor)
                .offset(y: GPSNetworkSignalGeometry.opticalVerticalOffset)
        }
        .foregroundStyle(statusColor)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("speed.gps-quality")
        .accessibilityLabel("GPS, \(accessibilityDescription)")
        .accessibilityValue("\(signalLevel) / 4")
    }
}

private struct GPSNetworkSignalView: View {
    let level: Int
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                Capsule()
                    .fill(color.opacity(bar <= level ? 1 : 0.16))
                    .frame(width: 4, height: CGFloat(4 + bar * 3))
            }
        }
        .frame(width: 24, height: 17, alignment: .bottom)
        .environment(\.layoutDirection, .leftToRight)
        .animation(.easeInOut(duration: 0.25), value: level)
        .accessibilityHidden(true)
    }
}

private struct SpeedNumberDashboard: View {
    let speed: Double
    let unit: String
    let theme: SpeedTheme
    let numberStyle: SpeedNumberStyle
    let showsDecimal: Bool
    let activeColor: Color
    let inactiveColor: Color
    let outlineColor: Color?

    private var displayNumber: String {
        speed.formatted(.number.precision(.fractionLength(showsDecimal ? 1 : 0)))
    }

    var body: some View {
        GeometryReader { proxy in
            let numberWidth = min(proxy.size.width * 0.98, 600)
            let numberHeight = min(proxy.size.height * 0.80, 400)

            VStack(spacing: 10) {
                Spacer(minLength: 0)
                SpeedNumberView(
                    text: displayNumber,
                    style: numberStyle,
                    modernColor: activeColor,
                    digitalActiveColor: activeColor,
                    digitalInactiveColor: inactiveColor,
                    digitalOutlineColor: outlineColor
                )
                    .frame(width: numberWidth, height: numberHeight)
                if numberStyle == .digital {
                    OutlinedUnitLabel(
                        text: unit,
                        fill: activeColor,
                        outline: outlineColor
                    )
                } else {
                    Text(unit)
                        .font(AppTypography.screenTitle)
                        .foregroundStyle(activeColor)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speed.display.number")
    }
}

private struct OutlinedUnitLabel: View {
    let text: String
    let fill: Color
    let outline: Color?

    private let outlineOffsets: [CGSize] = [
        CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
        CGSize(width: 0, height: -1), CGSize(width: 0, height: 1),
        CGSize(width: -0.7, height: -0.7), CGSize(width: 0.7, height: -0.7),
        CGSize(width: -0.7, height: 0.7), CGSize(width: 0.7, height: 0.7)
    ]

    var body: some View {
        ZStack {
            if let outline {
                ForEach(Array(outlineOffsets.enumerated()), id: \.offset) { _, offset in
                    label
                        .foregroundStyle(outline)
                        .offset(offset)
                }
            }
            label.foregroundStyle(fill)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text).font(AppTypography.screenTitle)
    }
}

struct TripRecordingControls: View {
    @ObservedObject var recorder: TripRecorder
    @ObservedObject var location: LocationMotionService
    @ObservedObject var routes: RouteArchiveStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var subscription: SubscriptionStore
    let onShowPaywall: () -> Void
    let onRequestFinish: () -> Void

    @ViewBuilder
    var body: some View {
        switch recorder.state {
        case .idle:
            CapsuleActionButton(action: startTrip) {
                Label(L10n.tr("trip_start"), systemImage: PlatformSymbol.name("record.circle"))
            }
            .accessibilityIdentifier("trip.start")
        case .recording, .paused:
            HStack(spacing: 12) {
                CapsuleActionButton(action: { recorder.togglePause() }, role: .neutral) {
                    Label(L10n.tr(recorder.state == .paused ? "trip_resume" : "trip_pause"), systemImage: PlatformSymbol.name(recorder.state == .paused ? "play.fill" : "pause.fill"))
                }
                .accessibilityIdentifier(recorder.state == .paused ? "trip.resume" : "trip.pause")
                CapsuleActionButton(action: onRequestFinish) {
                    Label(L10n.tr("trip_finish"), systemImage: PlatformSymbol.name("stop.fill"))
                }
                .accessibilityIdentifier("trip.finish")
            }
        }
    }

    private func startTrip() {
        guard subscription.isEntitled else { onShowPaywall(); return }
        recorder.start()
    }

}

private struct SpeedLimitBadge: View {
    let limit: Double
    let unit: String
    let accent: Color
    let isExceeded: Bool

    @ScaledMetric(relativeTo: .caption) private var horizontalInset: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var verticalInset: CGFloat = 7
    @ScaledMetric(relativeTo: .caption) private var contentSpacing: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var iconWidth: CGFloat = 18

    private var statusColor: Color {
        isExceeded ? AppPalette.destructiveAction : accent
    }

    var body: some View {
        HStack(spacing: contentSpacing) {
            Image(systemName: PlatformSymbol.name(isExceeded ? "exclamationmark.triangle.fill" : "speaker.wave.2.fill"))
                .font(.caption.weight(.bold))
                .foregroundStyle(statusColor)
                .frame(width: iconWidth)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("settings_speed_alert_limit"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(Int(limit.rounded()).formatted()) \(unit)")
                    .font(.caption.monospacedDigit().weight(.black))
                    .foregroundStyle(isExceeded ? statusColor : .primary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: true)
        }
        .padding(.vertical, verticalInset)
        .padding(.horizontal, horizontalInset)
        .frame(minHeight: 44)
        .background(statusColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(statusColor.opacity(isExceeded ? 1 : 0.65), lineWidth: 2))
        .shadow(color: isExceeded ? statusColor.opacity(0.25) : .clear, radius: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("settings_speed_alert_limit"))
        .accessibilityValue("\(Int(limit.rounded())) \(unit)")
        .accessibilityAddTraits(isExceeded ? .isSelected : [])
    }
}
