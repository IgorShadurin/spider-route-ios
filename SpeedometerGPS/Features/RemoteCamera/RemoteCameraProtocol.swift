import Foundation
import CryptoKit
import Security

enum RemoteCameraRole: String, Codable, CaseIterable { case camera, remote }
enum RemoteCameraConnectionProgress: String {
    case idle, discovering, connecting, verifying, awaitingApproval, connected
    var isBusy: Bool { self != .idle && self != .connected }
    static func resolve(active: Bool, canDiscover: Bool, candidate: Bool, remoteKey: Bool,
                        localApproved: Bool, authenticated: Bool) -> Self {
        guard active else { return .idle }
        if authenticated { return .connected }
        guard canDiscover else { return .idle }
        if remoteKey { return localApproved ? .awaitingApproval : .verifying }
        return candidate ? .connecting : .discovering
    }
    func titleKey(role: RemoteCameraRole, trusted: Bool) -> String {
        switch self {
        case .idle: return trusted ? "rc_not_connected" : "rc_not_paired"
        case .discovering: return trusted ? "rc_reconnecting" : role == .camera ? "rc_wait_remote" : "rc_search_camera"
        case .connecting: return "rc_connecting"
        case .verifying: return "rc_verify"
        case .awaitingApproval: return "rc_wait_approval"
        case .connected: return "rc_connected"
        }
    }
}

enum RemoteCameraPhase: String, Codable {
    case unavailable, ready, starting, recording, saving, error
    var isBusy: Bool { self == .starting || self == .recording || self == .saving }
    var title: String { L10n.tr("rc_state_\(rawValue)") }
}

struct RemoteCameraSettings: Codable, Equatable {
    var lens = "ultra"
    var resolution = 2160
    var fps = 30
    var stabilization = true
    var hdr = false
    var orientation = "landscapeRight"
    var audio = true
    var codec = "hevc"
    init() {}
    private enum CodingKeys: String, CodingKey {
        case lens, resolution, fps, stabilization, hdr, orientation, audio, codec
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lens = try values.decode(String.self, forKey: .lens)
        resolution = try values.decode(Int.self, forKey: .resolution)
        fps = try values.decode(Int.self, forKey: .fps)
        stabilization = try values.decode(Bool.self, forKey: .stabilization)
        // Older preferences and remote status packets retain all their choices.
        hdr = try values.decodeIfPresent(Bool.self, forKey: .hdr) ?? false
        orientation = try values.decode(String.self, forKey: .orientation)
        audio = try values.decode(Bool.self, forKey: .audio)
        codec = try values.decode(String.self, forKey: .codec)
    }
    static func initial(saved: Self?, availableLenses: [String], migrateLegacyDefault: Bool) -> Self {
        let preferred = availableLenses.contains("ultra") ? "ultra" : "wide"
        var legacy = Self()
        legacy.lens = "wide"
        if let saved, !(migrateLegacyDefault && saved == legacy) { return saved }
        var settings = Self()
        settings.lens = preferred
        return settings
    }
    static func lensTitle(_ lens: String, zoom: Double? = nil) -> String {
        let factor: Double? = lens == "ultra" ? 0.5 : lens == "wide" ? 1 : zoom
        if let factor, factor.isFinite, factor > 0 {
            return String(format: "%.1f", factor).replacingOccurrences(of: ".0", with: "") + "×"
        }
        return L10n.tr("rc_lens_\(lens)")
    }
    var summary: String { "\(resolution == 2160 ? "4K" : "1080p") · \(fps) fps · \(codec.uppercased())" + (hdr ? " · HDR" : "") }
}

struct RemoteCameraStatus: Codable, Equatable {
    var phase: RemoteCameraPhase = .unavailable
    var revision = UUID()
    var recordingID: UUID?
    var elapsed: TimeInterval = 0
    var battery: Int = -1
    var freeBytes: Int64 = 0
    var thermalWarning = false
    var errorKey: String?
    var settings = RemoteCameraSettings()
    var lensZoom: Double?
    var lastSavedRecordingID: UUID?
    var videoReceipts: [CameraVideoReceipt]?
    // Optional for peers running the original Remote-only accessory protocol.
    var accessoryDevice: RemoteCameraRole?
    // Relative duration, never a wall clock shared between two phones.
    var controlLockRemaining: TimeInterval?

    var hardwareShutterAction: RemoteCameraCommand.Action? {
        switch phase {
        case .ready: return .start
        case .recording: return .stop
        default: return nil
        }
    }
}

struct RemoteCameraCommand: Codable, Equatable {
    enum Action: String, Codable { case start, stop }
    var id = UUID()
    let action: Action
    let revision: UUID
    let recordingID: UUID?
}

/// A START is valid only for the exact READY generation observed by the remote.
/// A STOP targets a recording ID, so a delayed stop cannot end a later clip.
struct RemoteCameraCommandCooldown {
    static let duration: TimeInterval = 3
    private var deadline: TimeInterval = 0
    func remaining(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, deadline - now)
    }
    mutating func begin(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        extend(by: Self.duration, at: now)
    }
    mutating func extend(by duration: TimeInterval, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard duration.isFinite, duration > 0 else { return }
        deadline = max(deadline, now + min(Self.duration, duration))
    }
}

struct RemoteCameraCommandGate {
    private(set) var cooldown = RemoteCameraCommandCooldown()
    mutating func confirmedTransition(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        cooldown.begin(at: now)
    }
    private(set) var handled: [UUID] = []
    mutating func accept(_ command: RemoteCameraCommand, status: RemoteCameraStatus,
                         now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !handled.contains(command.id) else { return false }
        handled.append(command.id)
        if handled.count > 256 { handled.removeFirst(handled.count - 256) }
        // Remember rejected IDs too: retries must not become delayed actions.
        guard cooldown.remaining(at: now) == 0 else { return false }
        let valid: Bool
        switch command.action {
        case .start:
            valid = status.phase == .ready && command.revision == status.revision
        case .stop:
            valid = (status.phase == .starting || status.phase == .recording)
                && command.recordingID != nil && command.recordingID == status.recordingID
        }
        if valid { cooldown.begin(at: now) }
        return valid
    }
}

/// Every post-hello packet binds the sender's signature to the recipient's fresh
/// connection nonce and an increasing sequence, rejecting replay across sessions.
struct RemoteCameraPacket: Codable {
    var version = 1
    let kind: String
    let publicKey: Data
    let nonce: UUID
    let sequence: UInt64
    var role: RemoteCameraRole?
    var agreementKey: Data?
    var status: RemoteCameraStatus?
    var command: RemoteCameraCommand?
}

struct RemoteCameraEnvelope: Codable {
    let payload: Data
    let signature: Data

    init(packet: RemoteCameraPacket, key: Curve25519.Signing.PrivateKey) throws {
        payload = try JSONEncoder().encode(packet)
        signature = try key.signature(for: payload)
    }

    func verifiedPacket() throws -> RemoteCameraPacket {
        guard payload.count < 16_384 else { throw RemoteCameraSecurityError.invalidPacket }
        let packet = try JSONDecoder().decode(RemoteCameraPacket.self, from: payload)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: packet.publicKey)
        guard packet.version == 1, key.isValidSignature(signature, for: payload) else {
            throw RemoteCameraSecurityError.invalidPacket
        }
        return packet
    }

    static func verificationCode(keyA: Data, nonceA: UUID, keyB: Data, nonceB: UUID) -> String {
        let parts = [keyA.base64EncodedString() + nonceA.uuidString, keyB.base64EncodedString() + nonceB.uuidString].sorted()
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        let hex = digest.prefix(8).map { String(format: "%02X", $0) }
        return stride(from: 0, to: 8, by: 2).map { hex[$0..<$0 + 2].joined() }.joined(separator: " ")
    }
}

/// Rejects reused or out-of-order packets even if their signatures are valid.
struct RemoteCameraReplayWindow {
    var nonce: UUID
    private(set) var sequence: UInt64 = 0
    mutating func accept(nonce: UUID, sequence: UInt64) -> Bool {
        guard nonce == self.nonce, sequence > self.sequence else { return false }
        self.sequence = sequence
        return true
    }
}

struct RemoteCameraTransport: Codable {
    var hello: RemoteCameraEnvelope?
    var sealed: Data?
}

enum RemoteCameraSecurityError: Error { case invalidPacket, keychain(OSStatus) }

/// Device-local identity and pinned partner public key; never synced to iCloud.
enum RemoteCameraKeychain {
    private static let service = "com.wowcoded.speedometergps.remote-camera"
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw RemoteCameraSecurityError.keychain(result) }
        return value as? Data
    }
    static func write(_ data: Data?, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let data {
            let updates: [String: Any] = [kSecValueData as String: data]
            let result = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            if result == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else { throw RemoteCameraSecurityError.keychain(added) }
            } else if result != errSecSuccess { throw RemoteCameraSecurityError.keychain(result) }
        } else {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw RemoteCameraSecurityError.keychain(result) }
        }
    }
}
