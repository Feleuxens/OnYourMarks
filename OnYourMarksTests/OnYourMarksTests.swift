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

}



@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }

        await Task.yield()
    }

    #expect(condition())
}
