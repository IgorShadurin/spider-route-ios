import Foundation
import MultipeerConnectivity
import CryptoKit

/// Multipeer encryption plus application identity signatures. Discovery names
/// never authorize a peer. Only the pinned key, a fresh nonce and both approvals do.
final class RemoteCameraLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    var onProgress: ((RemoteCameraConnectionProgress) -> Void)?
    private var progress = RemoteCameraConnectionProgress.idle
    var onConnection: ((Bool) -> Void)?
    var onStatus: ((RemoteCameraStatus) -> Void)?
    var onCommand: ((RemoteCameraCommand) -> Void)?
    var onStatusRequest: (() -> Void)?
    var onPairing: ((String?) -> Void)?
    var onError: ((String) -> Void)?
    var onTrustChanged: ((Bool) -> Void)?
    private let service = "speed-gps-cam"
    private let identity: Curve25519.Signing.PrivateKey
    private var trustedKey: Data?
    private let peer: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var role: RemoteCameraRole = .camera
    private var active = false
    private var candidate: MCPeerID?
    private var agreement = Curve25519.KeyAgreement.PrivateKey()
    private var encryptionKey: SymmetricKey?
    private var remoteKey: Data?
    private var ownNonce = UUID()
    private var remoteNonce: UUID?
    private var sentSequence: UInt64 = 0
    private var helloSent = false
    private var replayWindow: RemoteCameraReplayWindow?
    private var localApproved = false
    private var remoteApproved = false
    private(set) var authenticated = false
    private var discovery: [MCPeerID: String] = [:]
    private var deadline: Date?
    private var pairingAllowedUntil: Date?
    private var reconnectAfter = Date.distantPast
    private var retryTimer: Timer?
    var hasTrust: Bool { trustedKey != nil }

    override init() {
        var loadedIdentity = Curve25519.Signing.PrivateKey()
        do {
            if let raw = try RemoteCameraKeychain.read("identity") {
                loadedIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            } else {
                let generated = Curve25519.Signing.PrivateKey()
                try RemoteCameraKeychain.write(generated.rawRepresentation, account: "identity")
                loadedIdentity = generated
            }
            trustedKey = try RemoteCameraKeychain.read("partner")
        } catch {
            // Fail closed if protected identity storage cannot be read/written.
            loadedIdentity = Curve25519.Signing.PrivateKey()
            trustedKey = nil
            keychainUnavailable = true
        }
        identity = loadedIdentity
        let fingerprint = SHA256.hash(data: identity.publicKey.rawRepresentation).prefix(4).map { String(format: "%02x", $0) }.joined()
        peer = MCPeerID(displayName: "Speedometer-" + fingerprint)
        super.init()
        makeSession()
    }
    private var keychainUnavailable = false
    private var fingerprint: String {
        identity.publicKey.rawRepresentation.base64EncodedString()
    }
    func start(role: RemoteCameraRole, allowPairing: Bool = false) {
        guard !keychainUnavailable else { onError?("rc_error_security"); return }
        if active, self.role != role { stop() }
        self.role = role
        active = true
        if allowPairing, trustedKey == nil { pairingAllowedUntil = Date().addingTimeInterval(120) }
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        }
        refreshDiscovery()
    }
    func stop() {
        active = false
        pairingAllowedUntil = nil
        retryTimer?.invalidate()
        retryTimer = nil
        stopDiscovery()
        disconnect()
    }
    func forget() {
        stop()
        do {
            try RemoteCameraKeychain.write(nil, account: "partner")
            trustedKey = nil
            onTrustChanged?(false)
        } catch { onError?("rc_error_security") }
    }
    func approve() {
        guard remoteKey != nil, remoteNonce != nil, candidate != nil else { return }
        localApproved = true
        send(kind: "approve")
        finishAuthentication()
        updateProgress()
    }
    func reject() {
        pairingAllowedUntil = nil
        disconnect()
        refreshDiscovery()
    }
    func sendStatus(_ status: RemoteCameraStatus) { if authenticated { send(kind: "status", status: status) } }
    func sendCommand(_ command: RemoteCameraCommand) { if authenticated { send(kind: "command", command: command) } }
    func requestStatus() { if authenticated { send(kind: "query") } }

    private func tick() {
        guard active else { return }
        if let deadline, Date() > deadline, !authenticated { disconnect() }
        if trustedKey == nil, let until = pairingAllowedUntil, Date() > until {
            pairingAllowedUntil = nil
            if !authenticated { disconnect() }
            updateProgress()
            onError?("rc_connection_timeout")
            return
        }
        refreshDiscovery()
        if role == .remote, candidate == nil, Date() >= reconnectAfter {
            if let found = discovery.first(where: { trustedKey == nil || $0.value == trustedKey?.base64EncodedString() }) {
                candidate = found.key
                deadline = Date().addingTimeInterval(30)
                browser?.invitePeer(found.key, to: session, withContext: nil, timeout: 15)
            }
        }
        updateProgress()
    }
    private func updateProgress() {
        let next = RemoteCameraConnectionProgress.resolve(active: active,
            canDiscover: trustedKey != nil || pairingAllowedUntil != nil,
            candidate: candidate != nil, remoteKey: remoteKey != nil,
            localApproved: localApproved, authenticated: authenticated)
        guard next != progress else { return }
        progress = next
        onProgress?(next)
    }
    private func refreshDiscovery() {
        defer { updateProgress() }
        guard active, trustedKey != nil || pairingAllowedUntil != nil else { stopDiscovery(); return }
        if role == .camera, advertiser == nil {
            advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["key": fingerprint], serviceType: service)
            advertiser?.delegate = self
            advertiser?.startAdvertisingPeer()
        } else if role == .remote, browser == nil {
            browser = MCNearbyServiceBrowser(peer: peer, serviceType: service)
            browser?.delegate = self
            browser?.startBrowsingForPeers()
        }
    }
    private func stopDiscovery() {
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        discovery.removeAll()
    }
    private func makeSession() {
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }
    private func disconnect() {
        // Retire the session so delayed callbacks from a prior connection cannot
        // reset or authenticate a newer one.
        let retired = session
        makeSession()
        retired?.disconnect()
        candidate = nil
        remoteKey = nil
        remoteNonce = nil
        agreement = Curve25519.KeyAgreement.PrivateKey()
        encryptionKey = nil
        ownNonce = UUID()
        sentSequence = 0
        helloSent = false
        replayWindow = nil
        authenticated = false
        localApproved = false
        remoteApproved = false
        deadline = nil
        reconnectAfter = Date().addingTimeInterval(4)
        onPairing?(nil)
        onConnection?(false)
        updateProgress()
    }
    private func send(kind: String, status: RemoteCameraStatus? = nil, command: RemoteCameraCommand? = nil) {
        guard let candidate, session.connectedPeers.contains(candidate) else { return }
        if kind == "hello" {
            guard !helloSent else { return }
            helloSent = true
        }
        sentSequence += 1
        let packet = RemoteCameraPacket(kind: kind, publicKey: identity.publicKey.rawRepresentation,
            nonce: kind == "hello" ? ownNonce : (remoteNonce ?? ownNonce), sequence: sentSequence,
            role: role, agreementKey: kind == "hello" ? agreement.publicKey.rawRepresentation : nil, status: status, command: command)
        do {
            let envelope = try RemoteCameraEnvelope(packet: packet, key: identity)
            let frame: RemoteCameraTransport
            if kind == "hello" { frame = RemoteCameraTransport(hello: envelope) }
            else {
                guard let encryptionKey else { return }
                let sealed = try AES.GCM.seal(JSONEncoder().encode(envelope), using: encryptionKey)
                frame = RemoteCameraTransport(sealed: sealed.combined)
            }
            try session.send(JSONEncoder().encode(frame), toPeers: [candidate], with: .reliable)
        } catch { disconnect() }
    }
    private func receive(_ data: Data, from sender: MCPeerID) {
        guard sender == candidate, data.count < 32_768 else { return }
        do {
            let frame = try JSONDecoder().decode(RemoteCameraTransport.self, from: data)
            let envelope: RemoteCameraEnvelope
            if let hello = frame.hello {
                guard frame.sealed == nil, remoteKey == nil else { throw RemoteCameraSecurityError.invalidPacket }
                envelope = hello
            } else {
                guard let sealed = frame.sealed, let encryptionKey else { throw RemoteCameraSecurityError.invalidPacket }
                let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: encryptionKey)
                envelope = try JSONDecoder().decode(RemoteCameraEnvelope.self, from: clear)
            }
            let packet = try envelope.verifiedPacket()
            guard (frame.hello != nil) == (packet.kind == "hello") else { throw RemoteCameraSecurityError.invalidPacket }
            guard packet.role != nil, packet.role != role else { throw RemoteCameraSecurityError.invalidPacket }
            if packet.kind == "hello" {
                guard remoteKey == nil, packet.publicKey != identity.publicKey.rawRepresentation,
                    trustedKey == nil || trustedKey == packet.publicKey,
                    trustedKey != nil || pairingAllowedUntil.map({ Date() < $0 }) == true else {
                    throw RemoteCameraSecurityError.invalidPacket
                }
                send(kind: "hello")
                remoteKey = packet.publicKey
                remoteNonce = packet.nonce
                guard let rawAgreement = packet.agreementKey else { throw RemoteCameraSecurityError.invalidPacket }
                let secret = try agreement.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawAgreement))
                let salt = [ownNonce.uuidString, packet.nonce.uuidString].sorted().joined(separator: "|")
                encryptionKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(salt.utf8),
                    sharedInfo: Data("Speedometer Remote Camera v1".utf8), outputByteCount: 32)
                replayWindow = RemoteCameraReplayWindow(nonce: ownNonce)
                if trustedKey != nil {
                    localApproved = true
                    send(kind: "approve")
                } else {
                    deadline = Date().addingTimeInterval(120)
                    onPairing?(RemoteCameraEnvelope.verificationCode(keyA: identity.publicKey.rawRepresentation,
                        nonceA: ownNonce, keyB: packet.publicKey, nonceB: packet.nonce))
                }
                updateProgress()
                return
            }
            guard packet.publicKey == remoteKey, packet.nonce == ownNonce,
                  replayWindow?.accept(nonce: packet.nonce, sequence: packet.sequence) == true else { throw RemoteCameraSecurityError.invalidPacket }
            if packet.kind == "approve" {
                remoteApproved = true
                finishAuthentication()
                return
            }
            guard authenticated else { return }
            switch packet.kind {
            case "query" where role == .camera: onStatusRequest?()
            case "status" where role == .remote:
                if let status = packet.status, status.elapsed.isFinite, status.elapsed >= 0 { onStatus?(status) }
            case "command" where role == .camera:
                if let command = packet.command { onCommand?(command) }
            default: break
            }
        } catch { disconnect() }
    }
    private func finishAuthentication() {
        guard localApproved, remoteApproved, let remoteKey, !authenticated else { return }
        do {
            if trustedKey == nil {
                try RemoteCameraKeychain.write(remoteKey, account: "partner")
                trustedKey = remoteKey
            }
            authenticated = true
            pairingAllowedUntil = nil
            deadline = nil
            onTrustChanged?(true)
            onPairing?(nil)
            onConnection?(true)
            updateProgress()
            if role == .remote { requestStatus() } else { onStatusRequest?() }
        } catch { onError?("rc_error_security"); disconnect() }
    }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [self] in
            guard session === self.session else { return }
            if state == .connected, candidate == peerID { send(kind: "hello") }
            else if state == .notConnected, candidate == peerID { disconnect() }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [self] in
            guard session === self.session else { return }
            receive(data, from: peerID)
        }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [self] in
            let accepts = advertiser === self.advertiser && active && role == .camera && candidate == nil
                && (trustedKey != nil || pairingAllowedUntil.map { Date() < $0 } == true)
            if accepts { candidate = peerID; deadline = Date().addingTimeInterval(30); updateProgress() }
            invitationHandler(accepts, accepts ? session : nil)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [self] in
            guard browser === self.browser, let key = info?["key"] else { return }
            discovery[peerID] = key
            tick()
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [self] in
            guard browser === self.browser else { return }
            discovery.removeValue(forKey: peerID)
        }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, advertiser === self.advertiser else { return }
            self.onError?("rc_error_network")
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, browser === self.browser else { return }
            self.onError?("rc_error_network")
        }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with progress: Progress) { progress.cancel() }
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at localURL: URL?, withError: Error?) {}
}
