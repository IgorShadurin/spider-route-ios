import SwiftUI
import UIKit

struct DisplayColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let resolved = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.init(red: red, green: green, blue: blue, alpha: alpha)
        } else {
            self.init(red: 0, green: 0, blue: 0)
        }
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    static let black = DisplayColor(red: 0, green: 0, blue: 0)
    static let white = DisplayColor(red: 1, green: 1, blue: 1)
    static let digitalGreen = DisplayColor(red: 0.50, green: 1.00, blue: 0.42)
}

enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var toggled: AppAppearance { self == .dark ? .light : .dark }
}

enum SpeedTheme: String, CaseIterable, Identifiable, Codable {
    case lime
    case amber
    case coral
    case violet

    var id: String { rawValue }

    var accent: Color {
        switch self {
        case .lime: AppPalette.brandAccent
        case .amber: Color(red: 1.00, green: 0.59, blue: 0.10)
        case .coral: Color(red: 1.00, green: 0.31, blue: 0.24)
        case .violet: Color(red: 0.58, green: 0.39, blue: 0.98)
        }
    }

    var secondary: Color {
        switch self {
        case .lime: AppPalette.brandAccent
        case .amber: Color(red: 0.98, green: 0.73, blue: 0.16)
        case .coral: Color(red: 0.25, green: 0.45, blue: 0.98)
        case .violet: Color(red: 1.00, green: 0.69, blue: 0.18)
        }
    }

    // Keep filmed sections distinct even when the ordinary route is violet.
    var inkSurfaceAccent: Color { self == .lime ? AppPalette.primaryAction : accent }
    var inkSurfaceSecondary: Color { self == .lime ? AppPalette.primaryAction : secondary }

    var videoRouteAccent: Color { self == .violet ? .green : .purple }

    var localizedName: String { L10n.tr("theme_\(rawValue)") }
}

enum SpeedNumberStyle: String, CaseIterable, Identifiable, Codable {
    case digital
    case modern

    var id: String { rawValue }
    var localizedName: String { L10n.tr("speed_number_style_\(rawValue)") }
}

enum SpeedDashboardStyle: String, CaseIterable, Identifiable, Codable {
    case number
    case gauge

    var id: String { rawValue }
}

enum AppPalette {
    static let ink = Color(red: 10 / 255, green: 17 / 255, blue: 14 / 255)
    // Softer than pure black, with enough contrast on the brand's lime fill.
    static let charcoal = Color(red: 43 / 255, green: 53 / 255, blue: 47 / 255)
    static let actionOutline = charcoal.opacity(0.65)
    static let forest = Color(red: 23 / 255, green: 57 / 255, blue: 44 / 255)
    // The asset also supplies native List/Form icons and nested sheets.
    static let brandAccent = Color("AccentColor")
    static let panel = Color(red: 20 / 255, green: 35 / 255, blue: 27 / 255)
    static let panelRaised = Color(red: 35 / 255, green: 59 / 255, blue: 44 / 255)
    static let primaryAction = Color(red: 213 / 255, green: 1, blue: 57 / 255)
    static let destructiveAction = Color(red: 0.88, green: 0.16, blue: 0.18)
    static let digitalGreen = Color(red: 0.50, green: 1.00, blue: 0.42)
    static let digitalGreenInactive = Color(red: 0.22, green: 0.42, blue: 0.24).opacity(0.10)

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ink : Color(red: 247 / 255, green: 248 / 255, blue: 242 / 255)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? panel : Color(uiColor: .secondarySystemGroupedBackground)
    }

    static func raisedCard(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? panelRaised : Color(uiColor: .systemBackground)
    }

    static func controlOutline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.20) : charcoal.opacity(0.24)
    }
}

enum AppTypography {
    static let welcomeTitle = Font.system(.title, design: .rounded).weight(.bold)
    static let screenTitle = Font.system(.title2, design: .rounded).weight(.bold)
    static let actionLabel = Font.headline.weight(.semibold)
    static let featureLabel = Font.body.weight(.semibold)
    static let supportingText = Font.subheadline.weight(.medium)
    static let compactLabel = Font.caption.weight(.regular)
    static let compactStrongLabel = Font.caption.weight(.semibold)
    static let valueLabel = Font.title3.weight(.bold).monospacedDigit()
    static let finePrint = Font.caption2.weight(.regular)
    static let legalLabel = Font.footnote.weight(.semibold)
}

enum UIShape {
    static let card: CGFloat = 24
    static let compactCard: CGFloat = 18
}

enum HUDColorStyle: String, CaseIterable, Identifiable, Codable {
    case green
    case amber
    case cyan

    var id: String { rawValue }

    var next: HUDColorStyle {
        switch self {
        case .green: .amber
        case .amber: .cyan
        case .cyan: .green
        }
    }

    var activeColor: Color {
        switch self {
        case .green: AppPalette.digitalGreen
        case .amber: Color(red: 1.00, green: 0.72, blue: 0.18)
        case .cyan: Color(red: 0.20, green: 0.92, blue: 1.00)
        }
    }

    var inactiveColor: Color {
        switch self {
        case .green: AppPalette.digitalGreenInactive
        case .amber, .cyan: activeColor.opacity(0.10)
        }
    }
}
