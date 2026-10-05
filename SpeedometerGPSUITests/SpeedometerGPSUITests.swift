import XCTest

final class SpeedometerGPSUITests: XCTestCase {

    func testSettingsAboutVisualMatrix() {
        let app = XCUIApplication()
        for locale in ["en-US", "es-ES", "ar"] {
            for scheme in ["light", "dark"] {
                app.launchArguments = ["--ui-screen=settings.main", "--ui-locale=\(locale)", "--ui-scheme=\(scheme)", "--debug-settings=about"]
                app.launch()
                let version = app.descendants(matching: .any)["settings.version"].firstMatch
                XCTAssertTrue(version.waitForExistence(timeout: 10))
                XCTAssertLessThan(version.frame.maxY, app.frame.maxY - 30)
                captureSettings(app, "\(locale)-\(scheme)-about")
                app.terminate()
            }
        }
    }

    func testDownloadSettingsVisualMatrix() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.download", "--ui-locale=en-US", "--ui-scheme=light",
            "--ui-download-catalog-region=country.BLR", "--ui-live-map-tiles"]
        app.launch()
        XCTAssertTrue(app.textFields["offline.name"].waitForExistence(timeout: 15))
        app.textFields["offline.name"].tap(); app.textFields["offline.name"].typeText(" QA Layout")
        app.buttons["offline.download"].tap()
        let pause = app.buttons["offline.pause-resume"].firstMatch
        if pause.waitForExistence(timeout: 5) { pause.tap() }
        for locale in ["en-US", "es-ES", "ar", "de", "ja"] {
            for scheme in ["light", "dark"] {
                app.terminate()
                app.launchArguments = ["--ui-screen=settings.offline-maps", "--ui-locale=\(locale)", "--ui-scheme=\(scheme)"]
                app.launch()
                let mapRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline.map.' AND label CONTAINS 'QA Layout'")).firstMatch
                XCTAssertTrue(mapRow.waitForExistence(timeout: 10))
                XCTAssertTrue(app.descendants(matching: .any)["offline.free-space"].firstMatch.exists)
                XCTAssertTrue(app.descendants(matching: .any)["offline.used-space"].firstMatch.exists)
                captureSettings(app, "\(locale)-\(scheme)-downloads")
                let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline.map.' AND label CONTAINS 'QA Layout'")).firstMatch
                if locale == "ar" { row.swipeRight() } else { row.swipeLeft() }
                XCTAssertTrue(app.buttons["offline.delete"].waitForExistence(timeout: 3))
                captureSettings(app, "\(locale)-\(scheme)-swipe")

            }
        }
        app.terminate()
        app.launchArguments = ["--ui-screen=settings.offline-maps", "--ui-locale=en-US"]
        app.launch()
        let savedRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline.map.' AND label CONTAINS 'QA Layout'")).firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 10))
        if !app.buttons["offline.stop"].firstMatch.exists {
            savedRow.tap()
            XCTAssertTrue(app.descendants(matching: .any)["screen.offline-map-preview"].waitForExistence(timeout: 5))
            captureSettings(app, "download-country-boundary-preview")
            app.buttons["Done"].firstMatch.tap()
        }
        // A previously interrupted visual run can leave another copy of this fixture.
        for _ in 0..<10 where savedRow.exists {
            savedRow.swipeLeft()
            app.buttons["offline.delete"].firstMatch.tap()
            app.buttons["destructive.confirmation.confirm"].tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["offline.empty"].firstMatch.waitForExistence(timeout: 5))
        captureSettings(app, "download-manager-empty")
        app.terminate()
        app.launchArguments = ["--ui-screen=settings.offline-maps", "--ui-locale=en-US", "--ui-scheme=light",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["offline.add"].waitForExistence(timeout: 10))
        captureSettings(app, "download-manager-accessibility")
        app.swipeUp()
        captureSettings(app, "download-manager-accessibility-summary")

    }

    func testDownloadControlsPauseResumeAndConfirmStopInline() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.download", "--ui-locale=en-US", "--ui-scheme=light",
            "--ui-download-catalog-region=country.BLR", "--ui-live-map-tiles"]
        app.launch()
        let field = app.textFields["offline.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(" QA Controls")
        app.buttons["offline.download"].tap()
        let pause = app.buttons["offline.pause-resume"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        let stop = app.buttons["offline.stop"].firstMatch
        let progress = app.progressIndicators["offline.progress"].firstMatch
        XCTAssertTrue(stop.exists); XCTAssertTrue(progress.exists)
        XCTAssertEqual(pause.label, "Pause")
        XCTAssertEqual(progress.frame.midY, pause.frame.midY, accuracy: 2)
        XCTAssertEqual(stop.frame.midY, pause.frame.midY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44)
        captureSettings(app, "download-active-inline")
        pause.tap()
        expectation(for: NSPredicate(format: "label == 'Resume'"), evaluatedWith: pause)
        waitForExpectations(timeout: 10)
        captureSettings(app, "download-paused-inline")
        pause.tap()
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: pause)
        waitForExpectations(timeout: 10)
        pause.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline.map.' AND label CONTAINS 'QA Controls'")).firstMatch
        row.swipeLeft()
        XCTAssertTrue(app.buttons["offline.delete"].waitForExistence(timeout: 3))
        captureSettings(app, "download-swiped-immediate")
        Thread.sleep(forTimeInterval: 0.5)
        captureSettings(app, "download-swiped-settled")
        app.buttons["offline.delete"].tap()
        app.buttons["destructive.confirmation.cancel"].tap()
        XCTAssertTrue(row.exists)
        stop.tap()
        XCTAssertTrue(app.buttons["destructive.confirmation.confirm"].waitForExistence(timeout: 3))
        captureSettings(app, "download-stop-confirmation")
        app.buttons["destructive.confirmation.cancel"].tap()
        XCTAssertTrue(row.exists)
        XCTAssertEqual(pause.label, "Resume")
        pause.tap()
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: pause)
        waitForExpectations(timeout: 10)
        stop.tap(); app.buttons["destructive.confirmation.confirm"].tap()
        XCTAssertFalse(row.exists)
        app.terminate()
        app.launchArguments = ["--ui-screen=settings.offline-maps", "--ui-locale=en-US"]
        app.launch()
        XCTAssertTrue(app.buttons["offline.add"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline.map.' AND label CONTAINS 'QA Controls'")).firstMatch.exists)
    }

    func testSettingsRemoteSectionAndSingleLineLanguageVersion() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.main", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()
        XCTAssertTrue(app.buttons["settings.remote-camera"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Remote Camera"].exists)
        captureSettings(app, "settings-map-and-camera")
        let version = app.descendants(matching: .any)["settings.version"].firstMatch
        for _ in 0..<10 where !version.isHittable { app.swipeUp() }
        XCTAssertTrue(version.isHittable)
        let language = app.staticTexts["settings.language.value"]
        XCTAssertTrue(language.exists)
        XCTAssertLessThan(language.frame.height, 30)
        captureSettings(app, "settings-language-and-version")
    }

    private func captureSettings(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testRidePreviewsLoadAgainAfterNavigationAndColdLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=trips.populated", "--ui-locale=en-US", "--ui-scheme=light",
            "--ui-trip-preview-probe", "--ui-trip-preview-fixtures", "--ui-offline-map"]
        let id = "trip.row.67A1C0DE-4F5A-4C67-9B20-000000000067"
        func assertReady() {
            let row = app.buttons[id]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            expectation(for: NSPredicate(format: "value == 'preview-ready'"), evaluatedWith: row)
            waitForExpectations(timeout: 10)
            XCTAssertTrue(row.isHittable)
        }
        app.launch()
        assertReady()
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "ride-route-previews"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["tab.speed"].tap()
        app.buttons["tab.trips"].tap()
        assertReady()
        app.terminate()
        app.launch()
        assertReady()
        app.buttons[id].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.trip-detail"].waitForExistence(timeout: 5))
    }

    func testRidePreviewsReturnAfterScrollingALargeLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=trips.populated", "--ui-locale=ar", "--ui-scheme=dark",
            "--ui-trip-preview-probe", "--ui-trip-preview-stress", "--ui-offline-map"]
        app.launch()
        let first = app.buttons["trip.row.67A1C0DE-4F5A-4C67-9B20-000000000067"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for _ in 0..<5 { app.swipeUp() }
        XCTAssertFalse(first.isHittable)
        for _ in 0..<6 { app.swipeDown() }
        expectation(for: NSPredicate(format: "value == 'preview-ready' AND hittable == true"), evaluatedWith: first)
        waitForExpectations(timeout: 10)
    }

    func testReturningLaunchShowsMapAndSettingsDuringMinuteLongCloudLookup() {
        let app = XCUIApplication()
        // Clear only this simulator's prior interrupted-trip fixture, then test
        // an ordinary returning launch without a deterministic screen override.
        app.launchArguments = ["--ui-screen=speed.idle", "--ui-locale=en-US"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.speed"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["-spiderroute_welcome_v2_dismissed", "YES",
            "--ui-startup-cloud-delay=60", "--ui-tab-order=map,speed,trips", "--ui-locale=en-US"]
        let began = Date()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.map"].waitForExistence(timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(began), 20, "A minute-long iCloud lookup must not delay the map")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "map-while-icloud-is-blocked"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["header.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testCountryAndProvinceDownloadsSurviveCacheClearAndConfirmedDeletion() {
        let app = XCUIApplication()
        func row(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "offline.map.", name)).firstMatch
        }
        func waitForPack(_ name: String) {
            let complete = NSPredicate { _, _ in row(name).exists && row(name).label.contains("Available offline") }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: complete, object: nil)], timeout: 180), .completed)
            XCTAssertGreaterThan(UInt64(row(name).staticTexts["offline.size"].value as? String ?? "0") ?? 0, 0)
        }
        func download(country: String, province: String?, name: String) {
            app.buttons["offline.add"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["screen.offline-regions"].waitForExistence(timeout: 10))
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText(country)
            let code = country == "Monaco" ? "MCO" : "SMR"
            app.buttons["offline.region.country.\(code)"].tap()
            let choice = app.buttons[province.map { "offline.region.\($0)" } ?? "offline.region.entire-country"]
            XCTAssertTrue(choice.waitForExistence(timeout: 10)); choice.tap()
            let field = app.textFields["offline.name"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            let form = XCTAttachment(screenshot: app.screenshot()); form.name = name + "-download-form"; form.lifetime = .keepAlways; add(form)
            let original = field.value as? String ?? ""
            field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + name)
            XCTAssertEqual(field.value as? String, name)
            XCTAssertTrue(app.buttons["offline.language"].label.contains("English"))
            app.buttons["offline.download"].tap()
            waitForPack(name)
        }
        func launchOffline() {
            app.terminate()
            clearAmbientMapCache(app)
            app.launchArguments = ["--ui-screen=settings.offline-maps", "--ui-locale=en-US", "--ui-live-map-tiles", "--ui-offline-map", "--ui-map-label-probe"]
            app.launch()
        }
        func verifyOffline(_ name: String) {
            waitForPack(name); row(name).tap()
            let labels = app.descendants(matching: .any)["map.rendered-labels"].firstMatch
            let rendered = NSPredicate { _, _ in labels.exists && !(labels.value as? String ?? "").isEmpty }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 25), .completed)
            let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name + "-pack-only-offline"; capture.lifetime = .keepAlways; add(capture)
            app.buttons["Done"].firstMatch.tap()
        }
        app.launchArguments = ["--ui-screen=settings.main", "--ui-locale=en-US", "--ui-live-map-tiles", "--ui-clean-offline-qa"]
        app.launch()
        let manager = app.buttons["settings.offline-maps"]
        XCTAssertTrue(manager.waitForExistence(timeout: 10))
        for _ in 0..<4 where !manager.isHittable { app.swipeUp() }
        manager.tap()
        XCTAssertTrue(app.buttons["offline.add"].waitForExistence(timeout: 10))
        download(country: "Monaco", province: nil, name: "QA Monaco Country")
        download(country: "San Marino", province: "province.1159315991", name: "QA San Marino Province")
        XCTAssertTrue(row("QA Monaco Country").exists)
        let managerCapture = XCTAttachment(screenshot: app.screenshot()); managerCapture.name = "two-regions-with-sizes"; managerCapture.lifetime = .keepAlways; add(managerCapture)
        launchOffline()
        verifyOffline("QA Monaco Country")
        app.terminate()
        app.launchArguments = ["--ui-screen=map.route", "--ui-locale=en-US", "--ui-live-map-tiles", "--ui-offline-map", "--ui-map-label-probe", "--ui-selected-offline-bounds"]
        app.launch()
        let mainLabels = app.descendants(matching: .any)["map.rendered-labels"].firstMatch
        let mainRendered = NSPredicate { _, _ in mainLabels.exists && (mainLabels.value as? String ?? "").contains("Monaco") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: mainRendered, object: nil)], timeout: 25), .completed)
        let mainCapture = XCTAttachment(screenshot: app.screenshot()); mainCapture.name = "main-map-pack-only-offline"; mainCapture.lifetime = .keepAlways; add(mainCapture)
        launchOffline()
        verifyOffline("QA San Marino Province")
        XCTAssertFalse(app.buttons["offline.delete"].exists)
        row("QA Monaco Country").swipeLeft(); app.buttons["offline.delete"].firstMatch.tap()
        app.buttons["destructive.confirmation.cancel"].tap()
        XCTAssertTrue(row("QA Monaco Country").exists)
        row("QA Monaco Country").swipeLeft(); app.buttons["offline.delete"].firstMatch.tap()
        app.buttons["destructive.confirmation.confirm"].tap()
        XCTAssertFalse(row("QA Monaco Country").exists)
        launchOffline()
        XCTAssertFalse(row("QA Monaco Country").exists)
        verifyOffline("QA San Marino Province")
        row("QA San Marino Province").swipeLeft(); app.buttons["offline.delete"].firstMatch.tap()
        app.buttons["destructive.confirmation.confirm"].tap()
        app.terminate(); clearAmbientMapCache(app)
        // Negative control: without the removed pack or ambient cache, the same
        // Monaco preview cannot obtain named map features with networking blocked.
        app.launchArguments = ["--ui-screen=map.download", "--ui-locale=en-US", "--ui-download-catalog-region=country.MCO", "--ui-live-map-tiles", "--ui-offline-map", "--ui-map-label-probe"]
        app.launch()
        let labels = app.descendants(matching: .any)["map.rendered-labels"].firstMatch
        XCTAssertTrue(labels.waitForExistence(timeout: 10))
        let rendered = NSPredicate { _, _ in !(labels.value as? String ?? "").isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 10), .timedOut)
        app.terminate()
    }

    private func clearAmbientMapCache(_ app: XCUIApplication) {
        app.launchArguments = ["--ui-clear-ambient-map-cache", "--ui-offline-map"]
        app.launch()
        let complete = NSPredicate(format: "label == %@", "complete")
        let status = app.staticTexts["offline.cache-cleanup"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: complete, object: status)], timeout: 20), .completed)
        app.terminate()
    }


    func testEnglishAppDownloadsRussianMapAndRendersItWithNetworkBlocked() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.download", "--ui-locale=en-US", "--ui-map-provider=openStreetMap", "--ui-live-map-tiles", "--ui-download-small-area", "--ui-clean-offline-qa"]
        app.launch()
        let language = app.buttons["offline.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 10))
        XCTAssertTrue(language.label.contains("English"), "New downloads default to the app language")
        language.tap()
        let languageRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "offline.language.option."))
        XCTAssertGreaterThan(languageRows.count, 0)
        let row = languageRows.element(boundBy: 1)
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        XCTAssertLessThanOrEqual(row.frame.height, 54)
        let languageScreenshot = XCTAttachment(screenshot: app.screenshot()); languageScreenshot.name = "compact-map-language-rows"; languageScreenshot.lifetime = .keepAlways; add(languageScreenshot)
        let russian = app.buttons["offline.language.option.ru"]
        for _ in 0..<12 where !russian.isHittable { app.swipeUp() }
        XCTAssertTrue(russian.isHittable); russian.tap()
        XCTAssertTrue(app.buttons["offline.language"].label.contains("Русский"))
        let name = app.textFields["offline.name"]
        name.tap(); name.typeText("QA Minsk Russian")
        app.buttons["offline.download"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.offline-maps"].waitForExistence(timeout: 10))
        let ready = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "offline.map.ru", "QA Minsk Russian")).firstMatch.descendants(matching: .any)["offline.status.ru"].firstMatch
        let complete = NSPredicate { _, _ in ready.exists && ready.label == "Available offline" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: complete, object: nil)], timeout: 90), .completed)
        app.terminate()
        clearAmbientMapCache(app)
        app.launchArguments = ["--ui-screen=settings.offline-maps", "--ui-locale=en-US", "--ui-live-map-tiles", "--ui-offline-map", "--ui-map-label-probe"]
        app.launch()
        let map = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "offline.map.ru", "QA Minsk Russian")).firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10)); map.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.offline-map-preview"].waitForExistence(timeout: 5))
        let labels = app.descendants(matching: .any)["map.rendered-labels"].firstMatch
        let rendered = NSPredicate { _, _ in labels.exists && !(labels.value as? String ?? "").isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 20), .completed)
        XCTAssertTrue((labels.value as? String ?? "").range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "english-app-russian-map-network-blocked"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["offline.delete"].exists)
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "offline.map.ru", "QA Minsk Russian")).firstMatch.swipeLeft()
        app.buttons["offline.delete"].firstMatch.tap()
        app.buttons["destructive.confirmation.cancel"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "offline.map.ru", "QA Minsk Russian")).firstMatch.exists)
        app.terminate()
        app.launchArguments = ["--ui-screen=settings.offline-maps", "--ui-locale=ar", "--ui-live-map-tiles", "--ui-offline-map"]
        app.launch()
        let arabicMap = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "offline.map.ru", "QA Minsk Russian")).firstMatch
        XCTAssertTrue(arabicMap.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["offline.delete"].exists)
        arabicMap.swipeRight()
        XCTAssertTrue(app.buttons["offline.delete"].waitForExistence(timeout: 3))
        let swipeScreenshot = XCTAttachment(screenshot: app.screenshot()); swipeScreenshot.name = "arabic-downloaded-map-trailing-swipe"; swipeScreenshot.lifetime = .keepAlways; add(swipeScreenshot)
        app.buttons["offline.delete"].firstMatch.tap()
        app.buttons["destructive.confirmation.confirm"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "offline.map.ru", "QA Minsk Russian")).firstMatch.exists)
        app.terminate()
    }



    func testDistanceLabelSizeMenuUpdatesAndKeepsSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.main", "--ui-locale=en-US"]
        app.launch()
        let picker = app.buttons["settings.map.distance-label-size"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(picker.label.contains("2×") || (picker.value as? String)?.contains("2×") == true)
        for size in ["1×", "2×", "3×"] {
            picker.tap()
            let option = app.buttons[size].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
            app.buttons["Done"].firstMatch.tap()
            app.buttons["header.settings"].tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            XCTAssertTrue(picker.label.contains(size) || (picker.value as? String)?.contains(size) == true)
        }
    }

    func testMapProviderSwitchPersistsAcrossLiveFullscreenAndSavedRide() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.route", "--ui-locale=en-US", "--ui-debug-paid", "--ui-map-provider=openStreetMap"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["map.openstreetmap-attribution"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["header.settings"].tap()
        app.buttons["settings.map-provider"].tap()
        XCTAssertTrue(app.buttons["settings.map-provider.option.openStreetMap"].isSelected)
        app.buttons["settings.map-provider.option.apple"].tap()
        XCTAssertTrue(app.buttons["settings.map-provider.option.apple"].isSelected)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any)["map.openstreetmap-attribution"].firstMatch.exists)
        app.buttons["map.expand"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.map.fullscreen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["map.openstreetmap-attribution"].firstMatch.exists)
        app.terminate()
        app.launchArguments = ["--ui-screen=trips.detail", "--ui-locale=en-US", "--ui-debug-paid"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.trip-detail"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["map.openstreetmap-attribution"].firstMatch.exists, "Saved rides must use the persisted provider")
        app.terminate()
        app.launchArguments = ["--ui-screen=settings.map-provider", "--ui-locale=en-US"]
        app.launch()
        XCTAssertTrue(app.buttons["settings.map-provider.option.apple"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["settings.map-provider.option.apple"].isSelected)
        app.buttons["settings.map-provider.option.openStreetMap"].tap()
        app.terminate()
        app.launchArguments = ["--ui-screen=map.route", "--ui-locale=en-US", "--ui-debug-paid"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["map.openstreetmap-attribution"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["map.expand"].tap()
        let full = app.descendants(matching: .any)["screen.map.fullscreen"]
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        XCTAssertTrue(full.descendants(matching: .any)["map.openstreetmap-attribution"].firstMatch.exists)
        app.terminate()
        app.launchArguments = ["--ui-screen=trips.detail", "--ui-locale=en-US", "--ui-debug-paid"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["map.openstreetmap-attribution"].firstMatch.waitForExistence(timeout: 8))
        app.terminate()
    }

    private func waitForStableGuideMarker(_ marker: XCUIElement) {
        var previous = CGRect.null
        var stable = 0
        let predicate = NSPredicate { _, _ in
            let current = marker.frame
            if current == previous && !current.isEmpty { stable += 1 } else { stable = 0 }
            previous = current
            return stable >= 2
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: marker)], timeout: 8), .completed)
    }

    func testEmbeddedGuidePhotoIsShownBeforeSourceLinks() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.guide-point", "--ui-locale=en-US", "--ui-guide-photo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["route-guide.point.summary"].waitForExistence(timeout: 8))
        let photo = app.images["route-guide.photo.demo-photo"]
        for _ in 0..<4 where !photo.isHittable { app.swipeUp() }
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.isHittable)
        XCTAssertTrue(app.buttons["UI test fixture"].exists)
    }

    func testRouteGuideMarkersOpenInBothRenderersAndFullscreen() {
        for legacy in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=map.guide", "--ui-locale=ru", "--ui-scheme=light", "--ui-guide-closeup"]
                + (legacy ? ["--ui-legacy-map", "--ui-map-provider=apple"] : ["--ui-map-provider=openStreetMap"])
            app.launch()
            let marker = app.descendants(matching: .any)["map.guide-point.demo-0"].firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 8))
            waitForStableGuideMarker(marker)
            marker.tap()
            XCTAssertTrue(app.staticTexts["route-guide.point.summary"].waitForExistence(timeout: 4))
            XCTAssertTrue(app.staticTexts["route-guide.point.title"].exists)
            app.buttons["Готово"].firstMatch.tap()
            app.buttons["map.expand"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["screen.map.fullscreen"].waitForExistence(timeout: 4))
            let expandedMarker = app.descendants(matching: .any)["screen.map.fullscreen"].descendants(matching: .any)["map.guide-point.demo-0"].firstMatch
            XCTAssertTrue(expandedMarker.waitForExistence(timeout: 5))
            waitForStableGuideMarker(expandedMarker)
            expandedMarker.tap()
            XCTAssertTrue(app.staticTexts["route-guide.point.summary"].waitForExistence(timeout: 4))
            app.terminate()
        }
    }

    func testGuideOverviewDotsRemainDiscoverableInBothRenderers() {
        for legacy in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=map.guide", "--ui-locale=en-US"]
                + (legacy ? ["--ui-legacy-map", "--ui-map-provider=apple"] : ["--ui-map-provider=openStreetMap"])
            app.launch()
            let marker = app.descendants(matching: .any)["map.guide-point.demo-0"].firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 8))
            waitForStableGuideMarker(marker)
            marker.tap()
            XCTAssertTrue(app.staticTexts["route-guide.point.summary"].waitForExistence(timeout: 4))
            app.terminate()
        }
    }

    func testRouteGuideCanBeHiddenAndReplacementCancelled() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.guide-library", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()
        let enabled = app.switches["route-guide.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 8))
        XCTAssertEqual(enabled.value as? String, "1")
        tapSwitch(enabled)
        XCTAssertTrue(waitForSwitch(enabled, value: "0"))
        app.buttons["route-guide.import"].tap()
        let confirmation = app.descendants(matching: .any)["route-guide.replace.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        app.buttons["route-guide.replace.confirmation.cancel"].tap()
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertTrue(app.buttons["route-guide.import"].exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any)["map.guide-point.demo-0"].exists)
        XCTAssertTrue(app.buttons["map.reference-route.menu"].exists)
        app.buttons["map.reference-route.menu"].tap()
        let menuEnabled = app.switches["map.route-guide.enabled"]
        XCTAssertTrue(menuEnabled.waitForExistence(timeout: 4))
        XCTAssertEqual(menuEnabled.value as? String, "0")
        tapSwitch(menuEnabled)
        XCTAssertTrue(waitForSwitch(menuEnabled, value: "1"))
    }

    func testRouteGuideReviewCanFocusPlaceWithoutCurrentLocationPullingBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.guide-library", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()
        let row = app.buttons["route-guide.row.demo-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        app.buttons["route-guide.point.focus"].tap()
        let follow = app.buttons["map.follow-location"]
        XCTAssertTrue(follow.waitForExistence(timeout: 4))
        XCTAssertEqual(follow.value as? String, "Off")
        follow.tap()
        XCTAssertEqual(follow.value as? String, "On")
    }

    func testSpeedColorSettingsSitBetweenAccessAndUnits() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.main", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        let access = app.staticTexts["Access"]
        let speedColors = app.buttons["settings.speed-colors"]
        XCTAssertTrue(access.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["settings.redeem-offer-code"].waitForExistence(timeout: 4))
        XCTAssertTrue(speedColors.waitForExistence(timeout: 4))
        XCTAssertLessThan(access.frame.minY, speedColors.frame.minY)
        XCTAssertTrue(app.switches["settings.map.follow-location"].exists)

        speedColors.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.settings.speed-colors"].waitForExistence(timeout: 4))
        for identifier in [
            "settings.speed-color.light.number",
            "settings.speed-color.light.outline-enabled",
            "settings.speed-color.light.outline",
            "settings.speed-color.dark.number",
            "settings.speed-color.dark.outline-enabled",
            "settings.speed-color.dark.outline",
            "settings.speed-colors.reset"
        ] {
            let control = app.descendants(matching: .any)[identifier]
            scrollToSettingsControl(control, in: app)
            XCTAssertTrue(control.waitForExistence(timeout: 4), "Missing \(identifier)")
        }
    }

    func testSpeedColorResetCanBeCancelledOrConfirmed() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.speed-colors", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        let reset = app.buttons["settings.speed-colors.reset"]
        scrollToSettingsControl(reset, in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 4))
        reset.tap()

        let confirmation = app.descendants(matching: .any)["settings.speed-colors.reset-confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons.matching(identifier: "settings.speed-colors.reset-confirmation")
            .matching(NSPredicate(format: "label == %@", "Cancel"))
            .firstMatch.tap()
        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(reset.exists)

        reset.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons.matching(identifier: "settings.speed-colors.reset-confirmation")
            .matching(NSPredicate(format: "label == %@", "Reset Colors"))
            .firstMatch.tap()
        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(reset.exists)
    }

    func testDeterministicSettingsCaptureHidesDebugTools() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.main", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["settings.debug.reset-all"].exists)
    }

    func testBottomNavigationSettingsShowsSavedDragOrder() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.bottom-navigation", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        let screen = app.descendants(matching: .any)["screen.settings.bottom-navigation"]
        XCTAssertTrue(screen.waitForExistence(timeout: 4))
        let identifiers = ["map", "speed", "trips"]
        let rows = identifiers.map { app.descendants(matching: .any)["settings.bottom-navigation.item.\($0)"] }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 2))
        }
        XCTAssertEqual(rows.map(\.frame.minY), rows.map(\.frame.minY).sorted())
    }

    func testMapFollowLocationRequiresConfirmationOnlyWhenDisabling() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.route", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        let follow = app.buttons["map.follow-location"]
        XCTAssertTrue(follow.waitForExistence(timeout: 4))
        XCTAssertEqual(follow.value as? String, "On")
        follow.tap()

        let confirmation = app.descendants(matching: .any)["map.follow-location.disable-confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(confirmation.exists)
        XCTAssertEqual(follow.value as? String, "On")

        follow.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons["Stop"].tap()
        XCTAssertEqual(follow.value as? String, "Off")

        follow.tap()
        XCTAssertEqual(follow.value as? String, "On")
        XCTAssertFalse(confirmation.exists)
    }

    func testDebugSettingsResetAsksForConfirmationAndCancelPreservesControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-spiderroute_welcome_v2_dismissed", "YES"]
        app.launch()

        app.buttons["header.settings"].tap()
        let resetWelcome = app.buttons["settings.debug.reset-welcome"]
        for _ in 0..<8 where !resetWelcome.exists {
            app.swipeUp()
        }
        XCTAssertTrue(resetWelcome.waitForExistence(timeout: 4))
        resetWelcome.tap()

        let confirmation = app.descendants(matching: .any)["settings.debug-reset.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Show welcome flow again?"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(resetWelcome.exists)
    }

    func testSharedAppearanceTogglePersistsAcrossMainTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=speed.idle", "--ui-debug-paid"]
        app.launch()

        let appearance = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'header.appearance.'")).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 4))
        let initialAppearance = appearance.identifier.hasSuffix(".dark") ? "dark" : "light"
        appearance.tap()
        let expectedAppearance = initialAppearance == "dark" ? "light" : "dark"
        let expectedButton = app.buttons["header.appearance.\(expectedAppearance)"]
        XCTAssertTrue(expectedButton.waitForExistence(timeout: 3))

        app.buttons["tab.map"].tap()
        XCTAssertTrue(app.buttons["header.appearance.\(expectedAppearance)"].exists)

        app.buttons["tab.trips"].tap()
        XCTAssertTrue(app.buttons["header.appearance.\(expectedAppearance)"].exists)
    }

    func testDeterministicCoreScreensAreReachable() {
        for screen in ["welcome.route", "welcome.display.number", "welcome.display.swipe", "welcome.display.gauge", "welcome.rides", "speed.idle", "speed.gauge", "speed.finish-confirmation", "trip.recovery", "speed.alert", "reference-route.import-confirmation", "map.reference-route", "map.reference-route-menu", "map.reference-route-fullscreen-menu", "map.route", "map.route-fullscreen", "map.route-one-pause", "map.route-multiple-pauses", "map.follow-disable-confirmation", "map.finish-confirmation", "trips.populated", "trips.delete-confirmation", "trips.detail", "trips.export", "paywall.trial", "settings.main", "settings.bottom-navigation", "settings.speed-alert", "settings.speed-colors", "settings.speed-colors-reset-confirmation", "settings.reference-routes", "settings.reference-route-rename", "settings.reference-route-delete-confirmation"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=\(screen)", "--ui-locale=en-US", "--ui-scheme=light"]
            app.launch()
            let screenElement = app.descendants(matching: .any)[expectedIdentifier(for: screen)]
            XCTAssertTrue(screenElement.waitForExistence(timeout: 4), "Missing \(screen)")
            app.terminate()
        }
    }

    func testSharedReferenceRouteCanBeCancelledOrImported() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=reference-route.import-confirmation", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        let confirmation = app.descendants(matching: .any)["reference-route.import.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["shared-weekend-route.gpx"].exists)
        let nameField = app.textFields["reference-route.import.confirmation.name"]
        XCTAssertTrue(nameField.exists)
        XCTAssertEqual(nameField.value as? String, "Shared weekend route")
        app.buttons["reference-route.import.confirmation.cancel"].tap()
        XCTAssertFalse(confirmation.exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        let editedNameField = app.textFields["reference-route.import.confirmation.name"]
        editedNameField.tap()
        editedNameField.typeText(" edited")
        let editedName = editedNameField.value as? String
        XCTAssertNotEqual(editedName, "Shared weekend route")
        XCTAssertTrue(editedName?.contains("edited") == true)
        app.buttons["reference-route.import.confirmation.confirm"].tap()
        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(app.descendants(matching: .any)["screen.map"].waitForExistence(timeout: 3))
    }

    func testFinishTripRequiresConfirmationAndCancelPreservesRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=speed.recording", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        let finish = app.buttons["Finish"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 4))
        finish.tap()
        let confirmation = app.descendants(matching: .any)["trip.finish.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Finish"].exists)

        app.buttons["Finish"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons.matching(identifier: "trip.finish.confirmation").matching(NSPredicate(format: "label == 'Finish'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Start Ride"].waitForExistence(timeout: 3))
        XCTAssertFalse(confirmation.exists)
    }

    func testSpeedRecordingControlsMatchLiveRoutePlacement() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=speed.recording", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        let speedPause = app.buttons["Pause"].firstMatch
        let speedFinish = app.buttons["Finish"].firstMatch
        XCTAssertTrue(speedPause.waitForExistence(timeout: 4))
        XCTAssertTrue(speedFinish.exists)
        let speedPauseFrame = speedPause.frame
        let speedFinishFrame = speedFinish.frame

        app.descendants(matching: .any)["tab.map"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.map"].waitForExistence(timeout: 4))

        let mapPause = app.descendants(matching: .any)["trip.pause"]
        let mapFinish = app.descendants(matching: .any)["trip.finish"]
        XCTAssertTrue(mapPause.waitForExistence(timeout: 3))
        XCTAssertTrue(mapFinish.exists)

        XCTAssertEqual(speedPauseFrame.minX, mapPause.frame.minX, accuracy: 1)
        XCTAssertEqual(speedPauseFrame.width, mapPause.frame.width, accuracy: 1)
        XCTAssertEqual(speedFinishFrame.maxX, mapFinish.frame.maxX, accuracy: 1)
        XCTAssertEqual(speedFinishFrame.width, mapFinish.frame.width, accuracy: 1)
        XCTAssertEqual(speedPauseFrame.midY, mapPause.frame.midY, accuracy: 1)
        XCTAssertEqual(speedFinishFrame.midY, mapFinish.frame.midY, accuracy: 1)
    }

    func testSpeedIdleStartControlMatchesLiveRoutePlacement() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=speed.idle", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        let speedStart = app.buttons["Start Ride"].firstMatch
        XCTAssertTrue(speedStart.waitForExistence(timeout: 4))
        let speedBottomMetric = app.staticTexts["Top speed"].firstMatch
        XCTAssertTrue(speedBottomMetric.exists)
        let speedStartFrame = speedStart.frame
        let speedMetricGap = speedStartFrame.minY - speedBottomMetric.frame.maxY

        app.descendants(matching: .any)["tab.map"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.map"].waitForExistence(timeout: 4))

        let mapStart = app.descendants(matching: .any)["trip.start"]
        XCTAssertTrue(mapStart.waitForExistence(timeout: 3))
        let mapBottomMetric = app.staticTexts["Average speed"].firstMatch
        XCTAssertTrue(mapBottomMetric.exists)
        let mapMetricGap = mapStart.frame.minY - mapBottomMetric.frame.maxY
        XCTAssertEqual(speedStartFrame.minX, mapStart.frame.minX, accuracy: 1)
        XCTAssertEqual(speedStartFrame.maxX, mapStart.frame.maxX, accuracy: 1)
        XCTAssertEqual(speedStartFrame.midY, mapStart.frame.midY, accuracy: 1)
        XCTAssertEqual(speedStartFrame.height, mapStart.frame.height, accuracy: 1)
        XCTAssertEqual(speedMetricGap, mapMetricGap, accuracy: 5)
    }

    func testInterruptedTripRecoveryCanContinueOrDiscard() {
        let continuingApp = XCUIApplication()
        continuingApp.launchArguments = ["--ui-screen=trip.recovery", "--ui-locale=en-US", "--ui-scheme=dark"]
        continuingApp.launch()

        let recovery = continuingApp.staticTexts["trip.recovery.prompt"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 4))
        XCTAssertTrue(continuingApp.staticTexts.matching(NSPredicate(format: "label CONTAINS '18:42'")).firstMatch.exists)
        let continueButton = continuingApp.descendants(matching: .any)["trip.recovery.continue"]
        let discardButton = continuingApp.descendants(matching: .any)["trip.recovery.discard"]
        XCTAssertTrue(continueButton.exists)
        XCTAssertTrue(discardButton.exists)
        continueButton.tap()
        XCTAssertTrue(continuingApp.buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertFalse(recovery.exists)
        continuingApp.terminate()

        let discardingApp = XCUIApplication()
        discardingApp.launchArguments = ["--ui-screen=trip.recovery", "--ui-locale=en-US", "--ui-scheme=dark"]
        discardingApp.launch()
        let secondRecovery = discardingApp.staticTexts["trip.recovery.prompt"]
        XCTAssertTrue(secondRecovery.waitForExistence(timeout: 4))
        discardingApp.descendants(matching: .any)["trip.recovery.discard"].tap()
        XCTAssertTrue(discardingApp.buttons["Start Ride"].waitForExistence(timeout: 3))
        XCTAssertFalse(secondRecovery.exists)
    }

    func testSpeedDisplaySwipesFromDefaultNumberToGauge() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=speed.idle", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        let pager = app.collectionViews.firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 4))
        XCTAssertEqual(pager.value as? String, "number")
        XCTAssertTrue(app.descendants(matching: .any)["speed.display.number"].exists)
        pager.swipeLeft()
        let selectedGauge = NSPredicate(format: "value == 'gauge'")
        expectation(for: selectedGauge, evaluatedWith: pager)
        waitForExpectations(timeout: 3)
    }

    func testGaugeIsBoundedAndCompactGPSQualitySitsAboveIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=speed.gauge", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        let gauge = app.descendants(matching: .any)["speed.gauge"]
        let gps = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'GPS,'")).firstMatch
        XCTAssertTrue(gauge.waitForExistence(timeout: 4))
        XCTAssertTrue(gps.waitForExistence(timeout: 4))
        XCTAssertTrue(gps.label.contains("GPS"))
        XCTAssertEqual(gps.value as? String, "4 / 4")
        XCTAssertLessThanOrEqual(gauge.frame.width, app.windows.firstMatch.frame.width * 0.80)
        XCTAssertLessThan(gps.frame.maxY, gauge.frame.minY)
    }

    func testPaywallColdLoadingCTAIsEnabledBeforeTap() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=paywall.cold", "--ui-storekit-slow", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()
        let subscribe = app.buttons["paywall.subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 4))
        XCTAssertTrue(subscribe.isEnabled)
        subscribe.tap()
        let enteredPurchasing = NSPredicate(format: "isEnabled == false")
        expectation(for: enteredPurchasing, evaluatedWith: subscribe)
        waitForExpectations(timeout: 3)
    }

    func testPaywallPlanSelectionChangesPurchaseActionAndDisclosure() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=paywall.trial", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()
        let purchase = app.buttons["paywall.subscribe"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        XCTAssertEqual(purchase.label, "Subscribe")
        app.buttons["paywall.plan.lifetime"].tap()
        XCTAssertEqual(purchase.label, "Buy Lifetime Access")
        XCTAssertTrue(app.staticTexts["One-time purchase. No subscription."].exists)
        app.buttons["paywall.plan.yearly"].tap()
        XCTAssertEqual(purchase.label, "Subscribe")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "$9.99 per year")).firstMatch.exists)
    }

    func testArabicPaywallPlacesPriceOnTheLeft() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=paywall.trial", "--ui-locale=ar", "--ui-scheme=light"]
        app.launch()
        let yearly = app.buttons["paywall.plan.yearly"]
        XCTAssertTrue(yearly.waitForExistence(timeout: 5))
        let price = yearly.staticTexts["$9.99"]
        XCTAssertTrue(price.exists)
        XCTAssertLessThan(price.frame.midX, yearly.frame.midX)
        XCTAssertEqual(app.buttons["paywall.subscribe"].label, "اشتراك")
    }

    func testPaywallShowsStaticTrialSummaryWithoutToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=paywall.trial", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        let trialSummary = app.descendants(matching: .any)["paywall.trial.summary"]
        XCTAssertTrue(trialSummary.waitForExistence(timeout: 4))
        XCTAssertTrue(trialSummary.label.localizedCaseInsensitiveContains("3-day free trial"))
        XCTAssertEqual(app.switches.count, 0)
    }

    func testSpeedNumberStyleMenuSwitchesBetweenDigitalAndModern() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.main", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        let picker = app.buttons["settings.speed-number-style"].firstMatch
        scrollToSettingsControl(picker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        picker.tap()
        tapSpeedNumberStyleOption("modern", fallbackLabel: "Modern", in: app)
        app.buttons["Done"].tap()
        app.buttons["tab.speed"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["speed.number.modern"].waitForExistence(timeout: 3))

        app.buttons["header.settings"].tap()
        scrollToSettingsControl(picker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        tapSpeedNumberStyleOption("digital", fallbackLabel: "Digital", in: app)
        app.buttons["Done"].tap()
        app.buttons["tab.speed"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["speed.number.digital"].waitForExistence(timeout: 3))
    }

    private func scrollToSettingsControl(_ control: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !control.exists {
            app.swipeUp()
        }
    }

    private func tapSpeedNumberStyleOption(_ style: String, fallbackLabel: String, in app: XCUIApplication) {
        let identified = app.descendants(matching: .any)["settings.speed-number-style.option.\(style)"].firstMatch
        if identified.waitForExistence(timeout: 2), identified.isHittable {
            identified.tap()
            return
        }
        let label = fallbackLabel
        let candidates = [app.buttons[label], app.menuItems[label], app.staticTexts[label]]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) && candidate.isHittable {
            candidate.tap()
            return
        }
        XCTFail("Missing hittable menu choice \(label)")
    }

    func testWelcomeRouteShowsRideMetrics() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=welcome.route", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen.welcome"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Your ride. Your route."].exists)
        XCTAssertFalse(app.buttons["tab.hud"].exists)
    }

    func testWelcomeDisplayUsesProductionNumberAndGauge() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=welcome.display.swipe", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen.welcome"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Find your own pace"].exists)
        XCTAssertFalse(app.staticTexts["Everything you need on the road"].exists)
    }

    func testLongImportedGPXRemainsInteractiveWhileRecordingOnAutomaticAndForcedNativeMap() {
        for legacy in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=map.reference-route", "--ui-locale=en-US", "--ui-scheme=light", "--ui-long-route", "--ui-debug-paid", "--ui-map-follow-camera"]
            if !app.launchArguments.contains(where: { $0.hasPrefix("--ui-map-provider=") }) { app.launchArguments.append("--ui-map-provider=\(legacy ? "apple" : "openStreetMap")") }
                if legacy { app.launchArguments.append("--ui-legacy-map") }
            app.launch()
            let count = app.staticTexts["map.recorded-point-count"]
            XCTAssertTrue(count.waitForExistence(timeout: 10))
            let before = Int(count.label) ?? 0
            XCTAssertGreaterThanOrEqual(before, 7_200)
            let map = app.maps.firstMatch
            XCTAssertTrue(map.waitForExistence(timeout: 5))
            let cameraSpan = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'camera-span:'")).firstMatch
            XCTAssertTrue(cameraSpan.waitForExistence(timeout: 3))
            let originalSpan = latitudeSpan(from: stabilizedValue(of: cameraSpan, timeout: 3))
            map.pinch(withScale: 2, velocity: 1)
            let zoomed = waitForLatitudeSpan(of: cameraSpan, lessThan: originalSpan * 0.8)
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))
            XCTAssertEqual(latitudeSpan(from: mapSpanValue(of: cameraSpan)), zoomed, accuracy: max(0.0001, zoomed * 0.03), "GPS updates must preserve the selected zoom")
            map.swipeLeft(velocity: .slow)
            map.pinch(withScale: 0.5, velocity: -1)
            XCTAssertGreaterThan(Int(count.label) ?? 0, before, "Live GPS must keep advancing during gestures")
            XCTAssertTrue(app.buttons["map.reference-route.menu"].isHittable)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = legacy ? "long-route-forced-native" : "long-route-automatic-native"
            capture.lifetime = .keepAlways
            add(capture)
            app.buttons["trip.pause"].tap()
            XCTAssertTrue(app.buttons["trip.resume"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    func testSuppliedLongReferencePanAndFullscreen() throws {
        for legacy in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=map.reference-route", "--ui-locale=en-US", "--ui-scheme=light",
                "--ui-reference-route-file=marker-repro.gpx"]
            if !app.launchArguments.contains(where: { $0.hasPrefix("--ui-map-provider=") }) { app.launchArguments.append("--ui-map-provider=\(legacy ? "apple" : "openStreetMap")") }
                if legacy { app.launchArguments.append("--ui-legacy-map") }
            app.launch()
            guard app.staticTexts["201.71 km"].waitForExistence(timeout: 8) else {
                app.terminate()
                throw XCTSkip("Install the private 201.71 km reference as Documents/marker-repro.gpx")
            }
            let map = app.maps.firstMatch
            XCTAssertTrue(map.waitForExistence(timeout: 5))
            for fullscreen in [false, true] {
                if fullscreen { app.buttons["map.expand"].tap() }
                map.pinch(withScale: 2, velocity: 1)
                map.swipeLeft(velocity: .slow)
                map.swipeRight(velocity: .slow)
                map.pinch(withScale: 0.5, velocity: -1)
                let surface = fullscreen ? app.descendants(matching: .any)["screen.map.fullscreen"] : app
                XCTAssertTrue(surface.buttons["map.reference-route.menu"].isHittable)
                surface.buttons["map.reference-route.focus"].tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let capture = XCTAttachment(screenshot: app.screenshot())
                capture.name = "201km-\(legacy ? "legacy" : "modern")-\(fullscreen ? "full" : "normal")"
                capture.lifetime = .keepAlways
                add(capture)
            }
            app.buttons["map.collapse"].tap()
            XCTAssertTrue(app.buttons["map.expand"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    func testSuppliedGPXAtTwoAndSevenHoursRemainsInteractive() throws {
        for seconds in [7_200, 26_000] {
            for legacy in [true, false] {
                let app = XCUIApplication()
                app.launchArguments = ["--ui-screen=map.reference-route", "--ui-locale=en-US", "--ui-scheme=light", "--ui-long-route", "--ui-debug-paid", "--ui-map-follow-camera", "--ui-replay-trip", "--ui-replay-seconds=\(seconds)", "--ui-reference-route-file=performance-reference.gpx"]
                if !app.launchArguments.contains(where: { $0.hasPrefix("--ui-map-provider=") }) { app.launchArguments.append("--ui-map-provider=\(legacy ? "apple" : "openStreetMap")") }
                if legacy { app.launchArguments.append("--ui-legacy-map") }
                app.launch()
                let count = app.staticTexts["map.recorded-point-count"]
                XCTAssertTrue(count.waitForExistence(timeout: 10))
                guard count.value as? String == "supplied" else {
                    app.terminate()
                    throw XCTSkip("Install a private GPX fixture with scripts/test-long-route.sh before running this optional replay")
                }
                let before = Int(count.label) ?? 0
                XCTAssertGreaterThan(before, 1_000)
                let map = app.maps.firstMatch
                XCTAssertTrue(map.waitForExistence(timeout: 5))
                let span = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'camera-span:'")).firstMatch
                let initial = latitudeSpan(from: stabilizedValue(of: span, timeout: 3))
                map.pinch(withScale: 2, velocity: 1)
                _ = waitForLatitudeSpan(of: span, lessThan: initial * 0.8)
                map.swipeLeft(velocity: .slow)
                map.pinch(withScale: 0.5, velocity: -1)
                XCTAssertGreaterThan(Int(count.label) ?? 0, before)
                app.buttons["map.reference-route.menu"].tap()
                XCTAssertTrue(app.descendants(matching: .any)["map.reference-route.menu-panel"].waitForExistence(timeout: 3))
                let capture = XCTAttachment(screenshot: app.screenshot())
                capture.name = "supplied-route-\(seconds)-\(legacy ? "legacy" : "modern")"
                capture.lifetime = .keepAlways
                add(capture)
                app.terminate()
            }
        }
    }

    func testExportShowsPreparationCanCancelAndThenOpensFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=trips.export", "--ui-locale=en-US", "--ui-scheme=light", "--ui-export-slow"]
        app.launch()
        let gpx = app.buttons["route.export.gpx"]
        XCTAssertTrue(gpx.waitForExistence(timeout: 8))
        gpx.tap()
        let preparing = NSPredicate(format: "value CONTAINS %@", "Preparing route file")
        expectation(for: preparing, evaluatedWith: gpx)
        waitForExpectations(timeout: 3)
        let cancel = app.buttons["route.export.close"]
        XCTAssertTrue(cancel.isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "export-preparation"
        capture.lifetime = .keepAlways
        add(capture)
        cancel.tap()
        let export = app.buttons["route.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        export.tap()
        XCTAssertTrue(gpx.waitForExistence(timeout: 3))
        XCTAssertTrue(gpx.isEnabled)
        gpx.tap()
        XCTAssertTrue(app.navigationBars["Move"].waitForExistence(timeout: 15) || app.buttons["Save"].exists || app.buttons["Export"].exists)
    }

    func testUnknownTripActivityIsHiddenAndKnownActivityRemains() {
        let app = XCUIApplication()
        for unknown in [true, false] {
            app.launchArguments = ["--ui-screen=trips.detail", "--ui-locale=en-US", "--ui-scheme=light"]
            if unknown { app.launchArguments.append("--ui-unknown-activity") }
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["screen.trip-detail"].waitForExistence(timeout: 8))
            app.swipeUp()
            XCTAssertFalse(app.staticTexts["Activity unknown"].exists)
            XCTAssertEqual(app.staticTexts["Activity"].exists, !unknown)
            XCTAssertTrue(app.buttons["route.export"].isHittable)
            app.terminate()
        }
    }

    func testVideoSectionsOpenInfoOnBothMapRenderersAndSavedTrips() {
        for legacy in [true, false] {
            for screen in ["trips.video-sections", "map.video-sections", "map.video-sections-fullscreen"] {
                let app = XCUIApplication()
                app.launchArguments = ["--ui-screen=\(screen)", "--ui-locale=en-US", "--ui-scheme=light", "--ui-video-hit-probe"]
                if !app.launchArguments.contains(where: { $0.hasPrefix("--ui-map-provider=") }) { app.launchArguments.append("--ui-map-provider=\(legacy ? "apple" : "openStreetMap")") }
                if legacy { app.launchArguments.append("--ui-legacy-map") }
                app.launch()
                let root = screen == "map.video-sections-fullscreen"
                    ? app.descendants(matching: .any)["screen.map.fullscreen"] : app
                let path = root.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "video-path")).firstMatch
                guard path.waitForExistence(timeout: 10) else {
                    XCTFail("Missing video path: \(screen), legacy=\(legacy)\n\(app.debugDescription)"); return
                }
                path.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.descendants(matching: .any)["video.recording.info"].waitForExistence(timeout: 4))
                XCTAssertTrue(app.staticTexts.matching(identifier: "video.recording.filename").firstMatch.exists)
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "video.recording.duration").firstMatch.exists)
                XCTAssertTrue(app.staticTexts["Saved on the camera phone."].firstMatch.exists)
                app.buttons["Done"].firstMatch.tap()
                XCTAssertFalse(app.descendants(matching: .any)["video.recording.info"].exists)
                app.terminate()
            }
        }
    }

    func testVideoRoutesAtTwoAndSevenHoursStayInteractiveOnAutomaticAndForcedNativeMap() {
        for (provider, legacy) in [("openStreetMap", false), ("apple", false), ("apple", true)] {
            for seconds in [7200, 25200] {
                let app = XCUIApplication()
                app.launchArguments = ["--ui-screen=map.reference-route", "--ui-locale=en-US", "--ui-scheme=light",
                    "--ui-map-provider=\(provider)", "--ui-long-route", "--ui-long-seconds=\(seconds)", "--ui-video-route", "--ui-debug-paid", "--ui-video-hit-probe"]
                if !app.launchArguments.contains(where: { $0.hasPrefix("--ui-map-provider=") }) { app.launchArguments.append("--ui-map-provider=\(legacy ? "apple" : "openStreetMap")") }
                if legacy { app.launchArguments.append("--ui-legacy-map") }
                app.launch()
                let path = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "video-path")).firstMatch
                XCTAssertTrue(path.waitForExistence(timeout: 15))
                path.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.descendants(matching: .any)["video.recording.info"].waitForExistence(timeout: 4))
                app.buttons["Done"].firstMatch.tap()
                let map = app.descendants(matching: .any).matching(identifier: "map.live-route").firstMatch
                map.pinch(withScale: 1.3, velocity: 1)
                map.swipeLeft()
                app.buttons["map.reference-route.menu"].tap()
                XCTAssertTrue(app.switches["map.reference-route.visibility"].waitForExistence(timeout: 3))
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "video-route-\(provider)-\(seconds)-\(legacy ? "forced-native" : "automatic-native")"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }

    func testAcceleratedRecordingShowsMapWithoutGuidePublication() {
        let app = XCUIApplication()
        app.launchArguments = ["--debug-route-persistence-probe", "--debug-route-20h", "--debug-map-guides-off"]
        app.launch()
        defer { app.terminate() }
        // The shared holder publishes before its recorder starts. Readiness must
        // follow recorder changes even when no guide data ever arrives.
        XCTAssertTrue(app.staticTexts["probe.point-count"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["probe.route-map"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Full screen"].isHittable)
        app.buttons["Full screen"].tap()
        XCTAssertTrue(app.buttons["Normal"].waitForExistence(timeout: 5))
    }

    func testThousandKilometerReplayWithAndWithoutPlacesOnAutomaticAndForcedNativeMap() {
        for legacy in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--debug-route-persistence-probe", "--debug-route-1000km",
                "--debug-route-probe-seconds=1200"] + (legacy ? ["--ui-legacy-map", "--ui-map-provider=apple"] : ["--ui-map-provider=openStreetMap"])
            app.launch()
            let count = app.staticTexts["probe.point-count"]
            XCTAssertTrue(count.waitForExistence(timeout: 90))
            XCTAssertTrue(count.label.contains("180"))
            let toggle = app.switches["Places (1,000)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            // Separate the dense kilometre-spaced markers before testing a
            // real tap on a specific photo-bearing place.
            app.buttons["Photo close-up"].tap()
            let marker = app.descendants(matching: .any)["map.guide-point.long-place-496"].firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 20))
            waitForStableGuideMarker(marker)
            marker.tap()
            XCTAssertTrue(app.staticTexts["route-guide.point.summary"].waitForExistence(timeout: 10))
            app.buttons["Done"].firstMatch.tap()
            toggle.tap()
            app.buttons["Full screen"].tap()
            app.descendants(matching: .any)["probe.route-map"].firstMatch.pinch(withScale: 1.3, velocity: 1)
            app.descendants(matching: .any)["probe.route-map"].firstMatch.swipeLeft()
            toggle.tap()
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(count.waitForExistence(timeout: 15))
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "thousand-kilometer-\(legacy ? "forced-native" : "automatic-native")"
            capture.lifetime = .keepAlways; add(capture)
            app.terminate()
        }
    }

    func testOSMMapInstancesReleaseAfterRepeatedMapAndPhotoTransitions() {
        let app = XCUIApplication()
        app.launchArguments = ["--debug-route-persistence-probe", "--debug-route-1000km",
            "--debug-route-probe-seconds=1200", "--debug-map-provider=openStreetMap",
            "--debug-osm-lifetimes", "--ui-live-map-tiles"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["probe.point-count"].waitForExistence(timeout: 90))
        let probe = app.descendants(matching: .any)["map.osm-lifetimes"].firstMatch
        func released() {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "maps:1,coordinators:1"), object: probe)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, "Previous OSM map/coordinator must be released")
        }
        released()
        for cycle in 0..<10 {
            app.buttons["Pan test"].tap() // Recreate the real native map surface.
            released()
            app.buttons["Photo close-up"].tap()
            let marker = app.descendants(matching: .any)["map.guide-point.long-place-496"].firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 15))
            waitForStableGuideMarker(marker)
            marker.tap()
            XCTAssertTrue(app.staticTexts["route-guide.point.summary"].waitForExistence(timeout: 8))
            app.buttons["Done"].firstMatch.tap()
            app.buttons["Full screen"].tap()
            app.descendants(matching: .any)["probe.route-map"].firstMatch.pinch(withScale: 1.2, velocity: 1)
            app.buttons["Normal"].tap()
            if cycle % 3 == 0 { XCUIDevice.shared.press(.home); app.activate() }
            released()
        }
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "osm-after-ten-map-photo-cycles"; capture.lifetime = .keepAlways; add(capture)
    }

    func testOSMFullscreenMapReleasesAfterRepeatedPresentation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.guide", "--ui-locale=en-US", "--ui-scheme=light",
            "--ui-long-route", "--ui-long-seconds=25200", "--ui-video-route", "--ui-guide-photo",
            "--ui-guide-closeup", "--ui-debug-paid", "--ui-map-provider=openStreetMap",
            "--debug-osm-lifetimes", "--ui-live-map-tiles"]
        app.launch()
        defer { app.terminate() }
        func released() {
            let probe = app.descendants(matching: .any)["map.osm-lifetimes"].firstMatch
            XCTAssertTrue(probe.waitForExistence(timeout: 15))
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "maps:1,coordinators:1"), object: probe)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, "Dismissed full-screen maps must be released; counts: \(probe.value ?? "nil")")
        }
        released()
        for cycle in 0..<10 {
            app.buttons["map.expand"].tap()
            let fullscreen = app.descendants(matching: .any)["screen.map.fullscreen"]
            XCTAssertTrue(fullscreen.waitForExistence(timeout: 8))
            let marker = fullscreen.descendants(matching: .any)["map.guide-point.demo-0"].firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 8))
            waitForStableGuideMarker(marker)
            marker.tap()
            XCTAssertTrue(app.images["route-guide.photo.demo-photo"].waitForExistence(timeout: 8))
            app.buttons["Done"].firstMatch.tap()
            let photoClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.images["route-guide.photo.demo-photo"])
            XCTAssertEqual(XCTWaiter.wait(for: [photoClosed], timeout: 8), .completed)
            if cycle % 3 == 0 { XCUIDevice.shared.press(.home); app.activate() }
            let collapse = app.buttons["map.collapse"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: collapse)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
            collapse.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: fullscreen)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed, "Full-screen cover must actually dismiss")
            released()
        }
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "osm-after-ten-fullscreen-presentations"; capture.lifetime = .keepAlways; add(capture)
    }

    func testGuidePlacesWithSevenHourRecordingRemainInteractiveThroughBackground() {
        for legacy in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=map.guide", "--ui-locale=en-US", "--ui-scheme=light",
                "--ui-long-route", "--ui-long-seconds=25200", "--ui-video-route", "--ui-guide-photo",
                "--ui-guide-closeup", "--ui-debug-paid"] + (legacy ? ["--ui-legacy-map", "--ui-map-provider=apple"] : ["--ui-map-provider=openStreetMap"])
            app.launch()
            let count = app.staticTexts["map.recorded-point-count"]
            XCTAssertTrue(count.waitForExistence(timeout: 15))
            let before = Int(count.label) ?? 0
            XCTAssertGreaterThanOrEqual(before, 25_200)
            let marker = app.descendants(matching: .any)["map.guide-point.demo-0"].firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 5))
            waitForStableGuideMarker(marker)
            marker.tap()
            XCTAssertTrue(app.staticTexts["route-guide.point.summary"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["route-guide.photo.demo-photo"].waitForExistence(timeout: 5))
            app.buttons["Done"].firstMatch.tap()
            app.buttons["map.expand"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["screen.map.fullscreen"].waitForExistence(timeout: 5))
            let fullscreenMap = app.descendants(matching: .any)["screen.map.fullscreen"].descendants(matching: .any)["map.live-route"].firstMatch
            fullscreenMap.pinch(withScale: 1.3, velocity: 1)
            fullscreenMap.swipeLeft()
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "seven-hour-places-\(legacy ? "legacy" : "modern")"
            capture.lifetime = .keepAlways; add(capture)
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertFalse(app.descendants(matching: .any)["trip.recovery.prompt"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["screen.map.fullscreen"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testRecordingMapMetricsIncludeAverageAndVisibleRouteTotal() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.route-progress", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()
        let average = app.descendants(matching: .any)["map.average-speed"]
        XCTAssertTrue(average.waitForExistence(timeout: 5))
        XCTAssertTrue(average.label.contains("21 km/h"))
        let distance = app.descendants(matching: .any)["map.distance"]
        XCTAssertTrue(distance.label.contains(" of "))
        let normalDistance = distance.label
        app.buttons["map.expand"].tap()
        let expanded = app.descendants(matching: .any)["screen.map.fullscreen"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 4))
        XCTAssertTrue(expanded.descendants(matching: .any)["map.fullscreen.average-speed"].label.contains("21 km/h"))
        XCTAssertEqual(expanded.descendants(matching: .any)["map.fullscreen.distance"].label, normalDistance)
        app.buttons["map.collapse"].tap()
        app.buttons["trip.pause"].tap()
        XCTAssertTrue(average.exists)
        XCTAssertEqual(distance.label, normalDistance)
        app.buttons["map.reference-route.menu"].tap()
        let visibility = app.switches["map.reference-route.visibility"]
        tapSwitch(visibility)
        XCTAssertTrue(waitForSwitch(visibility, value: "0"))
        // The denominator follows route visibility, while recording metrics persist.
        XCTAssertFalse(distance.label.contains(" of "))
        XCTAssertTrue(average.exists)
    }

    func testIdleMapShowsZeroAverageInBothLayoutsWithoutRouteProgress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.reference-route", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()
        let distance = app.descendants(matching: .any)["map.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 5))
        let average = app.descendants(matching: .any)["map.average-speed"]
        XCTAssertTrue(average.label.contains("0 km/h"))
        XCTAssertFalse(distance.label.contains(" of "))
        app.buttons["map.expand"].tap()
        let expandedAverage = app.descendants(matching: .any)["map.fullscreen.average-speed"]
        XCTAssertTrue(expandedAverage.waitForExistence(timeout: 4))
        XCTAssertTrue(expandedAverage.label.contains("0 km/h"))
        XCTAssertTrue(expandedAverage.isHittable)
        app.buttons["map.collapse"].tap()
        XCTAssertTrue(average.isHittable)
    }

    func testMapRouteShowsCurrentSpeedCombinedTripSummaryAndRecordingControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.route", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["map.current-location"].waitForExistence(timeout: 5))
        let speed = app.descendants(matching: .any)["map.speed"]
        let summary = app.descendants(matching: .any)["map.trip-summary"]
        let duration = app.descendants(matching: .any)["map.duration"]
        let distance = app.descendants(matching: .any)["map.distance"]
        XCTAssertTrue(speed.waitForExistence(timeout: 3))
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(duration.waitForExistence(timeout: 3))
        XCTAssertTrue(distance.waitForExistence(timeout: 3))
        XCTAssertEqual(speed.label, "Current speed")
        XCTAssertEqual(speed.value as? String, "24 km/h")
        XCTAssertFalse(app.staticTexts["Current speed"].exists)
        XCTAssertLessThan(speed.frame.maxX, summary.frame.minX)
        XCTAssertLessThan(duration.frame.maxY, distance.frame.minY)
        XCTAssertTrue(summary.frame.contains(CGPoint(x: duration.frame.midX, y: duration.frame.midY)))
        XCTAssertTrue(summary.frame.contains(CGPoint(x: distance.frame.midX, y: distance.frame.midY)))

        let pause = app.descendants(matching: .any)["trip.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["trip.finish"].exists)
        pause.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.resume"].waitForExistence(timeout: 3))
    }

    func testLiveRouteExpandsToFullMapAndReturnsWithMetrics() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.route", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        let expand = app.buttons["map.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()

        let fullMap = app.descendants(matching: .any)["screen.map.fullscreen"]
        XCTAssertTrue(fullMap.waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["map.fullscreen.speed"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["map.fullscreen.duration"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["map.fullscreen.distance"].exists)

        let metrics = fullMap.descendants(matching: .any)["map.fullscreen.metrics"]
        let follow = fullMap.descendants(matching: .button)["map.follow-location"]
        let collapse = fullMap.descendants(matching: .button)["map.collapse"]
        XCTAssertTrue(metrics.exists)
        XCTAssertTrue(follow.isHittable)
        XCTAssertTrue(collapse.isHittable)
        XCTAssertGreaterThan(collapse.frame.minY, fullMap.frame.midY)
        XCTAssertLessThanOrEqual(follow.frame.maxY, collapse.frame.minY)
        XCTAssertLessThanOrEqual(collapse.frame.maxY, metrics.frame.minY)
        XCTAssertLessThanOrEqual(metrics.frame.minY - collapse.frame.maxY, 12)
        let clockToggle = fullMap.buttons["map.fullscreen.clock-toggle"]
        XCTAssertTrue(clockToggle.isHittable)
        XCTAssertEqual(clockToggle.frame.midX, metrics.frame.midX, accuracy: 2)
        XCTAssertFalse(fullMap.staticTexts["map.fullscreen.clock"].exists)
        let initialMetricsFrame = metrics.frame
        let initialFollowFrame = follow.frame
        let initialCollapseFrame = collapse.frame
        clockToggle.tap()
        let clock = fullMap.staticTexts["map.fullscreen.clock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 2))
        XCTAssertEqual(clock.frame.midX, metrics.frame.midX, accuracy: 2)
        XCTAssertEqual(metrics.frame, initialMetricsFrame)
        XCTAssertEqual(follow.frame, initialFollowFrame)
        XCTAssertEqual(collapse.frame, initialCollapseFrame)
        XCTAssertLessThan(clock.frame.maxY, metrics.frame.minY)
        XCTAssertLessThanOrEqual(follow.frame.maxY, collapse.frame.minY)
        XCTAssertTrue(clock.value as? String == nil || (clock.value as? String)?.contains(":") == true)
        XCTAssertFalse((clock.value as? String ?? clock.label).contains("AM"))
        XCTAssertFalse((clock.value as? String ?? clock.label).contains("PM"))
        clockToggle.tap()
        XCTAssertFalse(clock.exists)
        collapse.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.map"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["map.expand"].isHittable)
    }

    func testMapRouteEventMarkersCoverNoOneAndMultiplePauses() {
        let scenarios: [(String, Int, Int)] = [
            ("map.route", 0, 0),
            ("map.route-one-pause", 1, 1),
            ("map.route-multiple-pauses", 2, 2)
        ]
        for (screen, pauseCount, resumeCount) in scenarios {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=\(screen)", "--ui-locale=en-US", "--ui-scheme=dark"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["map.event.start"].waitForExistence(timeout: 4))
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "map.event.pause").count, pauseCount)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "map.event.resume").count, resumeCount)
            app.terminate()
        }
    }

    func testKilometerMarkersInNormalAndExpandedMapOnBothRenderers() {
        for legacy in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=map.reference-route", "--ui-locale=en-US", "--ui-scheme=light",
                "--ui-reference-route-file=marker-repro.gpx", "--ui-reference-marker-closeup"]
            if !app.launchArguments.contains(where: { $0.hasPrefix("--ui-map-provider=") }) { app.launchArguments.append("--ui-map-provider=\(legacy ? "apple" : "openStreetMap")") }
                if legacy { app.launchArguments.append("--ui-legacy-map") }
            app.launch()
            let expand = app.buttons["map.expand"]
            XCTAssertTrue(expand.waitForExistence(timeout: 8))
            func capture(_ name: String) {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "kilometer-\(legacy ? "legacy" : "modern")-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            capture("normal")
            expand.tap()
            let full = app.descendants(matching: .any)["screen.map.fullscreen"]
            XCTAssertTrue(full.waitForExistence(timeout: 5))
            capture("expanded")
            app.buttons["map.collapse"].tap()
            XCTAssertTrue(expand.waitForExistence(timeout: 5))
            capture("returned")
            app.terminate()
        }
    }

    func testImportedRouteMarkersCanBeHiddenAndReversedOnBothRenderers() {
        for legacy in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=map.reference-route", "--ui-locale=en-US", "--ui-scheme=light"]
            if !app.launchArguments.contains(where: { $0.hasPrefix("--ui-map-provider=") }) { app.launchArguments.append("--ui-map-provider=\(legacy ? "apple" : "openStreetMap")") }
                if legacy { app.launchArguments.append("--ui-legacy-map") }
            app.launch()
            let menu = app.buttons["map.reference-route.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 8))
            menu.tap()
            let marks = app.switches["map.reference-route.distance-markers"]
            XCTAssertTrue(marks.waitForExistence(timeout: 3))
            XCTAssertEqual(marks.value as? String, "1")
            tapSwitch(marks)
            XCTAssertTrue(waitForSwitch(marks, value: "0"))
            app.buttons["reference-route.reverse"].tap()
            XCTAssertTrue(app.staticTexts["Reversed direction"].waitForExistence(timeout: 2))
            tapSwitch(marks)
            XCTAssertTrue(waitForSwitch(marks, value: "1"))
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "reference-markers-reversed-\(legacy ? "legacy" : "modern")"
            capture.lifetime = .keepAlways
            add(capture)
            app.terminate()
        }
    }

    func testDisconnectedReferenceRouteHidesMarkerAndDirectionControls() {
        for screen in ["map.reference-route-menu", "settings.reference-routes"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=\(screen)", "--ui-locale=en-US", "--ui-scheme=light", "--ui-reference-disconnected"]
            app.launch()
            let identifier = screen.hasPrefix("map.") ? "map.reference-route.menu-panel" : "screen.reference-routes"
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 8))
            XCTAssertFalse(app.buttons["reference-route.reverse"].exists)
            XCTAssertFalse(app.switches["map.reference-route.distance-markers"].exists)
            XCTAssertFalse(app.switches["settings.reference-routes.distance-markers"].exists)
            app.terminate()
        }
    }

    func testImportedRouteSettingsExposeMarkerPreferenceAndDirection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.reference-routes", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()
        let marks = app.switches["settings.reference-routes.distance-markers"]
        XCTAssertTrue(marks.waitForExistence(timeout: 8))
        XCTAssertEqual(marks.value as? String, "1")
        tapSwitch(marks)
        XCTAssertTrue(waitForSwitch(marks, value: "0"))
        app.buttons["reference-route.reverse"].tap()
        XCTAssertTrue(app.staticTexts["Reversed direction"].exists)
    }

    func testReferenceRouteMenuSelectsAndTogglesVisibility() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-screen=map.reference-route",
            "--ui-locale=en-US",
            "--ui-scheme=dark"
        ]
        app.launch()

        let menu = app.buttons["map.reference-route.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertEqual(menu.value as? String, "Reference route options, On")
        menu.tap()

        let panel = app.descendants(matching: .any)["map.reference-route.menu-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let visibility = app.switches["map.reference-route.visibility"]
        XCTAssertTrue(visibility.isHittable)
        XCTAssertEqual(visibility.value as? String, "1")
        tapSwitch(visibility)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '0'"),
            object: visibility
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 2), .completed)

        let alternate = app.buttons["map.reference-route.option.E14FE010-A11B-40F8-84E0-B1455A879CA7"]
        XCTAssertTrue(alternate.isHittable)
        alternate.tap()

        XCTAssertFalse(panel.exists)
        XCTAssertEqual(menu.label, "Minsk training loop")
        XCTAssertEqual(menu.value as? String, "Reference route options, On")
    }

    func testReferenceRouteMenuStaysAccessibleInFullscreenSafeArea() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-screen=map.reference-route",
            "--ui-locale=en-US",
            "--ui-scheme=light"
        ]
        app.launch()

        let expand = app.buttons["map.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()

        let fullMap = app.descendants(matching: .any)["screen.map.fullscreen"]
        XCTAssertTrue(fullMap.waitForExistence(timeout: 4))
        let menu = fullMap.descendants(matching: .button)["map.reference-route.menu"]
        let collapse = fullMap.descendants(matching: .button)["map.collapse"]
        XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(collapse.isHittable)
        XCTAssertGreaterThanOrEqual(menu.frame.minY, 44)
        XCTAssertLessThan(menu.frame.maxX, collapse.frame.minX)

        menu.tap()
        let panel = app.descendants(matching: .any)["map.reference-route.menu-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(panel.frame.minY, 44)
        XCTAssertTrue(app.switches["map.reference-route.visibility"].isHittable)
    }

    func testReferenceRouteLibrarySelectsAndDeletesWithConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.reference-routes", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen.reference-routes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.reference-routes.import"].exists)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.reference-route.row.'"))
        XCTAssertEqual(rows.count, 2)
        rows.element(boundBy: 1).tap()
        XCTAssertEqual(rows.element(boundBy: 1).value as? String, "Selected")

        let firstDelete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.reference-route.delete.'")).firstMatch
        XCTAssertTrue(firstDelete.waitForExistence(timeout: 3))
        firstDelete.tap()
        let confirmation = app.descendants(matching: .any)["reference-route.delete.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertEqual(rows.count, 2)

        firstDelete.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons
            .matching(identifier: "reference-route.delete.confirmation")
            .matching(NSPredicate(format: "label == 'Delete'"))
            .firstMatch
            .tap()
        XCTAssertEqual(rows.count, 1)
    }

    func testReferenceRouteLibraryCanRenameAnImportedRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=settings.reference-routes", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen.reference-routes"].waitForExistence(timeout: 5))
        let rename = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.reference-route.rename.'")).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.tap()

        let confirmation = app.descendants(matching: .any)["reference-route.rename.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        let nameField = app.textFields["reference-route.rename.confirmation.name"]
        XCTAssertEqual(nameField.value as? String, "Minsk–Babruysk")
        nameField.tap()
        nameField.typeText(" edited")
        app.buttons["reference-route.rename.confirmation.confirm"].tap()

        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(app.staticTexts["Minsk–Babruysk edited"].waitForExistence(timeout: 3))
    }

    func testMapKeepsUserZoomAcrossPauseAndResume() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.route", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        let map = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'map.live-route' AND NOT label BEGINSWITH 'camera-span:'"))
            .firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        let cameraSpan = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'camera-span:'"))
            .firstMatch
        XCTAssertTrue(cameraSpan.waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let initialScale = stabilizedValue(of: cameraSpan, timeout: 3)
        map.pinch(withScale: 2.2, velocity: 1.0)

        app.descendants(matching: .any)["trip.pause"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.resume"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["trip.resume"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.pause"].waitForExistence(timeout: 3))
        let zoomedLatitudeSpan = waitForLatitudeSpan(
            of: cameraSpan,
            lessThan: latitudeSpan(from: initialScale) * 0.8
        )

        app.descendants(matching: .any)["trip.pause"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.resume"].waitForExistence(timeout: 3))
        waitForLatitudeSpan(of: cameraSpan, equalTo: zoomedLatitudeSpan)
    }

    func testFollowOffPreservesDistantReferenceAndFreePanWithLiveGPS() {
        for legacy in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-screen=map.reference-route", "--ui-locale=en-US", "--ui-scheme=light",
                "--ui-long-route", "--ui-debug-paid", "--ui-map-follow-camera", "--ui-distant-reference-route", "--ui-reference-route-file=follow-off-mogilev-vitebsk.gpx", "--ui-map-free-browse-probe",
                "--ui-long-seconds=\(legacy ? 7200 : 25200)"]
            if !app.launchArguments.contains(where: { $0.hasPrefix("--ui-map-provider=") }) { app.launchArguments.append("--ui-map-provider=\(legacy ? "apple" : "openStreetMap")") }
                if legacy { app.launchArguments.append("--ui-legacy-map") }
            app.launch()
            XCTAssertTrue(app.buttons["map.reference-route.focus"].firstMatch.waitForExistence(timeout: 10))
            let probe = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'camera-span:'")).firstMatch
            func center() -> [Double] {
                // Automatic large-route selection also uses native MapKit.
                // Read the actual probe representation, not the requested mode.
                if let value = probe.value as? String {
                    let coordinates = value.split(separator: ",").compactMap { Double($0) }
                    if coordinates.count == 2 { return coordinates }
                }
                guard let value = probe.label.components(separatedBy: ";center:").dropFirst().first else { return [] }
                return value.split(separator: ",").compactMap { Double($0) }
            }
            let follow = app.buttons["map.follow-location"].firstMatch
            follow.tap()
            app.buttons["Stop"].tap()
            XCTAssertEqual(follow.value as? String, "Off")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            for full in [false, true] {
                if full { app.buttons["map.expand"].tap() }
                app.buttons["map.reference-route.focus"].firstMatch.tap()
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    let value = center()
                    if value.count == 2, value[1] > 29 { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let routeCenter = center()
                XCTAssertEqual(routeCenter.count, 2)
                if routeCenter.count == 2 { XCTAssertGreaterThan(routeCenter[1], 29, "GPS must not pull Mogilev–Vitebsk back to Minsk") }
                let before = Int(app.staticTexts["map.recorded-point-count"].label) ?? 0
                app.maps.firstMatch.swipeLeft(velocity: .slow)
                // Let MapKit finish inertial scrolling before measuring GPS drift.
                var last = center()
                var stable = 0
                let settleDeadline = Date().addingTimeInterval(6)
                while Date() < settleDeadline, stable < 4 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    let next = center()
                    stable = next == last ? stable + 1 : 0
                    last = next
                }
                let panned = center()
                if panned.count == 2, routeCenter.count == 2 {
                    XCTAssertGreaterThan(abs(panned[1] - routeCenter[1]), 0.1, "Pan must actually move away from the route focus")
                }
                RunLoop.current.run(until: Date().addingTimeInterval(3))
                let retained = center()
                if panned.count == 2, retained.count == 2 {
                    XCTAssertEqual(retained[0], panned[0], accuracy: 0.001)
                    XCTAssertEqual(retained[1], panned[1], accuracy: 0.001)
                } else { XCTFail("Missing camera telemetry") }
                if !full { XCTAssertGreaterThan(Int(app.staticTexts["map.recorded-point-count"].label) ?? 0, before) }
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "follow-off-\(legacy ? "legacy" : "modern")-\(full ? "full" : "normal")"
                shot.lifetime = .keepAlways; add(shot)
            }
            app.buttons["map.follow-location"].firstMatch.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let followed = center()
            if followed.count == 2 { XCTAssertLessThan(followed[1], 29, "Enabling follow must return to live position") }
            app.terminate()
        }
    }

    func testMapFollowDoesNotFightUserZoomGesture() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-screen=map.route",
            "--ui-locale=en-US",
            "--ui-scheme=dark",
            "--ui-map-follow-camera"
        ]
        app.launch()

        let map = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'map.live-route' AND NOT label BEGINSWITH 'camera-span:'"))
            .firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        let cameraSpan = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'camera-span:'"))
            .firstMatch
        XCTAssertTrue(cameraSpan.waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let initialScale = stabilizedValue(of: cameraSpan, timeout: 3)
        map.pinch(withScale: 2.2, velocity: 1.0)

        // A state/location-style update must not replace the completed pinch camera.
        app.descendants(matching: .any)["trip.pause"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.resume"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["trip.resume"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.pause"].waitForExistence(timeout: 3))
        let zoomedLatitudeSpan = waitForLatitudeSpan(
            of: cameraSpan,
            lessThan: latitudeSpan(from: initialScale) * 0.8
        )

        // Once following resumes, it may recenter but must retain the user's zoom.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        app.descendants(matching: .any)["trip.pause"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.resume"].waitForExistence(timeout: 3))
        waitForLatitudeSpan(of: cameraSpan, equalTo: zoomedLatitudeSpan)
    }

    func testRouteExportShowsEveryFormatWithoutScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=trips.export", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen.route-export"].waitForExistence(timeout: 5))
        for identifier in ["route.export.gpx", "route.export.kml", "route.export.geojson", "route.export.csv"] {
            let format = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(format.waitForExistence(timeout: 3), "Missing initially visible \(identifier)")
            XCTAssertTrue(format.isHittable, "Format is below the initial safe viewport: \(identifier)")
        }
    }

    func testTripSwipeDeleteRequiresConfirmationAndCancelPreservesTrip() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=trips.populated", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        let tripRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'trip.row.'")).firstMatch
        XCTAssertTrue(tripRow.waitForExistence(timeout: 5))
        let deletedTripIdentifier = tripRow.identifier
        tripRow.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        app.buttons["Delete"].tap()

        let confirmation = app.descendants(matching: .any)["trip.delete.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(tripRow.waitForExistence(timeout: 3))

        tripRow.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.buttons["Delete"].tap()
        let removedTrip = app.buttons[deletedTripIdentifier]
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: removedTrip)
        waitForExpectations(timeout: 3)
    }

    func testHUDSettingsOptInOpensRotatesAndCloses() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=speed.idle", "--ui-locale=en-US", "--ui-debug-paid", "-hud_enabled", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["header.settings"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["header.hud"].exists)
        app.buttons["header.settings"].tap()
        let toggle = app.switches["settings.hud-enabled"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        captureSettings(app, "hud-settings-enabled")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["header.hud"].waitForExistence(timeout: 4))
        app.buttons["header.hud"].tap()
        XCTAssertTrue(app.buttons["hud.close"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1) // Allow the system orientation animation to finish.
        captureSettings(app, "hud-landscape")
        app.buttons["hud.mirror"].tap()
        app.buttons["hud.color"].tap()
        app.buttons["hud.rotate"].tap()
        Thread.sleep(forTimeInterval: 1)
        captureSettings(app, "hud-portrait")
        app.buttons["hud.close"].tap()
        XCTAssertTrue(app.buttons["header.settings"].waitForExistence(timeout: 5))
        app.buttons["header.settings"].tap()
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["header.hud"].exists)
    }

    func testMapComesFirstAndRetiredHUDIsAbsent() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=speed.idle", "--ui-locale=en-US", "--ui-scheme=dark"]
        app.launch()

        XCTAssertTrue(app.buttons["tab.trips"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["tab.hud"].exists)
        XCTAssertFalse(app.buttons["header.trips"].exists)

        let mapFrame = app.buttons["tab.map"].frame
        let speedFrame = app.buttons["tab.speed"].frame
        let historyFrame = app.buttons["tab.trips"].frame
        XCTAssertLessThan(mapFrame.maxX, speedFrame.minX)
        XCTAssertLessThan(speedFrame.maxX, historyFrame.minX)

        app.buttons["tab.trips"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.trips"].waitForExistence(timeout: 3))
    }

    func testBottomNavigationExposesOnlyTheCurrentTabAsSelected() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screen=map.route", "--ui-locale=en-US", "--ui-scheme=light"]
        app.launch()

        let speed = app.buttons["tab.speed"]
        let map = app.buttons["tab.map"]
        let trips = app.buttons["tab.trips"]
        XCTAssertTrue(map.waitForExistence(timeout: 4))
        XCTAssertTrue(map.isSelected)
        XCTAssertFalse(speed.isSelected)
        XCTAssertFalse(trips.isSelected)

        speed.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.speed"].waitForExistence(timeout: 3))
        XCTAssertTrue(speed.isSelected)
        XCTAssertFalse(map.isSelected)
    }

    func testPersistedCustomTabBarOrderLoadsItsFirstItemAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-spiderroute_welcome_v2_dismissed", "YES",
            "--ui-tab-order=trips,map,speed",
            "--ui-locale=en-US",
            "--ui-scheme=dark"
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen.trips"].waitForExistence(timeout: 7))
        let orderedTabs = ["tab.trips", "tab.map", "tab.speed"].map { app.buttons[$0] }
        for tab in orderedTabs {
            XCTAssertTrue(tab.waitForExistence(timeout: 2))
        }
        XCTAssertEqual(orderedTabs.map(\.frame.minX), orderedTabs.map(\.frame.minX).sorted())

        app.terminate()
        app.launchArguments = [
            "-spiderroute_welcome_v2_dismissed", "YES",
            "--ui-locale=en-US",
            "--ui-scheme=dark"
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.trips"].waitForExistence(timeout: 7))
        XCTAssertEqual(["tab.trips", "tab.map", "tab.speed"].map { app.buttons[$0].frame.minX }, orderedTabs.map(\.frame.minX).sorted())
    }

    private func waitForWindow(_ app: XCUIApplication, portrait: Bool) {
        let predicate = NSPredicate { object, _ in
            guard let window = object as? XCUIElement else { return false }
            return portrait ? window.frame.height > window.frame.width : window.frame.width > window.frame.height
        }
        expectation(for: predicate, evaluatedWith: app.windows.firstMatch)
        waitForExpectations(timeout: 5)
    }

    private func tapSwitch(_ element: XCUIElement) {
        // SwiftUI exposes the label and control as one wide accessibility frame.
        // Hit the actual trailing UISwitch rather than empty space beside its label.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }

    private func waitForSwitch(_ element: XCUIElement, value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }

    private func stabilizedValue(of element: XCUIElement, timeout: TimeInterval = 2) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = mapSpanValue(of: element)
        var matchingSamples = 0
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let current = mapSpanValue(of: element)
            if current == previous {
                matchingSamples += 1
                if matchingSamples >= 3 { return current }
            } else {
                previous = current
                matchingSamples = 0
            }
        }
        return previous
    }

    private func latitudeSpan(from value: String?) -> Double {
        guard let component = value?.split(separator: ",").first,
              let span = Double(component) else {
            XCTFail("Missing map latitude span")
            return .nan
        }
        return span
    }

    private func mapSpanValue(of element: XCUIElement) -> String? {
        if element.label.hasPrefix("camera-span:") {
            return String(element.label.dropFirst("camera-span:".count))
        }
        return element.value as? String
    }

    private func waitForLatitudeSpan(
        of element: XCUIElement,
        lessThan threshold: Double,
        timeout: TimeInterval = 3
    ) -> Double {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = latitudeSpan(from: mapSpanValue(of: element))
        while Date() < deadline {
            if latest < threshold { return latest }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            latest = latitudeSpan(from: mapSpanValue(of: element))
        }
        XCTFail("Map did not retain the requested zoom")
        return latest
    }

    private func waitForLatitudeSpan(
        of element: XCUIElement,
        equalTo expected: Double,
        accuracy: Double = 0.000_1,
        timeout: TimeInterval = 3
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = latitudeSpan(from: mapSpanValue(of: element))
        while Date() < deadline {
            if abs(latest - expected) <= accuracy { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            latest = latitudeSpan(from: mapSpanValue(of: element))
        }
        XCTAssertEqual(latest, expected, accuracy: accuracy)
    }

    private func expectedIdentifier(for screen: String) -> String {
        if screen == "reference-route.import-confirmation" { return "reference-route.import.confirmation" }
        if screen == "map.route-fullscreen" { return "screen.map.fullscreen" }
        if screen == "map.follow-disable-confirmation" { return "map.follow-location.disable-confirmation" }
        if screen == "map.finish-confirmation" { return "trip.finish.confirmation" }
        if screen == "trips.detail" { return "screen.trip-detail" }
        if screen == "trips.export" || screen == "trips.export-preparing" { return "screen.route-export" }
        if screen == "trips.delete-confirmation" { return "trip.delete.confirmation" }
        if screen == "settings.speed-alert" { return "screen.speed-alert-settings" }
        if screen == "settings.speed-colors" { return "screen.settings.speed-colors" }
        if screen == "settings.speed-colors-reset-confirmation" { return "settings.speed-colors.reset-confirmation" }
        if screen == "settings.bottom-navigation" { return "screen.settings.bottom-navigation" }
        if screen == "settings.reference-routes" { return "screen.reference-routes" }
        if screen == "settings.reference-route-rename" { return "reference-route.rename.confirmation" }
        if screen == "settings.reference-route-delete-confirmation" { return "reference-route.delete.confirmation" }
        if screen.hasPrefix("welcome.") { return "screen.welcome" }
        if screen.hasPrefix("paywall.") { return "screen.paywall" }
        if screen.hasPrefix("settings.") { return "screen.settings" }
        if screen.hasPrefix("map.") { return "screen.map" }
        if screen == "speed.finish-confirmation" { return "trip.finish.confirmation" }
        if screen == "trip.recovery" { return "trip.recovery.prompt" }
        if screen.hasPrefix("trips.") { return "screen.trips" }
        return "screen.speed"
    }
}
