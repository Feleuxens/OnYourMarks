//
//  OnYourMarksUITests.swift
//  OnYourMarksUITests
//
//  Created by Felix on 11.06.26.
//

import XCTest

@MainActor
final class OnYourMarksUITests: XCTestCase {
    private var app: XCUIApplication!

    // Identifiers rather than labels, so the tests run in every language.
    private var startButton: XCUIElement { app.buttons["startButton"] }
    private var abortButton: XCUIElement { app.buttons["abortButton"] }
    private var errorAlert: XCUIElement { app.alerts.firstMatch }

    override func setUp() async throws {
        continueAfterFailure = false

        app = XCUIApplication()
        // Long wait before "On your marks", so no run ends on its own during a test.
        app.launchArguments += ["-starterConfig", Self.configArgument(blockTimeToReady: 20)]
        app.launch()

        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
    }

    /// A config as an old-style plist data literal, read by UserDefaults' argument domain.
    private static func configArgument(blockTimeToReady: Double) -> String {
        let json = #"{"blockTimeToReady": \#(blockTimeToReady), "startType": {"block": {}}}"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        return "<\(hex)>"
    }

    func testStartShowsAbortAndAbortReturnsToStart() {
        startButton.tap()

        XCTAssertTrue(abortButton.waitForExistence(timeout: 5))

        abortButton.tap()

        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertFalse(errorAlert.exists)
    }

    func testQuickStartAbortStartEndsRunning() {
        // Taps faster than the audio session can activate.
        startButton.tap()
        XCTAssertTrue(abortButton.waitForExistence(timeout: 5))
        abortButton.tap()
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        XCTAssertTrue(abortButton.waitForExistence(timeout: 5))
        XCTAssertFalse(errorAlert.exists)

        abortButton.tap()
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
    }

    func testControlsAreDisabledWhileRunning() {
        let standing = app.buttons["startType.standing"]
        XCTAssertTrue(standing.isEnabled)

        startButton.tap()
        XCTAssertTrue(abortButton.waitForExistence(timeout: 5))

        XCTAssertFalse(standing.isEnabled)

        abortButton.tap()
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertTrue(standing.isEnabled)
    }

    func testGoingToBackgroundAbortsRun() {
        startButton.tap()
        XCTAssertTrue(abortButton.waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))

        app.activate()

        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertFalse(errorAlert.exists)
    }

    func testStartAgainAfterBackgroundWorks() {
        startButton.tap()
        XCTAssertTrue(abortButton.waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))

        startButton.tap()

        XCTAssertTrue(abortButton.waitForExistence(timeout: 5))
        XCTAssertFalse(errorAlert.exists)

        abortButton.tap()
    }
    
    func testGermanInterfaceUsesTranslations() {
        // Apps launched by UI tests don't inherit -testLanguage; set it directly.
        app.terminate()
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["startType.standing"].label, "Hochstart")
        
        startButton.tap()
        XCTAssertTrue(abortButton.waitForExistence(timeout: 5))
        XCTAssertEqual(abortButton.label, "Abbrechen")
        
        abortButton.tap()
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
    }
    
    func testSettingsOfferOutputChoiceAndCalibration() {
        app.buttons["settingsButton"].tap()
        
        let picker = app.descendants(matching: .any)["outputPicker"]
        let found = picker.waitForExistence(timeout: 5) && app.buttons["calibrateButton"].exists
        
        if !found {
            add(XCTAttachment(string: app.debugDescription))
        }
        XCTAssertTrue(found)
    }
    
    func testRecordedStartsOpenFromTheToolbar() {
        app.buttons["recordingsButton"].tap()
        
        XCTAssertTrue(app.navigationBars.element.waitForExistence(timeout: 5))
        XCTAssertFalse(startButton.exists)
    }
    
    /// Kept also when the test passes: the picture is what there is to look at.
    private func keepScreenshot() {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    
    /// Needs a recording in the library; the simulator has no camera, so
    /// one is seeded there by `VideoRecordingTests/DemoRecordingTests` (TEST_RUNNER_SEED_RECORDING=1).
    func testReviewStepsThroughARecordedStart() throws {
        app.buttons["recordingsButton"].tap()
        
        let row = app.descendants(matching: .any)["recordingRow"].firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 3), "No recorded start in the library")
        row.tap()
        
        let frame = app.staticTexts["replayFrame"]
        XCTAssertTrue(frame.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["replayExportButton"].exists)
        
        keepScreenshot()
        
        let atTheGun = frame.label
        app.buttons["replayForwardButton"].tap()
        let next = frame.label
        XCTAssertNotEqual(next, atTheGun)
        
        app.buttons["replayBackButton"].tap()
        XCTAssertEqual(frame.label, atTheGun)
        
        app.buttons["replayForwardButton"].tap()
        app.buttons["replayGunButton"].tap()
        XCTAssertEqual(frame.label, atTheGun)
        
        // Picking an athlete shows where their movement began.
        let times = app.descendants(matching: .any)["reactionTimes"]
        if times.buttons.firstMatch.exists {
            times.buttons.firstMatch.tap()
            XCTAssertNotEqual(frame.label, atTheGun)
            keepScreenshot()
        }
    }
}
