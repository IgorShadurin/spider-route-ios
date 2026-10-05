import AVFoundation
import Foundation

struct SpeedAlertEvaluator {
    static let repeatInterval: TimeInterval = 15
    static let resetHysteresisMetersPerSecond = 1.4

    private(set) var isAboveLimit = false
    private(set) var lastAlertAt: Date?

    mutating func shouldPlayAlert(
        speedMetersPerSecond: Double,
        limitMetersPerSecond: Double,
        isEnabled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled,
              speedMetersPerSecond.isFinite,
              limitMetersPerSecond.isFinite,
              limitMetersPerSecond > 0 else {
            reset()
            return false
        }

        let resetSpeed = max(0, limitMetersPerSecond - Self.resetHysteresisMetersPerSecond)
        if speedMetersPerSecond <= resetSpeed {
            reset()
            return false
        }

        guard speedMetersPerSecond >= limitMetersPerSecond else { return false }

        if !isAboveLimit {
            isAboveLimit = true
            lastAlertAt = now
            return true
        }

        if let lastAlertAt, now.timeIntervalSince(lastAlertAt) >= Self.repeatInterval {
            self.lastAlertAt = now
            return true
        }

        return false
    }

    mutating func reset() {
        isAboveLimit = false
        lastAlertAt = nil
    }
}

@MainActor
final class SpeedAlertController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var evaluator = SpeedAlertEvaluator()
    private var player: AVAudioPlayer?
    private var audioLease: UUID?

    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: name, object: nil)
        }
    }
    @objc nonisolated private func audioInterrupted(_ notification: Notification) {
        if notification.name == AVAudioSession.interruptionNotification,
           (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }
    func process(
        speedMetersPerSecond: Double,
        limitMetersPerSecond: Double,
        isEnabled: Bool,
        now: Date = Date()
    ) {
        guard evaluator.shouldPlayAlert(
            speedMetersPerSecond: speedMetersPerSecond,
            limitMetersPerSecond: limitMetersPerSecond,
            isEnabled: isEnabled,
            now: now
        ) else { return }

        playPreview()
    }

    func playPreview() {
        finishPlayback()
        do {
            audioLease = try AppAudioSession.shared.acquire()
            let player = try AVAudioPlayer(data: SpeedAlertTone.data)
            player.delegate = self
            player.volume = 0.82
            player.prepareToPlay()
            self.player = player
            if !player.play() { finishPlayback() }
        } catch {
            finishPlayback()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.finishPlayback()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.finishPlayback()
        }
    }
    private func finishPlayback() {
        player?.stop()
        player = nil
        if let audioLease { AppAudioSession.shared.release(audioLease) }
        audioLease = nil
    }
}

private enum SpeedAlertTone {
    static let data: Data = makeData()

    private static func makeData() -> Data {
        let sampleRate = 44_100
        let duration = 0.44
        let sampleCount = Int(Double(sampleRate) * duration)
        var samples = Data(capacity: sampleCount * MemoryLayout<Int16>.size)

        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let sample: Int16

            if let pulse = pulse(at: time) {
                let localTime = time - pulse.start
                let fadeIn = min(localTime / 0.018, 1)
                let fadeOut = min((pulse.end - time) / 0.028, 1)
                let envelope = max(0, min(fadeIn, fadeOut))
                let wave = sin(2 * .pi * pulse.frequency * localTime)
                sample = Int16(max(-1, min(1, wave * envelope * 0.62)) * Double(Int16.max))
            } else {
                sample = 0
            }

            append(sample, to: &samples)
        }

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count), to: &wav)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt32(sampleRate), to: &wav)
        append(UInt32(sampleRate * MemoryLayout<Int16>.size), to: &wav)
        append(UInt16(MemoryLayout<Int16>.size), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(contentsOf: "data".utf8)
        append(UInt32(samples.count), to: &wav)
        wav.append(samples)
        return wav
    }

    private static func pulse(at time: TimeInterval) -> (start: TimeInterval, end: TimeInterval, frequency: Double)? {
        if (0.02...0.18).contains(time) { return (0.02, 0.18, 880) }
        if (0.25...0.41).contains(time) { return (0.25, 0.41, 1_046.5) }
        return nil
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
