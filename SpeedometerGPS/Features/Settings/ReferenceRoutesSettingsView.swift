import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ReferenceRoutesSettingsView: View {
    @ObservedObject var store: ReferenceRouteStore

    @State private var guideRoute: ReferenceRoute?
    @State private var showingImporter = false
    @State private var showingImportError = false
    @State private var pendingDeletion: ReferenceRoute?
    @State private var pendingRename: ReferenceRoute?
    @State private var renameDraft = ""

    var body: some View {
        List {
            importSection
            routeLibrarySection
            visibilitySection
            if let route = store.route {
                Section {
                    Button { guideRoute = route } label: {
                        Label(L10n.tr("route_guide_title"), systemImage: "mappin.and.ellipse")
                    }.accessibilityIdentifier("settings.route-guide.open")
                } footer: { Text(L10n.tr("route_guide_footer")) }
            }
        }
        .disabled(store.isImporting)
        .overlay { if store.isImporting { ProgressView().padding().background(.regularMaterial) } }
        .navigationTitle(L10n.tr("settings_reference_routes"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.reference-routes")
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.speedometerGPX, .speedometerKML, .speedometerGeoJSON, .commaSeparatedText, .xml, .json],
            allowsMultipleSelection: true
        ) { result in
            Task {
                do { for url in try result.get() { try await store.importRouteInBackground(from: url) } }
                catch { showingImportError = true }
            }
        }
        .alert(L10n.tr("reference_route_import_failed_title"), isPresented: $showingImportError) {
            Button(L10n.tr("common_ok"), role: .cancel) {}
        } message: {
            Text(L10n.tr("reference_route_import_failed_message"))
        }
        .sheet(item: $guideRoute) { RouteGuideLibrarySheet(store: store, route: $0) }
        .overlay { deletionConfirmation }
        .overlay { renameConfirmation }
        .onAppear(perform: prepareScreenshotState)
    }

    private var importSection: some View {
        Section {
            Button { showingImporter = true } label: {
                Label(L10n.tr("reference_route_import"), systemImage: PlatformSymbol.name("square.and.arrow.down"))
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("settings.reference-routes.import")
        } footer: {
            Text(L10n.tr("reference_routes_formats_footer"))
        }
    }

    @ViewBuilder private var routeLibrarySection: some View {
        Section(L10n.tr("reference_routes_imported")) {
            if store.routes.isEmpty {
                Label(L10n.tr("reference_routes_empty"), systemImage: PlatformSymbol.name("map"))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 52)
            } else {
                ForEach(store.routes) { route in
                    HStack(spacing: 8) {
                        Button { store.select(route.id) } label: {
                            routeSelectionContent(route)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.reference-route.row.\(route.id.uuidString)")
                        .accessibilityValue(
                            route.id == store.selectedRouteID ? L10n.tr("reference_routes_selected") : ""
                        )

                        routeActionButton(
                            systemName: "pencil",
                            color: AppPalette.primaryAction,
                            foreground: AppPalette.charcoal,
                            label: L10n.tr("reference_route_rename"),
                            identifier: "settings.reference-route.rename.\(route.id.uuidString)"
                        ) { beginRename(route) }

                        routeActionButton(
                            systemName: "trash",
                            color: AppPalette.destructiveAction,
                            label: L10n.tr("common_delete"),
                            identifier: "settings.reference-route.delete.\(route.id.uuidString)"
                        ) { pendingDeletion = route }
                    }
                    .padding(.vertical, 5)
                    .frame(minHeight: 54)
                }
            }
        }
    }

    private var visibilitySection: some View {
        Section {
            Toggle(L10n.tr("reference_routes_show_on_map"), isOn: visibilityBinding)
                .disabled(store.routes.isEmpty)
                .accessibilityIdentifier("settings.reference-routes.visibility")
            if let route = store.route, route.supportsDistanceMarkers {
                Toggle(L10n.tr("reference_route_distance_marks"), isOn: $store.showsDistanceMarkers)
                    .accessibilityIdentifier("settings.reference-routes.distance-markers")
                ReferenceRouteDirectionControl(store: store, route: route)
            }
        } footer: {
            Text(L10n.tr("reference_routes_map_footer"))
        }
    }

    private func routeSelectionContent(_ route: ReferenceRoute) -> some View {
        HStack(spacing: 12) {
            Image(systemName: PlatformSymbol.name(route.id == store.selectedRouteID ? "checkmark.circle.fill" : "circle"))
                .font(.title3)
                .foregroundStyle(route.id == store.selectedRouteID ? AppPalette.brandAccent : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(route.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(routeDetail(route)) • \(routeFileType(route))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func routeActionButton(
        systemName: String,
        color: Color,
        foreground: Color = .white,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: PlatformSymbol.name(systemName))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background(color, in: Circle())
                .overlay { Circle().strokeBorder(AppPalette.actionOutline, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(get: { store.isVisible }, set: { store.isVisible = $0 })
    }

    private func routeDetail(_ route: ReferenceRoute) -> String {
        L10n.format(
            "reference_routes_detail_format",
            SpeedFormatter.distance(store.display(for: route).distance),
            route.pointCount
        )
    }

    private func routeFileType(_ route: ReferenceRoute) -> String {
        URL(fileURLWithPath: route.sourceFileName).pathExtension.uppercased()
    }

    @ViewBuilder private var deletionConfirmation: some View {
        if let pendingDeletion {
            DestructiveConfirmationModal(
                title: L10n.tr("reference_routes_delete_title"),
                message: L10n.format("reference_routes_delete_message", pendingDeletion.name),
                confirmLabel: L10n.tr("common_delete"),
                systemName: "trash.fill",
                onCancel: { self.pendingDeletion = nil },
                onConfirm: {
                    store.delete(pendingDeletion.id)
                    self.pendingDeletion = nil
                }
            )
            .accessibilityIdentifier("reference-route.delete.confirmation")
        }
    }

    @ViewBuilder private var renameConfirmation: some View {
        if let pendingRename {
            RouteNameEditorModal(
                title: L10n.tr("reference_route_rename"),
                message: nil,
                sourceFileName: pendingRename.sourceFileName,
                name: $renameDraft,
                confirmLabel: L10n.tr("common_done"),
                accessibilityName: "reference-route.rename.confirmation",
                onCancel: { self.pendingRename = nil },
                onConfirm: {
                    if store.rename(pendingRename.id, to: renameDraft) {
                        self.pendingRename = nil
                    }
                }
            )
        }
    }

    private func beginRename(_ route: ReferenceRoute) {
        renameDraft = route.name
        pendingRename = route
    }

    private func prepareScreenshotState() {
#if DEBUG
        if ScreenshotState.requested == .settingsReferenceRouteDeleteConfirmation {
            pendingDeletion = store.routes.first
        } else if ScreenshotState.requested == .settingsReferenceRouteRename {
            if let route = store.routes.first { beginRename(route) }
        }
#endif
    }
}

/// Shared direction controls for the map popover and imported-route settings.
struct ReferenceRouteDirectionControl: View {
    @ObservedObject var store: ReferenceRouteStore
    let route: ReferenceRoute

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: PlatformSymbol.name("flag.fill")).foregroundStyle(.green)
                    Text(L10n.tr("route_start_marker"))
                    Image(systemName: PlatformSymbol.name("arrow.right")).foregroundStyle(.secondary)
                    Image(systemName: PlatformSymbol.name("flag.checkered")).foregroundStyle(AppPalette.brandAccent)
                    Text(L10n.tr("route_end_marker"))
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                Text(L10n.tr(store.isReversed(route) ? "reference_route_direction_reversed" : "reference_route_direction_original"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reference-route.direction")
            }
            Spacer(minLength: 0)
            Button { store.reverseDirection(of: route) } label: {
                Image(systemName: PlatformSymbol.name("arrow.left.arrow.right"))
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(AppPalette.brandAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.brandAccent)
            .accessibilityLabel(L10n.tr("reference_route_reverse"))
            .accessibilityIdentifier("reference-route.reverse")
        }
        .padding(.vertical, 2)
    }
}
