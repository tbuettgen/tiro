import XCTest
import notify

/// Drives the real app with a fake microphone (TIRO_FAKE_MIC, DEBUG builds
/// only) that "records" a spoken WAV, so the whole pipeline runs: model
/// download, whisper.cpp, formatting, history, and the keyboard session the
/// Tiro keyboard uses — commands over Darwin notifications while the app is
/// in the background. Run in order (test1…, test2…): the first installs the model.
final class TiroUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        let wav = Bundle(for: Self.self).path(forResource: "dictation", ofType: "wav")!
        app.launchEnvironment["TIRO_FAKE_MIC"] = wav
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["TIRO_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func allowSystemAlertIfShown() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] where sb.buttons[label].waitForExistence(timeout: 3) {
            sb.buttons[label].tap()
            return
        }
    }

    func test1_OnboardingDownloadsModelThenDictates() throws {
        app.launch()
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        shot("01-onboarding")
        next.tap()
        XCTAssertTrue(app.staticTexts["Nothing leaves your iPhone"].waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.staticTexts["Microphone"].waitForExistence(timeout: 5))
        shot("02-mic")
        let wasAsking = next.label == "Allow microphone"
        next.tap()
        if wasAsking { allowSystemAlertIfShown() }
        XCTAssertTrue(app.staticTexts["One download, then offline"].waitForExistence(timeout: 10))
        shot("03-model")
        if next.label.hasPrefix("Download") { next.tap() }
        XCTAssertTrue(waitForLabel(next, "Start dictating", timeout: 300), "model download finished")
        next.tap()

        // Dictate tab
        let mic = app.buttons["dictate.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        XCTAssertFalse(next.exists, "onboarding closed")
        shot("04-dictate-empty")
        mic.tap()
        XCTAssertTrue(waitForLabel(mic, "Stop dictating", timeout: 5))
        sleep(3)
        shot("05-recording")
        sleep(6)
        mic.tap()
        let result = app.staticTexts["dictate.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 60), "transcribed and formatted")
        XCTAssertTrue(result.label.contains("See you soon."), result.label)
        XCTAssertTrue(result.label.contains("Hello Beckett, this is a test of"), result.label)
        XCTAssertTrue(result.label.contains("\nSee you soon."), "new line command applied: \(result.label)")
        XCTAssertFalse(result.label.lowercased().contains("scratch"), result.label)
        shot("06-result")
    }

    private func waitForLabel(_ e: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let exp = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: e)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    func test2_KeyboardSessionRecordsAndTranscribesInBackground() throws {
        app.launch()
        let title = app.staticTexts["session.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let before = app.staticTexts["dictate.result"].exists ? app.staticTexts["dictate.result"].label : ""
        app.open(URL(string: "tiro://dictate")!)
        XCTAssertTrue(waitForLabel(title, "Keyboard is live", timeout: 10), "session started")
        shot("07-session-live")

        // Leave Tiro, like going back to Messages; drive it as the keyboard does.
        XCUIDevice.shared.press(.home)
        sleep(1)
        notify_post("dev.tiro.cmd.start")
        sleep(9)
        notify_post("dev.tiro.cmd.stop")
        sleep(8) // transcription runs in the background

        app.activate()
        let result = app.staticTexts["dictate.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 30), "background take transcribed")
        XCTAssertTrue(result.label.contains("See you soon."), result.label)
        _ = before
        shot("08-after-background-take")

        app.tabBars.buttons["History"].tap()
        let rows = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'See you soon.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(rows.count, 2, "both takes in history")
        shot("09-history")

        app.tabBars.buttons["Dictionary"].tap()
        shot("10-dictionary")
        app.tabBars.buttons["Settings"].tap()
        shot("11-settings")
        app.tabBars.buttons["Dictate"].tap()
        app.buttons["End"].tap()
        XCTAssertTrue(waitForLabel(title, "Dictate in any app", timeout: 5), "session ended")
    }

    /// The real keyboard: turn it on in the Settings app (with Full Access),
    /// switch to it in a text field, tap its mic, and check the text lands.
    func test3_RealKeyboardInsertsDictation() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        /// Tap a Settings row (cell or button, never the navigation title).
        func tapCell(_ prefix: String, in a: XCUIApplication, timeout: TimeInterval = 10) {
            let pred = NSPredicate(format: "label BEGINSWITH %@", prefix)
            func find() -> XCUIElement? {
                let cell = a.cells.matching(pred).firstMatch
                if cell.exists { return cell }
                let buttons = a.buttons.matching(pred).allElementsBoundByIndex.filter { b in
                    !a.navigationBars.buttons.allElementsBoundByIndex.contains(b)
                }
                if let b = buttons.first(where: { $0.isHittable }) { return b }
                let texts = a.staticTexts.matching(pred).allElementsBoundByIndex.filter { t in
                    !a.navigationBars.staticTexts.allElementsBoundByIndex.contains(t) && t.isHittable
                }
                return texts.last
            }
            let deadline = Date().addingTimeInterval(timeout)
            var swipes = 0
            while Date() < deadline {
                if let el = find() { el.tap(); return }
                if swipes < 6 { a.swipeUp(); swipes += 1 } else { usleep(300_000) }
            }
            XCTFail("\(prefix) in Settings")
        }
        tapCell("General", in: settings)
        tapCell("Keyboard", in: settings)
        tapCell("Keyboards", in: settings)
        shot("12-settings-keyboards")
        let already = settings.cells.matching(NSPredicate(format: "label BEGINSWITH 'Tiro'")).firstMatch
        if !already.exists {
            tapCell("Add New Keyboard", in: settings)
            tapCell("Tiro", in: settings)
        }
        tapCell("Tiro", in: settings)
        let fullAccess = settings.switches.matching(NSPredicate(format: "label BEGINSWITH 'Allow Full Access'")).firstMatch
        XCTAssertTrue(fullAccess.waitForExistence(timeout: 10))
        for _ in 0..<3 where (fullAccess.value as? String) != "1" {
            // Tap the toggle itself (the row's label area doesn't flip it).
            fullAccess.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let allow = settings.alerts.buttons.matching(NSPredicate(format: "label == 'Allow'")).firstMatch
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            sleep(1)
        }
        XCTAssertEqual(fullAccess.value as? String, "1", "Full Access on")
        shot("13-settings-full-access")

        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Set up the keyboard"].firstMatch.tap()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()

        // Switch keyboards until Tiro's mic bar shows up.
        let dictate = app.buttons["tiro.kb.mic"]
        for _ in 0..<6 where !dictate.waitForExistence(timeout: 2) {
            let globe = app.buttons["Next keyboard"]
            guard globe.exists else { break }
            globe.tap()
        }
        XCTAssertTrue(dictate.waitForExistence(timeout: 5), "Tiro keyboard is showing")
        shot("14-tiro-keyboard")
        dictate.tap() // opens tiro://dictate → session starts and records

        let finish = app.buttons["tiro.kb.mic"]
        XCTAssertTrue(waitForLabel(finish, "Finish dictation", timeout: 15), "keyboard shows recording")
        sleep(3)
        shot("15-keyboard-recording")
        sleep(6)
        finish.tap()
        let inserted = NSPredicate(format: "value CONTAINS 'See you soon.'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: inserted, evaluatedWith: field)], timeout: 60), .completed,
                       "keyboard inserted the take: \(field.value ?? "")")
        shot("16-keyboard-inserted")
    }
}
