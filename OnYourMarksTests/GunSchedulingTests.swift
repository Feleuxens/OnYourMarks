//
//  GunSchedulingTests.swift
//  OnYourMarksTests
//

import Testing
import QuartzCore
@testable import OnYourMarks

@MainActor
struct GunSchedulingTests {
    private func makeEngine(
        holdTime: Double,
        player: FakeSignalPlayer = FakeSignalPlayer()
    ) -> (StarterEngine, FakeSignalPlayer, FakeMovementDetector, StartConfig) {
        let detector = FakeMovementDetector()
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var config = StartConfig.instant
        config.blockTimeToStartMin = holdTime
        config.blockTimeToStartMax = holdTime
        
        return (engine, player, detector, config)
    }
    
    private func eventKinds(_ engine: StarterEngine) -> [StartEventKind] {
        (engine.currentSession ?? engine.lastSession)?.events.map(\.kind) ?? []
    }
    
    private func event(_ kind: StartEventKind, in engine: StarterEngine) -> StartEvent? {
        (engine.currentSession ?? engine.lastSession)?.events.first { $0.kind == kind }
    }
    
    @Test
    func gunIsScheduledWhenHoldBegins() async throws {
        let (engine, player, _, config) = makeEngine(holdTime: 0.3)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        let holdBegan = CACurrentMediaTime()
        
        #expect(player.scheduleRequests.count == 1)
        let requested = try #require(player.scheduleRequests.first)
        #expect(abs(requested.seconds - (holdBegan + 0.3)) < 0.05)
        
        engine.abort()
    }
    
    @Test
    func startStateIsNotReachedBeforeRenderStart() async throws {
        let player = FakeSignalPlayer()
        player.gunDuration = 1
        let (engine, _, _, config) = makeEngine(holdTime: 0.2, player: player)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        
        let renderStart = try #require(player.pendingSchedule?.renderStart)
        #expect(CACurrentMediaTime() >= renderStart.seconds)
        
        engine.abort()
    }
    
    @Test
    func scheduledAndMeasuredGunAreRecorded() async throws {
        let player = FakeSignalPlayer()
        player.outputLatency = 0.05
        let (engine, _, _, config) = makeEngine(holdTime: 0, player: player)
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        let kinds = eventKinds(engine)
        let scheduledIndex = try #require(kinds.firstIndex { $0.isGunScheduled })
        let measuredIndex = try #require(kinds.firstIndex(of: .gunPlaybackMeasured))
        #expect(scheduledIndex < measuredIndex)
        
        let scheduled = try #require(engine.lastSession?.events.first { $0.kind.isGunScheduled })
        #expect(scheduled.kind == .gunScheduled(player.preflight.gunTiming))
        let renderStart = try #require(player.scheduleRequests.first)
        #expect(scheduled.time.best.seconds == renderStart.seconds + 0.05)
        #expect(engine.lastSession?.outcome == .completed)
    }
    
    @Test
    func reactionIsMeasuredFromAudibleOnset() async throws {
        let player = FakeSignalPlayer()
        player.outputLatency = 0.05
        player.gunDuration = 1
        let (engine, _, detector, config) = makeEngine(holdTime: 0, player: player)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        
        let audible = try #require(player.pendingSchedule?.audibleOnset.best)
        detector.emitMovement(at: audible.seconds + 0.15)
        
        let reaction = try #require(engine.lastReactionTime)
        #expect(abs(reaction - 0.15) < 0.000_001)
        #expect(engine.lastDecision == .legal)
        
        engine.abort()
    }
    
    @Test
    func movementBetweenRenderAndAudibleOnsetIsFalseStart() async throws {
        let player = FakeSignalPlayer()
        player.outputLatency = 0.05
        player.gunDuration = 1
        let (engine, _, detector, config) = makeEngine(holdTime: 0, player: player)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        
        // Rendered already, but not yet heard.
        let renderStart = try #require(player.pendingSchedule?.renderStart)
        detector.emitMovement(at: renderStart.seconds + 0.01)
        
        #expect(engine.lastDecision == .definiteFalseStart)
        await waitUntil { !engine.isRunning }
        #expect(engine.lastSession?.outcome == .falseStart)
    }
    
    @Test
    func falseStartCancelsScheduledGun() async {
        let (engine, player, detector, config) = makeEngine(holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        #expect(player.pendingSchedule != nil)
        
        detector.emitMovement(at: CACurrentMediaTime())
        await waitUntil { !engine.isRunning }
        
        #expect(player.pendingSchedule == nil)
        #expect(!eventKinds(engine).contains(.gunPlaybackMeasured))
        #expect(engine.lastSession?.outcome == .falseStart)
    }
    
    @Test
    func abortCancelsScheduledGun() async {
        let (engine, player, _, config) = makeEngine(holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        engine.abort()
        
        #expect(player.pendingSchedule == nil)
        #expect(!eventKinds(engine).contains(.gunPlaybackMeasured))
    }
    
    @Test
    func failedScheduleFailsRun() async {
        let player = FakeSignalPlayer()
        player.failingSignal = .go
        let (engine, _, _, config) = makeEngine(holdTime: 0, player: player)
        
        var reportedError: String?
        engine.onError = { reportedError = $0 }
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        #expect(reportedError != nil)
        #expect(engine.lastSession?.outcome == reportedError.map(StartSessionOutcome.failed))
        #expect(!eventKinds(engine).contains { $0.isGunScheduled })
    }
    
    // MARK: - Precision window
    
    @Test
    func precisionWindowBeginsOneSecondBeforeTheGun() async throws {
        let (engine, player, detector, config) = makeEngine(holdTime: 1.6)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        // Monitoring runs from the start of the hold, the window opens later.
        #expect(detector.startCount == 1)
        #expect(!detector.isInPrecisionWindow)
        
        await waitUntil { detector.isInPrecisionWindow }
        
        let began = try #require(detector.precisionBegins.first)
        let gun = try #require(player.pendingSchedule?.renderStart.seconds)
        #expect(abs(gun - began - StarterEngine.precisionLead) < 0.1)
        
        engine.abort()
        #expect(!detector.isInPrecisionWindow)
    }
    
    @Test(arguments: [StartType.block, .standing])
    func shortHoldOpensTheWindowDuringTheCommandBefore(startType: StartType) async throws {
        let player = FakeSignalPlayer()
        player.commandDuration = 1.2
        let (engine, _, detector, _) = makeEngine(holdTime: 0, player: player)
        
        var config = StartConfig.instant
        config.startType = startType
        config.standingTimeToReady = 0
        config.blockTimeToStartMin = 0.3
        config.blockTimeToStartMax = 0.3
        config.standingTimeToStartMin = 0.3
        config.standingTimeToStartMax = 0.3
        
        engine.start(config: config)
        await waitUntil(timeout: .seconds(4)) { detector.isInPrecisionWindow }
        
        // Still in the last command: the hold alone is shorter than the lead.
        #expect(engine.state == (startType == .block ? .set : .onYourMarks))
        #expect(detector.startCount == 0)
        
        await waitUntil(timeout: .seconds(4)) { engine.state == .waitForStart }
        
        let began = try #require(detector.precisionBegins.first)
        let gun = try #require(player.pendingSchedule?.renderStart.seconds)
        #expect(abs(gun - began - StarterEngine.precisionLead) < 0.1)
        #expect(detector.precisionBegins.count == 1)
        
        engine.abort()
    }
    
    @Test
    func precisionWindowEndsWithTheRun() async throws {
        let (engine, _, detector, config) = makeEngine(holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        #expect(detector.precisionBegins.count == 1)
        #expect(detector.precisionEndCount == 1)
        
        let kinds = eventKinds(engine)
        let began = try #require(kinds.firstIndex(of: .precisionWindowBegan))
        let ended = try #require(kinds.firstIndex(of: .precisionWindowEnded))
        #expect(began < ended)
    }
    
    // MARK: - Preflight
    
    @Test
    func preflightIsRecordedBeforeTheFirstCommand() async throws {
        let (engine, player, _, config) = makeEngine(holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        let kinds = eventKinds(engine)
        let preparedIndex = try #require(kinds.firstIndex(of: .audioPrepared(player.preflight)))
        let firstCommandIndex = try #require(kinds.firstIndex(of: .stateChanged(.onYourMarks)))
        
        #expect(player.preflightCount == 1)
        #expect(preparedIndex < firstCommandIndex)
    }
    
    @Test
    func slowPreflightDelaysTheFirstCommand() async {
        let player = FakeSignalPlayer()
        player.preflightDuration = .milliseconds(300)
        let (engine, _, _, config) = makeEngine(holdTime: 0, player: player)
        
        let began = CACurrentMediaTime()
        engine.start(config: config)
        
        await waitUntil { engine.state == .preparing }
        #expect(player.played.isEmpty)
        
        await waitUntil { !player.played.isEmpty }
        #expect(CACurrentMediaTime() - began >= 0.3)
        
        await waitUntil { !engine.isRunning }
        #expect(engine.lastSession?.outcome == .completed)
    }
    
    @Test
    func preflightRunsWithinTheInitialWait() async {
        let player = FakeSignalPlayer()
        player.preflightDuration = .milliseconds(200)
        let (engine, _, _, _) = makeEngine(holdTime: 0, player: player)
        
        var config = StartConfig.instant
        config.blockTimeToReady = 0.4
        
        let began = CACurrentMediaTime()
        engine.start(config: config)
        await waitUntil { !player.played.isEmpty }
        let waited = CACurrentMediaTime() - began
        
        // The configured wait, not the wait plus the preflight.
        #expect(waited >= 0.4)
        #expect(waited < 0.55)
        
        engine.abort()
    }
    
    @Test
    func failedPreflightFailsRunBeforeAnySignal() async {
        let player = FakeSignalPlayer()
        player.preflightError = PreflightError.noOutput
        let (engine, _, _, config) = makeEngine(holdTime: 0, player: player)
        
        var reportedError: String?
        engine.onError = { reportedError = $0 }
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        #expect(reportedError != nil)
        #expect(engine.lastSession?.outcome == reportedError.map(StartSessionOutcome.failed))
        #expect(player.played.isEmpty)
    }
    
    @Test
    func abortDuringPreflightNeverPlays() async {
        let player = FakeSignalPlayer()
        player.preflightDuration = .milliseconds(200)
        let (engine, _, _, config) = makeEngine(holdTime: 0, player: player)
        
        var reportedError: String?
        engine.onError = { reportedError = $0 }
        
        engine.start(config: config)
        await waitUntil { player.preflightCount == 1 }
        engine.abort()
        
        try? await Task.sleep(for: .milliseconds(300))
        
        #expect(player.played.isEmpty)
        #expect(reportedError == nil)
        #expect(engine.lastSession?.outcome == .aborted)
    }
}

struct OutputTimingTests {
    @Test
    func wiredOutputsUseFixedUncertainty() {
        #expect(OutputTiming.uncertainty(latency: 0.010, isWireless: false) == OutputTiming.wiredUncertainty)
    }
    
    @Test(arguments: [0.010, 0.040, 0.200])
    func wirelessUncertaintyScalesWithLatency(latency: Double) {
        let uncertainty = OutputTiming.uncertainty(latency: latency, isWireless: true)
        
        #expect(uncertainty >= OutputTiming.minimumWirelessUncertainty)
        #expect(uncertainty >= latency * OutputTiming.wirelessUncertaintyShare)
    }
    
    @Test
    func audibleOnsetAddsLatencyAndOnset() {
        let onset = OutputTiming.audibleOnset(
            renderStart: MonotonicTimestamp(seconds: 100),
            latency: 0.012,
            onsetOffset: 0.024,
            uncertainty: 0.002
        )
        
        #expect(abs(onset.best.seconds - 100.036) < 0.000_000_1)
        #expect(abs(onset.earliest.seconds - 100.034) < 0.000_000_1)
        #expect(abs(onset.latest.seconds - 100.038) < 0.000_000_1)
    }
    
    @Test
    func minimumLeadCoversTwoRenderCycles() {
        #expect(OutputTiming.minimumLead(ioBufferDuration: 0.01) > 0.02)
    }
}
