//
//  CameraReliabilityTests.swift
//  OnYourMarksTests
//

import Testing
import CoreMedia
import Foundation
@testable import OnYourMarks

// MARK: - Frames arriving

struct FrameFlowTests {
    @Test
    func theFirstFrameBeginsTheFlow() {
        var flow = FrameFlow()

        #expect(flow.check(at: 100) == nil)
        #expect(!flow.isDelivering)

        #expect(flow.frameArrived(capturedAt: 99.98, arrivedAt: 100) == .began)
        #expect(flow.frameArrived(capturedAt: 99.99, arrivedAt: 100.01) == nil)
        #expect(flow.isDelivering)
    }

    @Test
    func framesStopAfterTheTimeout() {
        var flow = FrameFlow()
        _ = flow.frameArrived(capturedAt: 99.98, arrivedAt: 100)

        #expect(flow.check(at: 100 + FrameFlow.stallTimeout - 0.001) == nil)
        #expect(flow.check(at: 100 + FrameFlow.stallTimeout + 0.01) == .stopped(lastFrame: 99.98))
        #expect(!flow.isDelivering)

        // Said once.
        #expect(flow.check(at: 102) == nil)
        #expect(flow.frameArrived(capturedAt: 103, arrivedAt: 103.02) == .began)
    }

    @Test
    func aKnownInterruptionIsNotReportedAgain() {
        var flow = FrameFlow()
        _ = flow.frameArrived(capturedAt: 100, arrivedAt: 100)

        flow.interrupt()

        #expect(flow.check(at: 105) == nil)
        #expect(flow.frameArrived(capturedAt: 106, arrivedAt: 106) == .began)
    }

    @Test
    func aRestartIsNoPause() {
        var flow = FrameFlow()
        _ = flow.frameArrived(capturedAt: 100, arrivedAt: 100)

        // The restart blocked the session queue for 0.8 s.
        flow.expectFrames(from: 100.8)

        #expect(flow.check(at: 100.8 + FrameFlow.stallTimeout - 0.001) == nil)
        #expect(flow.check(at: 100.8 + FrameFlow.stallTimeout + 0.01) == .stopped(lastFrame: 100))
    }
}

// MARK: - The precision window

struct PrecisionWindowMonitorTests {
    private let opened: TimeInterval = 100

    private func monitor(maximumExposure: TimeInterval? = nil) -> PrecisionWindowMonitor {
        PrecisionWindowMonitor(requested: 120, expected: 120, openedAt: opened, maximumExposure: maximumExposure)
    }

    /// Sends frames at the rate from `start` on and returns the reports.
    private func send(
        _ count: Int,
        at rate: Double,
        from start: TimeInterval,
        to monitor: inout PrecisionWindowMonitor
    ) -> [PrecisionRateReport] {
        (0..<count).compactMap { monitor.frameArrived(at: start + Double($0) / rate).report }
    }

    private let still = PrecisionWindowMonitor.Exposure(isAdjusting: false, duration: 0.004)

    @Test
    func theRateArrivesByItself() throws {
        var window = monitor()

        // Idle frames, then the precision rate from 100.15 on.
        #expect(send(3, at: 15, from: 99.95, to: &window).isEmpty)
        let reports = send(10, at: 120, from: 100.15, to: &window)

        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.outcome == .arrived)
        #expect(report.arrivedAt?.seconds == 100.15)
        #expect(report.requestedAt.seconds == opened)
        #expect(report.restartedAt == nil)
        #expect(window.phase == .settling)
    }

    @Test
    func framesFromBeforeTheWindowDoNotCount() {
        var window = monitor()

        // At the rate, but captured before it was asked for.
        #expect(send(4, at: 120, from: opened - 4.0 / 120, to: &window).isEmpty)
        #expect(window.phase == .switching)
    }

    @Test
    func aRateThatDoesNotArriveRestartsTheSession() throws {
        var window = monitor()
        _ = send(6, at: 15, from: opened, to: &window)

        #expect(window.tick(at: opened + PrecisionWindowMonitor.arrivalDeadline - 0.001, exposure: still) == .none)
        #expect(window.tick(at: opened + PrecisionWindowMonitor.arrivalDeadline + 0.01, exposure: still).action == .restart)
        #expect(window.phase == .restarting)

        // Frames of the session that is stopping say nothing.
        #expect(send(4, at: 120, from: 100.42, to: &window).isEmpty)

        window.restarted(began: 100.45, finished: 101.2)
        #expect(window.phase == .switching)

        // The deadline counts from the end of the restart.
        #expect(window.tick(at: 101.2 + PrecisionWindowMonitor.arrivalDeadline - 0.001, exposure: still) == .none)

        let report = try #require(send(4, at: 120, from: 101.3, to: &window).first)
        #expect(report.outcome == .arrivedAfterRestart)
        #expect(report.restartedAt?.seconds == 101.2)
        #expect(report.arrivedAt?.seconds == 101.3)
    }

    @Test
    func afterOneRestartTheRateIsGivenUp() throws {
        var window = monitor()

        _ = window.tick(at: opened + 0.41, exposure: still)
        window.restarted(began: 100.41, finished: 100.9)
        _ = send(6, at: 15, from: 100.95, to: &window)

        let step = window.tick(at: 100.9 + PrecisionWindowMonitor.arrivalDeadline + 0.01, exposure: still)
        let report = try #require(step.report)

        #expect(step.action == nil)
        #expect(report.outcome == .missed)
        #expect(report.arrivedAt == nil)
        #expect(window.restarts == PrecisionWindowMonitor.maximumRestarts)
        #expect(window.phase == .settling)
    }

    @Test
    func settingsAreLockedOnceTheyHaveSettled() {
        var window = monitor(maximumExposure: 1.0 / 240)
        _ = send(4, at: 120, from: 100.15, to: &window)
        let arrival = 100.15 + 3.0 / 120

        // Not judged before the least time to settle.
        #expect(window.tick(at: arrival + 0.05, exposure: still) == .none)

        let adjusting = PrecisionWindowMonitor.Exposure(isAdjusting: true, duration: 0.004)
        #expect(window.tick(at: arrival + 0.2, exposure: adjusting) == .none)

        #expect(window.tick(at: arrival + 0.25, exposure: still).action == .lock(hasSettled: true))
        #expect(window.phase == .steady)
        #expect(window.tick(at: arrival + 1, exposure: still) == .none)
    }

    @Test
    func anExposureOverTheCapHasNotSettled() {
        var window = monitor(maximumExposure: 1.0 / 240)
        _ = send(4, at: 120, from: 100.15, to: &window)
        let arrival = 100.15 + 3.0 / 120

        let long = PrecisionWindowMonitor.Exposure(isAdjusting: false, duration: 1.0 / 120)
        #expect(window.tick(at: arrival + 0.3, exposure: long) == .none)

        // Locked as it is in the end: nothing must move during the hold.
        #expect(
            window.tick(at: arrival + PrecisionWindowMonitor.settleTimeout + 0.01, exposure: long).action
                == .lock(hasSettled: false)
        )
    }

    @Test
    func theDeliveryCountsFromTheArrival() throws {
        var window = monitor()
        _ = send(3, at: 15, from: 99.95, to: &window)
        _ = send(4, at: 120, from: 100.15, to: &window)

        for index in 4..<121 {
            _ = window.frameArrived(at: 100.15 + Double(index) / 120, exposure: 0.004, iso: index == 50 ? 500 : 400)
        }
        window.recordDropped(.late)

        let delivery = window.deliveryReport
        #expect(delivery.frames == 121)
        #expect(delivery.dropped == 1)
        #expect(abs(try #require(delivery.deliveredFrameRate) - 120) < 0.001)
        #expect(delivery.exposureDurations == 0.004...0.004)
        #expect(delivery.isoValues == 400...500)
        #expect(delivery.isReached)
    }

    @Test
    func dropsWhileSwitchingDoNotCount() {
        var window = monitor()
        window.recordDropped(.late)

        #expect(window.deliveryReport.dropped == 0)
    }
}

// MARK: - Exposure, focus and white balance

struct CaptureSettingsPolicyTests {
    private let wide = CMTime(value: 1, timescale: 100_000)...CMTime(value: 1, timescale: 2)

    @Test(arguments: [(60.0, Int64(8_333_333)), (120, 4_166_666), (240, 2_083_333)])
    func theExposureIsCappedAtHalfAFrame(rate: Double, nanoseconds: Int64) throws {
        let cap = try #require(CaptureSettingsPolicy.maximumExposure(frameRate: rate, supported: wide))

        #expect(cap.value == nanoseconds)
        #expect(cap.timescale == CaptureSettingsPolicy.exposureTimescale)
        #expect(cap.seconds <= CaptureSettingsPolicy.maximumExposureShare / rate)
    }

    @Test
    func theCapStaysWithinTheFormat() throws {
        let short = CMTime(value: 1, timescale: 100_000)...CMTime(value: 1, timescale: 1000)
        let long = CMTime(value: 1, timescale: 100)...CMTime(value: 1, timescale: 2)

        #expect(try #require(CaptureSettingsPolicy.maximumExposure(frameRate: 120, supported: short)) == short.upperBound)
        #expect(try #require(CaptureSettingsPolicy.maximumExposure(frameRate: 120, supported: long)) == long.lowerBound)
    }

    @Test
    func noCapWithoutARateOrTimes() {
        #expect(CaptureSettingsPolicy.maximumExposure(frameRate: 0, supported: wide) == nil)
        #expect(CaptureSettingsPolicy.maximumExposure(frameRate: 120, supported: CMTime.invalid...CMTime.invalid) == nil)
        #expect(CaptureSettingsPolicy.maximumExposure(frameRate: 120, supported: CMTime.zero...wide.upperBound) == nil)
    }

    @Test
    func onlySupportedModesAreSet() {
        let support = CaptureSettingsPolicy.Support(
            exposure: [.locked, .continuous],
            focus: [.continuous],
            whiteBalance: []
        )

        #expect(
            CaptureSettingsPolicy.modes(.locked, supported: support)
                == CaptureSettingsPolicy.Modes(exposure: .locked, focus: nil, whiteBalance: nil)
        )
        #expect(
            CaptureSettingsPolicy.modes(.continuous, supported: support)
                == CaptureSettingsPolicy.Modes(exposure: .continuous, focus: .continuous, whiteBalance: nil)
        )
    }
}

struct PrecisionRateDeliveryTests {
    @Test
    func aRateIsReachedFromNinetyPercent() {
        #expect(PrecisionRateDelivery.fake(delivered: 119.95).isReached)
        #expect(PrecisionRateDelivery.fake(delivered: 108).isReached)
        #expect(!PrecisionRateDelivery.fake(delivered: 107.9).isReached)
        #expect(!PrecisionRateDelivery.fake(delivered: 15).isReached)
        #expect(!PrecisionRateDelivery.fake(delivered: nil).isReached)
    }

    @Test
    func framesKeepTheirExposure() {
        var statistics = FrameStatistics()
        statistics.recordDelivered(at: 1, exposure: 0.004, iso: 400)
        statistics.recordDelivered(at: 2)
        statistics.recordDelivered(at: 3, exposure: 0.002, iso: 800)

        #expect(statistics.exposureDurations == 0.002...0.004)
        #expect(statistics.isoValues == 400...800)
    }

    @Test
    func cameraEventsSurviveStoring() throws {
        var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 1))
        let reports: [CameraReport] = [
            .prepared(CameraSetup(width: 1920, height: 1080, requestedFrameRate: 120, expectedFrameRate: 120)),
            .precisionRate(
                PrecisionRateReport(
                    requestedFrameRate: 120,
                    expectedFrameRate: 120,
                    outcome: .arrivedAfterRestart,
                    requestedAt: MonotonicTimestamp(seconds: 2),
                    restartedAt: MonotonicTimestamp(seconds: 2.5),
                    arrivedAt: MonotonicTimestamp(seconds: 2.6)
                )
            ),
            .restarted,
            .settingsLocked(.fake()),
            .failed(.interrupted(reason: 3), lastFrame: MonotonicTimestamp(seconds: 3)),
            .failed(.framesStopped, lastFrame: nil),
            .delivering,
            .delivered(.fake(delivered: 15)),
        ]
        for report in reports {
            session.record(.camera(report), at: .exact(MonotonicTimestamp(seconds: 4)), source: .cameraLocal)
        }

        let decoded = try JSONDecoder().decode(StartSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
    }
}

// MARK: - What the result says

struct CameraNoticeTests {
    private func session(_ kinds: [StartEventKind]) -> StartSession {
        var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 1))
        for kind in kinds {
            session.record(kind, at: .exact(MonotonicTimestamp(seconds: 2)), source: .system)
        }
        return session
    }

    @Test
    func aShortfallIsShownAndAReachedRateIsNot() {
        #expect(session([.camera(.delivered(.fake(delivered: 15)))]).precisionShortfall?.deliveredFrameRate == 15)
        #expect(session([.camera(.delivered(.fake(delivered: 119.9)))]).precisionShortfall == nil)
        #expect(session([]).precisionShortfall == nil)
    }

    @Test
    func onlyAFailureAfterTheGunIsShown() {
        let failure = StartEventKind.camera(.failed(.framesStopped, lastFrame: nil))

        #expect(session([.gunCommitted, failure]).cameraFailedAfterTheGun)
        #expect(!session([failure, .gunCommitted]).cameraFailedAfterTheGun)
        #expect(!session([failure]).cameraFailedAfterTheGun)
    }
}

// MARK: - The engine and the camera

@MainActor
struct CameraStartTests {
    private func makeEngine(
        holdTime: Double,
        camera: CameraCondition = .delivering(isSteady: false),
        clock: ManualClock
    ) -> (StarterEngine, FakeSignalPlayer, FakeMovementDetector, StartConfig) {
        let player = FakeSignalPlayer()
        player.clock = clock
        player.gunDuration = 1

        let detector = FakeMovementDetector()
        detector.clock = clock
        detector.setCamera(camera)

        let engine = StarterEngine(player: player, movementDetector: detector, clock: clock, decisionEngine: DecisionEngine())

        var config = StartConfig.instant
        config.blockTimeToStartMin = holdTime
        config.blockTimeToStartMax = holdTime

        return (engine, player, detector, config)
    }

    private func kinds(_ engine: StarterEngine) -> [StartEventKind] {
        (engine.currentSession ?? engine.lastSession)?.events.map { $0.kind } ?? []
    }

    private static let arrival = PrecisionRateReport(
        requestedFrameRate: 120,
        expectedFrameRate: 120,
        outcome: .arrived,
        requestedAt: MonotonicTimestamp(seconds: 1000),
        restartedAt: nil,
        arrivedAt: MonotonicTimestamp(seconds: 1000.15)
    )

    /// The window's rate arrived and the settings are held.
    private func steady(_ detector: FakeMovementDetector) {
        detector.changeCamera(to: .delivering(isSteady: false), reporting: .precisionRate(Self.arrival))
        detector.changeCamera(to: .delivering(isSteady: true), reporting: .settingsLocked(.fake()))
    }

    private func isFailed(_ engine: StarterEngine) -> Bool {
        if case .failed = engine.lastSession?.outcome { true } else { false }
    }

    // MARK: Preflight

    @Test
    func theCameraIsRecordedBeforeTheFirstCommand() async throws {
        let clock = ManualClock()
        let (engine, _, detector, config) = makeEngine(holdTime: 10, clock: clock)

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }

        let events = kinds(engine)
        let setup = try #require(detector.cameraSetup)
        let prepared = try #require(events.firstIndex(of: .camera(.prepared(setup))))
        let firstCommand = try #require(events.firstIndex(of: .stateChanged(.onYourMarks)))
        #expect(prepared < firstCommand)

        engine.abort()
    }

    @Test
    func withoutACameraNothingIsChecked() async {
        let clock = ManualClock()
        let (engine, player, _, config) = makeEngine(holdTime: 0, camera: .off, clock: clock)

        engine.start(config: config)
        await clock.advance(by: 1.1)

        #expect(engine.lastSession?.outcome == .completed)
        #expect(player.played == [.onYourMarks, .set, .go])
        #expect(!kinds(engine).contains { if case .camera = $0 { true } else { false } })
    }

    @Test(arguments: [CameraFault.interrupted(reason: 1), .framesStopped, .runtimeError("reset")])
    func aCameraThatDeliversNothingFailsTheStartBeforeAnySound(fault: CameraFault) async {
        let clock = ManualClock()
        let (engine, player, _, config) = makeEngine(holdTime: 0, camera: .failed(fault), clock: clock)

        var errors: [String] = []
        engine.onError = { errors.append($0) }

        engine.start(config: config)
        await waitUntil { !engine.isRunning }

        #expect(errors.count == 1)
        #expect(isFailed(engine))
        #expect(player.played.isEmpty)
    }

    @Test
    func aCameraJustSwitchedOnGetsTimeForItsFirstFrame() async {
        let clock = ManualClock()
        let (engine, player, detector, config) = makeEngine(holdTime: 10, camera: .starting, clock: clock)

        engine.start(config: config)
        await clock.advance(by: StarterEngine.cameraStartupTimeout - 0.01)

        #expect(engine.state == .preparing)
        #expect(player.played.isEmpty)

        detector.changeCamera(to: .delivering(isSteady: false), reporting: .delivering)
        await waitUntil { engine.state == .waitForStart }

        #expect(player.played == [.onYourMarks, .set])

        engine.abort()
    }

    @Test
    func aCameraWhoseFirstFrameNeverComesFailsTheStart() async {
        let clock = ManualClock()
        let (engine, player, _, config) = makeEngine(holdTime: 0, camera: .starting, clock: clock)

        var errors: [String] = []
        engine.onError = { errors.append($0) }

        engine.start(config: config)
        await clock.advance(by: StarterEngine.cameraStartupTimeout + 0.01)

        #expect(!engine.isRunning)
        #expect(errors.count == 1)
        #expect(isFailed(engine))
        #expect(player.played.isEmpty)
    }

    // MARK: Steady before the gun

    @Test
    func theGunWaitsForASteadyCamera() async throws {
        let clock = ManualClock()
        let (engine, player, detector, config) = makeEngine(holdTime: 0.5, clock: clock)

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        #expect(detector.isInPrecisionWindow)

        // Far longer than the hold; the athletes are ready all along.
        await clock.advance(by: 3)
        #expect(player.scheduleRequests.isEmpty)

        steady(detector)
        await waitUntil { !player.scheduleRequests.isEmpty }

        // The hold counts from the moment both were ready.
        #expect(player.scheduleRequests.first?.seconds == clock.now().seconds + 0.5)

        let events = kinds(engine)
        let arrived = try #require(events.firstIndex(of: .camera(.precisionRate(Self.arrival))))
        let locked = try #require(events.firstIndex(of: .camera(.settingsLocked(.fake()))))
        let ready = try #require(events.firstIndex(of: .athletesReady))
        #expect(arrived < locked)
        #expect(locked < ready)

        engine.abort()
    }

    @Test
    func aRestartedCameraIsRecorded() async {
        let clock = ManualClock()
        let (engine, player, detector, config) = makeEngine(holdTime: 0.5, clock: clock)

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }

        detector.changeCamera(to: .delivering(isSteady: false), reporting: .restarted)
        await clock.advance(by: 0.5)

        #expect(kinds(engine).contains(.camera(.restarted)))
        #expect(player.scheduleRequests.isEmpty)
        #expect(engine.isRunning)

        engine.abort()
    }

    @Test
    func aCameraThatNeverGetsSteadyFailsTheStart() async {
        let clock = ManualClock()
        let (engine, player, _, config) = makeEngine(holdTime: 0.5, clock: clock)
        engine.readinessTimeout = 1

        var errors: [String] = []
        engine.onError = { errors.append($0) }

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        await clock.advance(by: 1.01)

        #expect(!engine.isRunning)
        #expect(errors.count == 1)
        #expect(isFailed(engine))
        #expect(player.scheduleRequests.isEmpty)
    }

    @Test
    func aMissedRateLetsTheStartGoOn() async {
        let clock = ManualClock()
        let (engine, player, detector, config) = makeEngine(holdTime: 0.5, clock: clock)
        detector.delivery = .fake(delivered: 15)

        let missed = PrecisionRateReport(
            requestedFrameRate: 120,
            expectedFrameRate: 120,
            outcome: .missed,
            requestedAt: MonotonicTimestamp(seconds: 1000),
            restartedAt: MonotonicTimestamp(seconds: 1000.9),
            arrivedAt: nil
        )

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }

        detector.changeCamera(to: .delivering(isSteady: false), reporting: .precisionRate(missed))
        detector.changeCamera(to: .delivering(isSteady: true), reporting: .settingsLocked(.fake()))
        await waitUntil { !player.scheduleRequests.isEmpty }

        // The hold and the gun's sound.
        await clock.advance(by: 1.6)

        #expect(engine.lastSession?.outcome == .completed)
        #expect(kinds(engine).contains(.camera(.precisionRate(missed))))
        #expect(engine.lastSession?.precisionShortfall?.deliveredFrameRate == 15)
    }

    @Test
    func theDeliveredRateIsRecordedWithTheStart() async {
        let clock = ManualClock()
        let (engine, player, detector, config) = makeEngine(holdTime: 0.5, clock: clock)
        detector.delivery = .fake(delivered: 119.95)

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        steady(detector)
        await waitUntil { !player.scheduleRequests.isEmpty }
        await clock.advance(by: 1.6)

        #expect(engine.lastSession?.outcome == .completed)
        #expect(kinds(engine).contains(.camera(.delivered(.fake(delivered: 119.95)))))
        #expect(engine.lastSession?.precisionShortfall == nil)
    }

    // MARK: Failure during a start

    @Test
    func aCameraFailureBeforeTheGunTakesItBackAndFailsTheStart() async {
        let clock = ManualClock()
        let (engine, player, detector, config) = makeEngine(holdTime: 10, clock: clock)

        var errors: [String] = []
        engine.onError = { errors.append($0) }

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        steady(detector)
        await waitUntil { player.pendingSchedule != nil }

        let failure = CameraReport.failed(.interrupted(reason: 2), lastFrame: clock.now())
        detector.changeCamera(to: .failed(.interrupted(reason: 2)), reporting: failure)

        #expect(!engine.isRunning)
        #expect(player.pendingSchedule == nil)
        #expect(player.recallCount == 0)
        #expect(errors.count == 1)
        #expect(isFailed(engine))

        let events = kinds(engine)
        #expect(events.contains(.camera(failure)))
        #expect(events.contains(.gunCancelled))
        #expect(!events.contains(.gunCommitted))
        #expect(!detector.isInPrecisionWindow)
    }

    @Test
    func aCameraFailureDuringTheCommandsFailsTheStart() async {
        let clock = ManualClock()
        let (engine, player, detector, _) = makeEngine(holdTime: 1, clock: clock)
        player.commandDuration = 1

        var config = StartConfig.instant
        config.blockTimeToStartMin = 1
        config.blockTimeToStartMax = 1

        engine.start(config: config)
        await clock.advance(by: 0.5)
        #expect(engine.state == .onYourMarks)

        detector.changeCamera(to: .failed(.framesStopped), reporting: .failed(.framesStopped, lastFrame: nil))

        #expect(!engine.isRunning)
        #expect(isFailed(engine))
        #expect(player.played == [.onYourMarks])
    }

    @Test
    func afterTheGunAFailedCameraLeavesTheLaterAthletesWithoutAResult() async throws {
        let clock = ManualClock()
        let (engine, player, detector, config) = makeEngine(holdTime: 0, clock: clock)

        let first = AthleteID()
        let second = AthleteID()
        let quality = TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1)
        detector.roster = AthleteRoster(entries: [
            AthleteRoster.Entry(id: first, position: 1, quality: quality),
            AthleteRoster.Entry(id: second, position: 2, quality: quality),
        ])

        var errors: [String] = []
        engine.onError = { errors.append($0) }

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        steady(detector)
        await waitUntil { engine.state == .start }

        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        detector.emitMovement(at: gun + 0.15, athlete: first)

        // The last frame before the failure, then frames again after a gap.
        let failure = CameraReport.failed(.interrupted(reason: 1), lastFrame: MonotonicTimestamp(seconds: gun + 0.2))
        detector.changeCamera(to: .failed(.interrupted(reason: 1)), reporting: failure)
        #expect(engine.isRunning)

        detector.changeCamera(to: .delivering(isSteady: true), reporting: .delivering)
        detector.emitMovement(at: gun + 0.6, since: gun + 0.1, athlete: second)

        await clock.advance(by: engine.reactionWindow + 0.1)

        #expect(engine.lastSession?.outcome == .completed)
        #expect(errors.isEmpty)
        #expect(engine.athleteResults.map { $0.athleteID } == [first])
        #expect(engine.athleteResults.first?.decision == .legal)
        #expect(kinds(engine).contains(.camera(failure)))
        #expect(engine.lastSession?.cameraFailedAfterTheGun == true)
    }

    @Test
    func aMovementConfirmedOnceTheCameraCameBackIsNotJudged() async throws {
        let clock = ManualClock()
        let (engine, player, detector, config) = makeEngine(holdTime: 0, clock: clock)

        let athlete = AthleteID()
        let quality = TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1)
        detector.roster = AthleteRoster(entries: [AthleteRoster.Entry(id: athlete, position: 1, quality: quality)])

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        steady(detector)
        await waitUntil { engine.state == .start }

        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)

        // Crossed before the last frame, confirmed by one after the gap.
        let failure = CameraReport.failed(.interrupted(reason: 1), lastFrame: MonotonicTimestamp(seconds: gun + 0.03))
        detector.changeCamera(to: .failed(.interrupted(reason: 1)), reporting: failure)
        detector.changeCamera(to: .delivering(isSteady: true), reporting: .delivering)
        detector.emitMovement(at: gun + 0.02, since: gun, athlete: athlete, quality: quality, confirmedAt: gun + 0.08)

        await clock.advance(by: engine.reactionWindow + 0.1)

        #expect(engine.lastSession?.outcome == .completed)
        #expect(engine.athleteResults.isEmpty)
        #expect(player.played == [.onYourMarks, .set, .go])
    }
}
