//
//  ReadinessTests.swift
//  OnYourMarksTests
//

import Testing
import QuartzCore
@testable import OnYourMarks

@MainActor
struct ReadinessTests {
    private func makeEngine(
        holdTime: Double,
        ready: Bool = true
    ) -> (StarterEngine, FakeSignalPlayer, FakeMovementDetector, StartConfig) {
        let player = FakeSignalPlayer()
        player.gunDuration = 1
        
        let detector = FakeMovementDetector()
        detector.setReady(ready)
        
        var config = StartConfig.instant
        config.blockTimeToStartMin = holdTime
        config.blockTimeToStartMax = holdTime
        
        return (StarterEngine(player: player, movementDetector: detector), player, detector, config)
    }
    
    private func kinds(_ engine: StarterEngine) -> [StartEventKind] {
        (engine.currentSession ?? engine.lastSession)?.events.map { $0.kind } ?? []
    }
    
    /// Gives already scheduled tasks a chance to run before checking that nothing happened.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
    
    @Test
    func theGunWaitsUntilTheAthletesHoldStill() async throws {
        let (engine, player, detector, config) = makeEngine(holdTime: 0.2, ready: false)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        await settle()
        
        #expect(player.scheduleRequests.isEmpty)
        #expect(!kinds(engine).contains(.athletesReady))
        
        let becameReady = CACurrentMediaTime()
        detector.setReady(true)
        await waitUntil { !player.scheduleRequests.isEmpty }
        
        // The hold counts from the moment they were still.
        let requested = try #require(player.scheduleRequests.first?.seconds)
        #expect(requested >= becameReady + 0.2)
        #expect(requested < becameReady + 0.3)
        
        let events = kinds(engine)
        let ready = try #require(events.firstIndex(of: .athletesReady))
        let scheduled = try #require(events.firstIndex { $0.isGunScheduled })
        #expect(ready < scheduled)
        
        await waitUntil { !engine.isRunning }
        #expect(engine.lastSession?.outcome == .completed)
    }
    
    @Test
    func losingReadinessBeforeTheGunIsArmedKeepsWaiting() async {
        let (engine, player, detector, config) = makeEngine(holdTime: 10, ready: false)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        // Wakes the wait without anything to do.
        detector.onEvent?(.readinessChanged(false))
        await settle()
        
        #expect(player.scheduleRequests.isEmpty)
        #expect(engine.isRunning)
        
        engine.abort()
    }
    
    @Test
    func theStartIsGivenUpWhenNobodyHoldsStill() async {
        let (engine, player, _, config) = makeEngine(holdTime: 0, ready: false)
        engine.readinessTimeout = 0.1
        
        var errors: [String] = []
        engine.onError = { errors.append($0) }
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        #expect(errors.count == 1)
        #expect(player.scheduleRequests.isEmpty)
        #expect(!player.played.contains(.go))
        
        if case .failed = engine.lastSession?.outcome {} else {
            Issue.record("The start should have failed")
        }
    }
    
    @Test
    func anUnsteadyAthleteTakesTheGunBackWithoutAFault() async {
        let id = AthleteID()
        let (engine, player, detector, config) = makeEngine(holdTime: 10)
        detector.roster = AthleteRoster(
            entries: [AthleteRoster.Entry(id: id, position: 1, quality: TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1))]
        )
        detector.isReadyAfterResettle = false
        
        engine.start(config: config)
        await waitUntil { player.pendingSchedule != nil }
        
        detector.emitUnsteady(at: CACurrentMediaTime(), athlete: id)
        await waitUntil { player.pendingSchedule == nil }
        
        #expect(detector.resettled == [id])
        #expect(engine.isRunning)
        #expect(engine.state == .waitForStart)
        #expect(engine.athleteResults.isEmpty)
        #expect(player.recallCount == 0)
        
        let events = (engine.currentSession?.events ?? [])
        #expect(events.first { $0.kind == .athleteUnsteady(nil) }?.athleteID == id)
        #expect(events.contains { $0.kind == .gunCancelled })
        
        // Still again: the gun is armed anew with a fresh hold.
        await settle()
        #expect(player.scheduleRequests.count == 1)
        
        detector.setReady(true)
        await waitUntil { player.scheduleRequests.count == 2 }
        
        #expect(player.pendingSchedule != nil)
        #expect(kinds(engine).filter { $0 == .athletesReady }.count == 2)
        
        engine.abort()
    }
    
    @Test
    func theStartIsGivenUpAfterTooManyRestarts() async {
        let (engine, player, detector, config) = makeEngine(holdTime: 10)
        
        var errors: [String] = []
        engine.onError = { errors.append($0) }
        
        engine.start(config: config)
        
        for restart in 0...StarterEngine.maximumHoldRestarts {
            await waitUntil { player.scheduleRequests.count == restart + 1 }
            #expect(engine.isRunning)
            detector.emitUnsteady(at: CACurrentMediaTime())
        }
        
        await waitUntil { !engine.isRunning }
        
        #expect(errors.count == 1)
        #expect(player.scheduleRequests.count == StarterEngine.maximumHoldRestarts + 1)
        #expect(kinds(engine).filter { $0 == .gunCancelled }.count == StarterEngine.maximumHoldRestarts + 1)
        #expect(player.recallCount == 0)
    }
    
    @Test
    func unsteadinessWhileStillWaitingOnlyResettles() async {
        let (engine, player, detector, config) = makeEngine(holdTime: 10, ready: false)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        detector.emitUnsteady(at: CACurrentMediaTime())
        await settle()
        
        #expect(detector.resettled.count == 1)
        #expect(kinds(engine).contains(.athleteUnsteady(nil)))
        #expect(!kinds(engine).contains(.gunCancelled))
        #expect(player.scheduleRequests.isEmpty)
        
        engine.abort()
    }
    
    @Test
    func unsteadinessAfterTheGunIsIgnored() async {
        let (engine, player, detector, config) = makeEngine(holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        
        detector.emitUnsteady(at: CACurrentMediaTime())
        await settle()
        
        #expect(detector.resettled.isEmpty)
        #expect(!kinds(engine).contains(.athleteUnsteady(nil)))
        #expect(player.pendingSchedule != nil)
        
        engine.abort()
    }
    
    @Test
    func aStartMovementDuringTheHoldIsStillAFalseStart() async {
        let (engine, player, detector, config) = makeEngine(holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { player.pendingSchedule != nil }
        
        detector.emitMovement(at: CACurrentMediaTime())
        await waitUntil { !engine.isRunning }
        
        #expect(engine.lastSession?.outcome == .falseStart)
        #expect(!kinds(engine).contains(.gunCancelled))
    }
    
    @Test
    func theDetectorGetsTheProfileOfTheStartType() async {
        let (engine, _, detector, config) = makeEngine(holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        #expect(detector.profiles == [.block])
        engine.abort()
        
        var standing = config
        standing.startType = .standing
        standing.standingTimeToReady = 0
        standing.standingTimeToStartMin = 10
        standing.standingTimeToStartMax = 10
        
        engine.start(config: standing)
        await waitUntil { engine.state == .waitForStart }
        #expect(detector.profiles == [.block, .standing])
        engine.abort()
    }
}
