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
        #expect(engine.lastDecision == nil)
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
        #expect(engine.lastDecision == .definiteFalseStart)
        
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
        #expect(engine.lastDecision == .uncertain)
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
        
        #expect(engine.lastDecision == .uncertain)
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
}
