import GameController
import OSLog
import SwiftUI

// A local toggle resolves to a separate START or STOP; it never goes over the wire.
enum CameraButtonAction: String, Codable, CaseIterable, Identifiable {
    case start, stop, toggle
    var id: String { rawValue }
    var title: String { L10n.tr(self == .toggle ? "rc_external_toggle" : self == .start ? "rc_start" : "rc_stop") }
    func command(phase: RemoteCameraPhase, fresh: Bool, pending: Bool) -> RemoteCameraCommand.Action? {
        guard fresh, !pending else { return nil }
        switch (self, phase) {
        case (.start, .ready), (.toggle, .ready): return .start
        case (.stop, .recording), (.toggle, .recording): return .stop
        default: return nil
        }
    }
}

struct CameraExternalButton: Codable, Equatable, Identifiable {
    let family: String
    let code: String
    let name: String
    var id: String { family + ":" + code }
    static func capture(_ code: String) -> CameraExternalButton {
        CameraExternalButton(family: "capture", code: code,
            name: L10n.format("rc_external_key", code == "primary" ? 1 : 2))
    }
    var displayName: String { family == "capture" ? Self.capture(code).name : name }
    // UIKit/GameController keyboard codes are usages on the Keyboard page,
    // not Consumer Control usages or raw Bluetooth report bytes.
    var hexCode: String? {
        guard family == "keyboard", let usage = UInt16(code) else { return nil }
        return String(format: "0x%04X", Int(usage))
    }
    var diagnosticCode: String {
        if let hexCode { return "HID 0x0007 · HEX " + hexCode }
        return "ID: " + (family == "capture" ? "AVCaptureEvent." : "") + code // Controller profiles expose symbolic names, not HID bytes.
    }
}

struct CameraButtonBinding: Codable, Identifiable {
    let button: CameraExternalButton
    var action: CameraButtonAction
    var id: String { button.id }
}

struct CameraButtonPreferences: Codable {
    var enabled = false
    var bindings: [CameraButtonBinding] = []
    static var cameraDefaults: Self {
        Self(enabled: true, bindings: ["primary", "secondary"].map {
            CameraButtonBinding(button: .capture($0), action: .toggle)
        })
    }
    mutating func assign(_ button: CameraExternalButton, to action: CameraButtonAction, replacing id: String? = nil) {
        bindings.removeAll { $0.id == button.id || $0.id == id }
        bindings.append(CameraButtonBinding(button: button, action: action))
    }
}

struct CameraButtonPressGate {
    private var held: Set<String> = []
    mutating func change(_ id: String, pressed: Bool) -> Bool {
        if pressed { return held.insert(id).inserted }
        held.remove(id)
        return false
    }
    mutating func reset() { held.removeAll() }
}

@MainActor
final class RemoteCameraExternalInput: ObservableObject {
    @Published private(set) var preferences: CameraButtonPreferences
    @Published private(set) var devices: [String] = []
    @Published var learning = false { didSet { if learning != oldValue { onLearningChanged?(learning) } } }
    @Published private(set) var candidate: CameraExternalButton?
    @Published var selectedAction = CameraButtonAction.toggle
    @Published private(set) var timedOut = false
    @Published private(set) var learningSecondsRemaining = 15
    private(set) var learningDeadline: TimeInterval?
    private var timeoutGeneration = UUID()
    var onLearningChanged: ((Bool) -> Void)?
    private(set) var cameraMode = false
    private var preferencesKey: String { cameraMode ? "remoteCamera.cameraButtons" : "remoteCamera.externalButtons" }
    func setCameraMode(_ value: Bool) {
        guard value != cameraMode else { return }
        cancelLearning()
        cameraMode = value
        preferences = defaults.data(forKey: preferencesKey)
            .flatMap { try? JSONDecoder().decode(CameraButtonPreferences.self, from: $0) }
            ?? (value ? .cameraDefaults : CameraButtonPreferences())
        refresh()
    }
    var onAction: ((CameraButtonAction) -> Void)?
    var available = false { didSet { if available != oldValue { cancelLearning(); refresh() } } }
    private let logger = Logger(subsystem: "com.wowcoded.speedometergps", category: "ExternalButtons")
    private let defaults: UserDefaults
    private let fixture: Bool
    private var observers: [NSObjectProtocol] = []
    private var controllers: [GCController] = []
    private var keyboard: GCKeyboard?
    private var gate = CameraButtonPressGate()
    private var timeoutTask: Task<Void, Never>?
    private var editingID: String?
    private var surfaces: [UUID: WeakInputSurface] = [:]
    private var generation = UUID()
    private var suppressUntil: TimeInterval = 0

    init(defaults: UserDefaults, fixture: Bool) {
        self.defaults = defaults
        self.fixture = fixture
        preferences = defaults.data(forKey: "remoteCamera.externalButtons")
            .flatMap { try? JSONDecoder().decode(CameraButtonPreferences.self, from: $0) } ?? CameraButtonPreferences()
    }
    func setEnabled(_ value: Bool) {
        preferences.enabled = value
        persist()
        cancelLearning()
        refresh()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: preferencesKey) }
    }
    func remove(_ id: String) { preferences.bindings.removeAll { $0.id == id }; persist() }
    func beginLearning(_ binding: CameraButtonBinding? = nil) {
        guard preferences.enabled && available else { return }
        editingID = binding?.id
        candidate = nil
        selectedAction = binding?.action ?? .toggle
        timedOut = false
        startTimeout()
        learning = true
        focusInputSurface()
    }
    func listenAgain() {
        guard learning else { return }
        candidate = nil
        timedOut = false
        startTimeout()
    }
    func pauseLearningTimeout() {
        timeoutGeneration = UUID()
        timeoutTask?.cancel(); timeoutTask = nil
        learningDeadline = nil
    }
    func updateLearningCountdown(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let learningDeadline, candidate == nil else { return }
        let remaining = max(0, Int(ceil(learningDeadline - now)))
        if learningSecondsRemaining != remaining { learningSecondsRemaining = remaining }
        if remaining == 0 { timedOut = true; pauseLearningTimeout() }
    }
    private var acceptsLearningEvent: Bool {
        updateLearningCountdown()
        return learningDeadline != nil && !timedOut && candidate == nil
    }
    private func startTimeout() {
        pauseLearningTimeout()
        guard candidate == nil else { return }
        learningSecondsRemaining = 15
        learningDeadline = ProcessInfo.processInfo.systemUptime + 15
        let generation = timeoutGeneration
        timeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self, self.timeoutGeneration == generation, self.learning, self.candidate == nil else { return }
                self.updateLearningCountdown()
            }
        }
    }
    func cancelLearning() {
        // A key used to close the sheet may also have a queued hardware callback.
        if learning { suppressUntil = ProcessInfo.processInfo.systemUptime + 0.5 }
        pauseLearningTimeout()
        learning = false; candidate = nil; editingID = nil; timedOut = false
        focusInputSurface()
    }
    func saveLearning() {
        guard preferences.enabled, available, learning, let candidate else { return }
        preferences.assign(candidate, to: selectedAction, replacing: editingID)
        persist()
        cancelLearning()
    }
    // Used by hardware adapters and tests. A held/repeating key causes one action.
    func receive(_ button: CameraExternalButton, source: String, pressed: Bool) {
        guard preferences.enabled && available else { return }
        // Native capture events own volume-button cycles on modern Camera phones.
        // Avoid a keyboard-down action followed by a second native-ended action.
        if #available(iOS 17.2, *), cameraMode, button.family == "keyboard",
           ["128", "129"].contains(button.code) { return }
        guard gate.change(source + ":" + button.id, pressed: pressed) else { return }
        if learning {
            if !fixture { logger.notice("Learning input: \(button.family, privacy: .public) \(button.diagnosticCode, privacy: .public)") }
            guard acceptsLearningEvent else { return }
            candidate = button; timedOut = false; pauseLearningTimeout()
            return
        }
        guard ProcessInfo.processInfo.systemUptime >= suppressUntil,
              surfaces.values.contains(where: { $0.view?.isEligible == true && $0.view?.isLearningSurface == false }),
              let binding = preferences.bindings.first(where: { $0.id == button.id }) else { return }
        onAction?(binding.action)
    }
    // Capture events expose primary/secondary categories, never Bluetooth HID bytes.
    func receiveCapture(_ code: String, mayRecord: Bool) {
        guard cameraMode, preferences.enabled, available, ["primary", "secondary"].contains(code) else { return }
        let button = CameraExternalButton.capture(code)
        if learning {
            guard acceptsLearningEvent else { return }
            candidate = button
            timedOut = false
            pauseLearningTimeout()
            return
        }
        guard mayRecord, ProcessInfo.processInfo.systemUptime >= suppressUntil,
              let binding = preferences.bindings.first(where: { $0.id == button.id }) else { return }
        onAction?(binding.action)
    }
    var acceptsUIKitInput: Bool { preferences.enabled && available && keyboard?.keyboardInput == nil }
    func receiveUIKit(code: Int, pressed: Bool) {
        // Prefer GameController when present so two adapters cannot dispatch the
        // same physical press twice. UIKit is a fallback for key-only remotes.
        guard acceptsUIKitInput, (0...Int(UInt16.max)).contains(code) else { return }
        let keyboardName = L10n.tr("rc_external_keyboard")
        if pressed && !devices.contains(keyboardName) { devices.append(keyboardName) }
        receive(CameraExternalButton(family: "keyboard", code: String(code), name: Self.keyName(code)),
                source: "keyboard", pressed: pressed)
    }
    func focusInputSurface() {
        let views = surfaces.values.compactMap(\.view)
        let target = acceptsUIKitInput ? views.first(where: { $0.isEligible && $0.isLearningSurface == learning }) : nil
        for view in views where view !== target && view.isFirstResponder { view.resignFirstResponder() }
        if let target, !target.isFirstResponder { target.becomeFirstResponder() }
    }
    func register(_ view: ExternalButtonSurfaceView, id: UUID) {
        surfaces[id] = WeakInputSurface(view)
        view.input = self
        focusInputSurface()
    }
    func unregister(_ id: UUID) { surfaces.removeValue(forKey: id) }

    private func detach() {
        generation = UUID()
        surfaces.values.compactMap(\.view).filter(\.isFirstResponder).forEach { $0.resignFirstResponder() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        keyboard?.keyboardInput?.keyChangedHandler = nil
        controllers.forEach { controller in
            controller.physicalInputProfile.allButtons.forEach { $0.pressedChangedHandler = nil }
        }
        keyboard = nil; controllers = []; devices = []; gate.reset()
    }
    private func refresh() {
        defer { focusInputSurface() }
        detach()
        guard preferences.enabled, available, !fixture else { return }
        for notification in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect,
                             .GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        let currentGeneration = generation
        keyboard = GCKeyboard.coalesced
        if let keyboard, let input = keyboard.keyboardInput {
            keyboard.handlerQueue = .main
            devices.append(L10n.tr("rc_external_keyboard"))
            // Prime held keys so connecting/enabling cannot turn an existing hold into a press.
            for code in 4...231 where input.button(forKeyCode: GCKeyCode(rawValue: code))?.isPressed == true {
                _ = gate.change("keyboard:keyboard:\(code)", pressed: true)
            }
            input.keyChangedHandler = { [weak self] _, _, code, pressed in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    let name = Self.keyName(code.rawValue)
                    self.receive(CameraExternalButton(family: "keyboard", code: String(code.rawValue), name: name), source: "keyboard", pressed: pressed)
                }
            }
        }
        controllers = GCController.controllers()
        for controller in controllers {
            controller.handlerQueue = .main
            let name = controller.vendorName ?? controller.productCategory
            let family = "controller:" + controller.productCategory + ":" + name
            let source = String(describing: ObjectIdentifier(controller))
            devices.append(name)
            var seen: Set<ObjectIdentifier> = []
            for (code, button) in controller.physicalInputProfile.buttons.sorted(by: { $0.key < $1.key }) {
                guard seen.insert(ObjectIdentifier(button)).inserted else { continue }
                let descriptor = CameraExternalButton(family: family, code: code, name: name + " · " + (button.localizedName ?? code))
                _ = gate.change(source + ":" + descriptor.id, pressed: button.isPressed)
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in
                        guard let self, self.generation == currentGeneration else { return }
                        self.receive(descriptor, source: source, pressed: pressed)
                    }
                }
            }
        }
    }
    private static func keyName(_ code: Int) -> String {
        if (4...29).contains(code), let scalar = UnicodeScalar(65 + code - 4) { return String(scalar) }
        if (30...38).contains(code) { return String(code - 29) }
        if code == 39 { return "0" }
        if code == 40 { return "↵" }
        if code == 44 { return "␣" }
        return L10n.format("rc_external_key", code)
    }
}

private final class WeakInputSurface {
    weak var view: ExternalButtonSurfaceView?
    init(_ view: ExternalButtonSurfaceView) { self.view = view }
}

final class ExternalButtonSurfaceView: UIView {
    weak var input: RemoteCameraExternalInput?
    var isLearningSurface = false
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    override var canBecomeFirstResponder: Bool { input?.acceptsUIKitInput == true && isEligible }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.input?.focusInputSurface() }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        receive(presses, pressed: true)
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        receive(presses, pressed: false)
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        receive(presses, pressed: false)
        super.pressesCancelled(presses, with: event)
    }
    private func receive(_ presses: Set<UIPress>, pressed: Bool) {
        guard isEligible else { return }
        for press in presses {
            if let key = press.key { input?.receiveUIKit(code: key.keyCode.rawValue, pressed: pressed) }
        }
    }
    var isEligible: Bool {
        guard let window, window.isKeyWindow, !isHidden,
              var top = window.rootViewController else { return false }
        while let presented = top.presentedViewController { top = presented }
        guard isDescendant(of: top.view), !Self.isEditing(top.view) else { return false }
        return true
    }
    private static func isEditing(_ view: UIView) -> Bool {
        if view.isFirstResponder && (view is UITextField || view is UITextView) { return true }
        return view.subviews.contains(where: isEditing)
    }
}

struct ExternalButtonInputSurface: UIViewRepresentable {
    var isLearning = false
    @EnvironmentObject private var input: RemoteCameraExternalInput
    final class Coordinator { let id = UUID(); weak var input: RemoteCameraExternalInput? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ExternalButtonSurfaceView {
        let view = ExternalButtonSurfaceView()
        view.isLearningSurface = isLearning
        context.coordinator.input = input
        input.register(view, id: context.coordinator.id)
        return view
    }
    func updateUIView(_ view: ExternalButtonSurfaceView, context: Context) { input.focusInputSurface() }
    static func dismantleUIView(_ view: ExternalButtonSurfaceView, coordinator: Coordinator) {
        coordinator.input?.unregister(coordinator.id)
    }
}
