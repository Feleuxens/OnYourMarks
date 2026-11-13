//
//  MultiAthleteStartTests.swift
//  OnYourMarksTests
//

import Testing
import QuartzCore
@testable import OnYourMarks

@MainActor
struct MultiAthleteStartTests {
    private let good = TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1)
    private let poor = TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 0.2)
    
    private func roster(_ ids: [AthleteID]) -> AthleteRoster {
        AthleteRoster(
            entries: ids.enumerated().map {
                AthleteRoster.Entry(id: $0.element, position: $0.offset + 1, quality: good)
            }
        )
    }
    
    /// An engine whose detector reports the given athletes as its roster.
    private func makeEngine(
        athletes: [AthleteID],
        holdTime: Double
    ) -> (StarterEngine, FakeSignalPlayer, FakeMovementDetector, StartConfig) {
        let player = FakeSignalPlayer()
        player.gunDuration = 1
        
        let detector = FakeMovementDetector()
        detector.roster = roster(athletes)
        
        var config = StartConfig.instant
        config.blockTimeToStartMin = holdTime
        config.blockTimeToStartMax = holdTime
        
        return (StarterEngine(player: player, movementDetector: detector), player, detector, config)
    }
    
    private func events(_ engine: StarterEngine) -> [StartEvent] {
        (engine.currentSession ?? engine.lastSession)?.events ?? []
    }
    
    @Test
    func rosterIsRecordedWhenMonitoringBegins() async {
        let ids = [AthleteID(), AthleteID()]
        let (engine, _, _, config) = makeEngine(athletes: ids, holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        #expect(engine.roster == roster(ids))
        
        let kinds = events(engine).map { $0.kind }
        let monitoring = kinds.firstIndex(of: .monitoringStarted)
        #expect(monitoring != nil)
        #expect(monitoring.map { kinds[$0 + 1] } == .rosterEstablished(roster(ids)))
        
        engine.abort()
    }
    
    /// An engine on a clock of the test's, with a gun of 0.4 s.
    private func makeTimedEngine(
        athletes: [AthleteID]
    ) -> (StarterEngine, FakeSignalPlayer, FakeMovementDetector, StartConfig, ManualClock) {
        let clock = ManualClock()
        let player = FakeSignalPlayer()
        player.gunDuration = 0.4
        player.clock = clock
        
        let detector = FakeMovementDetector()
        detector.roster = roster(athletes)
        detector.clock = clock
        
        var config = StartConfig.instant
        config.blockTimeToStartMin = 0.5
        config.blockTimeToStartMax = 0.5
        
        let engine = StarterEngine(player: player, movementDetector: detector, clock: clock, decisionEngine: DecisionEngine())
        return (engine, player, detector, config, clock)
    }
    
    /// The gun's sound is over long before a slow start reaches the pose
    /// threshold; on the device a standing start took 0.52 s.
    @Test
    func aReactionAfterTheGunsSoundIsStillMeasured() async throws {
        let ids = [AthleteID(), AthleteID()]
        let (engine, player, detector, config, clock) = makeTimedEngine(athletes: ids)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        await clock.advance(by: 0.5)
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        await clock.advance(by: 0.6)
        #expect(engine.isRunning)
        #expect(engine.state == .start)
        
        detector.emitMovement(at: gun + 0.52, athlete: ids[0], quality: good)
        #expect(engine.isRunning)
        
        // The last athlete's movement ends the run.
        detector.emitMovement(at: gun + 0.58, athlete: ids[1], quality: good)
        await waitUntil { !engine.isRunning }
        
        #expect(engine.lastSession?.outcome == .completed)
        #expect(engine.athleteResults.map { $0.decision } == [.legal, .legal])
        #expect(abs((engine.athleteResults.first?.reaction?.best ?? 0) - 0.52) < 0.000_001)
    }
    
    /// With the recall switched off a false start is measured and shown,
    /// and the start goes on for everyone.
    @Test
    func withoutRecallAFalseStartIsMarkedAndTheStartGoesOn() async throws {
        let ids = [AthleteID(), AthleteID()]
        let (engine, player, detector, base, clock) = makeTimedEngine(athletes: ids)
        var config = base
        config.recallsFalseStarts = false
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        // The first athlete leaves 0.3 s before the gun.
        await clock.advance(by: 0.2)
        detector.emitMovement(at: clock.now().seconds, athlete: ids[0], quality: good)
        
        #expect(engine.athleteResults.map { $0.decision } == [.definiteFalseStart])
        #expect(engine.state == .waitForStart)
        #expect(detector.stopCount == 0)
        
        await clock.advance(by: 0.3)
        #expect(engine.state == .start)
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        // The other one is measured against the gun as usual.
        await clock.advance(by: 0.2)
        detector.emitMovement(at: gun + 0.18, athlete: ids[1], quality: good)
        await clock.advance(by: 0.3)
        
        #expect(!engine.isRunning)
        #expect(engine.lastSession?.outcome == .completed)
        #expect(engine.athleteResults.map { $0.decision } == [.definiteFalseStart, .legal])
        #expect(player.recallCount == 0)
        #expect(player.played.contains(.go))
        #expect(events(engine).filter { $0.kind == .recallSkipped }.map { $0.athleteID } == [ids[0]])
    }
    
    @Test
    func withoutRecallAReactionThatIsTooFastIsOnlyMarked() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, base) = makeEngine(athletes: ids, holdTime: 0)
        var config = base
        config.recallsFalseStarts = false
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.05, athlete: ids[0], quality: good)
        await waitUntil { !engine.isRunning }
        
        #expect(engine.athleteResults.map { $0.decision } == [.definiteFalseStart])
        #expect(engine.lastSession?.outcome == .completed)
        #expect(player.recallCount == 0)
    }
    
    @Test
    func theRunEndsWhenNobodyMovesWithinTheReactionWindow() async throws {
        let (engine, _, _, config, clock) = makeTimedEngine(athletes: [AthleteID()])
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        await clock.advance(by: 0.5 + engine.reactionWindow - 0.01)
        #expect(engine.isRunning)
        
        await clock.advance(by: 0.02)
        #expect(!engine.isRunning)
        #expect(engine.lastSession?.outcome == .completed)
        #expect(engine.athleteResults.isEmpty)
    }
    
    @Test
    func withoutAthletesTheRunEndsWithTheGunsSound() async throws {
        let (engine, _, _, config, clock) = makeTimedEngine(athletes: [])
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        await clock.advance(by: 0.5 + 0.39)
        #expect(engine.isRunning)
        
        await clock.advance(by: 0.02)
        #expect(!engine.isRunning)
    }
    
    @Test
    func eachAthleteGetsTheirOwnReaction() async throws {
        let ids = [AthleteID(), AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.15, athlete: ids[1], quality: good)
        
        // The other athlete is still being watched.
        #expect(detector.stopCount == 0)
        #expect(detector.isInPrecisionWindow)
        
        detector.emitMovement(at: gun + 0.18, athlete: ids[0], quality: good)
        
        #expect(engine.athleteResults.map { $0.athleteID } == [ids[1], ids[0]])
        #expect(engine.athleteResults.map { $0.position } == [2, 1])
        #expect(engine.athleteResults.map { $0.decision } == [.legal, .legal])
        
        let reactions = engine.athleteResults.compactMap { $0.reaction?.best }
        try #require(reactions.count == 2)
        #expect(abs(reactions[0] - 0.15) < 0.000_001)
        #expect(abs(reactions[1] - 0.18) < 0.000_001)
        
        // Everyone has moved: nothing is left to watch.
        #expect(detector.stopCount == 1)
        #expect(!detector.isInPrecisionWindow)
        
        let decisions = events(engine).filter { $0.kind == .decision(.legal) }
        #expect(decisions.map { $0.athleteID } == [ids[1], ids[0]])
        
        engine.abort()
    }
    
    @Test
    func anAthleteIsJudgedOnlyOnce() async throws {
        let ids = [AthleteID(), AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.15, athlete: ids[0], quality: good)
        detector.emitMovement(at: gun + 0.16, athlete: ids[0], quality: good)
        
        #expect(engine.athleteResults.count == 1)
        
        engine.abort()
    }
    
    @Test
    func someoneOutsideTheRosterIsNotJudged() async {
        let (engine, _, detector, config) = makeEngine(athletes: [AthleteID()], holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        detector.emitMovement(at: CACurrentMediaTime(), athlete: AthleteID(), quality: good)
        
        #expect(engine.athleteResults.isEmpty)
        #expect(engine.state == .waitForStart)
        
        engine.abort()
    }
    
    @Test
    func oneFalseStartRecallsTheFieldAndNamesTheAthlete() async throws {
        let ids = [AthleteID(), AthleteID(), AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.15, athlete: ids[0], quality: good)
        detector.emitMovement(at: gun + 0.05, athlete: ids[2], quality: good)
        
        #expect(engine.state == .falseStart)
        await waitUntil { !engine.isRunning }
        
        #expect(engine.lastSession?.outcome == .falseStart)
        #expect(engine.athleteResults.map { $0.decision } == [.legal, .definiteFalseStart])
        #expect(engine.athleteResults.last?.position == 3)
        #expect(events(engine).first { $0.kind == .decision(.definiteFalseStart) }?.athleteID == ids[2])
        #expect(player.recallCount == 3)
    }
    
    @Test
    func twoAthletesMovingTogetherBeforeTheGunBothFalseStart() async {
        let ids = [AthleteID(), AthleteID(), AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        let first = CACurrentMediaTime()
        detector.emitMovement(at: first, athlete: ids[2], quality: good)
        #expect(engine.state == .falseStart)
        
        // Too soon after the first to be a reaction to it.
        detector.emitMovement(at: first + 0.04, athlete: ids[0], quality: good)
        // This one may have followed the others; nothing is held against them.
        detector.emitMovement(
            at: first + DecisionEngine.independentMovementWindow + 0.05,
            athlete: ids[1],
            quality: good
        )
        
        await waitUntil { !engine.isRunning }
        
        #expect(engine.athleteResults.map { $0.athleteID } == [ids[2], ids[0]])
        #expect(engine.athleteResults.map { $0.position } == [3, 1])
        #expect(engine.athleteResults.allSatisfy { $0.decision == .definiteFalseStart })
        #expect(engine.lastSession?.outcome == .falseStart)
        #expect(player.recallCount == 3)
        
        let charged = events(engine).filter { $0.kind == .decision(.definiteFalseStart) }
        #expect(charged.map { $0.athleteID } == [ids[2], ids[0]])
        #expect(detector.stopCount == 1)
    }
    
    @Test
    func afterTheGunEveryTooFastReactionIsAFalseStart() async throws {
        let ids = [AthleteID(), AthleteID(), AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        // The first one moved even before the gun was heard.
        detector.emitMovement(at: gun - 0.05, athlete: ids[0], quality: good)
        #expect(engine.state == .falseStart)
        
        // More than the window after the first, but still faster than anyone can react to the gun.
        detector.emitMovement(at: gun + 0.08, athlete: ids[1], quality: good)
        // A legal reaction is recorded as one and doesn't hide the false starts.
        detector.emitMovement(at: gun + 0.16, athlete: ids[2], quality: good)
        
        #expect(engine.athleteResults.map { $0.decision } == [.definiteFalseStart, .definiteFalseStart, .legal])
        
        await waitUntil { !engine.isRunning }
        #expect(engine.lastSession?.outcome == .falseStart)
        #expect(player.recallCount == 3)
    }
    
    @Test
    func untrackedMovementsAfterAFalseStartAreIgnored() async {
        let (engine, _, detector, config) = makeEngine(athletes: [], holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        detector.emitMovement(at: CACurrentMediaTime())
        detector.emitMovement(at: CACurrentMediaTime())
        
        #expect(engine.athleteResults.count == 1)
        await waitUntil { !engine.isRunning }
    }
    
    @Test
    func movementBeforeTheGunOnAPoorTrackIsUncertain() async {
        let ids = [AthleteID(), AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        detector.emitMovement(at: CACurrentMediaTime(), athlete: ids[0], quality: poor)
        
        #expect(engine.state == .waitForStart)
        #expect(engine.athleteResults.last?.decision == .uncertain)
        #expect(engine.athleteResults.map { $0.reaction } == [nil])
        #expect(player.recallCount == 0)
        #expect(events(engine).contains { $0.kind == .movementObserved(poor) && $0.athleteID == ids[0] })
        
        // The well-tracked athlete is still held to the rule.
        detector.emitMovement(at: CACurrentMediaTime(), athlete: ids[1], quality: good)
        
        #expect(engine.state == .falseStart)
        await waitUntil { !engine.isRunning }
        #expect(engine.lastSession?.outcome == .falseStart)
    }
    
    @Test
    func tooFastAReactionOnAPoorTrackIsUncertain() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.05, athlete: ids[0], quality: poor)
        
        #expect(engine.athleteResults.last?.decision == .uncertain)
        #expect(engine.state == .start)
        
        engine.abort()
    }
    
    @Test
    func trackingChangesOfRosterAthletesAreRecordedWhileMonitoring() async {
        let ids = [AthleteID()]
        let (engine, _, detector, config) = makeEngine(athletes: ids, holdTime: 10)
        
        engine.start(config: config)
        
        // Not monitoring yet.
        detector.emitTrackingChange(.occluded, athlete: ids[0], at: 1)
        
        await waitUntil { engine.state == .waitForStart }
        
        detector.emitTrackingChange(.occluded, athlete: ids[0], at: 2)
        detector.emitTrackingChange(.occluded, athlete: AthleteID(), at: 3)
        detector.emitTrackingChange(.tracked, athlete: ids[0], at: 4)
        
        let changes = events(engine).filter {
            $0.kind == .athleteTrackingChanged(.occluded) || $0.kind == .athleteTrackingChanged(.tracked)
        }
        
        #expect(changes.map { $0.kind } == [.athleteTrackingChanged(.occluded), .athleteTrackingChanged(.tracked)])
        #expect(changes.map { $0.time.best.seconds } == [2, 4])
        #expect(changes.allSatisfy { $0.athleteID == ids[0] && $0.source == .cameraLocal })
        
        engine.abort()
    }
    
    @Test
    func decisionEngineOnlyDowngradesFalseStarts() {
        let engine = DecisionEngine()
        
        let first = MonotonicTimestamp(seconds: 10)
        let window = DecisionEngine.independentMovementWindow
        #expect(engine.isIndependentFalseStart(at: MonotonicTimestamp(seconds: 10 + window / 2), afterFalseStartAt: first))
        #expect(!engine.isIndependentFalseStart(at: MonotonicTimestamp(seconds: 10 + window * 2), afterFalseStartAt: first))
        
        #expect(engine.qualify(.definiteFalseStart, by: poor) == .uncertain)
        #expect(engine.qualify(.definiteFalseStart, by: good) == .definiteFalseStart)
        #expect(engine.qualify(.definiteFalseStart, by: nil) == .definiteFalseStart)
        #expect(engine.qualify(.legal, by: poor) == .legal)
        #expect(engine.qualify(.notApplicable, by: poor) == .notApplicable)
        #expect(engine.evaluateMovementBeforeGun(trackingQuality: nil) == .definiteFalseStart)
        #expect(engine.evaluateMovementBeforeGun(trackingQuality: poor) == .uncertain)
    }

    // MARK: - Intervals and refinement
    
    @Test
    func aMovementThatMayHaveBegunTooEarlyIsNotRecalled() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        // Last seen at rest 60 ms after the gun, certainly moving at 120 ms.
        detector.emitMovement(at: gun + 0.12, since: gun + 0.06, athlete: ids[0], quality: good)
        
        let result = try #require(engine.athleteResults.first)
        #expect(result.decision == .uncertain)
        #expect(abs((result.reaction?.earliest ?? 0) - 0.06) < 0.000_001)
        #expect(abs((result.reaction?.latest ?? 0) - 0.12) < 0.000_001)
        #expect(!result.isRefined)
        #expect(engine.state == .start)
        #expect(player.recallCount == 0)
        
        engine.abort()
    }
    
    @Test
    func aFalseStartFoundAfterwardsIsShownButNotRecalled() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.12, since: gun + 0.06, athlete: ids[0], quality: good)
        detector.emitRefinement(from: gun + 0.070, to: gun + 0.078, athlete: ids[0], droppedFrames: 1)
        
        let result = try #require(engine.athleteResults.first)
        #expect(engine.athleteResults.count == 1)
        #expect(result.decision == .definiteFalseStart)
        #expect(result.isRefined)
        #expect(abs((result.reaction?.latest ?? 0) - 0.078) < 0.000_001)
        #expect(result.movement.latest.seconds == gun + 0.078)
        
        // The athletes are running: no recall, the start goes on.
        #expect(engine.state == .start)
        #expect(player.recallCount == 0)
        
        let kinds = events(engine).map { $0.kind }
        #expect(kinds.contains(.decision(.uncertain)))
        #expect(kinds.contains(.decisionRevised(.definiteFalseStart)))
        #expect(kinds.contains { if case .movementOnsetRefined(let refinement) = $0 { refinement.droppedFrames == 1 } else { false } })
        #expect(kinds.contains { if case .reactionRefined = $0 { true } else { false } })
        
        await waitUntil { !engine.isRunning }
        #expect(engine.lastSession?.outcome == .completed)
        #expect(engine.athleteResults.first?.decision == .definiteFalseStart)
    }
    
    @Test
    func aRefinementCanClearAnUncertainStart() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.15, since: gun + 0.08, athlete: ids[0], quality: good)
        detector.emitRefinement(from: gun + 0.108, to: gun + 0.116, athlete: ids[0])
        
        #expect(engine.athleteResults.first?.decision == .legal)
        #expect(events(engine).contains { $0.kind == .decisionRevised(.legal) })
        
        // Only the first closer look counts.
        detector.emitRefinement(from: gun + 0.01, to: gun + 0.02, athlete: ids[0])
        #expect(engine.athleteResults.first?.decision == .legal)
        
        engine.abort()
    }
    
    /// Found afterwards, so it is shown and nobody is called back.
    @Test
    func aStandingStartFoundToBeginBeforeTheGunIsMarkedNotRecalled() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, base) = makeEngine(athletes: ids, holdTime: 0)
        var config = base
        config.startType = .standing
        config.standingTimeToReady = 0
        config.standingTimeToStartMin = 0
        config.standingTimeToStartMax = 0
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        // Poses saw the movement after the gun.
        detector.emitMovement(at: gun + 0.23, since: gun + 0.155, athlete: ids[0], quality: good)
        #expect(engine.athleteResults.first?.decision == .legal)
        
        detector.emitRefinement(from: gun - 0.093, to: gun - 0.026, athlete: ids[0])
        
        let result = try #require(engine.athleteResults.first)
        #expect(result.decision == .definiteFalseStart)
        #expect(try #require(result.reaction).latest < 0)
        #expect(events(engine).contains { $0.kind == .decisionRevised(.definiteFalseStart) })
        #expect(player.recallCount == 0)
        
        await waitUntil { !engine.isRunning }
        #expect(engine.lastSession?.outcome == .completed)
    }
    
    @Test
    func aRefinementThatAgreesRevisesNothing() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.2, since: gun + 0.15, athlete: ids[0], quality: good)
        detector.emitRefinement(from: gun + 0.160, to: gun + 0.168, athlete: ids[0])
        
        #expect(engine.athleteResults.first?.decision == .legal)
        #expect(engine.athleteResults.first?.isRefined == true)
        #expect(!events(engine).contains { if case .decisionRevised = $0.kind { true } else { false } })
        
        engine.abort()
    }
    
    @Test
    func aPoorlyTrackedAthleteStaysUncertainAfterRefinement() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        
        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        
        detector.emitMovement(at: gun + 0.12, since: gun + 0.06, athlete: ids[0], quality: poor)
        detector.emitRefinement(from: gun + 0.070, to: gun + 0.078, athlete: ids[0])
        
        #expect(engine.athleteResults.first?.decision == .uncertain)
        
        engine.abort()
    }
    
    @Test
    func refinementsForUnknownAthletesAndBeforeTheGunChangeNoDecision() async throws {
        let ids = [AthleteID()]
        let (engine, _, detector, config) = makeEngine(athletes: ids, holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        detector.emitRefinement(from: 1, to: 2, athlete: AthleteID())
        #expect(engine.athleteResults.isEmpty)
        
        let now = CACurrentMediaTime()
        detector.emitMovement(at: now, since: now - 0.05, athlete: ids[0], quality: good)
        detector.emitRefinement(from: now - 0.03, to: now - 0.022, athlete: ids[0])
        
        let result = try #require(engine.athleteResults.first)
        #expect(result.decision == .definiteFalseStart)
        #expect(result.reaction == nil)
        #expect(result.isRefined)
        #expect(result.movement.latest.seconds == now - 0.022)
        
        await waitUntil { !engine.isRunning }
        #expect(engine.lastSession?.outcome == .falseStart)
    }
}
