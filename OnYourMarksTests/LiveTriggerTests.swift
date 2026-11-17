//
//  LiveTriggerTests.swift
//  OnYourMarksTests
//

import Testing
@testable import OnYourMarks

/// What the engine does with movements that waited for a second piece of
/// evidence, and with those that never got one.
@MainActor
struct LiveTriggerTests {
    private let good = TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1)

    /// An engine on a clock of the test's, a hold of 0.5 s and a gun of 0.4 s.
    private func makeEngine(
        athletes: [AthleteID]
    ) -> (StarterEngine, FakeSignalPlayer, FakeMovementDetector, StartConfig, ManualClock) {
        let clock = ManualClock()
        let player = FakeSignalPlayer()
        player.gunDuration = 0.4
        player.clock = clock

        let detector = FakeMovementDetector()
        detector.roster = AthleteRoster(
            entries: athletes.enumerated().map { AthleteRoster.Entry(id: $0.element, position: $0.offset + 1, quality: good) }
        )
        detector.clock = clock

        var config = StartConfig.instant
        config.blockTimeToStartMin = 0.5
        config.blockTimeToStartMax = 0.5

        let engine = StarterEngine(player: player, movementDetector: detector, clock: clock, decisionEngine: DecisionEngine())
        return (engine, player, detector, config, clock)
    }

    private func events(_ engine: StarterEngine) -> [StartEvent] {
        (engine.currentSession ?? engine.lastSession)?.events ?? []
    }

    @Test
    func anUnconfirmedMovementIsRecordedButNotJudged() async throws {
        let id = AthleteID()
        let (engine, player, detector, config, clock) = makeEngine(athletes: [id])

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        await clock.advance(by: 0.2)

        let crossing = clock.now()
        let glitch = MovementObservation(
            time: crossing,
            onset: TimeEstimate(best: crossing, earliest: MonotonicTimestamp(seconds: crossing.seconds - 0.01), latest: crossing),
            athleteID: id,
            quality: good
        )
        detector.onEvent?(.movementUnconfirmed(UnconfirmedMovement(glitch, athleteID: id, reason: .contradicted)))

        #expect(engine.athleteResults.isEmpty)
        #expect(engine.state == .waitForStart)
        #expect(player.recallCount == 0)

        let recorded = try #require(events(engine).first { $0.kind == .movementUnconfirmed(UnconfirmedMovement(glitch, athleteID: id, reason: .contradicted)) })
        #expect(recorded.time == glitch.onset)
        #expect(recorded.athleteID == id)

        // The start goes on to the gun.
        await clock.advance(by: 0.4)
        #expect(engine.state == .start)
        engine.abort()
    }

    /// The report waits for the second frame; the time doesn't. A crossing
    /// before the gun that is confirmed after the gun was committed is
    /// still a movement before the gun.
    @Test
    func aMovementIsTimedFromItsFirstFrameNotFromItsConfirmation() async throws {
        let id = AthleteID()
        let (engine, player, detector, config, clock) = makeEngine(athletes: [id])

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        await clock.advance(by: 0.5)
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)

        let crossing = MonotonicTimestamp(seconds: gun - 0.02)
        let confirmation = MonotonicTimestamp(seconds: gun + 0.01)
        let observation = MovementObservation(time: crossing, athleteID: id, quality: good, confirmedAt: confirmation)

        detector.onEvent?(.movement(observation))

        let result = try #require(engine.athleteResults.first)
        #expect(result.movement == .exact(crossing))
        #expect(result.decision == .definiteFalseStart)
        #expect(engine.state == .falseStart)

        let confirmed = try #require(events(engine).first { $0.kind == .movementConfirmed })
        #expect(confirmed.time == .exact(confirmation))
        #expect(confirmed.athleteID == id)

        engine.abort()
    }

    /// A detector that confirms in the frame itself, like one that needs no
    /// second frame, adds nothing to the record.
    @Test
    func aMovementConfirmedInItsOwnFrameRecordsNoConfirmation() async {
        let id = AthleteID()
        let (engine, _, detector, config, clock) = makeEngine(athletes: [id])

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        await clock.advance(by: 0.1)

        detector.emitMovement(at: clock.now().seconds, athlete: id, quality: good)

        #expect(!events(engine).contains { $0.kind == .movementConfirmed })
        engine.abort()
    }
}
