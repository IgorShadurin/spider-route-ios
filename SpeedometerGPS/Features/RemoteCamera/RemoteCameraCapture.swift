import AVFoundation
import Foundation

struct RemoteCameraClip: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let date: Date
}

/// All capture configuration, lifecycle and file verification run on one worker.
/// Camera-button readiness keeps a video-only session; no file or microphone.
final class RemoteCameraCapture: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Event {
        case standbyFailed(String)
        case started(UUID, Date), saving(UUID), saved(UUID, URL, TimeInterval, String?), failed(UUID, String)
    }
    var onEvent: ((Event) -> Void)?
    private let queue = DispatchQueue(label: "com.wowcoded.speedometergps.camera.capture", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private var recordingID: UUID?
    private var stopRequested = false
    private var audioLease: UUID?
    private var requestedSettings: RemoteCameraSettings?
    private var automaticFrameRate = false
    private var stopReason: String?
    private var observers: [NSObjectProtocol] = []
    private var startTimeout: DispatchWorkItem?

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Camera Recordings", isDirectory: true)
    }
    static var pendingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pending Camera Recordings", isDirectory: true)
    }
    static func freeBytes() -> Int64 {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }
    static func clips() -> [RemoteCameraClip] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.pathExtension == "mov" }.map {
            RemoteCameraClip(url: $0, date: (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }
    static func device(for lens: String) -> AVCaptureDevice? {
        switch lens {
        case "ultra": return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case "tele": return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case "front": return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        default: return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }
    static func lensZoomFactors() -> [String: Double] {
        var factors: [String: Double] = ["wide": 1, "ultra": 0.5]
        for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera] {
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
            let devices = device.constituentDevices
            let switches = [1.0] + device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            guard devices.count == switches.count,
                  let main = devices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
                  let tele = devices.firstIndex(where: { $0.deviceType == .builtInTelephotoCamera }) else { continue }
            factors["tele"] = switches[tele] / switches[main]
            break
        }
        return factors
    }
    static func format(for settings: RemoteCameraSettings, device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == (settings.resolution == 2160 ? 3840 : 1920)
                && size.height == Int32(settings.resolution)
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(settings.fps) && $0.maxFrameRate >= Double(settings.fps) }
                && supportsDynamicRange(settings, pixelFormat: CMFormatDescriptionGetMediaSubType(format.formatDescription),
                    colorSpaces: format.supportedColorSpaces)
        }
        // Keep resolution, lens and HDR exact. Prefer stabilization before Auto FPS.
        for mode in stabilizationModes(enabled: settings.stabilization) {
            let supported = candidates.filter { mode == .off || $0.isVideoStabilizationModeSupported(mode) }
            if let best = supported.first(where: { usesAutomaticFrameRate(settings, format: $0) }) { return best }
            if let first = supported.first { return first }
        }
        return nil
    }
    static func stabilizationModes(enabled: Bool) -> [AVCaptureVideoStabilizationMode] {
        guard enabled else { return [.off] }
        var modes: [AVCaptureVideoStabilizationMode] = []
        if #available(iOS 18.0, *) { modes.append(.cinematicExtendedEnhanced) }
        return modes + [.cinematicExtended, .cinematic, .standard]
    }
    static func stabilizationMode(enabled: Bool,
                                  supports: (AVCaptureVideoStabilizationMode) -> Bool) -> AVCaptureVideoStabilizationMode? {
        stabilizationModes(enabled: enabled).first { $0 == .off || supports($0) }
    }
    static func automaticFrameRateEligible(fps: Int, formatMaximumFPS: Double, supported: Bool) -> Bool {
        // Auto FPS follows the FORMAT ceiling, not activeVideoMinFrameDuration.
        // Never enable a 60-fps automatic format for a requested 30-fps recording.
        supported && [30, 60].contains(fps) && abs(formatMaximumFPS - Double(fps)) < 0.01
    }
    private static func usesAutomaticFrameRate(_ settings: RemoteCameraSettings, format: AVCaptureDevice.Format) -> Bool {
        if #available(iOS 18.0, *) {
            return automaticFrameRateEligible(fps: settings.fps,
                formatMaximumFPS: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0,
                supported: format.isAutoVideoFrameRateSupported)
        }
        return false
    }
    static func recordedFrameRateMatches(_ actual: Double, requested: Int, automatic: Bool) -> Bool {
        guard actual.isFinite else { return false }
        if automatic, [30, 60].contains(requested) {
            // Variable-rate files report an average; include 23.976-fps timing.
            return actual >= 23.5 && actual <= Double(requested) + 0.1
        }
        return abs(actual - Double(requested)) < 1
    }
    static func supportsDynamicRange(_ settings: RemoteCameraSettings, pixelFormat: OSType,
                                     colorSpaces: [AVCaptureColorSpace]) -> Bool {
        let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        return settings.hdr
            ? settings.codec == "hevc" && tenBit && colorSpaces.contains(.HLG_BT2020)
            : !tenBit && colorSpaces.contains(.sRGB)
    }
    static func supportsHDR(_ settings: RemoteCameraSettings) -> Bool {
        guard let device = device(for: settings.lens) else { return false }
        var hdrSettings = settings
        hdrSettings.hdr = true
        hdrSettings.codec = "hevc"
        return format(for: hdrSettings, device: device) != nil
    }
    static func validationError(_ settings: RemoteCameraSettings) -> String? {
        guard let device = device(for: settings.lens) else { return "rc_error_camera" }
        guard format(for: settings, device: device) != nil else { return settings.hdr ? "rc_hdr_unavailable" : "rc_error_format" }
        return nil
    }

    func prepareStandby(settings: RemoteCameraSettings, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard recordingID == nil else {
                DispatchQueue.main.async { completion("rc_error_camera") }
                return
            }
            tearDown()
            var videoOnly = settings
            videoOnly.audio = false
            var failure: String?
            do { try configure(settings: videoOnly) }
            catch {
                failure = (error as? CaptureFailure)?.key ?? "rc_error_camera"
                tearDown()
            }
            let result = failure
            DispatchQueue.main.async { completion(result) }
        }
    }

    func shutdownStandby() {
        queue.async { [self] in
            if recordingID == nil { tearDown() }
        }
    }

    private func configure(settings: RemoteCameraSettings) throws {
        guard let device = Self.device(for: settings.lens) else { throw CaptureFailure("rc_error_camera") }
        guard let format = Self.format(for: settings, device: device) else {
            throw CaptureFailure(settings.hdr ? "rc_hdr_unavailable" : "rc_error_format")
        }
        let capture = AVCaptureSession()
        session = capture
        capture.usesApplicationAudioSession = true
        capture.automaticallyConfiguresApplicationAudioSession = false
        capture.automaticallyConfiguresCaptureDeviceForWideColor = false
        if settings.audio { audioLease = try AppAudioSession.shared.acquire(capture: true) }
        capture.beginConfiguration()
        capture.sessionPreset = .inputPriority
        do {
            let video = try AVCaptureDeviceInput(device: device)
            guard capture.canAddInput(video) else { throw CaptureFailure("rc_error_camera") }
            capture.addInput(video)
            if settings.audio {
                guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureFailure("rc_error_microphone") }
                let audio = try AVCaptureDeviceInput(device: microphone)
                guard capture.canAddInput(audio) else { throw CaptureFailure("rc_error_microphone") }
                capture.addInput(audio)
            }
            let movie = AVCaptureMovieFileOutput()
            movie.minFreeDiskSpaceLimit = 250_000_000
            // Frequent movie fragments improve the chance of recovering a
            // playable partial clip after process termination; keep originals.
            movie.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            guard capture.canAddOutput(movie) else { throw CaptureFailure("rc_error_camera") }
            capture.addOutput(movie)
            output = movie
            try device.lockForConfiguration()
            device.activeFormat = format
            // videoHDREnabled is the older SDR/EDR feature, not 10-bit
            // HDR. Select a genuine HLG format and control color explicitly.
            device.automaticallyAdjustsVideoHDREnabled = false
            // HLG-only formats reject even setting this legacy flag to
            // false. Their dynamic range is controlled by color space.
            if format.isVideoHDRSupported { device.isVideoHDREnabled = false }
            device.activeColorSpace = settings.hdr ? .HLG_BT2020 : .sRGB
            automaticFrameRate = Self.usesAutomaticFrameRate(settings, format: format)
            if #available(iOS 18.0, *), format.isAutoVideoFrameRateSupported {
                device.isAutoVideoFrameRateEnabled = automaticFrameRate
            }
            if !automaticFrameRate {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(settings.fps))
                device.activeVideoMaxFrameDuration = device.activeVideoMinFrameDuration
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = true
            }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
            guard let connection = movie.connection(with: .video) else { throw CaptureFailure("rc_error_camera") }
            if connection.isVideoOrientationSupported {
                switch settings.orientation {
                case "portrait": connection.videoOrientation = .portrait
                case "landscapeLeft": connection.videoOrientation = .landscapeLeft
                default: connection.videoOrientation = .landscapeRight
                }
            }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            if settings.stabilization {
                guard connection.isVideoStabilizationSupported else { throw CaptureFailure("rc_error_format") }
                guard let mode = Self.stabilizationMode(enabled: true, supports: format.isVideoStabilizationModeSupported) else {
                    throw CaptureFailure("rc_error_format")
                }
                connection.preferredVideoStabilizationMode = mode
            } else { connection.preferredVideoStabilizationMode = .off }
            let codec: AVVideoCodecType = settings.codec == "hevc" ? .hevc : .h264
            guard movie.availableVideoCodecTypes.contains(codec) else { throw CaptureFailure("rc_error_format") }
            movie.setOutputSettings([AVVideoCodecKey: codec], for: connection)
            capture.commitConfiguration()
        } catch {
            capture.commitConfiguration()
            throw error
        }
        observe(capture)
        capture.startRunning()
        guard capture.isRunning else { throw CaptureFailure("rc_error_camera") }
        guard device.activeColorSpace == (settings.hdr ? .HLG_BT2020 : .sRGB) else {
            throw CaptureFailure("rc_error_format")
        }
        guard let connection = output?.connection(with: .video),
              connection.activeVideoStabilizationMode == connection.preferredVideoStabilizationMode else {
            throw CaptureFailure("rc_error_format")
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-camera-quality-probe") {
            let report: [String: Any] = ["lens": settings.lens, "fpsCeiling": settings.fps,
                "hdr": settings.hdr, "automaticFrameRate": automaticFrameRate,
                "activeStabilization": connection.activeVideoStabilizationMode.rawValue,
                "requestedStabilization": connection.preferredVideoStabilizationMode.rawValue,
                "whiteBalanceMode": device.whiteBalanceMode.rawValue,
                "lensCorrection": device.isGeometricDistortionCorrectionSupported && device.isGeometricDistortionCorrectionEnabled]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("camera-quality-probe.json"), options: .atomic)
            }
        }
#endif
    }

    func start(id: UUID, settings: RemoteCameraSettings) {
        queue.async { [self] in
            guard recordingID == nil else { return }
            tearDown()
            recordingID = id
            requestedSettings = settings
            stopRequested = false
            stopReason = nil
            do {
                guard Self.freeBytes() > 300_000_000 else { throw CaptureFailure("rc_error_storage") }
                try configure(settings: settings)
                try FileManager.default.createDirectory(at: Self.pendingDirectory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                output?.startRecording(to: Self.pendingDirectory.appendingPathComponent(id.uuidString + ".mov"), recordingDelegate: self)
                let timeout = DispatchWorkItem { [weak self] in self?.stopOnQueue(reason: "rc_error_start_timeout") }
                startTimeout = timeout
                queue.asyncAfter(deadline: .now() + 20, execute: timeout)
            } catch {
                let key = (error as? CaptureFailure)?.key ?? "rc_error_camera"
                tearDown()
                emit(.failed(id, key))
            }
        }
    }

    func stop(reason: String? = nil) {
        queue.async { [weak self] in self?.stopOnQueue(reason: reason) }
    }
    private func stopOnQueue(reason: String?) {
        guard let id = recordingID else {
            if session != nil, let reason {
                tearDown()
                emit(.standbyFailed(reason))
            }
            return
        }
        stopRequested = true
        if let reason { stopReason = reason }
        emit(.saving(id))
        if output?.isRecording == true { output?.stopRecording() }
        // If startRecording has not acknowledged yet, didStart immediately stops
        // it. The start watchdog owns the failure path if it never acknowledges.
        else if reason == "rc_error_start_timeout" {
            tearDown()
            emit(.failed(id, reason!))
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let startedAt = Date()
        queue.async { [self] in
            guard let id = recordingID, fileURL.deletingPathExtension().lastPathComponent == id.uuidString else { return }
            startTimeout?.cancel()
            startTimeout = nil
            emit(.started(id, startedAt))
            if stopRequested { self.output?.stopRecording() }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { [self] in
            guard let id = recordingID, url.deletingPathExtension().lastPathComponent == id.uuidString else { return }
            emit(.saving(id))
            let reason = stopReason
            let expected = requestedSettings
            let usedAutomaticFrameRate = automaticFrameRate
            // Shut down the entire capture graph before reading/archiving the file.
            tearDown()
            do {
                let nsError = error as NSError?
                let saved = try Self.archivePlayable(url)
                let mismatch = expected.map { !Self.matchesSettings(saved, settings: $0, automaticFrameRate: usedAutomaticFrameRate) } ?? false
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--debug-camera-quality-probe") {
                    let reportURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("camera-quality-probe.json")
                    var report = (try? Data(contentsOf: reportURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    let asset = AVURLAsset(url: saved)
                    let track = asset.tracks(withMediaType: .video).first
                    report["filename"] = saved.lastPathComponent
                    report["duration"] = CMTimeGetSeconds(asset.duration)
                    report["nominalFrameRate"] = track?.nominalFrameRate
                    report["width"] = track?.naturalSize.width
                    report["height"] = track?.naturalSize.height
                    report["matchesSettings"] = !mismatch
                    report["warning"] = reason ?? Self.recordingWarning(nsError) ?? ""
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: reportURL, options: .atomic)
                    }
                }
#endif
                emit(.saved(id, saved, CMTimeGetSeconds(AVURLAsset(url: saved).duration), reason ?? Self.recordingWarning(nsError) ?? (mismatch ? "rc_error_format" : nil)))
            } catch {
                // Never delete the pending original, even if its container cannot
                // currently be opened. It remains available for manual recovery.
                emit(.failed(id, "rc_error_save"))
            }
        }
    }
    func recoverPending(completion: @escaping ([(url: URL, duration: TimeInterval)], Bool) -> Void) {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: Self.pendingDirectory,
                includingPropertiesForKeys: nil)) ?? []
            var failed = false
            var recovered: [(url: URL, duration: TimeInterval)] = []
            for file in files where file.pathExtension == "mov" {
                do {
                    let saved = try Self.archivePlayable(file)
                    recovered.append((saved, CMTimeGetSeconds(AVURLAsset(url: saved).duration)))
                } catch { failed = true }
            }
            DispatchQueue.main.async { completion(recovered, failed) }
        }
    }
    static func recordingWarning(_ error: NSError?) -> String? {
        guard let error else { return nil }
        // A playable movie after an automatic stop is still an interruption.
        // AVErrorRecordingSuccessfullyFinishedKey does not mean the camera is READY.
        return error.domain == AVFoundationErrorDomain && error.code == AVError.Code.diskFull.rawValue
            ? "rc_error_storage" : "rc_error_interrupted"
    }
    private static func matchesSettings(_ url: URL, settings: RemoteCameraSettings, automaticFrameRate: Bool) -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return false }
        let width = max(abs(track.naturalSize.width), abs(track.naturalSize.height))
        let height = min(abs(track.naturalSize.width), abs(track.naturalSize.height))
        return Int(width) == (settings.resolution == 2160 ? 3840 : 1920)
            && Int(height) == settings.resolution
            && recordedFrameRateMatches(Double(track.nominalFrameRate), requested: settings.fps, automatic: automaticFrameRate)
            && track.hasMediaCharacteristic(.containsHDRVideo) == settings.hdr
            && (!settings.audio || !asset.tracks(withMediaType: .audio).isEmpty)
    }
    private static func archivePlayable(_ url: URL) throws -> URL {
        let asset = AVURLAsset(url: url)
        guard asset.isPlayable, !asset.tracks(withMediaType: .video).isEmpty,
              CMTimeGetSeconds(asset.duration).isFinite, CMTimeGetSeconds(asset.duration) > 0 else {
            throw CaptureFailure("rc_error_save")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
    private func observe(_ capture: AVCaptureSession) {
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: capture, queue: nil) { [weak self] _ in
                self?.stop(reason: "rc_error_interrupted")
            })
        }
    }
    private func tearDown() {
        defer {
            if let audioLease { AppAudioSession.shared.release(audioLease) }
            audioLease = nil
        }
        startTimeout?.cancel()
        startTimeout = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        session?.stopRunning()
        if let session {
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
        }
        output = nil
        session = nil
        recordingID = nil
        automaticFrameRate = false
    }
    private func emit(_ event: Event) { DispatchQueue.main.async { [weak self] in self?.onEvent?(event) } }
    private struct CaptureFailure: Error {
        let key: String
        init(_ key: String) { self.key = key }
    }
}
