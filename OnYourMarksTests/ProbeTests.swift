//
//  ProbeTests.swift
//  OnYourMarksTests
//

import CoreGraphics
import Foundation
import Testing
@testable import OnYourMarks

/// A measurement run through the engine: the same sequence, gun and
/// session as a start, with probed regions instead of athletes.
@MainActor
struct ProbeStartTests {
    private let region = ProbeRegion(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))

    private func makeEngine() -> (StarterEngine, FakeSignalPlayer, FakeMovementDetector, StartConfig, ManualClock) {
        let clock = ManualClock()
        let player = FakeSignalPlayer()
        player.gunDuration = 0.4
        player.clock = clock

        let detector = FakeMovementDetector()
        detector.clock = clock
        // An athlete in view who never holds still must not hold up a measurement.
        detector.roster = AthleteRoster(
            entries: [AthleteRoster.Entry(id: AthleteID(), position: 1, quality: TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1))]
        )
        detector.setReady(false)

        var config = StartConfig.instant
        config.blockTimeToStartMin = 0.5
        config.blockTimeToStartMax = 0.5
        config.probeRegions = [region]

        let engine = StarterEngine(player: player, movementDetector: detector, clock: clock, decisionEngine: DecisionEngine())
        return (engine, player, detector, config, clock)
    }

    private func step(from earliest: TimeInterval, to latest: TimeInterval) -> ProbeObservation {
        ProbeObservation(
            ProbeStepDetector.Step(
                change: TimeEstimate(
                    best: MonotonicTimestamp(seconds: (earliest + latest) / 2),
                    earliest: MonotonicTimestamp(seconds: earliest),
                    latest: MonotonicTimestamp(seconds: latest)
                ),
                certainAt: MonotonicTimestamp(seconds: latest),
                droppedFrames: 0,
                size: 40,
                restLevel: 0.6,
                restSpread: 0.1,
                brightnessChange: 40
            ),
            in: region
        )
    }

    @Test
    func aMeasurementJudgesNobodyAndMeasuresTheProbeAgainstTheGun() async throws {
        let (engine, player, detector, config, clock) = makeEngine()

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }

        #expect(detector.probed == [[region]])
        #expect(detector.startCount == 0)
        #expect(engine.roster == .empty)

        // Nobody is waited for: the gun comes after the hold.
        await clock.advance(by: 0.5)
        #expect(engine.state == .start)
        let gun = try #require(player.pendingSchedule?.audibleOnset.best.seconds)

        // The light also lit before the gun, at a noise.
        detector.onEvent?(.probeChanged(step(from: gun - 0.3, to: gun - 0.292)))
        detector.onEvent?(.probeChanged(step(from: gun + 0.002, to: gun + 0.010)))

        // Every region has changed since the gun: the run ends with the sound.
        await clock.advance(by: 0.4)
        #expect(!engine.isRunning)
        #expect(engine.lastSession?.outcome == .completed)

        let result = try #require(engine.probeResults.first)
        #expect(engine.probeResults.count == 1)
        #expect(abs(result.offset.best - 0.006) < 0.000_001)
        #expect(abs(result.offset.earliest - 0.002) < 0.000_001)
        #expect(abs(result.offset.latest - 0.010) < 0.000_001)
        #expect(engine.athleteResults.isEmpty)

        let kinds = try #require(engine.lastSession).events.map { $0.kind }
        #expect(kinds.contains(.probingStarted([region])))
        #expect(kinds.filter { if case .probeChanged = $0 { true } else { false } }.count == 2)
        #expect(kinds.contains(.probeMeasured(result)))
    }

    @Test
    func aMeasurementWithoutAChangeWaitsTheReactionWindowAndMeasuresNothing() async {
        let (engine, _, _, config, clock) = makeEngine()

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        await clock.advance(by: 0.9)
        #expect(engine.isRunning)

        await clock.advance(by: engine.reactionWindow)
        #expect(!engine.isRunning)
        #expect(engine.probeResults.isEmpty)
    }

    @Test
    func aNormalStartDoesNotProbe() async {
        let (engine, _, detector, base, _) = makeEngine()
        var config = base
        config.probeRegions = []

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }

        #expect(detector.probed.isEmpty)
        #expect(detector.startCount == 1)
        engine.abort()
    }

    @Test
    func probeRegionsAreNotStored() throws {
        var config = StartConfig()
        config.probeRegions = [region]

        let decoded = try JSONDecoder().decode(StartConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.probeRegions.isEmpty)
    }
}

/// The probe's step detector on made-up frames of one region.
struct ProbeStepDetectorTests {
    /// Frame interval of the precision rate.
    private let frame: TimeInterval = 1.0 / 120
    private let cellCount = MotionSampler.gridSize * MotionSampler.gridSize

    /// A region at rest: grey, with a little noise that changes from frame
    /// to frame the way a sensor's does, but the same in every run.
    private func rest(_ index: Int, brightness: Int = 100) -> [UInt8] {
        (0..<cellCount).map { cell in
            let noise = (cell &* 7 &+ index &* 13) % 3 - 1
            return UInt8(clamping: brightness + noise)
        }
    }

    private func time(_ index: Int, start: TimeInterval = 10) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: start + Double(index) * frame)
    }

    /// Feeds the frames and returns every step with the index of the frame
    /// that reported it.
    private func run(_ frames: [(index: Int, cells: [UInt8])], start: TimeInterval = 10) -> [(at: Int, step: ProbeStepDetector.Step)] {
        var detector = ProbeStepDetector()
        var steps: [(Int, ProbeStepDetector.Step)] = []

        for (index, cells) in frames {
            if let step = detector.process(MotionSample(time: time(index, start: start), cells: cells)) {
                steps.append((index, step))
            }
        }
        return steps
    }

    @Test
    func aLightSwitchingOnIsAStepBetweenTwoFrames() throws {
        let frames = (0..<120).map { index in
            (index, index < 80 ? rest(index) : rest(index, brightness: 140))
        }

        let steps = run(frames)
        let step = try #require(steps.first)

        #expect(steps.count == 1)
        #expect(step.at == 80)
        #expect(step.step.change.earliest == time(79))
        #expect(step.step.change.latest == time(80))
        #expect(step.step.certainAt == time(80))
        #expect(step.step.droppedFrames == 0)
        #expect(abs(step.step.brightnessChange - 40) < 1)
        #expect(step.step.size > step.step.restLevel + 30)
    }

    /// A frame exposed while the light switched changes only partly. The
    /// change began after the frame before it, though only the next one
    /// makes it certain.
    @Test
    func aPartlyChangedFrameIsTheBeginning() throws {
        let still = [UInt8](repeating: 100, count: cellCount)
        var partly = still
        for cell in 0..<(cellCount * 3 / 4) {
            partly[cell] = 101
        }
        let lit = [UInt8](repeating: 140, count: cellCount)

        let frames = (0..<100).map { index in
            (index, index < 60 ? still : index == 60 ? partly : lit)
        }

        let step = try #require(run(frames).first)

        #expect(step.at == 61)
        #expect(step.step.change.earliest == time(59))
        #expect(step.step.change.latest == time(60))
        #expect(step.step.certainAt == time(61))
    }

    @Test
    func aLightThatStaysOnIsOneChangeAndSwitchingOffAnother() {
        let frames = (0..<240).map { index in
            (index, (80..<160).contains(index) ? rest(index, brightness: 140) : rest(index))
        }

        let steps = run(frames)

        #expect(steps.map { $0.at } == [80, 160])
        #expect(steps.map { $0.step.brightnessChange > 0 } == [true, false])
    }

    /// The recorded start at 240 fps differs more every fourth frame, all
    /// the time. That is rest, not a change.
    @Test
    func aRhythmAtRestIsNotAStep() {
        let frames = (0..<480).map { index in
            (index, rest(index, brightness: index.isMultiple(of: 4) ? 103 : 100))
        }

        #expect(run(frames).isEmpty)
    }

    /// Exposure settling or a cloud: the region drifts by a step now and
    /// then, never by more from one frame to the next than at rest.
    @Test
    func aSlowDriftIsNotAStep() {
        let frames = (0..<480).map { index in
            (index, rest(index, brightness: 100 + index / 12))
        }

        #expect(run(frames).isEmpty)
    }

    /// Changing to the precision rate may change the exposure as well;
    /// frames at another rate aren't compared with those after.
    @Test
    func aChangeOfRateBeginsRestAnew() {
        var detector = ProbeStepDetector()
        var steps: [ProbeStepDetector.Step] = []
        var now: TimeInterval = 10

        for index in 0..<30 {
            now += 1.0 / 15
            steps += [detector.process(MotionSample(time: MonotonicTimestamp(seconds: now), cells: rest(index)))].compactMap { $0 }
        }
        for index in 30..<150 {
            now += frame
            steps += [detector.process(MotionSample(time: MonotonicTimestamp(seconds: now), cells: rest(index, brightness: 70)))].compactMap { $0 }
        }

        #expect(steps.isEmpty)
    }

    /// Too little rest says nothing about it: right after the beginning a
    /// change is not reported.
    @Test
    func nothingIsReportedBeforeThereIsEnoughRest() {
        let frames = (0..<40).map { index in
            (index, index < 5 ? rest(index) : rest(index, brightness: 140))
        }

        #expect(run(frames).isEmpty)
    }

    @Test
    func aDroppedFrameWidensTheInterval() throws {
        let frames = (0..<120).filter { $0 != 80 }.map { index in
            (index, index < 80 ? rest(index) : rest(index, brightness: 140))
        }

        let step = try #require(run(frames).first)

        #expect(step.step.change.earliest == time(79))
        #expect(step.step.change.latest == time(81))
        #expect(step.step.droppedFrames == 1)
    }

    @Test
    func theNearestStepToTheGunIsMeasured() throws {
        let region = ProbeRegion(rect: CGRect(x: 0.8, y: 0.4, width: 0.1, height: 0.1))
        let other = ProbeRegion(rect: .init(x: 0, y: 0, width: 0.1, height: 0.1))
        let gun = TimeEstimate(
            best: MonotonicTimestamp(seconds: 20),
            earliest: MonotonicTimestamp(seconds: 19.998),
            latest: MonotonicTimestamp(seconds: 20.002)
        )

        func step(in region: ProbeRegion, from earliest: TimeInterval, to latest: TimeInterval) -> ProbeObservation {
            ProbeObservation(
                ProbeStepDetector.Step(
                    change: TimeEstimate(
                        best: MonotonicTimestamp(seconds: (earliest + latest) / 2),
                        earliest: MonotonicTimestamp(seconds: earliest),
                        latest: MonotonicTimestamp(seconds: latest)
                    ),
                    certainAt: MonotonicTimestamp(seconds: latest),
                    droppedFrames: 0,
                    size: 40,
                    restLevel: 0.6,
                    restSpread: 0.1,
                    brightnessChange: 40
                ),
                in: region
            )
        }

        // The light also lit at "Set", well before the gun.
        let results = ProbeResult.nearest(
            of: [step(in: region, from: 18, to: 18.008), step(in: region, from: 20.001, to: 20.009), step(in: other, from: 20.02, to: 20.028)],
            to: gun
        )

        #expect(results.map { $0.observation.regionID } == [region.id, other.id])

        let offset = try #require(results.first?.offset)
        #expect(abs(offset.best - 0.005) < 0.000_001)
        #expect(abs(offset.earliest - -0.001) < 0.000_001)
        #expect(abs(offset.latest - 0.011) < 0.000_001)
    }

    /// The buffer's first row is the upright picture's right edge.
    @Test
    func theReadoutRunsAcrossTheUprightPicture() {
        let right = ProbeRegion(rect: CGRect(x: 0.9, y: 0.45, width: 0.1, height: 0.1))
        let left = ProbeRegion(rect: CGRect(x: 0, y: 0.45, width: 0.1, height: 0.1))
        let top = ProbeRegion(rect: CGRect(x: 0.45, y: 0.9, width: 0.1, height: 0.1))
        let bottom = ProbeRegion(rect: CGRect(x: 0.45, y: 0, width: 0.1, height: 0.1))

        #expect(abs(right.readoutPosition - 0.05) < 0.000_001)
        #expect(abs(left.readoutPosition - 0.95) < 0.000_001)
        #expect(top.readoutPosition == bottom.readoutPosition)

        // The same as where the sampler takes the region from.
        let buffer = MotionSampler.bufferRegion(for: right.rect, bufferWidth: 1920, bufferHeight: 1080)
        #expect(abs(buffer.midY / 1080 - right.readoutPosition) < 0.000_001)
    }

    @Test
    func aRegionIsKeptInsideThePicture() {
        let region = ProbeRegion(rect: CGRect(x: 0.9, y: -0.1, width: -0.3, height: 0.3))

        let expected = CGRect(x: 0.6, y: 0, width: 0.3, height: 0.2)
        #expect(abs(region.rect.minX - expected.minX) < 0.000_001)
        #expect(abs(region.rect.minY - expected.minY) < 0.000_001)
        #expect(abs(region.rect.width - expected.width) < 0.000_001)
        #expect(abs(region.rect.height - expected.height) < 0.000_001)
    }
}
