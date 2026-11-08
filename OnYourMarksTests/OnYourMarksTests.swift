//
//  OnYourMarksTests.swift
//  OnYourMarksTests
//
//  Created by Felix on 11.06.26.
//

import Testing
import Foundation
import QuartzCore
@testable import OnYourMarks

struct OnYourMarksTests {

    @Test
    @MainActor
    func normalBlockSequenceCompletes() async {
        let player = FakeSignalPlayer()
        let detector = FakeMovementDetector()
        
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var config = StartConfig.standard
        
        config.blockTimeToReady = 0
        config.blockTimeToSet = 0
        config.blockTimeToStartMin = 0
        config.blockTimeToStartMax = 0
        
        engine.start(config: config)
        
        await waitUntil {
            !engine.isRunning
        }
        
        #expect(
            player.played == [
                .onYourMarks,
                .set,
                .go
            ]
        )
        #expect(engine.state == .idle)
    }
    
    @Test
    @MainActor
    func abortCancelsPendingSequences() async {
        let player = FakeSignalPlayer()
        let detector = FakeMovementDetector()
        
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var config = StartConfig.standard
        
        config.blockTimeToReady = 10
        
        engine.start(config: config)
        await waitUntil {
            engine.isRunning
        }
        
        engine.abort()
        
        #expect(!engine.isRunning)
        #expect(engine.state == .idle)
        #expect(engine.lastSession?.outcome == .aborted)
        
        // Give potentially scheduled jobs a chance to run
        for _ in 0..<10 {
            await Task.yield()
        }
        
        #expect(player.played.isEmpty)
    }
    
    @Test
    @MainActor
    func abortWithReasonMarksSessionFailed() async {
        let player = FakeSignalPlayer()
        let detector = FakeMovementDetector()
        
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var runEndedCount = 0
        engine.onRunEnded = { runEndedCount += 1 }
        
        var config = StartConfig.standard
        config.blockTimeToReady = 10
        
        engine.start(config: config)
        engine.abort(reason: "Audio output changed")
        
        #expect(!engine.isRunning)
        #expect(engine.state == .idle)
        #expect(engine.lastSession?.outcome == .failed("Audio output changed"))
        #expect(runEndedCount == 1)
        
        for _ in 0..<10 {
            await Task.yield()
        }
        
        #expect(player.played.isEmpty)
    }
    
    @Test
    @MainActor
    func twoConsecutiveStartsWork() async {
        let player = FakeSignalPlayer()
        let detector = FakeMovementDetector()
        
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var config = StartConfig.standard
        
        config.blockTimeToReady = 0
        config.blockTimeToSet = 0
        config.blockTimeToStartMin = 0
        config.blockTimeToStartMax = 0
        
        engine.start(config: config)
        await waitUntil {
            !engine.isRunning
        }
        
        engine.start(config: config)
        await waitUntil {
            !engine.isRunning
        }
        
        #expect(
            player.played == [
                .onYourMarks,
                .set,
                .go,
                .onYourMarks,
                .set,
                .go
            ]
        )
    }
    
    @Test
    @MainActor
    func audioFailureStopsSequence() async {
        let player = FakeSignalPlayer()
        player.failingSignal = .set
        
        let detector = FakeMovementDetector()
        
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var reportedError: String?
        
        engine.onError = {
            reportedError = $0
        }
        
        var config = StartConfig.standard
        
        config.blockTimeToReady = 0
        config.blockTimeToSet = 0
        config.blockTimeToStartMin = 0
        config.blockTimeToStartMax = 0
        
        engine.start(config: config)
        
        await waitUntil {
            !engine.isRunning
        }
        
        #expect(reportedError != nil)
        #expect(!player.played.contains(.go))
    }
    
    @Test
    @MainActor
    func preGunMovementTriggersFalseStart() async {
        let player = FakeSignalPlayer()
        let detector = FakeMovementDetector()
        
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var config = StartConfig.standard
        
        config.blockTimeToReady = 0
        config.blockTimeToSet = 0
        config.blockTimeToStartMin = 10
        config.blockTimeToStartMax = 10
        
        engine.start(config: config)
        
        await waitUntil {
            engine.state == .waitForStart
        }
        
        detector.emitMovement(at: CACurrentMediaTime())
        
        await waitUntil {
            !engine.isRunning
        }
        
        #expect(player.recallCount == 3)
        #expect(engine.state == .idle)
    }
    
    @Test
    @MainActor
    func diagnosticsAreLoggedAfterGun() async {
        let player = FakeSignalPlayer()
        let engine = StarterEngine(player: player, movementDetector: FakeMovementDetector())
        
        engine.start(config: .instant)
        await waitUntil { !engine.isRunning }
        
        #expect(player.diagnostics.count == 1)
        // All three signals, including the gun, had played before logging.
        #expect(player.diagnostics.first?.playedCount == 3)
    }
    
    @Test
    @MainActor
    func standingSequenceHasNoSetSignal() async {
        let player = FakeSignalPlayer()
        let engine = StarterEngine(player: player, movementDetector: FakeMovementDetector())
        
        var config = StartConfig.instant
        config.startType = .standing
        config.standingTimeToReady = 0
        config.standingTimeToStartMin = 0
        config.standingTimeToStartMax = 0
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        #expect(player.played == [.onYourMarks, .go])
        #expect(engine.lastSession?.outcome == .completed)
    }
    
    @Test
    @MainActor
    func randomStartTimeStaysWithinConfiguredRange() {
        let engine = StarterEngine(player: FakeSignalPlayer(), movementDetector: FakeMovementDetector())
        
        var config = StartConfig.standard
        // Swapped on purpose: the engine accepts min and max in either order.
        config.blockTimeToStartMin = 3
        config.blockTimeToStartMax = 1
        
        for _ in 0..<100 {
            let wait = engine.buildSequence(config: config)
                .first { $0.state == .waitForStart }?
                .duration
            
            #expect(wait.map { (1...3).contains($0) } == true)
        }
    }
    
    @Test
    @MainActor
    func startWhileRunningIsIgnored() async {
        let player = FakeSignalPlayer()
        let engine = StarterEngine(player: player, movementDetector: FakeMovementDetector())
        
        var config = StartConfig.instant
        config.blockTimeToReady = 10
        
        engine.start(config: config)
        let session = engine.currentSession
        
        engine.start(config: .instant)
        
        #expect(engine.currentSession?.createdAt == session?.createdAt)
        
        engine.abort()
        #expect(player.played.isEmpty)
    }
    
    @Test
    @MainActor
    func abortWhenIdleDoesNothing() {
        let engine = StarterEngine(player: FakeSignalPlayer(), movementDetector: FakeMovementDetector())
        
        var runEndedCount = 0
        engine.onRunEnded = { runEndedCount += 1 }
        
        engine.abort()
        
        #expect(runEndedCount == 0)
        #expect(engine.lastSession == nil)
    }
    
    @Test
    @MainActor
    func falseStartIsRecordedAndStopsMonitoring() async {
        let player = FakeSignalPlayer()
        let detector = FakeMovementDetector()
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var runEndedCount = 0
        engine.onRunEnded = { runEndedCount += 1 }
        
        var config = StartConfig.instant
        config.blockTimeToStartMin = 10
        config.blockTimeToStartMax = 10
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        #expect(detector.startCount == 1)
        
        detector.emitMovement(at: CACurrentMediaTime())
        await waitUntil { !engine.isRunning }
        
        #expect(engine.lastSession?.outcome == .falseStart)
        #expect(engine.lastDecision == .definiteFalseStart)
        #expect(detector.stopCount == 1)
        #expect(player.recallCount == 3)
        #expect(runEndedCount == 1)
    }
    
    @Test
    @MainActor
    func movementBeforeSetIsIgnored() async {
        let player = FakeSignalPlayer()
        let detector = FakeMovementDetector()
        let engine = StarterEngine(player: player, movementDetector: detector)
        
        var config = StartConfig.instant
        config.blockTimeToReady = 10
        
        engine.start(config: config)
        detector.emitMovement(at: CACurrentMediaTime())
        
        #expect(engine.isRunning)
        #expect(engine.state != .falseStart)
        #expect(engine.lastDecision == nil)
        
        engine.abort()
    }
}

extension StartConfig {
    /// Block start without any waiting between the signals.
    static var instant: StartConfig {
        var config = StartConfig.standard
        config.blockTimeToReady = 0
        config.blockTimeToSet = 0
        config.blockTimeToStartMin = 0
        config.blockTimeToStartMax = 0
        return config
    }
}
