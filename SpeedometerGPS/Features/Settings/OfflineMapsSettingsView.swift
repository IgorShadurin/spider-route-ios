import MapKit
import MapLibre
import SwiftUI

struct OfflineMapsSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var store = OfflineMapStore.shared
    private enum MapSheet: Identifiable {
        case download, customDownload, preview(DownloadedMapMetadata)
        var id: String { switch self { case .download: return "download"; case .customDownload: return "custom-download"; case .preview(let map): return map.id.uuidString } }
    }
    @State private var presentedMap: MapSheet?
    @State private var deleteTarget: OfflineMapStore.Entry?
    @State private var stoppingDownload = false
    @State private var availableBytes: Int64?
    @State private var usedBytes: Int64?
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                overview
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color(uiColor: .systemGroupedBackground))
            }
            .listSectionSeparator(.hidden)
            Section {
                if store.entries.isEmpty {
                    Label(L10n.tr("offline_empty"), systemImage: "map")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                        .accessibilityIdentifier("offline.empty")
                }
                ForEach(store.entries) { entry in
                    downloadRow(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Confirmation owns deletion; avoid List's optimistic removal.
                            Button { stoppingDownload = false; deleteTarget = entry } label: {
                                Label(L10n.tr("common_delete"), systemImage: "trash")
                            }.tint(.red).accessibilityIdentifier("offline.delete")
                        }
                }
            } header: {
                Text(L10n.tr("offline_your_maps"))
                    .font(.headline).foregroundStyle(.primary).textCase(nil)
                    .padding(.top, 12)
            }

        }
        .listStyle(.plain)
        .task {
            // Refresh only while this screen is present, not on every tile update.
            while !Task.isCancelled {
                availableBytes = await Task.detached(priority: .utility) { () -> Int64? in
                    let url = URL(fileURLWithPath: NSHomeDirectory())
                    guard let free = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else { return nil }
                    return Int64(free)
                }.value
                // The SDK counts shared map resources once, including its map cache.
                usedBytes = Int64(clamping: MLNOfflineStorage.shared.countOfBytesCompleted)
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { break }
            }
        }
        .environment(\.layoutDirection, AppLanguage.all.first { $0.id == AppLanguage.normalized(L10n.locale.identifier) }?.isRTL == true ? .rightToLeft : .leftToRight)
        .navigationTitle(L10n.tr("offline_maps"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.offline-maps")
        .overlay {
            if let target = deleteTarget {
                DestructiveConfirmationModal(title: L10n.tr(stoppingDownload ? "rc_stop" : "common_delete"),
                    message: stoppingDownload ? "\(L10n.tr("common_delete")): \(target.metadata.name)" : target.metadata.name,
                    confirmLabel: L10n.tr(stoppingDownload ? "rc_stop" : "common_delete"), systemName: stoppingDownload ? "stop.fill" : "trash",
                    onCancel: { deleteTarget = nil }, onConfirm: { store.delete(target.id); deleteTarget = nil })
            }
        }
        .sheet(item: $presentedMap) { sheet in
            switch sheet {
            case .download: OfflineRegionPickerView(settings: settings)
            case .customDownload: DownloadMapView(settings: settings)
            case .preview(let metadata): NavigationView {
                DownloadAreaMap(languageID: metadata.languageID, initialBounds: metadata.bounds, frozenStyleURL: metadata.frozenStyleURL, selectedShape: store.downloadedShape(for: metadata), framesSelection: true, onBoundsChanged: { _ in })
                    .overlay(alignment: .bottomLeading) { OSMDownloadAttribution().padding(8) }
                    .navigationTitle(metadata.name).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("common_done")) { presentedMap = nil } } }
            }.navigationViewStyle(.stack).tint(AppPalette.brandAccent)
                .accessibilityIdentifier("screen.offline-map-preview")
            }
        }
        .alert(L10n.tr("offline_failed"), isPresented: $store.failed) { Button(L10n.tr("common_done"), role: .cancel) {} }
#if DEBUG
        .onAppear { if ScreenshotState.requested == .mapDownload || ScreenshotState.requested == .mapDownloadLanguages { presentedMap = .customDownload } else if ScreenshotState.requested == .mapRegions || ScreenshotState.requested == .mapProvinces { presentedMap = .download } }
#endif
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                if !sizeCategory.isAccessibilityCategory {
                    Image(systemName: "map.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(AppPalette.brandAccent)
                        .accessibilityHidden(true)
                }
                Text(L10n.tr("offline_intro"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                storageRow(L10n.tr("offline_used_storage"), bytes: usedBytes, identifier: "offline.used-space")
                storageRow(L10n.tr("offline_free_storage"), bytes: availableBytes, identifier: "offline.free-space")
            }
            Button { presentedMap = .download } label: {
                Group {
                    if sizeCategory.isAccessibilityCategory {
                        Text(L10n.tr("offline_download"))
                    } else {
                        Label(L10n.tr("offline_download"), systemImage: "square.and.arrow.down")
                    }
                }
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(colorScheme == .dark ? AppPalette.ink : .white)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("offline.add")
        }
        .padding(.vertical, 12)
    }

    private func storageRow(_ title: String, bytes: Int64?, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                .monospacedDigit().fontWeight(.medium)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func downloadRow(_ entry: OfflineMapStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if entry.state == .complete {
                    store.selectedID = entry.id
                    settings.mapProvider = .openStreetMap
                    presentedMap = .preview(entry.metadata)
                }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.state == .complete ? "map" : "arrow.down.circle")
                            .font(.title2).foregroundStyle(AppPalette.brandAccent)
                            .frame(width: 28).padding(.top, 2).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(entry.metadata.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                if entry.state == .complete {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.subheadline).foregroundStyle(.green)
                                        .accessibilityLabel(L10n.tr("offline_ready"))
                                        .accessibilityIdentifier("offline.status.\(entry.metadata.languageID)")
                                }
                            }
                            Text(entry.metadata.languageName).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if entry.state == .complete {
                            Image(systemName: "chevron.forward")
                                .font(.subheadline).foregroundStyle(AppPalette.brandAccent)
                        }
                    }
                    if entry.state == .complete {
                        byteSize(entry).padding(.leading, 40)
                    } else if sizeCategory.isAccessibilityCategory {
                        VStack(alignment: .leading, spacing: 4) { status(entry); byteSize(entry) }
                    } else {
                        HStack {
                            status(entry)
                            Spacer(minLength: 8)
                            byteSize(entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("offline.map.\(entry.metadata.languageID)")
            if entry.state != .complete {
                HStack(spacing: 4) {
                    ProgressView(value: entry.progress)
                        .frame(maxWidth: .infinity).padding(.trailing, 8)
                        .accessibilityIdentifier("offline.progress")
                    Button { store.toggle(entry.id) } label: {
                        Image(systemName: entry.state == .active ? "pause.fill" : "play.fill")
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.tr(entry.state == .active ? "trip_pause" : "trip_resume"))
                    .accessibilityIdentifier("offline.pause-resume")
                    Button { stoppingDownload = true; deleteTarget = entry } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    .accessibilityLabel(L10n.tr("rc_stop"))
                    .accessibilityIdentifier("offline.stop")
                }
            }
        }
        .padding(.vertical, 12)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        .listRowSeparator(.visible)
    }

    private func status(_ entry: OfflineMapStore.Entry) -> some View {
        HStack(spacing: 5) {
            Image(systemName: entry.state == .complete ? "checkmark.circle" : entry.state == .active ? "arrow.down" : "pause.circle").accessibilityHidden(true)
            Text(L10n.tr(entry.state == .complete ? "offline_ready" : entry.state == .active ? "offline_downloading" : "offline_paused"))
                .accessibilityIdentifier("offline.status.\(entry.metadata.languageID)")
            if entry.state != .complete {
                Text(entry.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
        }
        .font(.caption).foregroundStyle(.secondary)

    }

    private func byteSize(_ entry: OfflineMapStore.Entry) -> some View {
        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.bytes), countStyle: .file))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .accessibilityIdentifier("offline.size").accessibilityValue(String(entry.bytes))
    }

}

struct DownloadMapView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    @ObservedObject private var store = OfflineMapStore.shared
    let region: OfflineRegion?
    let embedded: Bool
    let onCreated: (() -> Void)?
    @State private var name = ""
    @State private var choosingLanguage = false
    @State private var languageID = AppLanguage.normalized(L10n.locale.identifier)
    @State private var bounds: MLNCoordinateBounds
    @State private var shape: MLNShape?

    init(settings: AppSettings, region: OfflineRegion? = nil, embedded: Bool = false, onCreated: (() -> Void)? = nil) {
        self.settings = settings; self.embedded = embedded; self.onCreated = onCreated
        var selected = region
#if DEBUG
        _choosingLanguage = State(initialValue: ScreenshotState.requested == .mapDownloadLanguages)
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-download-catalog-region=") }) {
            let id = String(argument.dropFirst("--ui-download-catalog-region=".count))
            selected = try? OfflineRegionCatalog.load().first { $0.id == id }
        } else if ScreenshotState.requested == .mapDownload,
                  !ProcessInfo.processInfo.arguments.contains("--ui-download-small-area") {
            selected = try? OfflineRegionCatalog.load().first { $0.id == "country.MCO" }
        }
#endif
        self.region = selected
        _name = State(initialValue: selected?.localizedName(locale: L10n.locale) ?? "")
        var area = OfflineMapStore.shared.lastRegion
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-download-small-area") {
            area = .init(center: .init(latitude: 53.9, longitude: 27.5667), span: .init(latitudeDelta: 0.004, longitudeDelta: 0.006))
        }
#endif
        _bounds = State(initialValue: selected?.coordinateBounds ?? .init(sw: .init(latitude: area.center.latitude - area.span.latitudeDelta / 2, longitude: area.center.longitude - area.span.longitudeDelta / 2), ne: .init(latitude: area.center.latitude + area.span.latitudeDelta / 2, longitude: area.center.longitude + area.span.longitudeDelta / 2)))
    }
    private var validArea: Bool { region != nil ? shape != nil : OSMMapStyle.estimatedTileCount(bounds) <= 2_500 }
    var body: some View {
        Group {
            if embedded { content } else { NavigationView { content }.navigationViewStyle(.stack) }
        }
        .tint(AppPalette.brandAccent)
        .environment(\.layoutDirection, AppLanguage.all.first { $0.id == AppLanguage.normalized(L10n.locale.identifier) }?.isRTL == true ? .rightToLeft : .leftToRight)
        .accessibilityIdentifier("screen.map-download")
        .alert(L10n.tr("offline_failed"), isPresented: $store.failed) { Button(L10n.tr("common_done"), role: .cancel) {} }
    }
    private var content: some View {
        VStack(spacing: 0) {
            DownloadAreaMap(languageID: languageID, initialBounds: bounds, selectedShape: shape,
                onBoundsChanged: { if region == nil { bounds = $0 } })
                .overlay(alignment: .bottomLeading) { OSMDownloadAttribution().padding(8) }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("offline.area-map")
            Form {
                TextField(L10n.tr("offline_name"), text: $name).accessibilityIdentifier("offline.name")
                NavigationLink(isActive: $choosingLanguage) {
                    MapLanguageSelectionView(languageID: $languageID, onSelection: { choosingLanguage = false })
                } label: {
                    HStack {
                        Text(L10n.tr("offline_language"))
                        Spacer()
                        Text(AppLanguage.all.first { $0.id == languageID }?.nativeName ?? languageID)
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }.accessibilityIdentifier("offline.language")
                Text(L10n.tr(region != nil ? "offline_region_hint" : validArea ? "offline_hint" : "offline_too_large"))
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(height: 210)
        }
        .navigationTitle(L10n.tr("tab_map"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if !embedded { Button(L10n.tr("common_cancel")) { dismiss() }.disabled(store.isCreating) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    store.download(name: name, languageID: languageID, bounds: bounds, region: region, shape: shape) { success in
                        if success { settings.mapProvider = .openStreetMap; if let onCreated { onCreated() } else { dismiss() } }
                    }
                } label: { if store.isCreating { ProgressView() } else { Text(L10n.tr("offline_download_action")) } }
                    .disabled(!validArea || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isCreating)
                    .accessibilityIdentifier("offline.download")
            }
        }
        .task {
            guard let region, shape == nil else { return }
            do {
                shape = try await Task.detached(priority: .userInitiated) {
                    try MLNShape(data: region.shapeData(), encoding: String.Encoding.utf8.rawValue)
                }.value
            } catch { store.failed = true }
        }
    }
}

private struct OSMDownloadAttribution: View {
    var body: some View {
        HStack(spacing: 4) {
            Link("© OpenMapTiles", destination: URL(string: "https://openmaptiles.org/")!)
            Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
        }.font(.system(size: 10)).foregroundStyle(.black)
            .padding(5).background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 4))
            .frame(minHeight: 44)
    }
}

private struct DownloadAreaMap: UIViewRepresentable {
    let languageID: String
    let initialBounds: MLNCoordinateBounds
    var frozenStyleURL: URL? = nil
    var selectedShape: MLNShape? = nil
    var framesSelection = false
    let onBoundsChanged: (MLNCoordinateBounds) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onBoundsChanged) }
    func makeUIView(context: Context) -> MLNMapView {
        let map = SpiderRouteOSMMapView(frame: .zero, styleURL: frozenStyleURL ?? (try? OSMMapStyle.url(languageID: languageID, permitsNetwork: OSMMapStyle.permitsNetwork)))
        map.delegate = context.coordinator
        context.coordinator.selectedShape = selectedShape
#if DEBUG
        context.coordinator.labelProbe.install(in: map)
        OSMMapLifetimeProbe.register(map: map, coordinator: context.coordinator)
#endif
        map.logoView.isHidden = true; map.attributionButton.isHidden = true
        map.isPitchEnabled = false; map.isRotateEnabled = false
        let area = initialBounds
        map.onFirstLayout = { [weak map] in
            map?.setVisibleCoordinateBounds(area,
                edgePadding: framesSelection ? UIEdgeInsets(top: 48, left: 28, bottom: 64, right: 28) : .zero,
                animated: false)
        }
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.onBoundsChanged = onBoundsChanged
        if context.coordinator.selectedShape !== selectedShape {
            context.coordinator.selectedShape = selectedShape
            context.coordinator.renderSelection(in: map)
        }
        let url = frozenStyleURL ?? (try? OSMMapStyle.url(languageID: languageID, permitsNetwork: OSMMapStyle.permitsNetwork))
        if map.styleURL != url { map.styleURL = url }
    }
    final class Coordinator: NSObject, MLNMapViewDelegate {
#if DEBUG
        let labelProbe = OSMRenderedLabelsProbe()
#endif
        var selectedShape: MLNShape?
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) { renderSelection(in: mapView) }
        func renderSelection(in map: MLNMapView) {
            guard let style = map.style, let selectedShape else { return }
            if let source = style.source(withIdentifier: "offline-selection") as? MLNShapeSource { source.shape = selectedShape; return }
            let source = MLNShapeSource(identifier: "offline-selection", shape: selectedShape)
            style.addSource(source)
            let casing = MLNLineStyleLayer(identifier: "offline-selection-casing", source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 7)
            style.addLayer(casing)
            let line = MLNLineStyleLayer(identifier: "offline-selection-outline", source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor.systemRed)
            line.lineWidth = NSExpression(forConstantValue: 4)
            style.addLayer(line)
        }
        var onBoundsChanged: (MLNCoordinateBounds) -> Void
        init(_ onBoundsChanged: @escaping (MLNCoordinateBounds) -> Void) { self.onBoundsChanged = onBoundsChanged }
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { onBoundsChanged(mapView.visibleCoordinateBounds) }
    }
}

private struct MapLanguageSelectionView: View {
    @Binding var languageID: String
    let onSelection: () -> Void
    var body: some View {
        List(AppLanguage.all) { language in
            Button { languageID = language.id; onSelection() } label: {
                HStack {
                    Text(language.nativeName).foregroundStyle(.primary)
                    Spacer()
                    if languageID == language.id { Image(systemName: "checkmark") }
                }.frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .accessibilityIdentifier("offline.language.option.\(language.id)")
        }.environment(\.defaultMinListRowHeight, 52)
            .navigationTitle(L10n.tr("offline_language")).navigationBarTitleDisplayMode(.inline)
    }
}


#if DEBUG
/// Explicit device QA only. Uses the shipping download/preview components and
/// never seeds trips, changes entitlement, or replaces the user's libraries.
struct OSMDeviceRegionProbeView: View {
    @ObservedObject private var store = OfflineMapStore.shared
    @State private var preview: DownloadedMapMetadata?
    @State private var status = "Preparing device map test"
    @State private var report: [String: Any] = [:]
    @State private var samples: [[String: Any]] = []
    private let regionIDs = ["province.1159315869", "province.1159313099"]
    private var offline: Bool { ProcessInfo.processInfo.arguments.contains("--ui-offline-map") }

    var body: some View {
        VStack {
            Text(status).padding(8)
            if let preview {
                DownloadAreaMap(languageID: preview.languageID, initialBounds: preview.bounds,
                    frozenStyleURL: preview.frozenStyleURL, onBoundsChanged: { _ in })
                    .id(preview.id)
                    .overlay(alignment: .bottomLeading) { OSMDownloadAttribution().padding(8) }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task { await run() }
    }

    @MainActor
    private func run() async {
        let previousSelection = store.selectedID
        defer { store.selectedID = previousSelection }
        let began = Date()
        report = ["os": UIDevice.current.systemVersion, "network_blocked": offline,
                  "started_at": ISO8601DateFormatter().string(from: began)]
        do {
            let catalog = try await Task.detached { try OfflineRegionCatalog.load() }.value
            for _ in 0..<100 where MLNOfflineStorage.shared.packs == nil {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            var completed: [DownloadedMapMetadata] = []
            for regionID in regionIDs {
                guard let region = catalog.first(where: { $0.id == regionID }) else { throw CocoaError(.fileNoSuchFile) }
                let name = "Device QA 20260930 " + region.name
                if !store.entries.contains(where: { $0.metadata.name == name }) {
                    guard !offline else { throw CocoaError(.fileNoSuchFile) }
                    let shape = try await Task.detached {
                        try MLNShape(data: region.shapeData(), encoding: String.Encoding.utf8.rawValue)
                    }.value
                    let created: Bool = await withCheckedContinuation { continuation in
                        store.download(name: name, languageID: "ru", bounds: region.coordinateBounds,
                            region: region, shape: shape) { continuation.resume(returning: $0) }
                    }
                    store.selectedID = previousSelection
                    guard created else { throw CocoaError(.fileWriteUnknown) }
                }
                let downloadStart = Date()
                while true {
                    try Task.checkCancellation()
                    guard !store.failed else { throw CocoaError(.fileReadUnknown) }
                    if let entry = store.entries.first(where: { $0.metadata.name == name }) {
                        status = "\(region.name): \(Int(entry.progress * 100))% · \(entry.bytes / 1_000_000) MB"
                        report[regionID] = ["name": region.name, "progress": entry.progress,
                            "bytes": entry.bytes, "complete": entry.state == .complete,
                            "language": entry.metadata.languageID, "id": entry.id.uuidString]
                        writeReport()
                        if entry.state == .complete { completed.append(entry.metadata); break }
                    }
                    guard Date().timeIntervalSince(downloadStart) < 900 else { throw URLError(.timedOut) }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            for cycle in 0..<8 {
                let metadata = completed[cycle % completed.count]
                status = "\(offline ? "Offline" : "Online") · \(metadata.name) · \(cycle + 1)/8"
                preview = metadata
                try await Task.sleep(nanoseconds: 8_000_000_000)
                samples.append(["cycle": cycle + 1, "phase": "visible", "footprint": OSMDeviceMemory.footprint(),
                    "live_objects": OSMMapLifetimeProbe.counts, "rendered": OSMMapLifetimeProbe.renderedContent])
                preview = nil
                try await Task.sleep(nanoseconds: 2_000_000_000)
                samples.append(["cycle": cycle + 1, "phase": "released", "footprint": OSMDeviceMemory.footprint(),
                    "live_objects": OSMMapLifetimeProbe.counts])
                writeReport()
            }
            preview = completed.first
            status = offline ? "Offline device test complete" : "Downloads and device test complete"
            report["complete"] = true
            report["elapsed_seconds"] = Date().timeIntervalSince(began)
            writeReport()
        } catch {
            status = "Device test failed: \(error.localizedDescription)"
            report["error"] = String(describing: error); report["download_error"] = store.debugLastError ?? "none"; writeReport()
        }
    }

    private func writeReport() {
        var output = report; output["samples"] = samples
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("osm-device-regions.json"), options: .atomic)
        }
    }
}

enum OSMDeviceMemory {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
