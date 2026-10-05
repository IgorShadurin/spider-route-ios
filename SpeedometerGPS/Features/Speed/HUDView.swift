import SwiftUI
import UIKit

enum HUDOrientationMode: String, CaseIterable, Equatable {
    case landscapeRight = "landscape-right"
    case portrait
    case landscapeLeft = "landscape-left"

    var next: HUDOrientationMode {
        switch self {
        case .landscapeRight: .portrait
        case .portrait: .landscapeLeft
        case .landscapeLeft: .landscapeRight
        }
    }

    var interfaceMask: UIInterfaceOrientationMask {
        switch self {
        case .landscapeRight: .landscapeRight
        case .portrait: .portrait
        case .landscapeLeft: .landscapeLeft
        }
    }
}

struct HUDViewportLayout: Equatable {
    let numberWidth: CGFloat
    let numberHeight: CGFloat

    init(viewport: CGSize) {
        let isLandscape = viewport.width > viewport.height
        let horizontalInset: CGFloat = 40
        let availableWidth = max(0, viewport.width - horizontalInset)

        if isLandscape {
            numberWidth = min(availableWidth, viewport.width * 0.72)
            numberHeight = min(viewport.height * 0.54, 290)
        } else {
            numberWidth = min(availableWidth, viewport.width * 0.90)
            numberHeight = min(viewport.height * 0.48, 360)
        }
    }
}

enum HUDPlatformStrategy: Equatable {
    case canvasRotation
    case sceneGeometry

    static func strategy(forMajorVersion majorVersion: Int) -> HUDPlatformStrategy {
        majorVersion >= 16 ? .sceneGeometry : .canvasRotation
    }

    func canvasSize(viewport: CGSize, orientation: HUDOrientationMode) -> CGSize {
        guard self == .canvasRotation, orientation != .portrait else { return viewport }
        return CGSize(width: viewport.height, height: viewport.width)
    }

    func canvasRotation(orientation: HUDOrientationMode) -> Angle {
        guard self == .canvasRotation else { return .zero }
        switch orientation {
        case .landscapeRight: return Angle.degrees(90)
        case .portrait: return Angle.zero
        case .landscapeLeft: return Angle.degrees(-90)
        }
    }
}

@MainActor
enum HUDOrientationController {
    static func request(_ mode: HUDOrientationMode) {
        request(mode.interfaceMask)
    }

    static func requestPortrait() {
        request(UIInterfaceOrientationMask.portrait)
    }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        guard #available(iOS 16.0, *) else {
            // iOS 15 has no public scene-geometry request. HUDView keeps the
            // system interface portrait and rotates its complete canvas.
            SpeedometerGPSAppDelegate.supportedOrientations = .portrait
            return
        }
        SpeedometerGPSAppDelegate.supportedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
#if DEBUG
            print("HUD orientation request failed: \(error.localizedDescription)")
#endif
        }
    }
}

struct HUDView: View {
    @ObservedObject var location: LocationMotionService
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isMirrored = true
    @State private var orientationMode: HUDOrientationMode

    init(location: LocationMotionService, settings: AppSettings) {
        self.location = location
        self.settings = settings
        _orientationMode = State(initialValue: .landscapeRight)
    }

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = legacyCanvasSize(for: proxy.size)
            let layout = HUDViewportLayout(viewport: canvasSize)
            hudCanvas(layout: layout)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .rotationEffect(legacyCanvasRotation)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear { HUDOrientationController.requestPortrait() }
        .onDisappear { HUDOrientationController.requestPortrait() }
    }

    private func hudCanvas(layout: HUDViewportLayout) -> some View {
        ZStack {
                Color.black
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel(L10n.tr("paywall_benefit_hud"))
                    .accessibilityValue(orientationMode.rawValue)
                    .accessibilityIdentifier("screen.hud")
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        CircularIconButton(systemName: "xmark", accessibilityLabel: L10n.tr("common_close"), tint: .white) { dismiss() }
                            .accessibilityIdentifier("hud.close")
                        Spacer()
                        CircularIconButton(systemName: "rotate.right.fill", accessibilityLabel: L10n.tr("hud_rotate"), tint: AppPalette.primaryAction) {
                            rotateHUD()
                        }
                        .accessibilityIdentifier("hud.rotate")
                        CircularIconButton(systemName: "rectangle.2.swap", accessibilityLabel: L10n.tr("hud_mirror"), tint: AppPalette.digitalGreen) {
                            withAnimation(.easeInOut(duration: 0.25)) { isMirrored.toggle() }
                        }
                        .accessibilityIdentifier("hud.mirror")
                        CircularIconButton(systemName: "paintpalette.fill", accessibilityLabel: L10n.tr("hud_color"), tint: settings.hudColorStyle.activeColor) {
                            withAnimation(.easeInOut(duration: 0.20)) {
                                settings.hudColorStyle = settings.hudColorStyle.next
                            }
                        }
                        .accessibilityIdentifier("hud.color")
                    }

                    Spacer(minLength: 4)

                    VStack(spacing: 4) {
                        SpeedNumberView(
                            text: SpeedFormatter.number(location.metersPerSecond, unit: settings.unit, decimals: settings.showDecimal),
                            style: settings.speedNumberStyle,
                            modernColor: settings.hudColorStyle.activeColor,
                            digitalActiveColor: settings.hudColorStyle.activeColor,
                            digitalInactiveColor: settings.hudColorStyle.inactiveColor
                        )
                        .frame(width: layout.numberWidth, height: layout.numberHeight)
                        Text(settings.unit.rawValue)
                            .font(Font.largeTitle.weight(.bold).monospacedDigit())
                            .foregroundStyle(settings.hudColorStyle.activeColor)
                    }
                    .scaleEffect(x: isMirrored ? -1 : 1, y: 1)

                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    private func legacyCanvasSize(for viewport: CGSize) -> CGSize {
        platformStrategy.canvasSize(viewport: viewport, orientation: orientationMode)
    }

    private var legacyCanvasRotation: Angle {
        platformStrategy.canvasRotation(orientation: orientationMode)
    }

    private var platformStrategy: HUDPlatformStrategy {
        // Rotate the HUD canvas inside its stable full-screen presentation.
        // This also works with portrait lock and avoids scene-rotation clipping.
        .canvasRotation
    }

    private func rotateHUD() {
        orientationMode = orientationMode.next
    }
}
