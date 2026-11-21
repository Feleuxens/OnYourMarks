//
//  StartReplayTests.swift
//  OnYourMarksTests
//

import CoreGraphics
import Foundation
import QuartzCore
import Testing
import Vision
@testable import OnYourMarks

/// A recorded start made from synthetic poses the way the live detector and
/// the engine would have made it: tracker and monitor on every frame, the
/// engine's answers a frame later, as they arrive from the main actor.
struct SimulatedStart {
    static let rate = 60.0
    static let begin = 10.0

    var recording: StartRecording
    var tracking: [TrackingFrame]
    var motion: [MotionRecord] = []

    /// The live monitor's results, to compare the replay with.
    var regionAtMovement: CGRect?
    var stableTimes: [MonotonicTimestamp] = []

    /// How far down an athlete's whole body is, in picture heights, at a
    /// time since the beginning: getting into position, still, a sway out
    /// of the tolerance that is called unsteady, still again, the start.
    static func offset(at time: TimeInterval) -> CGFloat {
        switch time {
        case ..<0.3: 0.2 * time
        case ..<1.5: 0.06
        case ..<movementBegins: 0.09
        default: 0.09 + 0.5 * (time - movementBegins)
        }
    }

    /// An upright athlete; torso length 0.2.
    static func pose(at time: TimeInterval) -> DetectedPose {
        let dy = offset(at: time)
        return DetectedPose(
            joints: [
                .neck: CGPoint(x: 0.5, y: 0.6 - dy),
                .root: CGPoint(x: 0.5, y: 0.4 - dy),
                .leftShoulder: CGPoint(x: 0.47, y: 0.58 - dy),
                .rightShoulder: CGPoint(x: 0.53, y: 0.58 - dy),
                .leftWrist: CGPoint(x: 0.45, y: 0.5 - dy),
            ],
            confidence: 0.9,
            aspectRatio: 9.0 / 16.0
        )
    }

    /// When the movement begins, in seconds since the beginning.
    static let movementBegins: TimeInterval = 3

    /// - Parameter gun: when the gun is heard, in seconds since the
    ///   beginning, ± 2 ms; none if nil.
    init(frames: Int = 240, missing: Set<Int> = [40, 41, 130], monitoringFrom: Int = 4, gun: TimeInterval? = nil) {
        var tracker = AthleteTracker()
        var monitor = AthleteMotionMonitor()
        var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: Self.begin))
        var pendingResettle: AthleteID?
        var tracking: [TrackingFrame] = []
        var lastAthletes: [TrackedAthlete] = []

        for index in 0..<frames {
            let seconds = Double(index) / Self.rate
            let time = MonotonicTimestamp(seconds: Self.begin + seconds)

            if let gun, seconds >= gun, seconds - gun < 1 / Self.rate {
                let heard = TimeEstimate(
                    best: MonotonicTimestamp(seconds: Self.begin + gun),
                    earliest: MonotonicTimestamp(seconds: Self.begin + gun - 0.002),
                    latest: MonotonicTimestamp(seconds: Self.begin + gun + 0.002)
                )
                session.record(.gunScheduled(AudioPreflight.fake().gunTiming), at: heard, source: .audioLocal)
                session.record(.gunCommitted, at: heard, source: .audioLocal)
            }

            // The engine's resettle arrives while the next frame is analysed.
            if let athlete = pendingResettle {
                monitor.resettle(athlete)
                pendingResettle = nil
            }

            if index == monitoringFrom {
                let roster = monitor.begin(with: lastAthletes, profile: .block)
                tracker.retained = Set(roster.entries.map { $0.id })
                session.record(.monitoringStarted, at: .exact(time), source: .system)
                session.record(.rosterEstablished(roster), at: .exact(time), source: .cameraLocal)
            }

            let athletes = tracker.update(with: missing.contains(index) ? [] : [Self.pose(at: seconds)], at: time)
            lastAthletes = athletes
            let previous = monitor.phases

            for event in monitor.process(athletes, at: time) {
                switch event {
                case .unsteady(let observation):
                    session.record(
                        .athleteUnsteady(observation.quality),
                        at: .exact(observation.time),
                        source: .cameraLocal,
                        athleteID: observation.athleteID
                    )
                    pendingResettle = observation.athleteID
                case .readinessChanged(true):
                    // The engine takes it a moment after the frame was captured.
                    session.record(.athletesReady, at: .exact(MonotonicTimestamp(seconds: time.seconds + 0.02)), source: .cameraLocal)
                case .movement(let observation):
                    session.record(
                        .movementObserved(observation.quality),
                        at: observation.onset,
                        source: .cameraLocal,
                        athleteID: observation.athleteID
                    )
                    regionAtMovement = monitor.regions[observation.athleteID!]
                default:
                    break
                }
            }

            for (id, phase) in monitor.phases where phase == .stable && previous[id] != .stable {
                stableTimes.append(time)
            }

            if index >= monitoringFrom {
                tracking.append(TrackingFrame(time: time, athletes: athletes, phases: monitor.phases))
            }
        }

        session.finish(.completed, at: .exact(MonotonicTimestamp(seconds: Self.begin + Double(frames) / Self.rate)))

        self.tracking = tracking
        recording = StartRecording(
            id: UUID(),
            date: .now,
            session: session,
            results: [],
            frameTimes: tracking.map { $0.time },
            skippedFrames: 0
        )
    }

    var start: RecordedStart {
        RecordedStart(
            directory: URL(filePath: "/nonexistent"),
            recording: recording,
            tracking: tracking,
            motion: motion,
            truth: nil,
            analysis: nil
        )
    }
}

struct PoseReplayTests {
    @Test
    func theMonitorDoesAgainWhatItDidLive() throws {
        let simulated = SimulatedStart()
        let replay = StartReplay.poses(of: simulated.start)

        #expect(replay.monitoredFrames == simulated.tracking.count)
        #expect(replay.phaseMismatches == 0)
        #expect(replay.trackedAthletes > 0)
        #expect(replay.trackerMismatches == 0)

        let athlete = try #require(replay.athletes.first)
        #expect(athlete.position == 1)
        #expect(athlete.storedUnsteady.count == 1)
        #expect(athlete.replayedUnsteady == athlete.storedUnsteady)
        #expect(athlete.storedMovement != nil)
        #expect(athlete.replayedMovement == athlete.storedMovement)
        #expect(athlete.region == simulated.regionAtMovement)

        // Ready twice: before the sway and after settling again.
        #expect(replay.replayedReadiness.count == 2)
        #expect(zip(replay.storedReadiness, replay.replayedReadiness).allSatisfy { $0 > $1 })

        // The last rest: stable at the second time, still from 0.4 s before it.
        let stable = try #require(athlete.stableSince)
        #expect(stable == simulated.stableTimes.last)
        let still = try #require(athlete.stillSince)
        #expect(stable.seconds - still.seconds >= MotionProfile.block.settleDuration)
        #expect(stable.seconds - still.seconds < MotionProfile.block.settleDuration + 1.5 / SimulatedStart.rate)
    }

    /// The point of a replay: another constant, another result, on the same start.
    @Test
    func anotherProfileJudgesTheSameStartDifferently() throws {
        let simulated = SimulatedStart()
        let stored = try #require(StartReplay.poses(of: simulated.start).athletes.first?.storedMovement)

        let block = MotionProfile.block
        let later = MotionProfile(
            regionWeights: block.regionWeights,
            stillTolerance: block.stillTolerance,
            movementThreshold: 2 * block.movementThreshold,
            settleDuration: block.settleDuration,
            unsteadyDelay: block.unsteadyDelay
        )

        let replayed = try #require(StartReplay.poses(of: simulated.start, profile: later).athletes.first?.replayedMovement)
        #expect(replayed.latest > stored.latest)
    }

    @Test
    func aStartWithoutARosterHasNothingToReplay() {
        var simulated = SimulatedStart()
        simulated.tracking = simulated.tracking.map { TrackingFrame(time: $0.time, athletes: $0.athletes) }

        let replay = StartReplay.poses(of: simulated.start)
        #expect(replay.athletes.isEmpty)
        #expect(replay.monitoredFrames == 0)
    }
}

@MainActor
struct DecisionReplayTests {
    private let good = TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1)

    private func makeEngine(athletes: [AthleteID], holdTime: Double) -> (StarterEngine, FakeSignalPlayer, FakeMovementDetector, StartConfig) {
        let player = FakeSignalPlayer()
        player.gunDuration = 0.05

        let detector = FakeMovementDetector()
        detector.roster = AthleteRoster(
            entries: athletes.enumerated().map { AthleteRoster.Entry(id: $1, position: $0 + 1, quality: good) }
        )

        var config = StartConfig.instant
        config.blockTimeToStartMin = holdTime
        config.blockTimeToStartMax = holdTime

        return (StarterEngine(player: player, movementDetector: detector), player, detector, config)
    }

    private func recording(of engine: StarterEngine) throws -> StartRecording {
        StartRecording(
            id: UUID(),
            date: .now,
            session: try #require(engine.lastSession),
            results: engine.athleteResults,
            frameTimes: [],
            skippedFrames: 0
        )
    }

    @Test
    func reactionsAndRefinementsAreDecidedAgainAsLive() async throws {
        let ids = [AthleteID(), AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)

        engine.start(config: config)
        await waitUntil { engine.state == .start }
        await waitForGunReadBack(engine)
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)

        // Uncertain live, a false start once refined; and a legal one.
        detector.emitMovement(at: gun + 0.12, since: gun + 0.06, athlete: ids[0], quality: good)
        detector.emitRefinement(from: gun + 0.070, to: gun + 0.078, athlete: ids[0], droppedFrames: 1)
        detector.emitMovement(at: gun + 0.25, since: gun + 0.2, athlete: ids[1], quality: good)
        await waitUntil { !engine.isRunning }

        let replay = StartReplay.decisions(of: try recording(of: engine))

        #expect(replay.stored.count == 6)
        #expect(replay.replayed == replay.stored)
        #expect(replay.replayedResults == replay.storedResults)
        #expect(replay.isReproduced)
        #expect(replay.replayedResults.first?.decision == .definiteFalseStart)
    }

    /// Recorded before the engine rejected such refinements: the replay
    /// rejects it as the engine now does.
    @Test
    func aStoredRefinementThatBeganAfterTheMovementIsIgnored() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)

        engine.start(config: config)
        await waitUntil { engine.state == .start }
        await waitForGunReadBack(engine)
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)

        detector.emitMovement(at: gun + 0.12, since: gun + 0.06, athlete: ids[0], quality: good)
        await waitUntil { !engine.isRunning }

        let live = try recording(of: engine)
        var session = live.session
        let refinement = OnsetRefinement(
            athleteID: ids[0],
            onset: TimeEstimate(
                best: MonotonicTimestamp(seconds: gun + 0.1415),
                earliest: MonotonicTimestamp(seconds: gun + 0.131),
                latest: MonotonicTimestamp(seconds: gun + 0.152)
            ),
            droppedFrames: 0
        )
        session.record(.movementOnsetRefined(refinement), at: refinement.onset, source: .cameraLocal, athleteID: ids[0])

        let replay = StartReplay.decisions(
            of: StartRecording(id: live.id, date: live.date, session: session, results: live.results, frameTimes: [], skippedFrames: 0)
        )
        #expect(replay.isReproduced)
        #expect(replay.replayedResults.first?.decision == .uncertain)
        #expect(replay.replayedResults.first?.isRefined == false)
    }

    @Test
    func aGunThatCouldNotBeReadBackLeavesReactionsUncertainAgain() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)
        player.measuresPlayback = false

        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)
        await waitUntil { engine.lastSession == nil && engine.currentSession?.events.contains { $0.kind == .gunPlaybackNotMeasured } == true }

        detector.emitMovement(at: gun + 0.06, since: gun + 0.05, athlete: ids[0], quality: good)
        await waitUntil { !engine.isRunning }

        let recording = try recording(of: engine)
        #expect(recording.results.first?.decision == .uncertain)
        #expect(StartReplay.decisions(of: recording).isReproduced)
        #expect(StartReplay.gun(in: recording.session)?.isTrusted == false)
    }

    @Test
    func aMovementBeforeTheGunIsAFalseStartAgain() async throws {
        let ids = [AthleteID()]
        let (engine, _, detector, config) = makeEngine(athletes: ids, holdTime: 10)

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }

        detector.emitMovement(at: CACurrentMediaTime(), athlete: ids[0], quality: good)
        await waitUntil { !engine.isRunning }

        let recording = try recording(of: engine)
        let replay = StartReplay.decisions(of: recording)

        #expect(recording.session.outcome == .falseStart)
        #expect(replay.isReproduced)
        #expect(replay.replayedResults.first?.reaction == nil)
        #expect(StartReplay.gun(in: recording.session) == nil)
    }

    /// The same movements, judged by the standing start's rule.
    @Test
    func anotherProfileDecidesTheSameMovementsDifferently() async throws {
        let ids = [AthleteID()]
        let (engine, player, detector, config) = makeEngine(athletes: ids, holdTime: 0)

        engine.start(config: config)
        await waitUntil { engine.state == .start }
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)

        detector.emitMovement(at: gun + 0.06, since: gun + 0.05, athlete: ids[0], quality: good)
        await waitUntil { !engine.isRunning }

        let recording = try recording(of: engine)
        #expect(recording.results.first?.decision == .definiteFalseStart)
        #expect(StartReplay.decisions(of: recording, profile: .standing).replayedResults.first?.decision == .legal)
    }

    @Test
    func theRenderStartIsFoundBackFromTheHeardTime() {
        let basis = AudioPreflight.fake(calibration: .fake(correction: 0.1)).gunTiming
        let render = MonotonicTimestamp(seconds: 50)

        let heard = basis.audibleOnset(renderStart: render)
        #expect(abs(StartReplay.renderStart(of: heard, basis: basis).seconds - 50) < 0.000_000_1)
    }
}

struct OnsetReplayTests {
    /// Every frame of one athlete's region: rest, then from `begins` on a
    /// growing part of it changes.
    private func samples(count: Int, begins: Int, rate: Double = 240) -> [MotionSample] {
        let cellCount = MotionSampler.gridSize * MotionSampler.gridSize

        return (0..<count).map { frame in
            MotionSample(
                time: MonotonicTimestamp(seconds: 20 + Double(frame) / rate),
                cells: (0..<cellCount).map { cell in
                    var value = 60 + abs(cell * 37) % 120 + (frame &* 31 &+ cell &* 17) % 3 - 1
                    if frame >= begins, cell < min((frame - begins + 1) * 16, cellCount / 2) {
                        value += 50
                    }
                    return UInt8(clamping: value)
                }
            )
        }
    }

    private func start(samples: [MotionSample], confirmedAt confirmation: MonotonicTimestamp, refined: Bool = true) -> RecordedStart {
        let athlete = AthleteID()
        let quality = TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1)
        var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 19))

        session.record(
            .rosterEstablished(AthleteRoster(entries: [.init(id: athlete, position: 1, quality: quality)])),
            at: .exact(MonotonicTimestamp(seconds: 19)),
            source: .cameraLocal
        )
        session.record(.movementObserved(quality), at: .exact(confirmation), source: .cameraLocal, athleteID: athlete)

        if refined, let onset = MotionOnsetAnalyzer.onset(in: samples, confirmedAt: confirmation) {
            let refinement = OnsetRefinement(athleteID: athlete, onset: onset.interval, droppedFrames: onset.droppedFrames)
            session.record(.movementOnsetRefined(refinement), at: onset.interval, source: .cameraLocal, athleteID: athlete)
        }

        return RecordedStart(
            directory: URL(filePath: "/nonexistent"),
            recording: StartRecording(id: UUID(), date: .now, session: session, results: [], frameTimes: [], skippedFrames: 0),
            tracking: [],
            motion: [MotionRecord(athleteID: athlete, region: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4), samples: samples)],
            truth: nil,
            analysis: nil
        )
    }

    @Test
    func theBeginningIsFoundAgainInTheRecordedSamples() throws {
        // Samples go on after the confirmation, as the recorder keeps them.
        let samples = samples(count: 700, begins: 600)
        let start = start(samples: samples, confirmedAt: samples[630].time)

        let onset = try #require(StartReplay.onsets(of: start).first)
        #expect(onset.position == 1)
        #expect(onset.stored != nil)
        #expect(onset.replayed?.interval == onset.stored?.onset)
        #expect(onset.replayed?.interval.latest == samples[600].time)
    }

    @Test
    func otherConstantsCanBeTried() throws {
        let samples = samples(count: 700, begins: 600)
        let start = start(samples: samples, confirmedAt: samples[630].time)

        // Asking for too much rest leaves no statement.
        var parameters = MotionOnsetAnalyzer.Parameters.live
        parameters.minimumRest = 5
        #expect(StartReplay.onsets(of: start, parameters: parameters).first?.replayed == nil)
        #expect(StartReplay.onsets(of: start).first?.replayed != nil)
    }

    @Test
    func theLiveConstantsAreTheAnalyzersOwn() {
        let live = MotionOnsetAnalyzer.Parameters.live
        #expect(live.lookback == MotionOnsetAnalyzer.lookback)
        #expect(live.certainFactor == MotionOnsetAnalyzer.certainFactor)
        #expect(live.recentPast == MotionOnsetAnalyzer.recentPast)
        #expect(live.restDuration == MotionOnsetAnalyzer.restDuration)
    }

    @Test
    func theChangeSeriesIsWhatTheAnalysisThresholds() throws {
        let samples = samples(count: 700, begins: 600)
        let confirmation = samples[630].time

        let series = try #require(MotionOnsetAnalyzer.series(in: samples, until: confirmation))
        let changes = try #require(MotionOnsetAnalyzer.changes(in: samples, confirmedAt: confirmation))

        #expect(series.values == changes.values)
        #expect(series.times == changes.frames.map { $0.time })
        #expect(series.restCount == changes.restCount)
        #expect(series.levels.resting < 2)
        #expect(series.levels.certain > series.levels.resting)
        // The beginning lies where the curve crosses the certain level.
        let crossing = try #require(series.values.firstIndex { $0 > series.levels.certain })
        #expect(series.times[crossing] == samples[600].time)

        let stored = try JSONDecoder().decode(MotionOnsetAnalyzer.ChangeSeries.self, from: JSONEncoder().encode(series))
        #expect(stored == series)
    }
}

struct RecordedStartTests {
    @Test
    func aRecordingIsReadBackFromItsFolderWithItsTruth() throws {
        let store = RecordingStore.scratch()
        let simulated = SimulatedStart()
        let recording = simulated.recording
        let motion = [MotionRecord(athleteID: AthleteID(), region: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), samples: [])]

        _ = try store.prepare(recording.id)
        try store.write(recording, tracking: simulated.tracking, motion: motion)

        let folder = store.directory(of: recording.id, in: .temporary)
        let truth = RecordedTruth(athletes: [.init(position: 1, firstMovingFrame: 5, note: nil)], method: "test")
        try JSONEncoder().encode(truth).write(to: folder.appending(path: RecordingStore.truthFileName))

        let start = try RecordedStart.load(from: folder)
        #expect(start.recording == recording)
        #expect(start.tracking == simulated.tracking)
        #expect(start.motion == motion)
        #expect(start.truth == truth)
        #expect(start.analysis == nil)

        #expect(RecordedStart.folders(in: folder) == [folder])
        #expect(RecordedStart.folders(in: folder.deletingLastPathComponent()).map { $0.lastPathComponent } == [folder.lastPathComponent])
    }

    @Test
    func theTruthLiesBetweenTheFrameSeenMovingAndTheOneBefore() throws {
        let times = (0..<10).map { MonotonicTimestamp(seconds: 5 + Double($0) / 100) }
        let truth = RecordedTruth(athletes: [.init(position: 1, firstMovingFrame: 4, note: nil)], method: nil)

        let seen = try #require(truth.movement(of: truth.athletes[0], frameTimes: times))
        #expect(seen.earliest == times[2])
        #expect(seen.latest == times[3])

        #expect(truth.movement(of: .init(position: 1, firstMovingFrame: 1, note: nil), frameTimes: times) == nil)
        #expect(truth.movement(of: .init(position: 1, firstMovingFrame: 11, note: nil), frameTimes: times) == nil)
    }

    @Test
    func theReportSaysWhatWasReproduced() {
        let simulated = SimulatedStart()
        let rows = StartReplay.report(for: simulated.start)

        #expect(rows.contains { $0.quantity == "monitor: frames with other phases" && $0.difference == "same" })
        #expect(rows.contains { $0.quantity == "athlete 1 movement (poses)" && $0.difference == "same" })

        let table = StartReplay.table(rows, title: "simulated")
        #expect(table.split(separator: "\n").count == rows.count + 2)
    }
}

/// Replays every recorded start found in the folder `TEST_RUNNER_FIELD_DATA`
/// names: the regression corpus for any change to a constant.
struct FieldDataReplayTests {
    nonisolated static let fieldData = ProcessInfo.processInfo.environment["FIELD_DATA"].map { URL(filePath: $0) }
    nonisolated static let hasFieldData = fieldData != nil

    @Test(.enabled(if: hasFieldData))
    func everyRecordedStartIsReproduced() throws {
        let folders = RecordedStart.folders(in: try #require(Self.fieldData))
        try #require(!folders.isEmpty)

        for folder in folders {
            let start = try RecordedStart.load(from: folder)
            let rows = StartReplay.report(for: start)
            let name = folder.lastPathComponent

            Attachment.record(StartReplay.table(rows, title: name), named: "Replay \(name)")

            #expect(StartReplay.decisions(of: start.recording).isReproduced, "\(name)")

            for onset in StartReplay.onsets(of: start) {
                #expect(onset.replayed?.interval == onset.stored?.onset, "\(name)")
            }

            let poses = StartReplay.poses(of: start)
            for athlete in poses.athletes {
                #expect(athlete.replayedMovement == athlete.storedMovement, "\(name)")
                #expect(athlete.replayedUnsteady == athlete.storedUnsteady, "\(name)")
            }
            #expect(poses.phaseMismatches == 0, "\(name)")
        }
    }
}
