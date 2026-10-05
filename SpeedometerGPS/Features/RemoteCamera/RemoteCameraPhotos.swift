import Foundation
import Photos

/// Add-only Photos export. The playable app copy is retained on every outcome.
@MainActor
final class RemoteCameraPhotos {
    enum State: String {
        case local, waiting, saving, saved, denied, failed
        var titleKey: String {
            switch self {
            case .local: return "rc_photos_local"
            case .waiting: return "rc_photos_waiting"
            case .saving: return "rc_photos_saving"
            case .saved: return "rc_photos_saved"
            case .denied: return "rc_photos_denied"
            case .failed: return "rc_photos_failed"
            }
        }
        var canSave: Bool { self == .local || self == .denied || self == .failed || self == .waiting }
    }
    var onChange: (() -> Void)?
    private(set) var states: [String: State] = [:]
    private let defaults: UserDefaults
    private let authorization: () -> PHAuthorizationStatus
    private let request: () async -> PHAuthorizationStatus
    private let write: (URL) async -> Bool
    private var saved: Set<String>
    private var pending: Set<String>
    private var active = true
    private var requesting = false
    private var worker: Task<Void, Never>?
    private let directory: URL

    init(defaults: UserDefaults = .standard, directory: URL = RemoteCameraCapture.directory,
         authorization: @escaping () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .addOnly) },
         request: @escaping () async -> PHAuthorizationStatus = { await PHPhotoLibrary.requestAuthorization(for: .addOnly) },
         write: @escaping (URL) async -> Bool = RemoteCameraPhotos.writeVideo) {
        self.defaults = defaults
        self.directory = directory
        self.authorization = authorization
        self.request = request
        self.write = write
        saved = Set(defaults.stringArray(forKey: "remoteCamera.photos.saved") ?? [])
        pending = Set(defaults.stringArray(forKey: "remoteCamera.photos.pending") ?? []).subtracting(saved)
    }
    func state(for url: URL) -> State {
        let name = url.lastPathComponent
        if saved.contains(name) { return .saved }
        if let state = states[name] { return state }
        if pending.contains(name) { return allowed ? .waiting : .denied }
        return .local
    }
    private var allowed: Bool { [.authorized, .limited].contains(authorization()) }
    private func change(_ name: String, _ state: State) { states[name] = state; onChange?() }
    private func persist() {
        defaults.set(Array(saved), forKey: "remoteCamera.photos.saved")
        defaults.set(Array(pending), forKey: "remoteCamera.photos.pending")
    }
    /// Called by the explicit Enter black mode action, before capture is armed.
    func preparePermission() async {
        guard !requesting, active else { return }
        requesting = true
        if authorization() == .notDetermined { _ = await request() }
        requesting = false
        resume()
    }
    func sceneActive(_ value: Bool) {
        active = value
        if value { resume() }
    }
    func enqueue(_ url: URL) {
        let name = url.lastPathComponent
        guard !saved.contains(name) else { return }
        pending.insert(name)
        persist()
        if states[name] != .saving { change(name, allowed ? .waiting : .denied) }
        resume()
    }
    func saveManually(_ url: URL) async {
        guard !saved.contains(url.lastPathComponent), states[url.lastPathComponent] != .saving else { return }
        await preparePermission()
        enqueue(url)
    }
    /// Retry pending exports only on explicit retry, new capture, or foreground.
    /// Never prompt for permission from a recording completion/background callback.
    private func resume() {
        guard active, !requesting, worker == nil, !pending.isEmpty else { return }
        guard allowed else {
            for name in pending { change(name, .denied) }
            return
        }
        worker = Task { [weak self] in
            guard let self else { return }
            var attempted = Set<String>()
            while self.active, self.allowed,
                  let name = self.pending.subtracting(attempted).sorted().first {
                attempted.insert(name)
                let url = self.directory.appendingPathComponent(name)
                self.change(name, .saving)
                let success = await self.write(url)
                if success {
                    self.saved.insert(name)
                    self.pending.remove(name)
                    self.persist()
                }
                self.change(name, success ? .saved : .failed)
            }
            self.worker = nil
        }
    }
    nonisolated static func writeVideo(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                creation.addResource(with: .video, fileURL: url, options: options)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
#if DEBUG
    func fixture(_ url: URL, state: State) { change(url.lastPathComponent, state) }
#endif
}
