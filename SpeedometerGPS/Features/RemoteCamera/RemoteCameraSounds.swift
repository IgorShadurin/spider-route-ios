import AVFoundation
import OSLog

struct RemoteCameraSoundPreferences: Codable, Equatable {
    var start = true
    var stop = true
    var startVolume = 0.3
    var stopVolume = 0.3
    init(start: Bool = true, stop: Bool = true, startVolume: Double = 0.3, stopVolume: Double = 0.3) {
        self.start = start; self.stop = stop
        self.startVolume = Self.clamp(startVolume); self.stopVolume = Self.clamp(stopVolume)
    }
    private enum CodingKeys: String, CodingKey { case start, stop, startVolume, stopVolume }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve existing independent switches when old preferences have no levels.
        start = try values.decodeIfPresent(Bool.self, forKey: .start) ?? true
        stop = try values.decodeIfPresent(Bool.self, forKey: .stop) ?? true
        startVolume = Self.clamp((try? values.decode(Double.self, forKey: .startVolume)) ?? 0.3)
        stopVolume = Self.clamp((try? values.decode(Double.self, forKey: .stopVolume)) ?? 0.3)
    }
    static func clamp(_ volume: Double) -> Double { volume.isFinite ? min(1, max(0, volume)) : 0.3 }
    func volume(for cue: RemoteCameraSoundCue) -> Float { Float(Self.clamp(cue == .start ? startVolume : stopVolume)) }
    func allows(_ cue: RemoteCameraSoundCue) -> Bool { cue == .start ? start : stop }
}
enum RemoteCameraSoundCue { case start, stop }

struct RemoteCameraSoundGate {
    private var previous: RemoteCameraStatus?
    mutating func reset() { previous = nil }
    mutating func observe(_ status: RemoteCameraStatus, baseline: Bool = false) -> [RemoteCameraSoundCue] {
        defer { previous = status }
        guard !baseline, let previous else { return [] }
        var cues: [RemoteCameraSoundCue] = []
        // Saving is not confirmation: only a finalized retained file produces STOP.
        if let saved = status.lastSavedRecordingID, saved != previous.lastSavedRecordingID,
           saved == previous.recordingID {
            cues.append(.stop)
        }
        if status.phase == .recording, status.recordingID != nil,
           previous.phase != .recording || previous.recordingID != status.recordingID {
            cues.append(.start)
        }
        return cues
    }
}

@MainActor
final class RemoteCameraSounds: NSObject, AVAudioPlayerDelegate {
    private static let logger = Logger(subsystem: "com.wowcoded.speedometergps", category: "RecordingSounds")
    private var player: AVAudioPlayer?
    private var lease: UUID?
    private struct Playback { let cue: RemoteCameraSoundCue; let volume: Float }
    private var pending: [Playback] = []
    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: name, object: nil)
        }
    }
    @objc nonisolated private func audioInterrupted(_ notification: Notification) {
        if notification.name == AVAudioSession.interruptionNotification,
           (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
        Task { @MainActor [weak self] in self?.stop() }
    }
    func play(_ cue: RemoteCameraSoundCue, volume: Float) {
        let gain = Float(RemoteCameraSoundPreferences.clamp(Double(volume)))
        guard gain > 0, pending.count < 4 else { return }
        pending.append(Playback(cue: cue, volume: gain))
        if player == nil { playNext() }
    }
    func stop() {
        pending.removeAll()
        player?.stop(); player = nil
        if let lease { AppAudioSession.shared.release(lease) }
        lease = nil
    }
    private func playNext() {
        guard !pending.isEmpty else { return }
        let request = pending.removeFirst()
        do {
            lease = try AppAudioSession.shared.acquire()
            let next = try Self.makePlayer(request.cue, volume: request.volume)
            next.delegate = self
            next.prepareToPlay()
            player = next
            let started = next.play()
            let session = AVAudioSession.sharedInstance()
            Self.logger.notice("Cue \(String(describing: request.cue), privacy: .public) started=\(started) gain=\(request.volume) category=\(session.category.rawValue, privacy: .public) volume=\(session.outputVolume) outputs=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","), privacy: .public)")
            guard started else { stop(); return }
        } catch {
            Self.logger.error("Recording cue failed: \(String(describing: error), privacy: .public)")
            stop()
        }
    }
    nonisolated static func makePlayer(_ cue: RemoteCameraSoundCue, volume: Float) throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(data: RemoteCameraTone.data(cue))
        // Per-cue gain multiplies the user-owned media volume. It cannot bypass mute.
        player.volume = Float(RemoteCameraSoundPreferences.clamp(Double(volume)))
        return player
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil
            if let lease = self.lease { AppAudioSession.shared.release(lease) }
            self.lease = nil
            self.playNext()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }
}

enum RemoteCameraTone {
    // Distinct rising/falling notes, long enough to recognize on a mounted phone.
    static func data(_ cue: RemoteCameraSoundCue) -> Data { cue == .start ? start : stop }
    private static let start = make(rising: true)
    private static let stop = make(rising: false)
    private static func make(rising: Bool) -> Data {
        let rate = 44_100
        let count = rate * 48 / 100
        var samples = Data(capacity: count * 2)
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let second = time >= 0.26
            let local = second ? time - 0.26 : time
            let frequency = (second == rising) ? 1046.5 : 784.0
            let envelope = max(0, min(1, min(local / 0.012, (0.22 - local) / 0.025)))
            append(Int16(sin(2 * .pi * frequency * local) * envelope * 0.8 * Double(Int16.max)), to: &samples)
        }
        var wav = Data("RIFF".utf8)
        append(UInt32(36 + samples.count), to: &wav)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav); append(UInt16(1), to: &wav)
        append(UInt32(rate), to: &wav); append(UInt32(rate * 2), to: &wav)
        append(UInt16(2), to: &wav); append(UInt16(16), to: &wav)
        wav.append(contentsOf: "data".utf8)
        append(UInt32(samples.count), to: &wav); wav.append(samples)
        return wav
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
