import SwiftUI
import MapLibre

struct OfflineRegionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    @State private var regions: [OfflineRegion] = []
    @State private var query = ""
    @State private var results: [OfflineRegion] = []
    @State private var failed = false
    @State private var loaded = false
#if DEBUG
    @State private var showProvince = false
#endif

    var body: some View {
        NavigationView {
            List(results) { country in
                NavigationLink {
                    OfflineProvincePickerView(settings: settings, country: country,
                        provinces: regions.filter { $0.parentID == country.id }, onCreated: { dismiss() })
                } label: {
                    Text(country.localizedName(locale: L10n.locale)).frame(minHeight: 36)
                }.accessibilityIdentifier("offline.region.\(country.id)")
            }
            .overlay { if !loaded { ProgressView() } }
            .background {
#if DEBUG
                NavigationLink(isActive: $showProvince) {
                    if let country = regions.first(where: { $0.id == "country.BLR" }) {
                        OfflineProvincePickerView(settings: settings, country: country,
                            provinces: regions.filter { $0.parentID == country.id }, onCreated: { dismiss() })
                    }
                } label: { EmptyView() }
#endif
            }
            .searchable(text: $query)
            .navigationTitle(L10n.tr("offline_regions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common_cancel")) { dismiss() } } }
            .task {
                do {
                    regions = try await Task.detached(priority: .userInitiated) { try OfflineRegionCatalog.load() }.value; loaded = true
#if DEBUG
                    showProvince = ScreenshotState.requested == .mapProvinces
#endif
                }
                catch { failed = true; loaded = true }
            }
            .task(id: "\(loaded)-\(query)") {
                let all = regions, search = query, locale = L10n.locale
                let matches = await Task.detached(priority: .userInitiated) {
                    all.filter { $0.parentID == nil && (search.isEmpty || $0.localizedName(locale: locale).localizedStandardContains(search) || $0.name.localizedStandardContains(search)) }
                        .sorted { $0.localizedName(locale: locale).localizedStandardCompare($1.localizedName(locale: locale)) == .orderedAscending }
                }.value
                if !Task.isCancelled {
                    results = matches
#if DEBUG
                    if loaded && ScreenshotState.requested == .mapRegions { regionScreenshotReady("map.regions") }
#endif
                }
            }
            .alert(L10n.tr("offline_failed"), isPresented: $failed) { Button(L10n.tr("common_done")) {} }
            .accessibilityIdentifier("screen.offline-regions")
        }.navigationViewStyle(.stack)
            .environment(\.layoutDirection, AppLanguage.all.first { $0.id == AppLanguage.normalized(L10n.locale.identifier) }?.isRTL == true ? .rightToLeft : .leftToRight)
    }
}

#if DEBUG
/// A separate process with no maps alive clears only the ambient cache. The next
/// cold, network-blocked launch can therefore prove pack-backed rendering.
struct OfflineMapCacheCleanupView: View {
    @State private var status = "clearing"
    var body: some View {
        Text(status).accessibilityIdentifier("offline.cache-cleanup")
            .task {
                _ = OfflineMapStore.shared
                do { try await MLNOfflineStorage.shared.clearAmbientCache(); status = "complete" }
                catch { status = "failed" }
            }
    }
}
#endif

struct OfflineProvincePickerView: View {
    @ObservedObject var settings: AppSettings
    let country: OfflineRegion
    let provinces: [OfflineRegion]
    let onCreated: () -> Void
    @State private var query = ""

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DownloadMapView(settings: settings, region: country, embedded: true, onCreated: onCreated)
                } label: { Label(L10n.tr("offline_entire_country"), systemImage: "arrow.down.circle") }
                    .accessibilityIdentifier("offline.region.entire-country")
            }
            Section {
                ForEach(provinces.filter { query.isEmpty || $0.localizedName(locale: L10n.locale).localizedStandardContains(query) || $0.name.localizedStandardContains(query) }
                    .sorted { $0.localizedName(locale: L10n.locale).localizedStandardCompare($1.localizedName(locale: L10n.locale)) == .orderedAscending }) { province in
                    NavigationLink {
                        DownloadMapView(settings: settings, region: province, embedded: true, onCreated: onCreated)
                    } label: {
                        HStack {
                            Text(province.localizedName(locale: L10n.locale))
                            Spacer(minLength: 8)
                            if let code = province.subdivisionCode { Text(code).font(.caption).foregroundStyle(.secondary) }
                        }.frame(minHeight: 36)
                    }
                        .accessibilityIdentifier("offline.region.\(province.id)")
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(country.localizedName(locale: L10n.locale)).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.offline-provinces")
#if DEBUG
        .onAppear { if ScreenshotState.requested == .mapProvinces { regionScreenshotReady("map.provinces") } }
#endif
    }
}

#if DEBUG
private func regionScreenshotReady(_ screen: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("offline-region-ui-ready")
    try? Data(screen.utf8).write(to: url, options: .atomic)
}
#endif
