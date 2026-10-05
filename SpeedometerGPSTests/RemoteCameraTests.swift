import AVFoundation
import CryptoKit
import XCTest
@testable import SpeedometerGPS

final class RemoteCameraTests: XCTestCase {
    func testAccessoryTargetStatusMigrationAndReceiptRoundTrip() throws {
        let old = RemoteCameraStatus(phase: .ready)
        let oldData = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(RemoteCameraStatus.self, from: oldData).accessoryDevice)
        var current = old
        current.accessoryDevice = .camera
        current.recordingID = UUID()
        current.elapsed = 12.5
        current.phase = .recording
        XCTAssertEqual(try JSONDecoder().decode(RemoteCameraStatus.self, from: JSONEncoder().encode(current)), current)
    }
    func testLocalShutterAndNetworkCommandsShareRecordingGeneration() {
        var status = RemoteCameraStatus(phase: .ready)
        let delayedNetworkStart = RemoteCameraCommand(action: .start, revision: status.revision, recordingID: nil)
        var gate = RemoteCameraCommandGate()
        let localStart = RemoteCameraCommand(action: status.hardwareShutterAction!, revision: status.revision, recordingID: nil)
        XCTAssertTrue(gate.accept(localStart, status: status, now: 100))
        status.phase = .starting
        status.revision = UUID()
        status.recordingID = UUID()
        XCTAssertNil(status.hardwareShutterAction)
        XCTAssertFalse(gate.accept(delayedNetworkStart, status: status))
        status.phase = .recording
        let stop = RemoteCameraCommand(action: status.hardwareShutterAction!, revision: status.revision, recordingID: status.recordingID)
        XCTAssertTrue(gate.accept(stop, status: status, now: 103))
        status.phase = .saving
        XCTAssertNil(status.hardwareShutterAction)
        XCTAssertFalse(gate.accept(stop, status: status))
        status.phase = .recording
        status.recordingID = UUID()
        let delayedStop = RemoteCameraCommand(action: .stop, revision: stop.revision, recordingID: stop.recordingID)
        XCTAssertFalse(gate.accept(delayedStop, status: status))
        for phase in [RemoteCameraPhase.unavailable, .starting, .saving, .error] {
            status.phase = phase
            XCTAssertNil(status.hardwareShutterAction)
        }
    }

    func testRapidToggleBurstCreatesOnlyOneRecordingAndRejectedRetriesStayRejected() throws {
        var gate = RemoteCameraCommandGate()
        var status = RemoteCameraStatus(phase: .ready)
        var starts = 0
        var stops = 0
        func startCommand() -> RemoteCameraCommand {
            RemoteCameraCommand(action: .start, revision: status.revision, recordingID: nil)
        }
        if gate.accept(startCommand(), status: status, now: 100) { starts += 1 }
        status.phase = .starting
        status.recordingID = UUID()
        status.revision = UUID()
        // Slow capture acknowledgement starts a fresh full three-second guard.
        gate.confirmedTransition(at: 110)
        status.phase = .recording
        let earlyStop = RemoteCameraCommand(action: .stop, revision: status.revision, recordingID: status.recordingID)
        XCTAssertFalse(gate.accept(earlyStop, status: status, now: 110.1))
        XCTAssertFalse(gate.accept(RemoteCameraCommand(action: .stop, revision: status.revision,
            recordingID: status.recordingID), status: status, now: 112.999))
        XCTAssertFalse(gate.accept(earlyStop, status: status, now: 113))
        let stop = RemoteCameraCommand(action: .stop, revision: status.revision, recordingID: status.recordingID)
        if gate.accept(stop, status: status, now: 113) { stops += 1 }
        status.phase = .saving
        XCTAssertFalse(gate.accept(stop, status: status, now: 113.1))
        // Finalization may also be slow. READY still carries a fresh guard.
        gate.confirmedTransition(at: 130)
        status = RemoteCameraStatus(phase: .ready)
        let accidentalRestart = startCommand()
        XCTAssertFalse(gate.accept(accidentalRestart, status: status, now: 130.1))
        XCTAssertFalse(gate.accept(startCommand(), status: status, now: 132.999))
        XCTAssertFalse(gate.accept(accidentalRestart, status: status, now: 133))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(gate.accept(startCommand(), status: status, now: 133))
        status.controlLockRemaining = 3
        XCTAssertEqual(try JSONDecoder().decode(RemoteCameraStatus.self,
            from: JSONEncoder().encode(status)).controlLockRemaining, 3)
        let old = RemoteCameraStatus(phase: .ready)
        XCTAssertNil(try JSONDecoder().decode(RemoteCameraStatus.self,
            from: JSONEncoder().encode(old)).controlLockRemaining)
    }
    func testRemoteCooldownUsesRelativeTimeAndCannotBeShortenedByOldStatus() {
        var cooldown = RemoteCameraCommandCooldown()
        cooldown.begin(at: 10)
        cooldown.extend(by: 0, at: 11)
        XCTAssertEqual(cooldown.remaining(at: 11), 2)
        cooldown.extend(by: 30, at: 12)
        XCTAssertEqual(cooldown.remaining(at: 14), 1)
        XCTAssertEqual(cooldown.remaining(at: 15), 0)
        cooldown.extend(by: .nan, at: 18)
        XCTAssertEqual(cooldown.remaining(at: 18), 0)
    }

    func testEnhancedStabilizationPreferenceAndSupportedFallbacks() {
        if #available(iOS 18.0, *) {
            XCTAssertEqual(RemoteCameraCapture.stabilizationMode(enabled: true, supports: { _ in true }), .cinematicExtendedEnhanced)
        }
        XCTAssertEqual(RemoteCameraCapture.stabilizationMode(enabled: true, supports: { [.standard, .cinematic, .cinematicExtended].contains($0) }), .cinematicExtended)
        XCTAssertEqual(RemoteCameraCapture.stabilizationMode(enabled: true, supports: { [.standard, .cinematic].contains($0) }), .cinematic)
        XCTAssertEqual(RemoteCameraCapture.stabilizationMode(enabled: true, supports: { $0 == .standard }), .standard)
        XCTAssertNil(RemoteCameraCapture.stabilizationMode(enabled: true, supports: { _ in false }))
        XCTAssertEqual(RemoteCameraCapture.stabilizationMode(enabled: false, supports: { _ in false }), .off)
    }
    func testAutoFPSRespectsRequestedCeilingAndHardwareSupport() {
        XCTAssertTrue(RemoteCameraCapture.automaticFrameRateEligible(fps: 30, formatMaximumFPS: 30, supported: true))
        XCTAssertTrue(RemoteCameraCapture.automaticFrameRateEligible(fps: 60, formatMaximumFPS: 60, supported: true))
        XCTAssertFalse(RemoteCameraCapture.automaticFrameRateEligible(fps: 30, formatMaximumFPS: 60, supported: true))
        XCTAssertFalse(RemoteCameraCapture.automaticFrameRateEligible(fps: 60, formatMaximumFPS: 120, supported: true))
        XCTAssertFalse(RemoteCameraCapture.automaticFrameRateEligible(fps: 24, formatMaximumFPS: 30, supported: true))
        XCTAssertFalse(RemoteCameraCapture.automaticFrameRateEligible(fps: 30, formatMaximumFPS: 30, supported: false))
    }
    func testVariableFPSFileValidationRequiresActualAutomaticCapture() {
        for actual in [23.976, 24, 27.4, 29.97, 30] {
            XCTAssertTrue(RemoteCameraCapture.recordedFrameRateMatches(actual, requested: 30, automatic: true))
        }
        for actual in [0, 15, 31, 60, Double.nan, Double.infinity] {
            XCTAssertFalse(RemoteCameraCapture.recordedFrameRateMatches(actual, requested: 30, automatic: true))
        }
        XCTAssertFalse(RemoteCameraCapture.recordedFrameRateMatches(24, requested: 30, automatic: false))
        XCTAssertTrue(RemoteCameraCapture.recordedFrameRateMatches(29.97, requested: 30, automatic: false))
        XCTAssertTrue(RemoteCameraCapture.recordedFrameRateMatches(47.5, requested: 60, automatic: true))
        XCTAssertFalse(RemoteCameraCapture.recordedFrameRateMatches(30, requested: 24, automatic: true))
    }

    func testDefaultIs4K30WithStabilizationAndSettingsRoundTrip() throws {
        let settings = RemoteCameraSettings()
        XCTAssertEqual(settings.lens, "ultra")
        XCTAssertEqual(settings.resolution, 2160)
        XCTAssertEqual(settings.fps, 30)
        XCTAssertTrue(settings.stabilization)
        XCTAssertFalse(settings.hdr)
        XCTAssertEqual(try JSONDecoder().decode(RemoteCameraSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testHDRMigrationPreservesLegacySettingsAndNewStatusRoundTrips() throws {
        let legacy = Data(#"{"lens":"tele","resolution":1080,"fps":60,"stabilization":false,"orientation":"portrait","audio":false,"codec":"h264"}"#.utf8)
        var value = try JSONDecoder().decode(RemoteCameraSettings.self, from: legacy)
        XCTAssertFalse(value.hdr)
        XCTAssertEqual(value.lens, "tele")
        XCTAssertEqual(value.resolution, 1080)
        XCTAssertEqual(value.fps, 60)
        XCTAssertFalse(value.stabilization)
        XCTAssertEqual(value.orientation, "portrait")
        XCTAssertFalse(value.audio)
        XCTAssertEqual(value.codec, "h264")
        value.hdr = true
        value.codec = "hevc"
        let status = RemoteCameraStatus(settings: value)
        let restored = try JSONDecoder().decode(RemoteCameraStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(restored, status)
        XCTAssertTrue(restored.settings.summary.contains("HDR"))
    }
    func testHDRRequiresTenBitHLGAndHEVCAndSDRRejectsHDRFormats() {
        var settings = RemoteCameraSettings()
        let eight = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let ten = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        XCTAssertTrue(RemoteCameraCapture.supportsDynamicRange(settings, pixelFormat: eight, colorSpaces: [.sRGB]))
        XCTAssertFalse(RemoteCameraCapture.supportsDynamicRange(settings, pixelFormat: ten, colorSpaces: [.HLG_BT2020]))
        settings.hdr = true
        XCTAssertTrue(RemoteCameraCapture.supportsDynamicRange(settings, pixelFormat: ten, colorSpaces: [.HLG_BT2020]))
        XCTAssertFalse(RemoteCameraCapture.supportsDynamicRange(settings, pixelFormat: eight, colorSpaces: [.sRGB]))
        XCTAssertFalse(RemoteCameraCapture.supportsDynamicRange(settings, pixelFormat: ten, colorSpaces: [.sRGB]))
        settings.codec = "h264"
        XCTAssertFalse(RemoteCameraCapture.supportsDynamicRange(settings, pixelFormat: ten, colorSpaces: [.HLG_BT2020]))
    }
    func testDefaultLensChecksHardwareAndMigratesOnlyLegacyDefaultsOnce() {
        XCTAssertEqual(RemoteCameraSettings.initial(saved: nil, availableLenses: ["ultra", "wide"], migrateLegacyDefault: true).lens, "ultra")
        XCTAssertEqual(RemoteCameraSettings.initial(saved: nil, availableLenses: ["wide", "front"], migrateLegacyDefault: true).lens, "wide")
        var saved = RemoteCameraSettings()
        saved.lens = "wide"
        XCTAssertEqual(RemoteCameraSettings.initial(saved: saved, availableLenses: ["ultra", "wide"], migrateLegacyDefault: true).lens, "ultra")
        XCTAssertEqual(RemoteCameraSettings.initial(saved: saved, availableLenses: ["ultra", "wide"], migrateLegacyDefault: false), saved)
        saved.fps = 60
        XCTAssertEqual(RemoteCameraSettings.initial(saved: saved, availableLenses: ["ultra", "wide"], migrateLegacyDefault: true), saved)
        XCTAssertEqual(RemoteCameraSettings.lensTitle("wide"), "1×")
        XCTAssertEqual(RemoteCameraSettings.lensTitle("ultra"), "0.5×")
        XCTAssertEqual(RemoteCameraSettings.lensTitle("tele", zoom: 5), "5×")
        XCTAssertEqual(RemoteCameraSettings.lensTitle("tele", zoom: 2.5), "2.5×")
    }
    func testStartCannotExecuteTwiceOrAfterReadyGenerationChanges() {
        var status = RemoteCameraStatus(phase: .ready)
        var gate = RemoteCameraCommandGate()
        let start = RemoteCameraCommand(action: .start, revision: status.revision, recordingID: nil)
        XCTAssertTrue(gate.accept(start, status: status, now: 100))
        XCTAssertFalse(gate.accept(start, status: status, now: 106))
        status.revision = UUID()
        let delayed = RemoteCameraCommand(action: .start, revision: start.revision, recordingID: nil)
        XCTAssertFalse(gate.accept(delayed, status: status, now: 107))
    }
    func testStartRejectedInEveryNonReadyState() {
        for phase: RemoteCameraPhase in [.unavailable, .starting, .recording, .saving, .error] {
            let status = RemoteCameraStatus(phase: phase)
            var gate = RemoteCameraCommandGate()
            XCTAssertFalse(gate.accept(RemoteCameraCommand(action: .start, revision: status.revision, recordingID: nil), status: status))
        }
    }
    func testStopOnlyTargetsCurrentRecordingAndIsIdempotent() {
        let id = UUID()
        let status = RemoteCameraStatus(phase: .recording, recordingID: id)
        var gate = RemoteCameraCommandGate()
        let oldStop = RemoteCameraCommand(action: .stop, revision: UUID(), recordingID: UUID())
        XCTAssertFalse(gate.accept(oldStop, status: status, now: 100))
        let stop = RemoteCameraCommand(action: .stop, revision: UUID(), recordingID: id)
        XCTAssertTrue(gate.accept(stop, status: status, now: 101))
        XCTAssertFalse(gate.accept(stop, status: status, now: 107))
        let later = RemoteCameraStatus(phase: .recording, recordingID: UUID())
        XCTAssertFalse(gate.accept(RemoteCameraCommand(action: .stop, revision: later.revision, recordingID: id), status: later, now: 108))
    }
    func testEvictedCommandStillCannotRestartNewGeneration() {
        var gate = RemoteCameraCommandGate()
        let original = RemoteCameraStatus(phase: .ready)
        let old = RemoteCameraCommand(action: .start, revision: original.revision, recordingID: nil)
        XCTAssertTrue(gate.accept(old, status: original, now: 100))
        let next = RemoteCameraStatus(phase: .ready)
        for _ in 0..<300 {
            _ = gate.accept(RemoteCameraCommand(action: .stop, revision: UUID(), recordingID: UUID()), status: next, now: 106)
        }
        XCTAssertEqual(gate.handled.count, 256)
        XCTAssertFalse(gate.accept(old, status: next, now: 106))
    }
    func testSignedPacketsRejectPayloadChangesAndImpersonation() throws {
        let key = Curve25519.Signing.PrivateKey()
        let packet = RemoteCameraPacket(kind: "query", publicKey: key.publicKey.rawRepresentation, nonce: UUID(), sequence: 1)
        let signed = try RemoteCameraEnvelope(packet: packet, key: key)
        XCTAssertEqual(try signed.verifiedPacket().nonce, packet.nonce)
        let attacker = Curve25519.Signing.PrivateKey()
        let forged = try RemoteCameraEnvelope(packet: packet, key: attacker)
        XCTAssertThrowsError(try forged.verifiedPacket())
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signed)) as! [String: Any]
        encoded["payload"] = Data("changed".utf8).base64EncodedString()
        let changed = try JSONDecoder().decode(RemoteCameraEnvelope.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertThrowsError(try changed.verifiedPacket())
    }
    func testReplayWindowRejectsOldConnectionAndOutOfOrderPackets() {
        let nonce = UUID()
        var window = RemoteCameraReplayWindow(nonce: nonce)
        XCTAssertTrue(window.accept(nonce: nonce, sequence: 2))
        XCTAssertFalse(window.accept(nonce: nonce, sequence: 2))
        XCTAssertFalse(window.accept(nonce: nonce, sequence: 1))
        XCTAssertFalse(window.accept(nonce: UUID(), sequence: 100))
        XCTAssertTrue(window.accept(nonce: nonce, sequence: 3))
    }
    func testAuthenticatedEncryptionRejectsTamperingAndOtherSessions() throws {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let ab = try a.sharedSecretFromKeyAgreement(with: b.publicKey)
        let ba = try b.sharedSecretFromKeyAgreement(with: a.publicKey)
        let salt = Data(UUID().uuidString.utf8)
        let info = Data("Speedometer Remote Camera v1".utf8)
        let k1 = ab.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let k2 = ba.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data("status".utf8), using: k1)
        XCTAssertEqual(try AES.GCM.open(sealed, using: k2), Data("status".utf8))
        XCTAssertThrowsError(try AES.GCM.open(sealed, using: SymmetricKey(size: .bits256)))
        var changed = sealed.combined!
        changed[changed.count - 1] ^= 1
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: changed), using: k2))
    }
    func testPairingCodeAgreesOnBothPhonesButBindsBothIdentitiesAndNonces() {
        let a = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let b = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let n1 = UUID(), n2 = UUID()
        let code = RemoteCameraEnvelope.verificationCode(keyA: a, nonceA: n1, keyB: b, nonceB: n2)
        XCTAssertEqual(code, RemoteCameraEnvelope.verificationCode(keyA: b, nonceA: n2, keyB: a, nonceB: n1))
        XCTAssertNotEqual(code, RemoteCameraEnvelope.verificationCode(keyA: a, nonceA: UUID(), keyB: b, nonceB: n2))
        XCTAssertNotEqual(code, RemoteCameraEnvelope.verificationCode(keyA: b, nonceA: n1, keyB: b, nonceB: n2))
        XCTAssertEqual(code.count, 19)
    }
    func testPlayableAutomaticStopStillReportsItsCause() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue,
                            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true])
        XCTAssertEqual(RemoteCameraCapture.recordingWarning(error), "rc_error_storage")
        XCTAssertEqual(RemoteCameraCapture.recordingWarning(NSError(domain: AVFoundationErrorDomain,
            code: AVError.Code.mediaServicesWereReset.rawValue)), "rc_error_interrupted")
        XCTAssertNil(RemoteCameraCapture.recordingWarning(nil))
    }
    func testSimulatorNeverClaimsCaptureSupport() {
#if targetEnvironment(simulator)
        XCTAssertNotNil(RemoteCameraCapture.validationError(RemoteCameraSettings()))
#endif
    }
}

final class RemoteCameraExternalButtonTests: XCTestCase {
    @MainActor
    func testLearningDeadlineRejectsLateEventsAndRetryStartsFresh() throws {
        let suite = "camera-learning-timeout-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = RemoteCameraExternalInput(defaults: defaults, fixture: true)
        input.setCameraMode(true)
        input.available = true
        var actions: [CameraButtonAction] = []
        input.onAction = { actions.append($0) }
        input.beginLearning()
        let deadline = try XCTUnwrap(input.learningDeadline)
        input.updateLearningCountdown(at: deadline - 2.2)
        XCTAssertEqual(input.learningSecondsRemaining, 3)
        input.updateLearningCountdown(at: deadline)
        XCTAssertTrue(input.timedOut)
        XCTAssertEqual(input.learningSecondsRemaining, 0)
        input.receiveCapture("primary", mayRecord: true)
        input.receiveUIKit(code: 44, pressed: true)
        input.receiveUIKit(code: 44, pressed: false)
        XCTAssertNil(input.candidate, "Expired attempts must wait for explicit retry")
        input.listenAgain()
        XCTAssertFalse(input.timedOut)
        XCTAssertEqual(input.learningSecondsRemaining, 15)
        input.pauseLearningTimeout()
        input.receiveCapture("secondary", mayRecord: true)
        XCTAssertNil(input.candidate, "Camera preparation must not accept events or consume the wait window")
        input.listenAgain()
        input.receiveCapture("secondary", mayRecord: true)
        XCTAssertEqual(input.candidate?.code, "secondary")
        XCTAssertNil(input.learningDeadline)
        XCTAssertTrue(actions.isEmpty)
        input.cancelLearning()
        input.listenAgain()
        XCTAssertNil(input.learningDeadline, "A dismissed sheet must not restart its timer")
    }
    @MainActor
    func testNativeCameraLearningDoesNotRecordAndPreferencesAreRoleScoped() {
        let suite = "native-buttons-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = RemoteCameraExternalInput(defaults: defaults, fixture: true)
        input.available = true
        input.setCameraMode(true)
        XCTAssertTrue(input.preferences.enabled)
        XCTAssertEqual(input.preferences.bindings.count, 2)
        var actions: [CameraButtonAction] = []
        input.onAction = { actions.append($0) }
        input.receiveCapture("primary", mayRecord: true)
        XCTAssertEqual(actions, [.toggle])
        input.receiveCapture("secondary", mayRecord: false)
        XCTAssertEqual(actions.count, 1)
        input.beginLearning(input.preferences.bindings[0])
        XCTAssertNil(input.candidate) // existing mapping is not proof of a press
        input.receiveCapture("primary", mayRecord: true)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(input.candidate?.diagnosticCode, "ID: AVCaptureEvent.primary")
        XCTAssertNil(input.candidate?.hexCode)
        input.selectedAction = .stop
        input.saveLearning()
        let restored = RemoteCameraExternalInput(defaults: defaults, fixture: true)
        restored.setCameraMode(true)
        XCTAssertEqual(restored.preferences.bindings.first(where: { $0.id == "capture:primary" })?.action, .stop)
        restored.available = true
        restored.onAction = { actions.append($0) }
        restored.receiveCapture("primary", mayRecord: true)
        XCTAssertEqual(actions.last, .stop)
        restored.setCameraMode(false)
        XCTAssertFalse(restored.preferences.enabled)
        XCTAssertTrue(restored.preferences.bindings.isEmpty)
        restored.receiveCapture("primary", mayRecord: true)
        XCTAssertEqual(actions.count, 2)
    }

    func testKeyboardHexUsesTheActualUsageAndDoesNotInventControllerBytes() throws {
        let key = CameraExternalButton(family: "keyboard", code: "128", name: "Key")
        XCTAssertEqual(key.hexCode, "0x0080")
        XCTAssertEqual(key.diagnosticCode, "HID 0x0007 · HEX 0x0080")
        XCTAssertEqual(try JSONDecoder().decode(CameraExternalButton.self,
            from: JSONEncoder().encode(key)).id, "keyboard:128")
        XCTAssertNil(CameraExternalButton(family: "controller:gamepad", code: "Button A", name: "A").hexCode)
        XCTAssertNil(CameraExternalButton(family: "keyboard", code: "-1", name: "Invalid").hexCode)
    }

    @MainActor
    func testUIKitLearningSurfaceReceivesKeysWithoutDispatchAndReleasesFocus() throws {
        let suite = "camera-uikit-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = RemoteCameraExternalInput(defaults: defaults, fixture: true)
        input.available = true
        input.setEnabled(true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        let view = ExternalButtonSurfaceView(frame: controller.view.bounds)
        view.isLearningSurface = true
        controller.view.addSubview(view)
        let id = UUID()
        input.register(view, id: id)
        input.beginLearning()
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(view.isEligible)
        XCTAssertTrue(view.isFirstResponder)
        var commands = 0
        input.onAction = { _ in commands += 1 }
        input.receiveUIKit(code: 128, pressed: true)
        XCTAssertEqual(input.candidate?.hexCode, "0x0080")
        XCTAssertFalse(input.devices.isEmpty)
        input.receiveUIKit(code: 128, pressed: true)
        input.receiveUIKit(code: 128, pressed: false)
        input.saveLearning()
        XCTAssertFalse(view.isFirstResponder)
        input.receiveUIKit(code: 128, pressed: true)
        XCTAssertEqual(commands, 0, "A learning surface must never qualify as the map action surface")
        input.available = false
        input.beginLearning()
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertNil(input.candidate)
        input.unregister(id)
    }

    @MainActor
    func testUIKitMapDispatchesOnceAndRejectsCoveredOrDisabledInput() async throws {
        let suite = "camera-uikit-map-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = RemoteCameraExternalInput(defaults: defaults, fixture: true)
        input.available = true
        input.setEnabled(true)
        input.beginLearning()
        input.receiveUIKit(code: 44, pressed: true)
        input.receiveUIKit(code: 44, pressed: false)
        input.saveLearning()
        try await Task.sleep(nanoseconds: 600_000_000)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let surface = ExternalButtonSurfaceView(frame: controller.view.bounds)
        controller.view.addSubview(surface)
        let id = UUID()
        input.register(surface, id: id)
        var actions: [CameraButtonAction] = []
        input.onAction = { actions.append($0) }
        input.receiveUIKit(code: 44, pressed: true)
        input.receiveUIKit(code: 44, pressed: true)
        XCTAssertEqual(actions, [.toggle])
        input.receiveUIKit(code: 44, pressed: false)
        let sheet = UIViewController()
        controller.present(sheet, animated: false)
        input.receiveUIKit(code: 44, pressed: true)
        input.receiveUIKit(code: 44, pressed: false)
        XCTAssertEqual(actions, [.toggle])
        controller.dismiss(animated: false)
        input.setEnabled(false)
        input.receiveUIKit(code: 44, pressed: true)
        XCTAssertEqual(actions, [.toggle])
        XCTAssertFalse(surface.isFirstResponder)
        input.unregister(id)
    }

    func testExternalButtonsDefaultOffAndAssignmentsAreUniqueAndPortable() throws {
        var prefs = CameraButtonPreferences()
        XCTAssertFalse(prefs.enabled)
        let key = CameraExternalButton(family: "keyboard", code: "44", name: "Space")
        prefs.assign(key, to: .start)
        prefs.assign(key, to: .toggle)
        XCTAssertEqual(prefs.bindings.count, 1)
        XCTAssertEqual(prefs.bindings.first?.action, .toggle)
        let other = CameraExternalButton(family: "keyboard", code: "40", name: "Return")
        prefs.assign(other, to: .stop)
        let restored = try JSONDecoder().decode(CameraButtonPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored.bindings.map(\.id), [key.id, other.id])
        prefs.assign(other, to: .start, replacing: key.id)
        XCTAssertEqual(prefs.bindings.count, 1)
        XCTAssertEqual(prefs.bindings.first?.action, .start)
    }
    func testToggleOnlyUsesFreshAuthoritativeIdleOrRecordingState() {
        XCTAssertEqual(CameraButtonAction.toggle.command(phase: .ready, fresh: true, pending: false), .start)
        XCTAssertEqual(CameraButtonAction.toggle.command(phase: .recording, fresh: true, pending: false), .stop)
        for phase in [RemoteCameraPhase.unavailable, .starting, .saving, .error] {
            XCTAssertNil(CameraButtonAction.toggle.command(phase: phase, fresh: true, pending: false))
        }
        XCTAssertNil(CameraButtonAction.toggle.command(phase: .ready, fresh: false, pending: false))
        XCTAssertNil(CameraButtonAction.toggle.command(phase: .recording, fresh: true, pending: true))
        XCTAssertNil(CameraButtonAction.start.command(phase: .recording, fresh: true, pending: false))
        XCTAssertNil(CameraButtonAction.stop.command(phase: .ready, fresh: true, pending: false))
    }
    func testHeldKeysAndReleasesDoNotRepeatCommands() {
        var gate = CameraButtonPressGate()
        XCTAssertFalse(gate.change("key", pressed: false))
        XCTAssertTrue(gate.change("key", pressed: true))
        XCTAssertFalse(gate.change("key", pressed: true))
        XCTAssertFalse(gate.change("key", pressed: false))
        XCTAssertTrue(gate.change("key", pressed: true))
        XCTAssertTrue(gate.change("other-device:key", pressed: true))
    }
    @MainActor
    func testLearningRequiresExplicitSaveAndNeverDispatches() {
        let suite = "camera-buttons-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = RemoteCameraExternalInput(defaults: defaults, fixture: true)
        input.available = true
        let key = CameraExternalButton(family: "keyboard", code: "44", name: "Space")
        var commands = 0
        input.onAction = { _ in commands += 1 }
        input.beginLearning()
        XCTAssertFalse(input.learning) // opt-in is required
        input.setEnabled(true)
        input.beginLearning()
        input.receive(key, source: "fixture", pressed: true)
        XCTAssertEqual(input.candidate, key)
        XCTAssertTrue(input.preferences.bindings.isEmpty)
        input.cancelLearning()
        XCTAssertTrue(input.preferences.bindings.isEmpty)
        input.receive(key, source: "fixture", pressed: false)
        input.beginLearning()
        input.receive(key, source: "fixture", pressed: true)
        input.selectedAction = .stop
        input.saveLearning()
        XCTAssertEqual(input.preferences.bindings.first?.action, .stop)
        XCTAssertEqual(commands, 0)
        let restored = RemoteCameraExternalInput(defaults: defaults, fixture: true)
        XCTAssertTrue(restored.preferences.enabled)
        XCTAssertEqual(restored.preferences.bindings.first?.button, key)
        input.available = false
        input.beginLearning()
        XCTAssertFalse(input.learning)
        input.setEnabled(false)
        XCTAssertEqual(input.preferences.bindings.count, 1) // disabling preserves mappings
    }
}

final class RemoteCameraSoundTests: XCTestCase {
    func testSoundLevelsMigrateIndependentlyAndReachThePlayer() throws {
        var preferences = try JSONDecoder().decode(RemoteCameraSoundPreferences.self,
            from: Data(#"{"start":false,"stop":true}"#.utf8))
        XCTAssertFalse(preferences.start)
        XCTAssertTrue(preferences.stop)
        XCTAssertEqual(preferences.volume(for: .start), 0.3)
        XCTAssertEqual(preferences.volume(for: .stop), 0.3)
        preferences.startVolume = 1
        preferences.stopVolume = 0.02
        let restored = try JSONDecoder().decode(RemoteCameraSoundPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(try RemoteCameraSounds.makePlayer(.start, volume: restored.volume(for: .start)).volume, 1)
        XCTAssertEqual(try RemoteCameraSounds.makePlayer(.stop, volume: restored.volume(for: .stop)).volume, 0.02)
        preferences.stopVolume = 0
        XCTAssertEqual(try RemoteCameraSounds.makePlayer(.stop, volume: preferences.volume(for: .stop)).volume, 0)
        XCTAssertEqual(preferences.volume(for: .start), 1)
        XCTAssertEqual(RemoteCameraSoundPreferences(startVolume: -2, stopVolume: 3).volume(for: .start), 0)
        XCTAssertEqual(RemoteCameraSoundPreferences(startVolume: -2, stopVolume: 3).volume(for: .stop), 1)
        XCTAssertEqual(RemoteCameraSoundPreferences(startVolume: .nan).volume(for: .start), 0.3)
    }
    func testBothSoundsDefaultOnAndCanBeDisabledIndependently() throws {
        var preferences = RemoteCameraSoundPreferences()
        XCTAssertTrue(preferences.allows(.start))
        XCTAssertTrue(preferences.allows(.stop))
        preferences.start = false
        XCTAssertFalse(preferences.allows(.start))
        XCTAssertTrue(preferences.allows(.stop))
        XCTAssertEqual(try JSONDecoder().decode(RemoteCameraSoundPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }
    func testOnlyConfirmedRecordingAndSavedFileSoundOnce() {
        var gate = RemoteCameraSoundGate()
        var status = RemoteCameraStatus(phase: .ready)
        XCTAssertTrue(gate.observe(status).isEmpty)
        status.phase = .starting
        let id = UUID()
        status.recordingID = id
        XCTAssertTrue(gate.observe(status).isEmpty)
        status.phase = .recording
        XCTAssertEqual(gate.observe(status), [.start])
        status.revision = UUID()
        XCTAssertTrue(gate.observe(status).isEmpty)
        status.phase = .saving
        XCTAssertTrue(gate.observe(status).isEmpty)
        status.phase = .ready
        status.recordingID = nil
        status.lastSavedRecordingID = id
        XCTAssertEqual(gate.observe(status), [.stop])
        XCTAssertTrue(gate.observe(status).isEmpty)
    }
    func testReconnectAndFailureAreNotSuccessSounds() {
        var gate = RemoteCameraSoundGate()
        var status = RemoteCameraStatus(phase: .recording, recordingID: UUID())
        XCTAssertTrue(gate.observe(status).isEmpty)
        status.phase = .error
        XCTAssertTrue(gate.observe(status).isEmpty)
        status.phase = .recording
        XCTAssertTrue(gate.observe(status, baseline: true).isEmpty)
        XCTAssertTrue(gate.observe(status).isEmpty)
        gate.reset()
        status.phase = .ready
        status.lastSavedRecordingID = status.recordingID
        status.recordingID = nil
        XCTAssertTrue(gate.observe(status).isEmpty)
    }
    func testFinishingAnyToneKeepsCaptureAudioActive() {
        var leases = AppAudioLeases()
        let camera = UUID(), startSound = UUID(), speedAlert = UUID()
        leases.insert(camera, capture: true)
        leases.insert(startSound, capture: false)
        leases.insert(speedAlert, capture: false)
        XCTAssertEqual(leases.mode, .capture)
        leases.remove(startSound)
        leases.remove(startSound) // duplicate completion cannot deactivate other owners
        XCTAssertEqual(leases.mode, .capture)
        leases.remove(camera)
        XCTAssertEqual(leases.mode, .playback)
        leases.remove(speedAlert)
        XCTAssertEqual(leases.mode, .inactive)
    }
    func testGeneratedConfirmationTonesDecodeAsDistinctShortAudio() throws {
        let start = RemoteCameraTone.data(.start), stop = RemoteCameraTone.data(.stop)
        XCTAssertNotEqual(start, stop)
        for data in [start, stop] {
            let player = try AVAudioPlayer(data: data)
            XCTAssertEqual(player.duration, 0.48, accuracy: 0.001)
            XCTAssertEqual(player.numberOfChannels, 1)
            // Inspect the actual PCM: audible gain without digital clipping,
            // with a quiet gap so the two notes remain distinguishable.
            let samples = stride(from: 44, to: data.count, by: 2).map {
                Double(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)) / 32768
            }
            XCTAssertGreaterThan(samples.map { abs($0) }.max()!, 0.79)
            XCTAssertLessThan(samples.map { abs($0) }.max()!, 0.81)
            XCTAssertTrue(samples[Int(0.225 * 44100)..<Int(0.255 * 44100)].allSatisfy { $0 == 0 })
        }
    }
}

final class RemoteCameraConnectionProgressTests: XCTestCase {
    func testDiscoveryAndTransportAreNeverShownAsAuthenticated() {
        typealias Progress = RemoteCameraConnectionProgress
        XCTAssertEqual(Progress.resolve(active: true, canDiscover: true, candidate: false, remoteKey: false, localApproved: false, authenticated: false), .discovering)
        XCTAssertEqual(Progress.resolve(active: true, canDiscover: true, candidate: true, remoteKey: false, localApproved: false, authenticated: false), .connecting)
        XCTAssertEqual(Progress.resolve(active: true, canDiscover: true, candidate: true, remoteKey: true, localApproved: false, authenticated: false), .verifying)
        XCTAssertEqual(Progress.resolve(active: true, canDiscover: true, candidate: true, remoteKey: true, localApproved: true, authenticated: false), .awaitingApproval)
        XCTAssertEqual(Progress.resolve(active: true, canDiscover: false, candidate: true, remoteKey: true, localApproved: true, authenticated: true), .connected)
        XCTAssertFalse(Progress.connected.isBusy)
    }
    func testCancellationAndExpiredDiscoveryDoNotKeepSpinnerAlive() {
        typealias Progress = RemoteCameraConnectionProgress
        XCTAssertEqual(Progress.resolve(active: false, canDiscover: true, candidate: true, remoteKey: true, localApproved: true, authenticated: true), .idle)
        XCTAssertEqual(Progress.resolve(active: true, canDiscover: false, candidate: false, remoteKey: false, localApproved: false, authenticated: false), .idle)
        XCTAssertFalse(Progress.idle.isBusy)
        XCTAssertTrue(Progress.awaitingApproval.isBusy)
        XCTAssertEqual(Progress.discovering.titleKey(role: .camera, trusted: false), "rc_wait_remote")
        XCTAssertEqual(Progress.discovering.titleKey(role: .remote, trusted: false), "rc_search_camera")
        XCTAssertEqual(Progress.discovering.titleKey(role: .remote, trusted: true), "rc_reconnecting")
        XCTAssertEqual(Progress.idle.titleKey(role: .remote, trusted: true), "rc_not_connected")
    }
}
