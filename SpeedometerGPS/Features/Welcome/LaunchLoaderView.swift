import SwiftUI

struct LaunchLoaderView: View {
    // Retain the initializer label for callers while retiring the speed-only launch.
    init(numberStyle: SpeedNumberStyle = .digital) {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var startedAt = Date()

    var body: some View {
        ZStack {
            AppPalette.canvas(colorScheme).ignoresSafeArea()
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let progress = WelcomeStoryTiming.loadingProgress(
                    at: context.date.timeIntervalSince(startedAt), reducedMotion: reduceMotion)
                VStack(spacing: 24) {
                    Image("SpiderRouteBrand")
                        .resizable().scaledToFit()
                        .frame(width: 132, height: 132)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                        .scaleEffect(0.94 + progress * 0.06)
                    Text(L10n.tr("app_name_short"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.brandAccent)
                    Capsule()
                        .fill(AppPalette.brandAccent.opacity(0.15))
                        .frame(width: 112, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(AppPalette.brandAccent).frame(width: 112 * progress, height: 4)
                        }
                }
            }
        }
        .accessibilityIdentifier("screen.loader")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("loading_speed"))
    }
}
