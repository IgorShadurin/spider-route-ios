import SwiftUI

struct DecisionConfirmationModal: View {
    let title: String
    let message: String
    var detail: String?
    let confirmLabel: String
    var confirmRole: CapsuleActionRole = .primary
    var systemName = "questionmark.circle.fill"
    var accessibilityName = "decision.confirmation"
    var isProcessing = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(spacing: 18) {
                Image(systemName: PlatformSymbol.name(systemName))
                    .font(.system(size: 32))
                    .foregroundStyle(confirmRole == .destructive ? AppPalette.destructiveAction : AppPalette.brandAccent)
                    .accessibilityIdentifier(accessibilityName)
                Text(title).font(.title3.bold()).multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .accessibilityIdentifier("\(accessibilityName).detail")
                }
                if isProcessing { ProgressView().accessibilityIdentifier("\(accessibilityName).progress") }
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    CapsuleActionButton(action: onCancel, role: .neutral) { Text(L10n.tr("common_cancel")) }
                        .accessibilityIdentifier("\(accessibilityName).cancel")
                    CapsuleActionButton(action: onConfirm, role: confirmRole, isEnabled: !isProcessing) { Text(confirmLabel) }
                        .disabled(isProcessing)
                        .accessibilityIdentifier("\(accessibilityName).confirm")
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.primary.opacity(0.12)))
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }
}

struct DestructiveConfirmationModal: View {
    let title: String
    let message: String
    let confirmLabel: String
    var confirmRole: CapsuleActionRole = .destructive
    var systemName = "exclamationmark.triangle.fill"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        DecisionConfirmationModal(
            title: title,
            message: message,
            confirmLabel: confirmLabel,
            confirmRole: confirmRole,
            systemName: systemName,
            accessibilityName: "destructive.confirmation",
            onCancel: onCancel,
            onConfirm: onConfirm
        )
    }
}

struct RouteNameEditorModal: View {
    let title: String
    let message: String?
    let sourceFileName: String?
    @Binding var name: String
    let confirmLabel: String
    var systemName = "pencil"
    var accessibilityName = "route-name.editor"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var canConfirm: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(spacing: 16) {
                Image(systemName: PlatformSymbol.name(systemName))
                    .font(.system(size: 32))
                    .foregroundStyle(AppPalette.brandAccent)
                    .accessibilityIdentifier(accessibilityName)
                Text(title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("reference_route_name"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(L10n.tr("reference_route_name"), text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.14)))
                        .accessibilityIdentifier("\(accessibilityName).name")
                }
                if let sourceFileName {
                    Text(sourceFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    CapsuleActionButton(action: onCancel, role: .neutral) { Text(L10n.tr("common_cancel")) }
                        .accessibilityIdentifier("\(accessibilityName).cancel")
                    CapsuleActionButton(action: onConfirm, role: .primary) { Text(confirmLabel) }
                        .disabled(!canConfirm)
                        .opacity(canConfirm ? 1 : 0.45)
                        .accessibilityIdentifier("\(accessibilityName).confirm")
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.primary.opacity(0.12)))
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }
}
