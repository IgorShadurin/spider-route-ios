import XCTest

final class RemoteCameraUITests: XCTestCase {
    func testMapCooldownDisablesBothActionsThenUnlocksInBothLayouts() {
        for (state, locale, scheme) in [("map.camera-ready", "ru", "light"),
                                        ("map.camera-recording", "en-US", "dark"),
                                        ("map.camera-fullscreen-ready", "es", "light"),
                                        ("map.camera-fullscreen-recording", "ar", "dark")] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=" + state, "--ui-locale=" + locale, "--ui-scheme=" + scheme, "--ui-camera-cooldown"]
            app.launch()
            let actions = app.buttons.matching(identifier: state.contains("recording") ? "camera.remote.stop" : "camera.remote.start")
            XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 5))
            let action = actions.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? actions.firstMatch
            XCTAssertFalse(action.isEnabled)
            XCTAssertTrue((action.value as? String ?? "").contains("0:0"))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "cooldown-" + state
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(NSPredicate(format: "enabled == true").evaluate(with: action)
                || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: action)], timeout: 5) == .completed)
            XCTAssertFalse((action.value as? String ?? "").contains("0:0"))
            app.terminate()
        }
    }
    func testSoundLevelsLocalizedLayout() {
        for locale in ["ru", "ar"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=settings.camera", "--ui-locale=" + locale, "--ui-scheme=" + (locale == "ru" ? "light" : "dark")]
            app.launch()
            let stop = app.sliders["camera.sound.volume.stop"]
            let list = app.collectionViews["screen.camera.settings"].exists
                ? app.collectionViews["screen.camera.settings"] : app.tables["screen.camera.settings"]
            for _ in 0..<8 {
                if stop.isHittable { break }
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
            }
            XCTAssertTrue(app.sliders["camera.sound.volume.start"].isHittable)
            XCTAssertTrue(stop.isHittable)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "sound-levels-" + locale
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
    func testStartAndStopSoundLevelsAreIndependentInBothRoles() {
        for role in ["camera", "remote"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=settings.camera", "--ui-locale=en-US", "--ui-scheme=light", "--ui-camera-role=" + role]
            app.launch()
            let start = app.sliders["camera.sound.volume.start"]
            let stop = app.sliders["camera.sound.volume.stop"]
            for _ in 0..<8 {
                if stop.exists, stop.frame.maxY < app.frame.height - 100 { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
            }
            XCTAssertEqual(app.staticTexts["camera.sound.level.start"].label, "30%")
            XCTAssertEqual(app.staticTexts["camera.sound.level.stop"].label, "30%")
            let initial = XCTAttachment(screenshot: app.screenshot())
            initial.name = "sound-levels-" + role
            initial.lifetime = .keepAlways
            add(initial)
            start.adjust(toNormalizedSliderPosition: 1)
            XCTAssertEqual(app.staticTexts["camera.sound.level.start"].label, "100%")
            XCTAssertEqual(app.staticTexts["camera.sound.level.stop"].label, "30%")
            stop.adjust(toNormalizedSliderPosition: 0)
            XCTAssertEqual(app.staticTexts["camera.sound.level.stop"].label, "0%")
            XCTAssertEqual(app.staticTexts["camera.sound.level.start"].label, "100%")
            app.buttons["camera.sound.test.start"].tap()
            app.buttons["camera.sound.test.stop"].tap()
            XCTAssertEqual(app.switches["camera.sound.start"].value as? String, "1")
            XCTAssertEqual(app.switches["camera.sound.stop"].value as? String, "1")
            app.terminate()
        }
    }
    func testCameraButtonTimeoutAndRetryStatus() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=camera.button-learning", "--ui-locale=ru", "--ui-scheme=light", "--ui-camera-buttons"]
        app.launch()
        let retry = app.buttons["camera.external.listen-again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 22))
        let countdown = app.staticTexts["camera.external.countdown"]
        let status = app.staticTexts["camera.external.listen-status"]
        XCTAssertEqual(countdown.label, "0:00")
        XCTAssertEqual(status.label, "Время ожидания истекло. Повторите попытку.")
        XCTAssertFalse(app.images["camera.external.listening"].exists)
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("button-timeout")
        retry.tap()
        XCTAssertFalse(app.buttons["camera.external.save"].isEnabled)
        XCTAssertEqual(status.label, "Нажмите одну кнопку на внешнем пульте.")
        XCTAssertNotEqual(countdown.label, "0:00")
        XCTAssertTrue(app.images["camera.external.listening"].exists)
        XCTAssertFalse(retry.exists)
        capture("button-retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 18))
        XCTAssertEqual(countdown.label, "0:00")
        XCTAssertEqual(status.label, "Время ожидания истекло. Повторите попытку.")
        XCTAssertFalse(app.images["camera.external.listening"].exists)
        capture("button-timeout-again")
    }
    func testCameraRoleHasDefaultButtonsAndLearnsNativeCaptureWithoutRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=camera.button-learning", "--ui-locale=en-US", "--ui-camera-buttons", "--ui-camera-capture=primary"]
        app.launch()
        XCTAssertTrue(app.staticTexts["ID: AVCaptureEvent.primary"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["camera.external.save"].isEnabled)
        app.buttons["camera.external.save"].tap()
        XCTAssertTrue(app.buttons["camera.external.binding.capture:primary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["camera.external.enable"].value as? String, "1")
    }
    func testOrientationStaysOneLineAndCanChange() {
        for locale in ["en-US", "ru", "de", "ar"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=settings.camera", "--ui-locale=" + locale, "--ui-scheme=light"]
            app.launch()
            let orientation = app.buttons["camera.orientation"]
            for _ in 0..<6 { if orientation.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(orientation.isHittable)
            let title = app.staticTexts["camera.orientation.title"]
            let value = app.staticTexts["camera.orientation.value"]
            XCTAssertLessThan(title.frame.height, 34)
            XCTAssertLessThan(value.frame.height, 34)
            XCTAssertEqual(title.frame.midY, value.frame.midY, accuracy: 2)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "orientation-" + locale
            screenshot.lifetime = .keepAlways
            add(screenshot)
            if locale == "en-US" {
                orientation.tap()
                app.buttons["Portrait"].firstMatch.tap()
                XCTAssertTrue(orientation.label.contains("Portrait"))
            }
            app.terminate()
        }
    }

    func testAccessoryDefaultsToCameraAndCanSwitchToRemote() {
        let app = app("settings.camera")
        let picker = app.buttons["camera.accessory.device"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(picker.label.contains("Camera"))
        picker.tap()
        app.buttons["Remote control"].firstMatch.tap()
        XCTAssertTrue(picker.label.contains("Remote"))
        picker.tap()
        app.buttons.matching(identifier: "Camera").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(picker.label.contains("Camera"))
    }

    func testHDRDefaultsOffCanToggleAndExplainsUnsupportedHardware() {
        let app = app("settings.camera")
        let hdr = app.switches["camera.hdr"]
        for _ in 0..<4 { if hdr.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(hdr.isHittable)
        XCTAssertEqual(hdr.value as? String, "0")
        hdr.switches.firstMatch.tap()
        XCTAssertEqual(hdr.value as? String, "1")
        hdr.switches.firstMatch.tap()
        XCTAssertEqual(hdr.value as? String, "0")
        app.terminate()
        app.launchArguments.append("--ui-camera-hdr-unavailable")
        app.launch()
        for _ in 0..<4 { if hdr.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(hdr.value as? String, "0")
        XCTAssertFalse(hdr.isEnabled)
        XCTAssertTrue(app.staticTexts["HDR is unavailable for these camera settings."].exists)
    }
    func testGalleryStatusesAndRecoveryActionsAreVisible() {
        let app = app("camera.photos")
        XCTAssertTrue(app.staticTexts["Added to Photos"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Adding to Photos…"].exists)
        let settings = app.buttons["camera.photos.settings"].firstMatch
        for _ in 0..<3 { if settings.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(app.buttons["camera.photos.save"].firstMatch.exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Could not add to Photos. The video is safe here; retry saving."].exists)
        XCTAssertTrue(app.staticTexts["Saved in the app only"].exists)
    }
    func testLearnedButtonShowsHexAndRetainsItAfterSaving() {
        for scheme in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=camera.button-learning", "--ui-locale=en-US", "--ui-scheme=\(scheme)", "--ui-external-key=128"]
            app.launch()
            let code = app.staticTexts["camera.external.code"]
            // The iOS 18 iPad sheet can defer its nested fixture navigation.
            // Exercise the actual Settings link when that happens.
            if !code.waitForExistence(timeout: 4) {
                let link = app.buttons["camera.external.settings"]
                if link.exists { link.tap() }
            }
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            XCTAssertEqual(code.label, "HID 0x0007 · HEX 0x0080")
            XCTAssertTrue(app.buttons["camera.external.save"].isEnabled)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "External HEX \(scheme)"
            capture.lifetime = .keepAlways
            add(capture)
            app.buttons["camera.external.save"].tap()
            XCTAssertTrue(app.buttons["camera.external.binding.keyboard:128"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["HID 0x0007 · HEX 0x0080"].exists)
            app.terminate()
        }
    }

    func testExternalButtonsAreOptInAndUnrecognizedButtonCannotBeSaved() {
        let app = app("settings.camera-buttons")
        let enabled = app.switches["camera.external.enable"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 8))
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(app.buttons["camera.external.assign"].exists)
        enabled.switches.firstMatch.tap()
        XCTAssertEqual(enabled.value as? String, "1")
        let assign = app.buttons["camera.external.assign"]
        if !assign.isHittable { app.swipeUp() }
        XCTAssertTrue(assign.waitForExistence(timeout: 4))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "External buttons enabled"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        assign.tap()
        XCTAssertTrue(app.buttons["camera.external.save"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["camera.external.save"].isEnabled)
        XCTAssertTrue(app.staticTexts["Press one button on your accessory."].exists)
        let timeout = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No button event received.")).firstMatch
        XCTAssertTrue(timeout.waitForExistence(timeout: 17))
        XCTAssertFalse(app.buttons["camera.external.save"].isEnabled)
        app.buttons["camera.external.cancel"].tap()
        XCTAssertTrue(assign.waitForExistence(timeout: 3))
    }
    func testRecordingSoundsDefaultOnAndToggleIndependently() {
        let app = app("settings.camera")
        let start = app.switches["camera.sound.start"]
        let stop = app.switches["camera.sound.stop"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        XCTAssertTrue(stop.waitForExistence(timeout: 4))
        // Bring both complete rows above the bottom safe area without scrolling past them.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertEqual(start.value as? String, "1")
        XCTAssertEqual(stop.value as? String, "1")
        for id in ["camera.sound.test.start", "camera.sound.test.stop"] {
            let preview = app.buttons[id]
            for _ in 0..<3 { if preview.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(preview.isHittable)
            preview.tap()
        }
        XCTAssertEqual(start.value as? String, "1")
        XCTAssertEqual(stop.value as? String, "1")
        start.switches.firstMatch.tap()
        XCTAssertEqual(start.value as? String, "0")
        XCTAssertEqual(stop.value as? String, "1")
        stop.switches.firstMatch.tap()
        XCTAssertEqual(stop.value as? String, "0")
        start.switches.firstMatch.tap()
        XCTAssertEqual(start.value as? String, "1")
        XCTAssertEqual(stop.value as? String, "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "separate-recording-sounds"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    func testCameraConnectImmediatelyShowsWaitingAndCanBeCancelled() {
        let app = app("camera.setup")
        XCTAssertTrue(app.buttons["camera.connect"].waitForExistence(timeout: 8))
        app.buttons["camera.connect"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "camera.connection.progress").firstMatch.waitForExistence(timeout: 4))
        XCTAssertEqual(app.staticTexts["camera.connection.status"].label, "Waiting for remote phone…")
        XCTAssertFalse(app.buttons["camera.connect"].exists)
        app.buttons["camera.connection.cancel"].tap()
        XCTAssertTrue(app.buttons["camera.connect"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "camera.connection.progress").firstMatch.exists)
        app.buttons["camera.connect"].tap()
        XCTAssertTrue(app.buttons["camera.connection.cancel"].waitForExistence(timeout: 4))
    }
    func testRemoteConnectionSheetShowsSearchAndCancel() {
        let app = app("map.camera-offline")
        XCTAssertTrue(app.buttons["camera.remote.connect"].waitForExistence(timeout: 8))
        app.buttons["camera.remote.connect"].tap()
        XCTAssertTrue(app.buttons["camera.connect"].waitForExistence(timeout: 4))
        app.buttons["camera.connect"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "camera.connection.progress").firstMatch.waitForExistence(timeout: 4))
        XCTAssertEqual(app.staticTexts["camera.connection.status"].label, "Searching for camera…")
        app.buttons["camera.connection.cancel"].tap()
        XCTAssertTrue(app.buttons["camera.connect"].waitForExistence(timeout: 4))
    }
    func testPairApprovalShowsPendingUntilOtherPhoneConfirms() {
        let app = app("camera.pairing")
        let confirm = app.buttons["camera.pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "camera.pairing.progress").firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertTrue(app.staticTexts["Waiting for confirmation on the other phone…"].exists)
        app.buttons["camera.pairing.cancel"].tap()
        XCTAssertTrue(app.buttons["camera.connect"].waitForExistence(timeout: 4))
    }
    private func app(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=\(state)", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()
        return app
    }
    func testSettingsEnableAddsCameraTab() {
        let app = app("settings.camera")
        XCTAssertTrue(app.switches["camera.enable"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.otherElements["screen.camera.settings"].exists || app.navigationBars["Remote Camera"].exists)
        let stabilization = app.switches["camera.stabilization"]
        for _ in 0..<4 { if stabilization.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(stabilization.isHittable)
    }
    func testMapStartWaitsForCameraRatherThanInventingRecording() {
        let app = app("map.camera-ready")
        let start = app.buttons["camera.remote.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(app.buttons["camera.remote.stop"].exists)
        start.tap()
        XCTAssertFalse(start.isEnabled)
        XCTAssertEqual(start.value as? String, "Waiting for camera confirmation…")
        XCTAssertFalse(app.buttons["camera.remote.stop"].exists)
        app.buttons["camera.remote.connect"].tap()
        XCTAssertTrue(app.staticTexts["Waiting for camera confirmation…"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["camera.remote.state"].label, "Ready")
    }
    func testOfflineAndSavingShowOnlyOneDisabledCommand() {
        for state in ["map.camera-offline", "map.camera-starting", "map.camera-saving"] {
            let app = app(state)
            let isSaving = state == "map.camera-saving"
            let visible = app.buttons[isSaving ? "camera.remote.stop" : "camera.remote.start"]
            XCTAssertTrue(visible.waitForExistence(timeout: 6))
            XCTAssertFalse(visible.isEnabled)
            XCTAssertFalse(app.buttons[isSaving ? "camera.remote.start" : "camera.remote.stop"].exists)
            app.terminate()
        }
    }
    func testRecordingOnlyShowsStopAndInfoContainsActualParameters() {
        let app = app("map.camera-recording")
        let stop = app.buttons["camera.remote.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 6))
        XCTAssertTrue(stop.isEnabled)
        XCTAssertFalse(app.buttons["camera.remote.start"].exists)
        XCTAssertFalse(app.staticTexts["camera.remote.state"].exists)
        app.buttons["camera.remote.connect"].tap()
        XCTAssertTrue(app.staticTexts["camera.remote.state"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.staticTexts["camera.remote.state"].label, "REC")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "4K")).firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 4))
        stop.tap()
        XCTAssertFalse(stop.isEnabled)
        XCTAssertFalse(app.buttons["camera.remote.start"].exists)
    }
    func testCompactControlsStayAtMapEdgeInBothLayouts() {
        let app = app("map.camera-reference")
        let start = app.buttons["camera.remote.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        let map = app.descendants(matching: .any).matching(identifier: "map.live-route").firstMatch
        XCTAssertLessThan(start.frame.maxY, map.frame.midY)
        XCTAssertGreaterThan(start.frame.minX, map.frame.midX)
        XCTAssertLessThanOrEqual(start.frame.maxY, map.frame.maxY)
        XCTAssertEqual(start.frame.width, 67.2, accuracy: 1)
        let info = app.buttons["camera.remote.connect"]
        XCTAssertGreaterThan(info.frame.minY, start.frame.maxY)
        XCTAssertGreaterThan(info.frame.minY - start.frame.maxY, 80)
        XCTAssertEqual(info.frame.midX, app.buttons["map.follow-location"].frame.midX, accuracy: 1)
        XCTAssertLessThan(info.frame.maxY, app.buttons["map.follow-location"].frame.minY)
        XCTAssertFalse(start.frame.intersects(app.buttons["map.expand"].frame))
        XCTAssertFalse(start.frame.intersects(app.buttons["map.reference-route.menu"].frame))
        app.buttons["map.expand"].tap()
        XCTAssertTrue(app.buttons["map.collapse"].waitForExistence(timeout: 5))
        let expanded = app.descendants(matching: .any).matching(identifier: "screen.map.fullscreen").firstMatch
        let expandedStart = expanded.buttons["camera.remote.start"]
        XCTAssertTrue(expandedStart.isHittable)
        let expandedInfo = expanded.buttons["camera.remote.connect"]
        XCTAssertGreaterThan(expandedInfo.frame.minY, expandedStart.frame.maxY)
        XCTAssertGreaterThan(expandedInfo.frame.minY - expandedStart.frame.maxY, 80)
        XCTAssertEqual(expandedInfo.frame.midX, expanded.buttons["map.follow-location"].frame.midX, accuracy: 1)
        XCTAssertLessThan(expandedInfo.frame.maxY, expanded.buttons["map.follow-location"].frame.minY)
        XCTAssertLessThan(expandedStart.frame.maxY, app.frame.height * 0.3)
        XCTAssertGreaterThan(expandedStart.frame.minX, app.frame.width * 0.65)
        XCTAssertFalse(expandedStart.frame.intersects(app.buttons["map.collapse"].frame))
        XCTAssertFalse(expandedStart.frame.intersects(expanded.buttons["map.reference-route.menu"].frame))
        app.buttons["map.collapse"].tap()
        XCTAssertTrue(app.buttons["map.expand"].waitForExistence(timeout: 4))
    }
    func testBlackScreenFiveQuickTapsRevealControlsAndCancelPreservesMode() {
        let app = app("camera.black")
        let black = app.descendants(matching: .any)["camera.black-screen"].firstMatch
        XCTAssertTrue(black.waitForExistence(timeout: 6))
        black.press(forDuration: 5.2)
        XCTAssertFalse(app.buttons["camera.black.resume"].exists)
        black.tap(withNumberOfTaps: 4, numberOfTouches: 1)
        XCTAssertFalse(app.buttons["camera.black.resume"].exists)
        // A pause breaks the sequence; the next single tap is not a fifth tap.
        Thread.sleep(forTimeInterval: 1)
        black.tap()
        XCTAssertFalse(app.buttons["camera.black.resume"].exists)
        Thread.sleep(forTimeInterval: 1)
        black.tap(withNumberOfTaps: 5, numberOfTouches: 1)
        XCTAssertTrue(app.buttons["camera.black.resume"].waitForExistence(timeout: 3))
        app.buttons["camera.black.resume"].tap()
        XCTAssertFalse(app.buttons["camera.black.exit"].exists)
        black.tap(withNumberOfTaps: 5, numberOfTouches: 1)
        XCTAssertTrue(app.buttons["camera.black.exit"].waitForExistence(timeout: 3))
        app.buttons["camera.black.exit"].tap()
        XCTAssertTrue(app.buttons["camera.enter-black"].waitForExistence(timeout: 4))
    }

    func testBlackScreenMenuCountsDownAndReturnsAutomatically() {
        let app = app("camera.black")
        let black = app.descendants(matching: .any)["camera.black-screen"].firstMatch
        XCTAssertTrue(black.waitForExistence(timeout: 6))
        black.tap(withNumberOfTaps: 5, numberOfTouches: 1)
        let timer = app.descendants(matching: .any)["camera.black.countdown"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "five-tap-controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let initial = Int(timer.value as? String ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(initial, 18)
        let ticking = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = Int(timer.value as? String ?? "") ?? 0
            return value > 0 && value < initial
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ticking], timeout: 4), .completed)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.buttons["camera.black.resume"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 21), .completed)
        XCTAssertTrue(black.exists)
        // SwiftUI keeps underlying tab elements in the accessibility tree.
        // The black cover must remain the actual interactive surface.
        XCTAssertTrue(black.isHittable)
        black.tap(withNumberOfTaps: 5, numberOfTouches: 1)
        XCTAssertTrue(timer.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(Int(timer.value as? String ?? "") ?? 0, 18)
        app.buttons["camera.black.exit"].tap()
        XCTAssertTrue(app.buttons["camera.enter-black"].waitForExistence(timeout: 4))
    }
}
