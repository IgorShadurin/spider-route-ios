import SwiftUI

enum CapsuleActionRole: Equatable {
    case primary
    case neutral
    case destructive

    func foreground(in colorScheme: ColorScheme) -> Color {
        switch self {
        case .primary: AppPalette.charcoal
        case .neutral: colorScheme == .dark ? .white : .primary
        case .destructive: .white
        }
    }

    func background(in colorScheme: ColorScheme) -> Color {
        switch self {
        case .primary: AppPalette.primaryAction
        case .neutral: AppPalette.raisedCard(colorScheme)
        case .destructive: AppPalette.destructiveAction
        }
    }
}

struct CapsuleActionButton<Label: View>: View {
    let action: () -> Void
    var role: CapsuleActionRole = .primary
    var height: CGFloat = 54
    var isEnabled = true
    @ViewBuilder let label: () -> Label
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            label()
                .font(AppTypography.actionLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .foregroundStyle(role.foreground(in: colorScheme))
                .background(role.background(in: colorScheme), in: Capsule())
                .overlay {
                    if role == .primary {
                        Capsule().strokeBorder(AppPalette.actionOutline, lineWidth: 1)
                    } else if role == .neutral {
                        Capsule().strokeBorder(AppPalette.controlOutline(colorScheme), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableCapsuleStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
    }
}

private struct PressableCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

struct CircularIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var tint: Color = AppPalette.brandAccent
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: PlatformSymbol.name(systemName))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(AppPalette.raisedCard(colorScheme), in: Circle())
                .overlay(Circle().strokeBorder(AppPalette.controlOutline(colorScheme), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let systemName: String
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: PlatformSymbol.name(systemName))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accent)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppPalette.raisedCard(colorScheme), in: RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: UIShape.compactCard, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
