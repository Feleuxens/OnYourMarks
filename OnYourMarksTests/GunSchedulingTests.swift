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
        let scheduledIndex = try #require(kinds.firstIndex(of: .gunScheduled))
        let measuredIndex = try #require(kinds.firstIndex(of: .gunPlaybackMeasured))
        #expect(scheduledIndex < measuredIndex)
        
        let scheduled = try #require(event(.gunScheduled, in: engine))
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
        
        #expect(reportedError?.contains("schedule") == true)
        #expect(!eventKinds(engine).contains(.gunScheduled))
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
