import Combine
@preconcurrency import CoreLocation
import CoreMotion
import Foundation

enum LocationProviderKind: String, Equatable {
    case legacyManager
    case modernLiveUpdates
}

enum LocationProviderSelector {
    static func kind(forMajorVersion majorVersion: Int) -> LocationProviderKind {
        majorVersion >= 17 ? .modernLiveUpdates : .legacyManager
    }

    static var current: LocationProviderKind {
        kind(forMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

struct LegacyLocationTrackingConfiguration: Equatable {
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance
    let pausesAutomatically: Bool
    let allowsBackgroundUpdates: Bool
    let showsBackgroundIndicator: Bool
}

enum LocationTrackingPolicy {
    static func legacyConfiguration(isTripActive: Bool) -> LegacyLocationTrackingConfiguration {
        LegacyLocationTrackingConfiguration(
            desiredAccuracy: isTripActive ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest,
            distanceFilter: isTripActive ? kCLDistanceFilterNone : 10,
            pausesAutomatically: !isTripActive,
            allowsBackgroundUpdates: isTripActive,
            showsBackgroundIndicator: isTripActive
        )
    }

    static func needsModernBackgroundActivity(isTripActive: Bool) -> Bool {
        isTripActive
    }
}

@MainActor
private protocol LocationProvider: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var onLocation: ((CLLocation) -> Void)? { get set }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get set }

    func requestWhenInUseAuthorization()
    func start()
    func stop()
    func setTripTrackingActive(_ isActive: Bool)
}

@MainActor
final class LocationMotionService: ObservableObject {
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var activityKey = "activity_unknown"
    @Published private(set) var isMotionAuthorized = false
    @Published private(set) var isTripTrackingActive = false

    let providerKind: LocationProviderKind

    private let provider: LocationProvider
    private let motionManager = CMMotionActivityManager()
    private var requestedMotion = false
    private var cameraStandby = false
    private var shouldSuspendSensors: Bool { cameraStandby && !isTripTrackingActive }

    init() {
        let provider: LocationProvider
        if #available(iOS 17.0, *) {
            provider = ModernLocationProvider()
            providerKind = .modernLiveUpdates
        } else {
            provider = LegacyLocationProvider()
            providerKind = .legacyManager
        }
        self.provider = provider
        authorizationStatus = provider.authorizationStatus

        provider.onLocation = { [weak self] location in
            guard location.horizontalAccuracy >= 0 else { return }
            self?.latestLocation = location
        }
        provider.onAuthorizationChange = { [weak self] status in
            guard let self else { return }
            self.authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.startLocationUpdates()
                self.requestMotionAccessIfNeeded()
            } else if status != .notDetermined {
                self.requestMotionAccessIfNeeded()
            }
        }
    }

    var metersPerSecond: Double { max(0, latestLocation?.speed ?? 0) }
    var altitude: Double { latestLocation?.altitude ?? 0 }
    var coordinate: CLLocationCoordinate2D? { latestLocation?.coordinate }
    var horizontalAccuracy: Double { latestLocation?.horizontalAccuracy ?? -1 }

    func requestAccessInOrder() {
        switch authorizationStatus {
        case .notDetermined:
            provider.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationUpdates()
            requestMotionAccessIfNeeded()
        default:
            requestMotionAccessIfNeeded()
        }
    }

    func startLocationUpdates() {
#if DEBUG
        if ScreenshotState.requested != nil { return }
#endif
        guard !shouldSuspendSensors else { return }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        provider.start()
    }

    func stopLocationUpdates() {
        provider.stop()
    }

    func setTripTrackingActive(_ isActive: Bool) {
        isTripTrackingActive = isActive
        provider.setTripTrackingActive(isActive)
        synchronizeCameraStandby()
        if isActive { startLocationUpdates() }
    }

    func setCameraStandby(_ standby: Bool) {
        cameraStandby = standby
        synchronizeCameraStandby()
    }

    private func synchronizeCameraStandby() {
        if shouldSuspendSensors {
            provider.stop()
            motionManager.stopActivityUpdates()
        } else {
            startLocationUpdates()
            if requestedMotion && isMotionAuthorized { startMotionUpdates() }
        }
    }

    private func startMotionUpdates() {
        guard !shouldSuspendSensors else { return }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.activityKey = Self.key(for: activity)
        }
    }

    private func requestMotionAccessIfNeeded() {
#if DEBUG
        if ScreenshotState.requested != nil { return }
#endif
        guard !requestedMotion, CMMotionActivityManager.isActivityAvailable() else { return }
        requestedMotion = true
        let now = Date()
        motionManager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { [weak self] activities, _ in
            guard let self else { return }
            self.isMotionAuthorized = CMMotionActivityManager.authorizationStatus() == .authorized
            if let activity = activities?.last { self.activityKey = Self.key(for: activity) }
            self.startMotionUpdates()
        }
    }

    private static func key(for activity: CMMotionActivity) -> String {
        if activity.automotive { return "activity_automotive" }
        if activity.cycling { return "activity_cycling" }
        if activity.running { return "activity_running" }
        if activity.walking { return "activity_walking" }
        if activity.stationary { return "activity_stationary" }
        return "activity_unknown"
    }
}

@MainActor
private final class LegacyLocationProvider: NSObject, LocationProvider, @preconcurrency CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = true
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func start() { manager.startUpdatingLocation() }
    func stop() { manager.stopUpdatingLocation() }

    func setTripTrackingActive(_ isActive: Bool) {
        let configuration = LocationTrackingPolicy.legacyConfiguration(isTripActive: isActive)
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = configuration.desiredAccuracy
        manager.distanceFilter = configuration.distanceFilter
        manager.pausesLocationUpdatesAutomatically = configuration.pausesAutomatically
        manager.allowsBackgroundLocationUpdates = configuration.allowsBackgroundUpdates
        manager.showsBackgroundLocationIndicator = configuration.showsBackgroundIndicator
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Core Location may deliver several chronological fixes after a delay.
        // Preserve every sample, including stationary readings for video timing.
        for location in locations { onLocation?(location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { onAuthorizationChange?(.denied) }
    }
}

@available(iOS 17.0, *)
@MainActor
private final class ModernLocationProvider: NSObject, LocationProvider, @preconcurrency CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private let authorizationManager = CLLocationManager()
    private var updatesTask: Task<Void, Never>?
    private var backgroundActivity: CLBackgroundActivitySession?
    private var serviceSessionHolder: AnyObject?
    private var tripTrackingActive = false

    override init() {
        super.init()
        authorizationManager.delegate = self
    }

    deinit { updatesTask?.cancel() }

    var authorizationStatus: CLAuthorizationStatus { authorizationManager.authorizationStatus }

    func requestWhenInUseAuthorization() { authorizationManager.requestWhenInUseAuthorization() }

    func start() {
        guard updatesTask == nil else { return }
        if #available(iOS 18.0, *) {
            serviceSessionHolder = ModernServiceSessionHolder()
        }
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self, !Task.isCancelled else { return }
                    if #available(iOS 18.0, *), update.authorizationDenied {
                        self.onAuthorizationChange?(.denied)
                    }
                    if let location = update.location { self.onLocation?(location) }
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        backgroundActivity = nil
        serviceSessionHolder = nil
    }

    func setTripTrackingActive(_ isActive: Bool) {
        tripTrackingActive = isActive
        backgroundActivity = LocationTrackingPolicy.needsModernBackgroundActivity(isTripActive: isActive)
            ? CLBackgroundActivitySession()
            : nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { onAuthorizationChange?(.denied) }
    }
}

@available(iOS 18.0, *)
private final class ModernServiceSessionHolder {
    let session = CLServiceSession(authorization: .whenInUse)
}
