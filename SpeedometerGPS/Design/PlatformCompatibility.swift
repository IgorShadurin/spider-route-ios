import SwiftUI
import UIKit

struct PlatformNavigationContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(.stack)
        }
    }
}

extension View {
    @ViewBuilder
    func platformLargeSheetPresentation() -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.large])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    @ViewBuilder
    func platformFixedSheetHeight(_ height: CGFloat, enabled: Bool) -> some View {
        if #available(iOS 16.0, *), enabled {
            presentationDetents([.height(height)])
        } else {
            self
        }
    }

    @ViewBuilder
    func platformPopoverPresentation() -> some View {
        if #available(iOS 16.4, *) {
            presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }

    @ViewBuilder
    func platformHiddenScrollBackground() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func platformBottomContentMargin(_ margin: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            contentMargins(.bottom, margin, for: .scrollContent)
        } else {
            self
        }
    }

    @ViewBuilder
    func platformNumericTextTransition() -> some View {
        if #available(iOS 17.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }
}

enum PlatformSymbol {
    private static let fallbacks: [String: String] = [
        "figure.walk.motion": "figure.walk",
        "gauge.with.needle": "speedometer",
        "gauge.with.needle.fill": "speedometer",
        "person.badge.key.fill": "person.crop.circle.badge.checkmark",
        "rectangle.2.swap": "rectangle.on.rectangle",
        "rectangle.bottomthird.inset.filled": "rectangle.bottomthird.inset",
        "rectangle.inset.filled.and.person.filled": "rectangle.on.rectangle",
        "road.lanes": "map",
        "point.topleft.down.to.point.bottomright.curvepath": "map",
        "flag.checkered": "flag.fill"
    ]

    static func name(_ requested: String) -> String {
        guard UIImage(systemName: requested) == nil else { return requested }
        let fallback = fallbacks[requested] ?? "questionmark.circle"
        return UIImage(systemName: fallback) == nil ? "questionmark.circle" : fallback
    }

    static func name(_ preferred: String, fallback: String) -> String {
        UIImage(systemName: preferred) == nil ? fallback : preferred
    }
}

/// A real finish flag on every supported OS, independent of SF Symbols versions.
struct CheckeredFlagIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let cloth = CGRect(x: size * 0.2, y: size * 0.1, width: size * 0.72, height: size * 0.55)
            ZStack {
                Path { $0.addRect(cloth) }.fill(.white)
                Path { path in
                    path.addRect(CGRect(x: size * 0.12, y: size * 0.08, width: size * 0.08, height: size * 0.86))
                    for row in 0..<3 {
                        for column in 0..<4 where (row + column).isMultiple(of: 2) {
                            path.addRect(CGRect(x: cloth.minX + CGFloat(column) * cloth.width / 4,
                                                y: cloth.minY + CGFloat(row) * cloth.height / 3,
                                                width: cloth.width / 4, height: cloth.height / 3))
                        }
                    }
                }.fill(.black)
                Path { $0.addRect(cloth) }.stroke(.black, lineWidth: size * 0.055)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
