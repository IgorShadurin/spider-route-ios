import Foundation
import SwiftUI

enum BottomNavigationItem: String, CaseIterable, Codable, Identifiable {
    case speed
    case map
    case trips

    var id: String { rawValue }

    static let defaultOrder: [BottomNavigationItem] = [.map, .speed, .trips]

    var localizedName: String {
        switch self {
        case .speed: L10n.tr("tab_speed")
        case .map: L10n.tr("tab_map")
        case .trips: L10n.tr("tab_trips")
        }
    }

    var symbolName: String {
        let requested = switch self {
        case .speed: "gauge.with.needle"
        case .map: "map.fill"
        case .trips: "clock.arrow.circlepath"
        }
        return PlatformSymbol.name(requested)
    }

    static func normalized(_ storedValues: [String]?) -> [BottomNavigationItem] {
        var seen = Set<BottomNavigationItem>()
        let stored = (storedValues ?? []).compactMap(BottomNavigationItem.init(rawValue:))
        let uniqueStored = stored.filter { seen.insert($0).inserted }
        let missing = defaultOrder.filter { seen.insert($0).inserted }
        return uniqueStored + missing
    }
}

enum MapProvider: String, CaseIterable, Codable, Identifiable {
    case apple
    case openStreetMap

    var id: String { rawValue }
    // Provider trademarks retain their official names in every language.
    var displayName: String {
        switch self {
        case .apple: "Apple Maps"
        case .openStreetMap: "OpenStreetMap"
        }
    }
}

enum RouteDistanceLabelSize: Int, CaseIterable, Identifiable {
    case one = 1, two = 2, three = 3
    var id: Int { rawValue }
    var title: String { "\(rawValue)×" }
    var fontSize: CGFloat { 10 * CGFloat(rawValue) }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var unit: SpeedUnit { didSet { save() } }
    @Published var maximumSpeed: Double { didSet { save() } }
    @Published var showDecimal: Bool { didSet { save() } }
    @Published var showGPSStrength: Bool { didSet { save() } }
    @Published var theme: SpeedTheme { didSet { save() } }
    @Published var speedNumberStyle: SpeedNumberStyle { didSet { save() } }
    @Published var speedDashboardStyle: SpeedDashboardStyle { didSet { save() } }
    @Published var hudEnabled: Bool { didSet { save() } }
    @Published var hudColorStyle: HUDColorStyle { didSet { save() } }
    @Published var appearance: AppAppearance { didSet { save() } }
    @Published var lightSpeedNumberColor: DisplayColor { didSet { save() } }
    @Published var darkSpeedNumberColor: DisplayColor { didSet { save() } }
    @Published var lightSpeedOutlineEnabled: Bool { didSet { save() } }
    @Published var darkSpeedOutlineEnabled: Bool { didSet { save() } }
    @Published var lightSpeedOutlineColor: DisplayColor { didSet { save() } }
    @Published var darkSpeedOutlineColor: DisplayColor { didSet { save() } }
    @Published var syncWithICloud: Bool { didSet { save() } }
    @Published var speedAlertEnabled: Bool { didSet { save() } }
    @Published var speedAlertLimitMetersPerSecond: Double { didSet { save() } }
    @Published var mapProvider: MapProvider { didSet { save() } }
    @Published var distanceLabelSize: RouteDistanceLabelSize { didSet { save() } }
    @Published var mapLanguageID: String? { didSet { save() } }
    @Published var fullscreenMapShowsClock: Bool { didSet { save() } }
    @Published var followLocationOnMap: Bool { didSet { save() } }
    @Published var bottomNavigationOrder: [BottomNavigationItem] { didSet { save() } }

    private let defaults: UserDefaults
    private var isInitializing = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unit = SpeedUnit(rawValue: defaults.string(forKey: "speed_unit") ?? "") ?? .kilometersPerHour
        let storedMaximum = defaults.double(forKey: "maximum_speed")
        maximumSpeed = storedMaximum > 0 ? storedMaximum : 60
        showDecimal = defaults.object(forKey: "show_decimal") as? Bool ?? false
        showGPSStrength = defaults.object(forKey: "show_gps_strength") as? Bool ?? true
        theme = SpeedTheme(rawValue: defaults.string(forKey: "speed_theme") ?? "") ?? .lime
        speedNumberStyle = SpeedNumberStyle(rawValue: defaults.string(forKey: "speed_number_style") ?? "") ?? .digital
        speedDashboardStyle = SpeedDashboardStyle(rawValue: defaults.string(forKey: "speed_dashboard_style") ?? "") ?? .number
        hudEnabled = defaults.object(forKey: "hud_enabled") as? Bool ?? false
        hudColorStyle = HUDColorStyle(rawValue: defaults.string(forKey: "hud_color_style") ?? "") ?? .green
        appearance = AppAppearance(rawValue: defaults.string(forKey: "app_appearance") ?? "") ?? .system
        lightSpeedNumberColor = Self.decodeColor(defaults.data(forKey: "light_speed_number_color")) ?? .black
        darkSpeedNumberColor = Self.decodeColor(defaults.data(forKey: "dark_speed_number_color")) ?? .digitalGreen
        lightSpeedOutlineEnabled = defaults.object(forKey: "light_speed_outline_enabled") as? Bool ?? false
        darkSpeedOutlineEnabled = defaults.object(forKey: "dark_speed_outline_enabled") as? Bool ?? false
        lightSpeedOutlineColor = Self.decodeColor(defaults.data(forKey: "light_speed_outline_color")) ?? .white
        darkSpeedOutlineColor = Self.decodeColor(defaults.data(forKey: "dark_speed_outline_color")) ?? .black
        syncWithICloud = defaults.object(forKey: "sync_icloud") as? Bool ?? true
        speedAlertEnabled = defaults.object(forKey: "speed_alert_enabled") as? Bool ?? false
        let storedAlertLimit = defaults.double(forKey: "speed_alert_limit_mps")
        speedAlertLimitMetersPerSecond = storedAlertLimit > 0 ? min(storedAlertLimit, 140) : 25 / 3.6
        mapProvider = MapProvider(rawValue: defaults.string(forKey: "map_provider") ?? "") ?? .openStreetMap
        distanceLabelSize = RouteDistanceLabelSize(rawValue: defaults.integer(forKey: "route_distance_label_size")) ?? .two
        mapLanguageID = defaults.string(forKey: "map_language").flatMap { stored in AppLanguage.all.first { $0.id == stored }?.id }
        fullscreenMapShowsClock = defaults.object(forKey: "fullscreen_map_shows_clock") as? Bool ?? false
        followLocationOnMap = defaults.object(forKey: "follow_location_on_map") as? Bool ?? true
        let storedOrder = defaults.stringArray(forKey: "bottom_navigation_order")
        // Move the old default (and a retired HUD launch destination) to Map.
        // A deliberately reordered set of surviving tabs remains the user's choice.
        let legacyDefault = storedOrder == ["speed", "map", "trips", "hud"] || storedOrder?.first == "hud"
        bottomNavigationOrder = legacyDefault ? BottomNavigationItem.defaultOrder : BottomNavigationItem.normalized(storedOrder)
        isInitializing = false
    }

    func reset() {
        unit = .kilometersPerHour
        maximumSpeed = 60
        showDecimal = false
        showGPSStrength = true
        theme = .lime
        speedNumberStyle = .digital
        speedDashboardStyle = .number
        hudEnabled = false
        hudColorStyle = .green
        appearance = .system
        lightSpeedNumberColor = .black
        darkSpeedNumberColor = .digitalGreen
        lightSpeedOutlineEnabled = false
        darkSpeedOutlineEnabled = false
        lightSpeedOutlineColor = .white
        darkSpeedOutlineColor = .black
        syncWithICloud = true
        speedAlertEnabled = false
        speedAlertLimitMetersPerSecond = 25 / 3.6
        mapProvider = .openStreetMap
        distanceLabelSize = .two
        mapLanguageID = nil
        fullscreenMapShowsClock = false
        followLocationOnMap = true
        bottomNavigationOrder = BottomNavigationItem.defaultOrder
    }

    func resetSpeedColors() {
        lightSpeedNumberColor = .black
        darkSpeedNumberColor = .digitalGreen
        lightSpeedOutlineEnabled = false
        darkSpeedOutlineEnabled = false
        lightSpeedOutlineColor = .white
        darkSpeedOutlineColor = .black
    }

    private func save() {
        guard !isInitializing else { return }
        defaults.set(unit.rawValue, forKey: "speed_unit")
        defaults.set(maximumSpeed, forKey: "maximum_speed")
        defaults.set(showDecimal, forKey: "show_decimal")
        defaults.set(showGPSStrength, forKey: "show_gps_strength")
        defaults.set(theme.rawValue, forKey: "speed_theme")
        defaults.set(speedNumberStyle.rawValue, forKey: "speed_number_style")
        defaults.set(speedDashboardStyle.rawValue, forKey: "speed_dashboard_style")
        defaults.set(hudEnabled, forKey: "hud_enabled")
        defaults.set(hudColorStyle.rawValue, forKey: "hud_color_style")
        if appearance == .system {
            defaults.removeObject(forKey: "app_appearance")
        } else {
            defaults.set(appearance.rawValue, forKey: "app_appearance")
        }
        defaults.set(Self.encodeColor(lightSpeedNumberColor), forKey: "light_speed_number_color")
        defaults.set(Self.encodeColor(darkSpeedNumberColor), forKey: "dark_speed_number_color")
        defaults.set(lightSpeedOutlineEnabled, forKey: "light_speed_outline_enabled")
        defaults.set(darkSpeedOutlineEnabled, forKey: "dark_speed_outline_enabled")
        defaults.set(Self.encodeColor(lightSpeedOutlineColor), forKey: "light_speed_outline_color")
        defaults.set(Self.encodeColor(darkSpeedOutlineColor), forKey: "dark_speed_outline_color")
        defaults.set(syncWithICloud, forKey: "sync_icloud")
        defaults.set(speedAlertEnabled, forKey: "speed_alert_enabled")
        defaults.set(speedAlertLimitMetersPerSecond, forKey: "speed_alert_limit_mps")
        defaults.set(mapProvider.rawValue, forKey: "map_provider")
        defaults.set(distanceLabelSize.rawValue, forKey: "route_distance_label_size")
        defaults.set(mapLanguageID, forKey: "map_language")
        defaults.set(fullscreenMapShowsClock, forKey: "fullscreen_map_shows_clock")
        defaults.set(followLocationOnMap, forKey: "follow_location_on_map")
        defaults.set(bottomNavigationOrder.map(\.rawValue), forKey: "bottom_navigation_order")
    }

    func moveBottomNavigation(fromOffsets: IndexSet, toOffset: Int) {
        bottomNavigationOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func speedNumberColor(for scheme: ColorScheme) -> Color {
        (scheme == .dark ? darkSpeedNumberColor : lightSpeedNumberColor).color
    }

    func speedNumberInactiveColor(for scheme: ColorScheme) -> Color {
        speedNumberColor(for: scheme).opacity(scheme == .dark ? 0.10 : 0.022)
    }

    func speedNumberOutlineColor(for scheme: ColorScheme) -> Color? {
        let enabled = scheme == .dark ? darkSpeedOutlineEnabled : lightSpeedOutlineEnabled
        guard enabled else { return nil }
        return (scheme == .dark ? darkSpeedOutlineColor : lightSpeedOutlineColor).color
    }

    private static func encodeColor(_ color: DisplayColor) -> Data? {
        try? JSONEncoder().encode(color)
    }

    private static func decodeColor(_ data: Data?) -> DisplayColor? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(DisplayColor.self, from: data)
    }
}
