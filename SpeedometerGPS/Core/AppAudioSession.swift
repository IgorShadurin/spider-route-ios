import AVFoundation

/// All app-owned tones and camera capture share leases: a tone finishing must
/// never deactivate the microphone's session or change its recording category.
struct AppAudioLeases {
    enum Mode { case inactive, playback, capture }
    private var owners: [UUID: Bool] = [:]
    var mode: Mode { owners.values.contains(true) ? .capture : owners.isEmpty ? .inactive : .playback }
    mutating func insert(_ id: UUID, capture: Bool) { owners[id] = capture }
    mutating func remove(_ id: UUID) { owners.removeValue(forKey: id) }
}

final class AppAudioSession: @unchecked Sendable {
    static let shared = AppAudioSession()
    private let lock = NSLock()
    private var leases = AppAudioLeases()
    private var appliedMode = AppAudioLeases.Mode.inactive
    func acquire(capture: Bool = false) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        var next = leases
        next.insert(id, capture: capture)
        do {
            if next.mode == appliedMode { try AVAudioSession.sharedInstance().setActive(true) }
            else { try apply(next.mode) }
        }
        catch { try? apply(leases.mode, force: true); throw error }
        leases = next
        return id
    }
    func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        leases.remove(id)
        try? apply(leases.mode)
    }
    private func apply(_ mode: AppAudioLeases.Mode, force: Bool = false) throws {
        guard force || mode != appliedMode else { return }
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .inactive:
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        case .playback:
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        case .capture:
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true)
        }
        appliedMode = mode
    }
}
