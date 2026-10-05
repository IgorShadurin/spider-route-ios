import StoreKit
import SwiftUI

enum PaywallPreviewState: Equatable {
    case lifetime
    case normal
    case loading
    case purchasing
    case pending
    case failure
    case restored
}

@MainActor
struct PaywallView: View {
    @ObservedObject var subscription: SubscriptionStore
    let onClose: () -> Void
    var previewState: PaywallPreviewState?

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var notice: String?
    @State private var selectedPlan: AccessPlan = .yearly

    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let privacyURL = URL(string: "https://spiderroute.com/ios/privacy")!

    init(subscription: SubscriptionStore, onClose: @escaping () -> Void, previewState: PaywallPreviewState? = nil) {
        self.subscription = subscription
        self.onClose = onClose
        self.previewState = previewState
        _selectedPlan = State(initialValue: previewState == .lifetime ? .lifetime : .yearly)
    }

    var body: some View {
        PlatformNavigationContainer {
            GeometryReader { proxy in
                let compact = proxy.size.height < 730 && !dynamicTypeSize.isAccessibilitySize
                ZStack {
                    AppPalette.canvas(colorScheme).ignoresSafeArea()
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: compact ? 8 : 14) {
                            hero(compact: compact)
                            VStack(spacing: compact ? 8 : 10) {
                                planCard(.yearly, compact: compact)
                                planCard(.lifetime, compact: compact)
                            }
                            previewStatus
                            purchaseButton
                            disclosure
                            compliance
                        }
                        .frame(maxWidth: 560)
                        .padding(.horizontal, compact ? 20 : 24)
                        .padding(.top, compact ? 10 : 16)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 10))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: compact ? proxy.size.height : 0, alignment: compact ? .center : .top)
                    }

                }
            }
            .environment(\.layoutDirection, layoutDirection)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.tr("common_close"))
                }
            }
        }
        .accessibilityIdentifier("screen.paywall")
        .task {
            if previewState == nil { await subscription.prepare() }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { isPresented in if !isPresented { notice = nil } })) {
            Button(L10n.tr("common_ok"), role: .cancel) { notice = nil }
        }
    }

    private func hero(compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 8) {
            Image("SpiderRouteBrand")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 64 : 84, height: compact ? 64 : 84)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 16 : 21, style: .continuous))
                .accessibilityHidden(true)

            Text(L10n.tr("paywall_title"))
                .font(AppTypography.welcomeTitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(0.84)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            Text(L10n.tr("paywall_subtitle"))
                .font(AppTypography.supportingText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
        }
    }

    private func planCard(_ plan: AccessPlan, compact: Bool) -> some View {
        let selected = selectedPlan == plan
        return Button { selectedPlan = plan } label: {
            VStack(alignment: .leading, spacing: compact ? 7 : 9) {
                if plan == .yearly { trialSummary }
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? AppPalette.brandAccent : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan == .yearly ? subscription.displayTitle : L10n.tr("paywall_lifetime_title"))
                            .font(AppTypography.featureLabel)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(plan == .yearly ? subscription.displayPeriod : subscription.displayTitle)
                            .font(AppTypography.compactLabel)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(subscription.displayPrice(for: plan))
                            .font(AppTypography.valueLabel)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text(L10n.tr(plan == .yearly ? "paywall_price_per_year" : "paywall_lifetime_period"))
                            .font(AppTypography.finePrint)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(compact ? 12 : 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.raisedCard(colorScheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(selected ? AppPalette.brandAccent : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(subscription.blocksConflictingActions || isPurchasing || previewState == .pending)
        .accessibilityIdentifier("paywall.plan.\(plan.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var trialSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: PlatformSymbol.name("checkmark.circle.fill"))
                .font(.title2)
                .foregroundStyle(AppPalette.brandAccent)
            Text(L10n.tr("paywall_trial_title"))
                .font(AppTypography.featureLabel)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.trial.summary")
    }

    private var purchaseButton: some View {
        CapsuleActionButton(
            action: purchase,
            height: dynamicTypeSize.isAccessibilitySize ? 76 : 54,
            isEnabled: canPurchase
        ) {
            HStack(spacing: 9) {
                if isPurchasing { ProgressView().tint(AppPalette.charcoal) }
                Text(L10n.tr(selectedPlan.actionKey))
            }
        }
        .accessibilityIdentifier("paywall.subscribe")
    }

    @ViewBuilder
    private var previewStatus: some View {
        if let status = previewStatusContent {
            Label(L10n.tr(status.key), systemImage: PlatformSymbol.name(status.symbol))
                .font(AppTypography.compactStrongLabel)
                .foregroundStyle(status.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(status.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("paywall.status")
        }
    }

    private var previewStatusContent: (key: String, symbol: String, color: Color)? {
        switch previewState {
        case .pending: ("paywall_error_pending", "clock.badge.exclamationmark", .orange)
        case .failure: ("paywall_error_verification", "exclamationmark.triangle.fill", .red)
        case .restored: ("paywall_restore_success", "checkmark.seal.fill", .green)
        default: nil
        }
    }

    private var disclosure: some View {
        Text(selectedPlan == .yearly
             ? L10n.format("paywall_disclosure", subscription.displayPrice)
             : L10n.tr("paywall_lifetime_notice"))
            .font(AppTypography.finePrint)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var compliance: some View {
        VStack(spacing: 0) {
            Button(action: restore) {
                HStack(spacing: 7) {
                    if isRestoring { ProgressView().tint(.primary) }
                    Text(L10n.tr(isRestoring ? "paywall_restoring" : "paywall_restore"))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(subscription.blocksConflictingActions || previewState == .purchasing || previewState == .pending)
            .accessibilityIdentifier("paywall.restore")
            Link(destination: termsURL) {
                Text(L10n.tr("paywall_terms"))
                    .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            Link(destination: privacyURL) {
                Text(L10n.tr("paywall_privacy"))
                    .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
        }
        .font(AppTypography.legalLabel)
        .tint(.primary.opacity(0.82))
    }

    private var canPurchase: Bool {
        if previewState != nil { return previewState != .purchasing && previewState != .pending && previewState != .restored }
        return subscription.canStartPurchase
    }
    private var isPurchasing: Bool { previewState == .purchasing || subscription.activity == .purchasing }
    private var isRestoring: Bool { subscription.activity == .restoring }

    private func purchase() {
        guard previewState == nil else { return }
        let plan = selectedPlan
        Task {
            let succeeded = await subscription.purchase(plan: plan)
            if succeeded { onClose() }
            else if let failure = subscription.failure { notice = L10n.tr(failure.key) }
        }
    }

    private func restore() {
        guard previewState == nil else { return }
        Task {
            let restored = await subscription.restore()
            notice = L10n.tr(restored ? "paywall_restore_success" : "paywall_restore_not_found")
            if restored { onClose() }
        }
    }
}
