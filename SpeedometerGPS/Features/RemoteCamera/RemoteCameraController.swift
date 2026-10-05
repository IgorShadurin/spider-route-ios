import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class RemoteCameraController: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            if !enabled { connectionRequested = false }
            persist(); refreshLink()
        }
    }
    @Published var role: RemoteCameraRole {
        didSet {
            if role != oldValue {
                // A remote snapshot never becomes this phone's camera state.
                status = RemoteCameraStatus()
                lastStatusAt = nil
                connectionCancelled = false
                clearPending()
                soundGate.reset()
                sounds.stop()
            }
            persist()
            refreshLink()
        }
    }
    @Published var soundPreferences: RemoteCameraSoundPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(soundPreferences) { defaults.set(data, forKey: "remoteCamera.sounds") }
            sounds.stop()
        }
    }
    private let sounds = RemoteCameraSounds()
    private var soundGate = RemoteCameraSoundGate()
    @Published var accessoryDevice: RemoteCameraRole {
        didSet {
            defaults.set(accessoryDevice.rawValue, forKey: "remoteCamera.accessoryDevice")
            refreshInputAvailability()
            publishStatus()
        }
    }
    private var standbyGeneration = UUID()
    var cameraButtonsSupported: Bool {
        if #available(iOS 17.2, *) { return true }
        return false
    }
    var usesCameraButtons: Bool { accessoryDevice == .camera && cameraButtonsSupported && externalInput.preferences.enabled }
    var cameraButtonsEnabled: Bool {
        showsCamera && armed && foreground && blackScreen && usesCameraButtons && !preparing && externalInput.preferences.enabled && !externalInput.learning
            && status.hardwareShutterAction != nil
    }
    var readinessHelp: String {
        let target = showsRemote ? (status.accessoryDevice ?? .remote) : accessoryDevice
        return target == .remote ? "rc_eco_help" : (showsRemote || cameraButtonsSupported ? "rc_camera_buttons_help" : "rc_camera_buttons_unavailable")
    }
    @Published private(set) var buttonTestPreparing = false
    @Published private(set) var buttonTestReady = false
    @Published private(set) var buttonTestError: String?
    private var buttonTestGeneration = UUID()
    private var inputAvailable: Bool {
        remoteAccessoryAvailable || (showsCamera && accessoryDevice == .camera && (foreground || buttonTestPreparing))
    }
    private func refreshInputAvailability() {
        externalInput.setCameraMode(role == .camera)
        externalInput.available = inputAvailable
    }
    private var remoteAccessoryAvailable: Bool {
        showsRemote && foreground && (status.accessoryDevice ?? .remote) == .remote
    }
    @Published var settings: RemoteCameraSettings { didSet { persist(); publishStatus() } }
    @Published private(set) var status = RemoteCameraStatus()
    @Published private(set) var connected = false
    @Published private(set) var connectionProgress = RemoteCameraConnectionProgress.idle
    @Published private(set) var trusted = false
    @Published private(set) var pairingCode: String?
    @Published private(set) var linkError: String?
    @Published private(set) var armed = false
    @Published var blackScreen = false
    @Published private(set) var preparing = false
    @Published private(set) var commandPending = false
    @Published private(set) var videoReceipts: [CameraVideoReceipt] = []
    private var cameraVideoLedger: [CameraVideoReceipt] = []
    @Published private(set) var clips: [RemoteCameraClip] = []
    @Published private(set) var recoveryFailed = false
    private let defaults: UserDefaults
    let photos: RemoteCameraPhotos
    let externalInput: RemoteCameraExternalInput
    let availableLenses: [String]
    let lensZoomFactors: [String: Double]
    private let capture = RemoteCameraCapture()
    private lazy var link: RemoteCameraLink = makeLink()
    private var gate = RemoteCameraCommandGate()
    private var remoteCooldown = RemoteCameraCommandCooldown()
    private var foreground = UIApplication.shared.applicationState == .active
    private var timer: Timer?
    private var recordingBegan: TimeInterval?
    private var lastStatusAt: TimeInterval?
    private var pendingCommand: RemoteCameraCommand?
    private var pendingSince: TimeInterval?
    private var previousBrightness: CGFloat?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var fixture = false
    private var readyAfterRecovery = false
    private var connectionRequested = false
    private var connectionCancelled = false
#if DEBUG
    private var audioProbeStarted = false
    // Explicit hardware diagnostic only. Uses the real capture/event/sound path,
    // existing permissions/settings and local retention. Never runs in Release.
    private func runAudioProbeIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("--debug-camera-burst-probe") {
            guard !audioProbeStarted, readyAfterRecovery, foreground, showsCamera,
                  AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
            audioProbeStarted = true
            let before = Set(RemoteCameraCapture.clips().map { $0.url.lastPathComponent })
            armed = true
            blackScreen = true
            prepareReadiness()
            Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0..<100 {
                    if self.status.phase == .ready { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.status.phase == .ready else { return }
                @MainActor func burst() {
                    for _ in 0..<3 {
                        guard let action = self.status.hardwareShutterAction else { continue }
                        self.receive(RemoteCameraCommand(action: action, revision: self.status.revision,
                            recordingID: self.status.recordingID))
                    }
                }
                burst()
                for _ in 0..<200 {
                    if self.status.phase == .recording { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.status.phase == .recording else { return }
                let id = self.status.recordingID
                burst()
                let startProtected = self.status.phase == .recording && self.status.recordingID == id
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                burst()
                for _ in 0..<300 {
                    if self.status.phase == .ready { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.status.phase == .ready else { return }
                burst()
                let stopProtected = self.status.phase == .ready
                for _ in 0..<100 {
                    if let clip = RemoteCameraCapture.clips().first(where: { !before.contains($0.url.lastPathComponent) }),
                       self.photos.state(for: clip.url) == .saved { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let added = RemoteCameraCapture.clips().filter { !before.contains($0.url.lastPathComponent) }
                let result: [String: Any] = ["startBurstProtected": startProtected,
                    "stopBurstProtected": stopProtected, "newClipCount": added.count,
                    "photosSavedCount": added.filter { self.photos.state(for: $0.url) == .saved }.count,
                    "fileNames": added.map { $0.url.lastPathComponent },
                    "trigger": "synthetic command bursts through production gate; real capture and PhotoKit"]
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("camera-burst-probe.json")
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: url, options: .atomic)
                }
                self.disarm()
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--debug-camera-learning-probe") {
            guard !audioProbeStarted, readyAfterRecovery, foreground, showsCamera else { return }
            audioProbeStarted = true
            let before = RemoteCameraCapture.clips().count
            externalInput.beginLearning()
            Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0..<100 {
                    if self.buttonTestReady || self.buttonTestError != nil { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                self.handleCaptureButton("primary")
                let result: [String: Any] = ["runningVideoOnlyTest": self.buttonTestReady,
                    "candidate": self.externalInput.candidate?.diagnosticCode ?? "none",
                    "phase": self.status.phase.rawValue, "recordingIDAbsent": self.status.recordingID == nil,
                    "clipsBefore": before, "clipsAfter": RemoteCameraCapture.clips().count,
                    "error": self.buttonTestError ?? "none", "trigger": "synthetic native handler; not CF15 hardware"]
                self.previewSound(.start)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.previewSound(.stop)
                self.externalInput.cancelLearning()
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("camera-learning-probe.json")
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: url, options: .atomic)
                }
            }
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--debug-camera-shutter-probe") {
            guard !audioProbeStarted, readyAfterRecovery, foreground, showsCamera,
                  AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
            audioProbeStarted = true
            armed = true
            blackScreen = true
            prepareReadiness()
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Wait for the actual trusted peer after a diagnostic relaunch;
                // clips recorded during reconnect only prove receipt catch-up.
                for _ in 0..<150 {
                    if self.connected { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard self.connected else { return }
                for _ in 0..<2 {
                    for _ in 0..<100 {
                        if self.cameraButtonsEnabled && self.status.phase == .ready && self.controlLockSeconds == 0 { break }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    guard self.cameraButtonsEnabled, self.status.phase == .ready else { return }
                    self.handleHardwareShutter()
                    for _ in 0..<100 {
                        if self.status.phase == .recording { break }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    guard self.status.phase == .recording else { return }
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    self.handleHardwareShutter()
                }
            }
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("--debug-camera-audio-probe")
                || ProcessInfo.processInfo.arguments.contains("--debug-camera-hdr-probe")
                || ProcessInfo.processInfo.arguments.contains("--debug-camera-quality-probe"),
              !audioProbeStarted, readyAfterRecovery, foreground, enabled, role == .camera,
              !status.phase.isBusy, AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              !settings.audio || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        audioProbeStarted = true
        armed = true
        transition(.ready)
        blackScreen = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.foreground else { return }
            self.startCapture()
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            self.disarm()
        }
    }
#endif
    var showsCamera: Bool { enabled && role == .camera }
    var showsRemote: Bool { enabled && role == .remote }
    var configurationLocked: Bool { armed || preparing || status.phase.isBusy || externalInput.learning }
    var isFresh: Bool {
        connected && (fixture || lastStatusAt.map { ProcessInfo.processInfo.systemUptime - $0 < 7 } == true)
    }
    var canStart: Bool { showsRemote && isFresh && status.phase == .ready && !commandPending && controlLockSeconds == 0 }
    var canStop: Bool { showsRemote && isFresh && status.phase == .recording && !commandPending && controlLockSeconds == 0 }
    var controlLockSeconds: Int {
        Int(ceil(role == .camera ? gate.cooldown.remaining() : remoteCooldown.remaining()))
    }
    var controlLockText: String { String(format: "0:%02d", controlLockSeconds) }
    var visiblePhase: RemoteCameraPhase { showsRemote && !isFresh ? .unavailable : status.phase }
    var displayedElapsed: TimeInterval {
        guard status.phase == .recording else { return status.elapsed }
        if role == .camera, let recordingBegan { return max(0, ProcessInfo.processInfo.systemUptime - recordingBegan) }
        guard isFresh, let lastStatusAt else { return status.elapsed }
        return status.elapsed + max(0, ProcessInfo.processInfo.systemUptime - lastStatusAt)
    }

    init(defaults: UserDefaults = .standard) {
        var storage = defaults
#if DEBUG
        if ScreenshotState.requested != nil {
            storage = UserDefaults(suiteName: "remote-camera-ui-fixture")!
            storage.removePersistentDomain(forName: "remote-camera-ui-fixture")
            fixture = true
        }
#endif
        self.defaults = storage
        cameraVideoLedger = storage.data(forKey: "remoteCamera.videoLedger.v1")
            .flatMap { try? JSONDecoder().decode([CameraVideoReceipt].self, from: $0) }?.filter(\.isValid).suffix(8).map { $0 } ?? []
        photos = RemoteCameraPhotos(defaults: storage)
        soundPreferences = storage.data(forKey: "remoteCamera.sounds")
            .flatMap { try? JSONDecoder().decode(RemoteCameraSoundPreferences.self, from: $0) } ?? RemoteCameraSoundPreferences()
        externalInput = RemoteCameraExternalInput(defaults: storage, fixture: fixture)
        enabled = storage.bool(forKey: "remoteCamera.enabled")
        accessoryDevice = RemoteCameraRole(rawValue: storage.string(forKey: "remoteCamera.accessoryDevice") ?? "camera") ?? .camera
        role = RemoteCameraRole(rawValue: storage.string(forKey: "remoteCamera.role") ?? "camera") ?? .camera
        let isFixture = fixture
        availableLenses = ["ultra", "wide", "tele", "front"].filter { isFixture || RemoteCameraCapture.device(for: $0) != nil }
        lensZoomFactors = fixture ? ["ultra": 0.5, "wide": 1, "tele": 5] : RemoteCameraCapture.lensZoomFactors()
        let saved = storage.data(forKey: "remoteCamera.settings").flatMap { try? JSONDecoder().decode(RemoteCameraSettings.self, from: $0) }
        settings = RemoteCameraSettings.initial(saved: saved, availableLenses: availableLenses,
            migrateLegacyDefault: !storage.bool(forKey: "remoteCamera.defaultLensV2"))
        if let data = try? JSONEncoder().encode(settings) { storage.set(data, forKey: "remoteCamera.settings") }
        storage.set(true, forKey: "remoteCamera.defaultLensV2")
#if DEBUG
        // Explicit QA cleanup after testing the setting on a physical phone.
        if ProcessInfo.processInfo.arguments.contains("--debug-camera-hdr-off") {
            settings.hdr = false
            if let data = try? JSONEncoder().encode(settings) { storage.set(data, forKey: "remoteCamera.settings") }
        }
#endif
        photos.onChange = { [weak self] in self?.objectWillChange.send() }
        photos.sceneActive(!fixture && foreground)
        capture.onEvent = { [weak self] event in self?.captureEvent(event) }
        externalInput.onLearningChanged = { [weak self] learning in
            guard let self, self.showsCamera else { return }
            if learning { self.prepareButtonTest() } else { self.endButtonTest() }
        }
        externalInput.onAction = { [weak self] action in
            guard let self else { return }
            if self.showsCamera { self.handleCameraAction(action) }
            else if self.remoteAccessoryAvailable,
                    let command = action.command(phase: self.status.phase, fresh: self.isFresh, pending: self.commandPending) {
                self.send(command)
            }
        }
        if !fixture {
            capture.recoverPending { [weak self] recovered, failed in
                guard let self else { return }
                self.recoveryFailed = failed
                self.readyAfterRecovery = true
                self.reloadClips()
                for clip in recovered {
                    if let id = UUID(uuidString: clip.url.deletingPathExtension().lastPathComponent) {
                        self.updateVideoLedger(id: id, duration: clip.duration, state: .saved)
                    }
                    self.photos.enqueue(clip.url)
                }
                for index in self.cameraVideoLedger.indices where !self.cameraVideoLedger[index].isFinal {
                    self.cameraVideoLedger[index].state = .interrupted
                }
                self.persistVideoLedger()
                self.publishStatus()
#if DEBUG
                self.runAudioProbeIfRequested()
#endif
            }
            trusted = link.hasTrust
            refreshLink()
        } else { readyAfterRecovery = true }
    }
    private func makeLink() -> RemoteCameraLink {
        let link = RemoteCameraLink()
        link.onProgress = { [weak self] progress in
            self?.connectionProgress = progress
        }
        link.onConnection = { [weak self] value in
            guard let self else { return }
            self.connected = value
            self.lastStatusAt = nil
            // A lost START reply is never guessed or replayed after reconnect.
            self.pendingCommand = nil
            self.commandPending = false
            self.pendingSince = nil
            if value { self.linkError = nil; self.publishStatus() }
        }
        link.onStatus = { [weak self] value in
            guard let self else { return }
            self.confirmedSounds(value, baseline: !self.isFresh)
#if DEBUG
            self.logShutterProbe(value)
#endif
            self.remoteCooldown.extend(by: value.controlLockRemaining ?? 0)
            self.status = value
            self.refreshInputAvailability()
            self.videoReceipts = Array((value.videoReceipts ?? []).filter(\.isValid).suffix(8))
            self.lastStatusAt = ProcessInfo.processInfo.systemUptime
            if let pending = self.pendingCommand {
                let acknowledged = pending.action == .start
                    ? value.revision != pending.revision || value.phase != .ready
                    : value.recordingID != pending.recordingID || (value.phase != .recording && value.phase != .starting)
                if acknowledged { self.clearPending() }
            }
        }
        link.onCommand = { [weak self] command in self?.receive(command) }
        link.onStatusRequest = { [weak self] in self?.publishStatus() }
        link.onPairing = { [weak self] code in self?.pairingCode = code }
        link.onError = { [weak self] key in
            guard let self else { return }
            self.linkError = key
            self.cancelConnection()
        }
        link.onTrustChanged = { [weak self] value in
            self?.trusted = value
            if value { self?.connectionRequested = false }
        }
        return link
    }
    private func persist() {
        defaults.set(enabled, forKey: "remoteCamera.enabled")
        defaults.set(role.rawValue, forKey: "remoteCamera.role")
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "remoteCamera.settings") }
    }
    private func refreshLink() {
        refreshInputAvailability()
        if !enabled || role != .camera { cancelStandby() }
        if !enabled || !foreground { sounds.stop(); soundGate.reset() }
        guard !fixture else { return }
        if enabled && foreground {
            UIDevice.current.isBatteryMonitoringEnabled = true
            if (trusted && !connectionCancelled) || connectionRequested { link.start(role: role, allowPairing: !trusted && connectionRequested) }
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            }
        } else {
            link.stop()
            timer?.invalidate(); timer = nil
            UIDevice.current.isBatteryMonitoringEnabled = false
        }
    }
    func connect() {
        guard enabled, foreground, !connected, !connectionProgress.isBusy else { return }
        linkError = nil
        connectionCancelled = false
        connectionRequested = true
        connectionProgress = .discovering
        if !fixture { link.start(role: role, allowPairing: !trusted) }
    }
    func cancelConnection() {
        guard !connected else { return }
        connectionRequested = false
        connectionCancelled = true
        if !fixture { link.stop() }
        pairingCode = nil
        connectionProgress = .idle
    }
    func approvePairing() {
        if !fixture { link.approve() }
        else { connectionProgress = .awaitingApproval }
    }
    func rejectPairing() { cancelConnection() }
    func forgetPair() {
        guard !configurationLocked else { return }
        connectionRequested = false
        if !fixture { link.forget() }
        trusted = false
        connected = false
    }
    func arm() {
        guard enabled, role == .camera, connected, !configurationLocked, readyAfterRecovery else { return }
        guard !fixture else { armed = true; blackScreen = true; transition(.ready); return }
        preparing = true
        Task { @MainActor in
            let cameraAllowed = await Self.permission(.video)
            let audioAllowed: Bool
            if settings.audio { audioAllowed = await Self.permission(.audio) } else { audioAllowed = true }
            defer { if !armed { preparing = false } }
            guard enabled, role == .camera else { return }
            guard cameraAllowed else { fail("rc_error_permission_camera"); return }
            guard audioAllowed else { fail("rc_error_permission_microphone"); return }
            if let error = RemoteCameraCapture.validationError(settings) { fail(error); return }
            for _ in 0..<100 {
                if foreground { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard foreground else { fail("rc_error_background"); return }
            await photos.preparePermission()
            // Permission sheets may temporarily deactivate the scene and close
            // Multipeer sessions. Finish this same user action after reconnect.
            for _ in 0..<100 {
                if foreground && connected { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard foreground, connected else { fail("rc_error_network"); return }
            armed = true
            blackScreen = true
            prepareReadiness()
        }
    }
    private static func permission(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
    private func cancelStandby() {
        standbyGeneration = UUID()
        preparing = false
        capture.shutdownStandby()
    }
    private func prepareReadiness() {
        guard armed, foreground, showsCamera, !status.phase.isBusy else { return }
        cancelStandby()
        guard usesCameraButtons, !fixture else { transition(.ready); return }
        let generation = standbyGeneration
        preparing = true
        transition(.unavailable)
        capture.prepareStandby(settings: settings) { [weak self] error in
            guard let self, self.standbyGeneration == generation,
                  self.armed, self.foreground, self.showsCamera else { return }
            self.preparing = false
            if let error { self.fail(error) } else { self.transition(.ready) }
        }
    }
    func handleHardwareShutter() { handleCaptureButton("primary") }
    func handleCaptureButton(_ code: String) {
        guard cameraButtonsEnabled || (buttonTestReady && externalInput.learning && foreground) else { return }
        externalInput.receiveCapture(code, mayRecord: cameraButtonsEnabled)
    }
    private func handleCameraAction(_ action: CameraButtonAction) {
        guard cameraButtonsEnabled,
              let command = action.command(phase: status.phase, fresh: true, pending: false) else { return }
        receive(RemoteCameraCommand(action: command, revision: status.revision, recordingID: status.recordingID))
    }
    private func prepareButtonTest() {
        guard showsCamera, !armed, !status.phase.isBusy else { return }
        endButtonTest()
        externalInput.pauseLearningTimeout()
        buttonTestPreparing = true
        if fixture { buttonTestPreparing = false; buttonTestReady = true; externalInput.listenAgain(); return }
        let generation = buttonTestGeneration
        Task { @MainActor in
            let allowed = await Self.permission(.video)
            for _ in 0..<100 {
                if foreground { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard buttonTestGeneration == generation else { return }
            guard externalInput.learning, foreground, showsCamera else {
                endButtonTest()
                externalInput.cancelLearning()
                return
            }
            guard allowed else { buttonTestPreparing = false; buttonTestError = "rc_error_permission_camera"; return }
            guard cameraButtonsSupported else { buttonTestPreparing = false; buttonTestError = "rc_camera_buttons_unavailable"; return }
            capture.prepareStandby(settings: settings) { [weak self] error in
                guard let self, self.buttonTestGeneration == generation, self.externalInput.learning else { return }
                self.buttonTestPreparing = false
                self.buttonTestError = error
                self.buttonTestReady = error == nil
                if error == nil { self.externalInput.listenAgain() }
            }
        }
    }
    func listenForButtonAgain() {
        if showsCamera, externalInput.learning, buttonTestError != nil, !buttonTestPreparing {
            prepareButtonTest()
        } else if !buttonTestPreparing {
            externalInput.listenAgain()
        }
    }
    private func endButtonTest() {
        buttonTestGeneration = UUID()
        buttonTestPreparing = false
        buttonTestReady = false
        buttonTestError = nil
        if !armed { capture.shutdownStandby() }
    }
    func disarm() {
        cancelStandby()
        armed = false
        blackScreen = false
        restoreBrightness()
        if status.phase.isBusy { stopCapture(reason: nil) }
        else { transition(.unavailable) }
    }
    func previewSound(_ cue: RemoteCameraSoundCue) {
        guard enabled, foreground, !fixture else { return }
        sounds.stop()
        // Explicit audition does not change the automatic confirmation switches.
        sounds.play(cue, volume: soundPreferences.volume(for: cue))
    }
    var supportsHDR: Bool {
#if DEBUG
        if fixture { return !ProcessInfo.processInfo.arguments.contains("--ui-camera-hdr-unavailable") }
#endif
        return RemoteCameraCapture.supportsHDR(settings)
    }
    func setHDR(_ enabled: Bool) {
        guard !configurationLocked, !enabled || supportsHDR else { return }
        var value = settings
        value.hdr = enabled
        if enabled { value.codec = "hevc" }
        settings = value
    }
    func retryCamera() {
        guard armed, foreground, !status.phase.isBusy else { return }
        prepareReadiness()
    }
    func dimScreen() {
        guard foreground, !fixture else { return }
        if previousBrightness == nil { previousBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0
    }
    func restoreBrightness() {
        if let previousBrightness { UIScreen.main.brightness = previousBrightness }
        previousBrightness = nil
    }
    func sceneChanged(_ phase: ScenePhase) {
        foreground = phase == .active
        if !fixture { photos.sceneActive(foreground) }
        if !foreground {
            cancelStandby()
            if role == .camera, !status.phase.isBusy { transition(.unavailable) }
            restoreBrightness()
            if role == .camera, status.phase.isBusy {
                if backgroundTask == .invalid {
                    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish camera file") { [weak self] in
                        Task { @MainActor in self?.endBackgroundTask() }
                    }
                }
                stopCapture(reason: "rc_error_background")
            }
            publishStatus()
        } else {
            if blackScreen { dimScreen() }
            if armed && status.phase == .unavailable { prepareReadiness() }
        }
        refreshLink()
#if DEBUG
        runAudioProbeIfRequested()
#endif
    }
    func send(_ action: RemoteCameraCommand.Action) {
        guard action == .start ? canStart : canStop else { return }
        let command = RemoteCameraCommand(action: action, revision: status.revision, recordingID: status.recordingID)
        pendingCommand = command
        pendingSince = ProcessInfo.processInfo.systemUptime
        commandPending = true
        remoteCooldown.begin()
        if !fixture { link.sendCommand(command) }
    }
    private func receive(_ command: RemoteCameraCommand) {
        guard enabled, role == .camera, armed, foreground else { publishStatus(); return }
        guard gate.accept(command, status: status) else { publishStatus(); return }
        switch command.action {
        case .start: startCapture()
        case .stop: stopCapture(reason: nil)
        }
    }
    private func startCapture() {
        if ProcessInfo.processInfo.thermalState == .critical { fail("rc_error_thermal"); return }
        if UIDevice.current.batteryLevel >= 0 && UIDevice.current.batteryLevel <= 0.05 { fail("rc_error_battery"); return }
        if RemoteCameraCapture.freeBytes() < 500_000_000 { fail("rc_error_storage"); return }
        let id = UUID()
        status.recordingID = id
        status.elapsed = 0
        recordingBegan = nil
        transition(.starting)
        capture.start(id: id, settings: captureSettings)
    }
    private var captureSettings: RemoteCameraSettings {
        var value = settings
#if DEBUG
        // Override only the capture request: a hardware probe must never write
        // its HDR choice through the observed/persisted settings property.
        if ProcessInfo.processInfo.arguments.contains("--debug-camera-hdr-probe") {
            value.hdr = true
            value.codec = "hevc"
        }
#endif
        return value
    }
    private func stopCapture(reason: String?) {
        guard status.phase.isBusy else { return }
        if let recordingBegan { status.elapsed = ProcessInfo.processInfo.systemUptime - recordingBegan }
        transition(.saving)
        capture.stop(reason: reason)
    }
    private func captureEvent(_ event: RemoteCameraCapture.Event) {
        switch event {
        case .standbyFailed(let key):
            if externalInput.learning { externalInput.pauseLearningTimeout(); endButtonTest(); buttonTestError = key }
            if armed, !status.phase.isBusy { cancelStandby(); fail(key) }
        case .started(let id, let startedAt):
            guard id == status.recordingID else { return }
            gate.confirmedTransition()
            recordingBegan = ProcessInfo.processInfo.systemUptime
            cameraVideoLedger.removeAll { $0.id == id }
            cameraVideoLedger.append(CameraVideoReceipt(id: id, fileName: id.uuidString + ".mov", startedAt: startedAt,
                duration: 0, reportedAt: Date(), state: .recording))
            cameraVideoLedger = Array(cameraVideoLedger.suffix(8))
            persistVideoLedger()
            if !armed || !foreground || status.phase == .saving { stopCapture(reason: foreground ? nil : "rc_error_background") }
            else { transition(.recording) }
        case .saving(let id):
            guard id == status.recordingID else { return }
            if let recordingBegan { status.elapsed = ProcessInfo.processInfo.systemUptime - recordingBegan }
            updateVideoLedger(id: id, duration: status.elapsed, state: .saving)
            recordingBegan = nil
            transition(.saving)
        case .saved(let id, let url, let duration, let warning):
            guard id == status.recordingID else { return }
            gate.confirmedTransition()
            updateVideoLedger(id: id, duration: duration, state: .saved)
            photos.enqueue(url)
            status.lastSavedRecordingID = id
            reloadClips()
            recordingBegan = nil
            status.recordingID = nil
            status.elapsed = 0
            if let warning, warning != "rc_error_background" { fail(warning) }
            else { transition(.unavailable); prepareReadiness() }
            endBackgroundTask()
        case .failed(let id, let key):
            guard status.recordingID == nil || status.recordingID == id else { return }
            updateVideoLedger(id: id, duration: displayedElapsed, state: .interrupted)
            recordingBegan = nil
            fail(key)
            reloadClips()
            endBackgroundTask()
        }
    }
    private func updateVideoLedger(id: UUID, duration: TimeInterval, state: CameraVideoReceipt.State) {
        guard duration.isFinite, let index = cameraVideoLedger.firstIndex(where: { $0.id == id }) else { return }
        cameraVideoLedger[index].duration = max(0, duration)
        cameraVideoLedger[index].state = state
        cameraVideoLedger[index].reportedAt = Date()
        persistVideoLedger()
    }
    private func persistVideoLedger() {
        if let data = try? JSONEncoder().encode(cameraVideoLedger) {
            defaults.set(data, forKey: "remoteCamera.videoLedger.v1")
        }
    }

    private func transition(_ phase: RemoteCameraPhase) {
        status.phase = phase
        status.revision = UUID()
        status.errorKey = nil
        publishStatus()
    }
    private func fail(_ key: String) {
        cancelStandby()
        status.phase = .error
        status.revision = UUID()
        status.errorKey = key
        publishStatus()
    }
    private func confirmedSounds(_ snapshot: RemoteCameraStatus, baseline: Bool = false) {
        let cues = soundGate.observe(snapshot, baseline: baseline)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-camera-audio-probe"), !cues.isEmpty {
            NSLog("CAMERA_AUDIO_PROBE phase=%@ cues=%@ enabled=%d foreground=%d fixture=%d start=%d stop=%d", snapshot.phase.rawValue, String(describing: cues), enabled, foreground, fixture, soundPreferences.start, soundPreferences.stop)
        }
#endif
        guard enabled, foreground, !fixture else { return }
        for cue in cues where soundPreferences.allows(cue) { sounds.play(cue, volume: soundPreferences.volume(for: cue)) }
    }
    private func publishStatus() {
        guard role == .camera else { return }
        if status.settings != captureSettings { status.settings = captureSettings }
        status.controlLockRemaining = gate.cooldown.remaining()
        status.accessoryDevice = accessoryDevice
        status.lensZoom = lensZoomFactors[settings.lens]
        confirmedSounds(status)
        let now = Date()
        var receipts = cameraVideoLedger
        if let index = receipts.firstIndex(where: { $0.id == status.recordingID }), status.phase == .recording {
            receipts[index].duration = displayedElapsed
        }
        for index in receipts.indices { receipts[index].reportedAt = now }
        videoReceipts = receipts
        status.videoReceipts = receipts
        guard !fixture else { return }
        var snapshot = status
        snapshot.elapsed = displayedElapsed
        snapshot.battery = UIDevice.current.batteryLevel < 0 ? -1 : Int(UIDevice.current.batteryLevel * 100)
        snapshot.freeBytes = RemoteCameraCapture.freeBytes()
        snapshot.thermalWarning = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        if !foreground || (!armed && snapshot.phase == .ready) { snapshot.phase = .unavailable }
#if DEBUG
        logShutterProbe(snapshot)
#endif
        link.sendStatus(snapshot)
    }
    private func tick() {
        if role == .camera {
            if status.phase == .recording {
                if ProcessInfo.processInfo.thermalState == .critical { stopCapture(reason: "rc_error_thermal") }
                else if UIDevice.current.batteryLevel >= 0 && UIDevice.current.batteryLevel <= 0.05 { stopCapture(reason: "rc_error_battery") }
                else if RemoteCameraCapture.freeBytes() < 300_000_000 { stopCapture(reason: "rc_error_storage") }
            }
            if armed, usesCameraButtons, status.phase == .ready {
                if ProcessInfo.processInfo.thermalState == .critical { fail("rc_error_thermal") }
                else if UIDevice.current.batteryLevel >= 0 && UIDevice.current.batteryLevel <= 0.05 { fail("rc_error_battery") }
            }
            publishStatus()
        } else {
            objectWillChange.send()
            if let since = pendingSince, ProcessInfo.processInfo.systemUptime - since > 8 {
                clearPending()
                linkError = "rc_error_command_timeout"
                // Invalidate stale READY and wait for a fresh authoritative snapshot.
                lastStatusAt = nil
                link.requestStatus()
            } else if let pendingCommand { link.sendCommand(pendingCommand) }
            if !isFresh { link.requestStatus() }
        }
    }
    private func clearPending() { pendingCommand = nil; pendingSince = nil; commandPending = false }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func reloadClips() { if !fixture { clips = RemoteCameraCapture.clips() } }
    func saveToPhotos(_ clip: RemoteCameraClip) {
        guard !fixture else { return }
        Task { await photos.saveManually(clip.url) }
    }

#if DEBUG
    private func logShutterProbe(_ snapshot: RemoteCameraStatus) {
        guard ProcessInfo.processInfo.arguments.contains("--debug-camera-shutter-probe"),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("camera-shutter-probe.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10])) } catch { }
    }
    func applyFixture(_ state: ScreenshotState?) {
        guard fixture, let state, state.rawValue.contains("camera") else { return }
        if state == .cameraPhotos {
            clips = [RemoteCameraPhotos.State.saved, .saving, .denied, .failed, .local].enumerated().map { index, value in
                let url = URL(fileURLWithPath: "/fixture/clip-\(index).mov")
                photos.fixture(url, state: value)
                return RemoteCameraClip(url: url, date: Date(timeIntervalSince1970: 1_789_300_000 - Double(index) * 300))
            }
        }
        enabled = true
        if ProcessInfo.processInfo.arguments.contains("--ui-camera-hdr-on") { settings.hdr = true }
        role = state.rawValue.hasPrefix("map.") || state == .settingsCameraButtons || state == .cameraButtonLearning ? .remote : .camera
        if ProcessInfo.processInfo.arguments.contains("--ui-camera-buttons") { role = .camera }
        if ProcessInfo.processInfo.arguments.contains("--ui-camera-role=remote") { role = .remote }
        let pending = [ScreenshotState.cameraSearching, .cameraConnecting, .cameraPairing, .cameraPairingWaiting, .mapCameraSearching].contains(state)
        connected = state != .cameraSetup && state != .mapCameraOffline && !pending
        trusted = connected
        connectionProgress = connected ? .connected : .idle
        if state == .cameraSearching || state == .mapCameraSearching { connectionProgress = .discovering }
        if state == .cameraConnecting { connectionProgress = .connecting }
        if state == .cameraPairing { connectionProgress = .verifying }
        if state == .cameraPairingWaiting { connectionProgress = .awaitingApproval }
        lastStatusAt = ProcessInfo.processInfo.systemUptime
        status = RemoteCameraStatus(phase: role == .camera ? .unavailable : .ready)
        refreshInputAvailability()
        status.battery = 82
        status.freeBytes = 64_000_000_000
        if state == .mapCameraRecording || state == .mapCameraFullscreenRecording || state == .mapCameraInfo { status.phase = .recording; status.elapsed = 38; status.recordingID = UUID() }
        if ProcessInfo.processInfo.arguments.contains("--ui-camera-cooldown") { remoteCooldown.begin() }
        if state == .mapCameraStarting { status.phase = .starting; status.recordingID = UUID() }
        if state == .mapCameraSaving { status.phase = .saving; status.recordingID = UUID() }
        if state == .mapCameraError { status.phase = .error; status.errorKey = "rc_error_storage" }
        if state == .cameraPairing || state == .cameraPairingWaiting { pairingCode = "AB27 18F3 90CD 45E6" }
        if state == .cameraBlack || state == .cameraExit { armed = true; status.phase = .ready; blackScreen = true }
    }
#endif
}
