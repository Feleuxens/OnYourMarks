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

    private var startButton: XCUIElement { app.buttons["Start"] }
    private var abortButton: XCUIElement { app.buttons["Abbrechen"] }
    private var errorAlert: XCUIElement { app.alerts["OnYourMarks Error"] }

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
        let standing = app.buttons["Hochstart"]
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
}
