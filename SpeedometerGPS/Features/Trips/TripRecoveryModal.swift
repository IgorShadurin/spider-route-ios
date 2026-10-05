import SwiftUI

struct TripRecoveryModal: View {
    let checkpoint: ActiveTripCheckpoint
    let distance: Double
    @ObservedObject var settings: AppSettings
    let onDiscard: () -> Void
    let onContinue: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.52).ignoresSafeArea()

                ScrollView(showsIndicators: dynamicTypeSize.isAccessibilitySize) {
                    recoveryContent
                        .frame(maxWidth: 460)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                        .padding(24)
                }
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var recoveryContent: some View {
        VStack(spacing: 18) {
            Image(systemName: PlatformSymbol.name("location.fill.viewfinder"))
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(AppPalette.brandAccent)

            VStack(spacing: 7) {
                Text(L10n.tr("trip_recovery_title"))
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trip.recovery.prompt")
                Text(L10n.tr("trip_recovery_message"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            recoveryMetrics

            Label {
                Text(L10n.format(
                    "trip_recovery_last_update_format",
                    checkpoint.savedAt.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)
                    )
                ))
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: PlatformSymbol.name("clock.arrow.circlepath"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            recoveryActions
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var recoveryMetrics: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 9) {
                recoveryMetric(title: L10n.tr("metric_distance"), value: recoveryDistance(distance), systemName: "road.lanes")
                recoveryMetric(title: L10n.tr("metric_duration"), value: SpeedFormatter.duration(checkpoint.elapsed), systemName: "timer")
                recoveryMetric(title: L10n.tr("route_points"), value: checkpoint.points.count.formatted(), systemName: "mappin.and.ellipse")
            }
        } else {
            HStack(spacing: 9) {
                recoveryMetric(title: L10n.tr("metric_distance"), value: recoveryDistance(distance), systemName: "road.lanes")
                recoveryMetric(title: L10n.tr("metric_duration"), value: SpeedFormatter.duration(checkpoint.elapsed), systemName: "timer")
                recoveryMetric(title: L10n.tr("route_points"), value: checkpoint.points.count.formatted(), systemName: "mappin.and.ellipse")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                discardButton
                continueButton
            }
        } else {
            HStack(spacing: 12) {
                discardButton
                continueButton
            }
        }
    }

    private var discardButton: some View {
        recoveryButton(
            title: L10n.tr("trip_recovery_discard"),
            foreground: .white,
            background: AppPalette.destructiveAction,
            identifier: "trip.recovery.discard",
            action: onDiscard
        )
    }

    private var continueButton: some View {
        recoveryButton(
            title: L10n.tr("trip_recovery_continue"),
            foreground: AppPalette.charcoal,
            background: AppPalette.primaryAction,
            identifier: "trip.recovery.continue",
            action: onContinue
        )
    }

    private func recoveryMetric(title: String, value: String, systemName: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    Image(systemName: PlatformSymbol.name(systemName))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.brandAccent)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value)
                            .font(.headline.bold().monospacedDigit())
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 7) {
                    Image(systemName: PlatformSymbol.name(systemName))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.brandAccent)
                    Text(value)
                        .font(.caption.bold().monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: dynamicTypeSize.isAccessibilitySize ? nil : .infinity)
        .padding(dynamicTypeSize.isAccessibilitySize ? 14 : 12)
        .background(AppPalette.raisedCard(colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func recoveryDistance(_ meters: Double) -> String {
        if meters < 1_000 {
            return L10n.format("distance_meters_format", Int(meters))
        }
        let value = String(format: "%.1f", locale: L10n.locale, meters / 1_000)
        return L10n.format("trip_recovery_distance_kilometers_format", value)
    }

    private func recoveryButton(
        title: String,
        foreground: Color,
        background: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.actionLabel)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 72 : 52)
                .background(background, in: Capsule())
                .overlay(Capsule().strokeBorder(AppPalette.actionOutline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
