//
//  GunHearingTests.swift
//  OnYourMarksTests
//

import Testing
import AVFAudio
import Foundation
import QuartzCore
@testable import OnYourMarks

/// A gun rendered at 100 s on the built-in speaker: heard at 100.036 s ± 2 ms
/// by the model (12 ms latency, onset 24 ms into the file).
private func gunAt100(route: OutputRoute? = OutputRoute(id: "speaker", name: "Speaker", isWireless: false, isBuiltInSpeaker: true)) -> ScheduledSignal {
    let basis = SignalTimingBasis(
        route: route,
        outputLatency: 0.012,
        onsetOffset: 0.024,
        calibration: nil,
        uncertainty: OutputTiming.wiredUncertainty
    )
    let renderStart = MonotonicTimestamp(seconds: 100)

    return ScheduledSignal(
        signal: .go,
        renderStart: renderStart,
        cancellableUntil: MonotonicTimestamp(seconds: 99.95),
        audibleOnset: basis.audibleOnset(renderStart: renderStart),
        basis: basis
    )
}

struct HearingMathTests {
    private let sampleRate = 48_000.0
    private let inputLatency = 0.005

    /// Quiet noise with a gun-like sound reaching the microphone at
    /// `soundAt`, timestamped late by the input latency, in tap-sized chunks.
    private func recording(
        from start: TimeInterval = 99.5,
        to end: TimeInterval = 100.6,
        soundAt: TimeInterval?,
        noise: Float = 0.001,
        level: Float = 0.5,
        quietSound: (from: TimeInterval, to: TimeInterval, level: Float)? = nil
    ) -> [RecordedChunk] {
        let count = Int((end - start) * sampleRate)
        var samples = (0..<count).map { index in noise * (index.isMultiple(of: 2) ? 1 : -1) }

        // Timestamps of the recording, like the chunks'.
        if let quietSound {
            let first = Int(((quietSound.from - start) * sampleRate).rounded(.up))
            let last = Int(((quietSound.to - start) * sampleRate).rounded(.down))
            for index in first..<last {
                samples[index] = quietSound.level * (index.isMultiple(of: 2) ? 1 : -1)
            }
        }

        if let soundAt {
            let first = Int(((soundAt + inputLatency - start) * sampleRate).rounded(.up))
            for index in first..<min(first + 13_000, count) {
                samples[index] = level * (index.isMultiple(of: 2) ? 1 : -1)
            }
        }

        return stride(from: 0, to: count, by: 1024).map { offset in
            RecordedChunk(
                hostSeconds: start + Double(offset) / sampleRate,
                sampleRate: sampleRate,
                samples: Array(samples[offset..<min(offset + 1024, count)])
            )
        }
    }

    private func hear(_ chunks: [RecordedChunk], interruptedAt: TimeInterval? = nil, travel: DurationEstimate? = HeardSignal.builtInSpeakerTravel) -> SignalHearing {
        let gun = gunAt100()
        return HearingMath.hear(
            in: chunks,
            window: HearingMath.window(for: gun, interruptedAt: interruptedAt.map { MonotonicTimestamp(seconds: $0) }),
            inputLatency: inputLatency,
            modelled: gun.audibleOnset,
            travel: travel
        )
    }

    @Test
    func theSearchRunsFromTheRenderStartToAWhileAfterTheModel() throws {
        let window = HearingMath.window(for: gunAt100(), interruptedAt: nil)

        let search = try #require(window.search)
        #expect(search.lowerBound == 100)
        #expect(abs(search.upperBound - (100.038 + HearingMath.searchAfterModel)) < 1e-9)
        #expect(abs(window.noise.lowerBound - (100 + HearingMath.noiseWindow.lowerBound)) < 1e-9)
        #expect(abs(window.noise.upperBound - (100 + HearingMath.noiseWindow.upperBound)) < 1e-9)
        #expect(!window.isCutOff)
    }

    @Test
    func aStopEndsTheSearchWhereTheNextSoundCouldFirstBeHeard() throws {
        // A sample rendered at the stop is heard 10 ms later at the
        // earliest: 12 ms latency less the 2 ms the model may be off.
        let window = HearingMath.window(for: gunAt100(), interruptedAt: MonotonicTimestamp(seconds: 100.1))

        let search = try #require(window.search)
        #expect(abs(search.upperBound - 100.11) < 1e-9)
        #expect(window.isCutOff)
    }

    @Test
    func aStopBeforeAnythingCouldBeHeardLeavesNothingToSearch() {
        let window = HearingMath.window(for: gunAt100(), interruptedAt: MonotonicTimestamp(seconds: 99.98))

        #expect(window.search == nil)
        #expect(window.isCutOff)
        #expect(hear(recording(soundAt: 100.0365), interruptedAt: 99.98) == .notHeard(.stoppedBeforeHeard))
    }

    @Test
    func aStopLongAfterTheSearchChangesNothing() {
        #expect(!HearingMath.window(for: gunAt100(), interruptedAt: MonotonicTimestamp(seconds: 101)).isCutOff)
    }

    @Test
    func theOnsetIsFoundWithoutTheInputLatency() throws {
        guard case .heard(let heard) = hear(recording(soundAt: 100.0365)) else {
            Issue.record("not heard")
            return
        }

        #expect(abs(heard.heard.best.seconds - 100.0365) <= 1 / sampleRate)
        #expect(heard.inputLatency == inputLatency)

        let uncertainty = HearingMath.timingUncertainty(sampleRate: sampleRate)
        #expect(abs(heard.heard.latest.seconds - heard.heard.best.seconds - uncertainty) < 1e-9)
        #expect(abs(heard.heard.best.seconds - heard.heard.earliest.seconds - uncertainty) < 1e-9)

        #expect(heard.check == .agrees)
        #expect(heard.peakLevel > heard.noiseLevel * Double(CalibrationMath.minimumSignalToNoise))
    }

    @Test
    func aGunHeardMuchLaterThanTheModelDisagrees() {
        guard case .heard(let heard) = hear(recording(soundAt: 100.050)) else {
            Issue.record("not heard")
            return
        }

        #expect(heard.check == .heardLater)
    }

    @Test
    func silenceIsNotHeard() {
        #expect(hear(recording(soundAt: nil)) == .notHeard(.nothingAboveNoise))
    }

    @Test
    func aRecordingThatEndsBeforeTheGunHasNoAudio() {
        #expect(hear(recording(to: 99.95, soundAt: nil)) == .notHeard(.noAudio))
    }

    /// The chunk with the attack never arrived: the loud tail after the
    /// gap is not the onset.
    @Test
    func aGapBeforeTheOnsetLeavesNoAudio() {
        let attack = 100.0365 + inputLatency
        let chunks = recording(soundAt: 100.0365).filter { !($0.hostSeconds <= attack && $0.end > attack) }

        #expect(hear(chunks) == .notHeard(.noAudio))
    }

    /// A quiet sound before the gap, at 2 % of the gun after it, is only
    /// loud against itself: the peak comes from the whole window.
    @Test
    func aQuietSoundBeforeAGapIsNotTakenForTheGun() {
        let attack = 100.0365 + inputLatency
        let full = recording(soundAt: 100.0365)
        let missing = full.first { $0.hostSeconds <= attack && $0.end > attack }!

        let chunks = recording(
            soundAt: 100.0365,
            quietSound: (missing.hostSeconds - 0.015, missing.hostSeconds, 0.01)
        ).filter { $0.hostSeconds != missing.hostSeconds }

        #expect(hear(chunks) == .notHeard(.noAudio))
    }

    @Test
    func aGapAfterTheOnsetAndItsSustainChangesNothing() throws {
        let later = 100.0365 + inputLatency + 0.05
        let chunks = recording(soundAt: 100.0365).filter { !($0.hostSeconds <= later && $0.end > later) }

        guard case .heard(let heard) = hear(chunks) else {
            Issue.record("not heard")
            return
        }
        #expect(abs(heard.heard.best.seconds - 100.0365) <= 1 / sampleRate)
    }

    @Test
    func aSearchCutShortThatFindsNothingWasStopped() {
        // Stopped 5 ms after the render start; the sound would only have
        // come later.
        #expect(hear(recording(soundAt: 100.2), interruptedAt: 100.005) == .notHeard(.stoppedBeforeHeard))
    }

    @Test
    func aSoundAfterTheStopIsNotTakenForTheGun() {
        // The recall's first shot, after the gun was stopped unheard.
        #expect(hear(recording(soundAt: 100.06), interruptedAt: 100.03) == .notHeard(.stoppedBeforeHeard))
    }
}

struct HeardSignalTests {
    private func heard(after delay: TimeInterval, travel: DurationEstimate?) -> HeardSignal {
        let modelled = TimeEstimate(
            best: MonotonicTimestamp(seconds: 10),
            earliest: MonotonicTimestamp(seconds: 9.998),
            latest: MonotonicTimestamp(seconds: 10.002)
        )
        let best = 10 + delay

        return HeardSignal(
            heard: TimeEstimate(
                best: MonotonicTimestamp(seconds: best),
                earliest: MonotonicTimestamp(seconds: best - 0.001),
                latest: MonotonicTimestamp(seconds: best + 0.001)
            ),
            modelled: modelled,
            travel: travel,
            inputLatency: 0.002,
            peakLevel: 0.5,
            noiseLevel: 0.001
        )
    }

    @Test
    func withTheWayKnownTheModelIsCheckedBothWays() {
        let travel = HeardSignal.builtInSpeakerTravel

        #expect(heard(after: 0.0017, travel: travel).check == .agrees)
        #expect(heard(after: -0.0029, travel: travel).check == .agrees)
        #expect(heard(after: 0.0040, travel: travel).check == .heardLater)
        #expect(heard(after: -0.0031, travel: travel).check == .heardEarlier)
    }

    @Test
    func theModelErrorTakesTheWayOut() throws {
        let error = try #require(heard(after: 0.0017, travel: HeardSignal.builtInSpeakerTravel).modelError)

        #expect(abs(error.best - 0.0017) < 1e-9)
        #expect(abs(error.earliest - (0.0017 - 0.003 - HeardSignal.builtInSpeakerTravel.latest)) < 1e-9)
        #expect(abs(error.latest - (0.0017 + 0.003)) < 1e-9)
    }

    @Test
    func withTheWayUnknownALateSoundDecidesNothing() throws {
        let signal = heard(after: 0.030, travel: nil)

        #expect(signal.check == .undecided)
        #expect(signal.modelError == nil)

        let distance = try #require(signal.distanceIfModelHolds)
        #expect(abs(distance.lowerBound - 0.027 * HeardSignal.speedOfSound) < 1e-9)
        #expect(abs(distance.upperBound - 0.033 * HeardSignal.speedOfSound) < 1e-9)
    }

    @Test
    func withTheWayUnknownAnEarlySoundStillContradictsTheModel() {
        let signal = heard(after: -0.004, travel: nil)

        #expect(signal.check == .heardEarlier)
        #expect(signal.distanceIfModelHolds == nil)
    }

    @Test
    func withoutAModelThereIsNothingToCompare() {
        let signal = HeardSignal(
            heard: .exact(MonotonicTimestamp(seconds: 5)),
            modelled: nil,
            travel: nil,
            inputLatency: 0,
            peakLevel: 0.5,
            noiseLevel: 0.01
        )

        #expect(signal.check == .noModel)
        #expect(signal.heardAfterModel == nil)
    }

    @Test @MainActor
    func aHeardGunSurvivesTheSessionRecord() throws {
        var session = StartSession(startType: .block, profile: StartType.block.profile, createdAt: MonotonicTimestamp(seconds: 1))
        let signal = heard(after: 0.0017, travel: HeardSignal.builtInSpeakerTravel)
        session.record(.gunHeard(signal), at: signal.heard, source: .audioLocal)
        session.record(.gunNotHeard(.nothingAboveNoise), at: .exact(MonotonicTimestamp(seconds: 11)), source: .audioLocal)

        let decoded = try JSONDecoder().decode(StartSession.self, from: JSONEncoder().encode(session))

        #expect(decoded == session)
        #expect(ReplayTimeline.gunHearing(in: decoded) == .notHeard(.nothingAboveNoise))
    }

    @Test
    func aPreflightStoredBeforeListeningStillLoads() throws {
        let stored = Data(
            #"""
            {"sampleRate":48000,"ioBufferDuration":0.021,"gunTiming":{"outputLatency":0.012,"onsetOffset":0.024,"uncertainty":0.002}}
            """#.utf8
        )

        let preflight = try JSONDecoder().decode(AudioPreflight.self, from: stored)

        #expect(preflight.microphone == nil)
    }
}

@MainActor
struct GunHearingEngineTests {
    private let heardGun = HeardSignal(
        heard: .exact(MonotonicTimestamp(seconds: 5)),
        modelled: .exact(MonotonicTimestamp(seconds: 4.97)),
        travel: HeardSignal.builtInSpeakerTravel,
        inputLatency: 0.002,
        peakLevel: 0.5,
        noiseLevel: 0.001
    )

    private func makeEngine(
        holdTime: Double,
        player: FakeSignalPlayer,
        clock: ManualClock? = nil
    ) -> (StarterEngine, FakeMovementDetector, StartConfig) {
        let detector = FakeMovementDetector()
        let engine: StarterEngine

        if let clock {
            player.clock = clock
            detector.clock = clock
            engine = StarterEngine(player: player, movementDetector: detector, clock: clock, decisionEngine: DecisionEngine())
        } else {
            engine = StarterEngine(player: player, movementDetector: detector)
        }

        var config = StartConfig.instant
        config.blockTimeToStartMin = holdTime
        config.blockTimeToStartMax = holdTime
        return (engine, detector, config)
    }

    private func kinds(_ engine: StarterEngine) -> [StartEventKind] {
        (engine.currentSession ?? engine.lastSession)?.events.map { $0.kind } ?? []
    }

    @Test
    func theCommittedGunIsListenedForAndWhatWasHeardIsRecorded() async throws {
        let player = FakeSignalPlayer()
        player.hearing = .heard(heardGun)
        let (engine, _, config) = makeEngine(holdTime: 0, player: player)

        engine.start(config: config)
        await waitUntil { !engine.isRunning }

        let scheduled = try #require(player.hearRequests.first)
        #expect(player.hearRequests.count == 1)
        #expect(scheduled.signal == .go)

        let event = try #require(engine.lastSession?.events.first { $0.kind == .gunHeard(heardGun) })
        #expect(event.time == heardGun.heard)
        #expect(event.source == .audioLocal)
        #expect(engine.lastSession?.outcome == .completed)
    }

    @Test
    func aGunNotHeardIsRecorded() async {
        let player = FakeSignalPlayer()
        player.hearing = .notHeard(.nothingAboveNoise)
        let (engine, _, config) = makeEngine(holdTime: 0, player: player)

        engine.start(config: config)
        await waitUntil { !engine.isRunning }

        #expect(kinds(engine).contains(.gunNotHeard(.nothingAboveNoise)))
    }

    @Test
    func withoutListeningNothingIsRecorded() async {
        let player = FakeSignalPlayer()
        let (engine, _, config) = makeEngine(holdTime: 0, player: player)

        engine.start(config: config)
        await waitUntil { !engine.isRunning }

        #expect(player.hearRequests.count == 1)
        #expect(!kinds(engine).contains { kind in
            switch kind {
            case .gunHeard, .gunNotHeard: true
            default: false
            }
        })
    }

    @Test
    func whatIsHeardDoesNotChangeTheDecision() async throws {
        let player = FakeSignalPlayer()
        player.outputLatency = 0.05
        player.gunDuration = 1
        // Heard 30 ms after the model: outside its range.
        player.hearing = .heard(heardGun)
        let (engine, detector, config) = makeEngine(holdTime: 0, player: player)

        engine.start(config: config)
        await waitUntil { engine.state == .start }
        await waitForGunReadBack(engine)
        await waitUntil { kinds(engine).contains(.gunHeard(heardGun)) }

        let audible = try #require(player.pendingSchedule?.audibleOnset.best)
        detector.emitMovement(at: audible.seconds + 0.15)

        let reaction = try #require(engine.athleteResults.last?.reaction?.best)
        #expect(abs(reaction - 0.15) < 0.000_001)
        #expect(engine.athleteResults.last?.decision == .legal)
        #expect(!kinds(engine).contains(.gunTimeRevised))

        engine.abort()
    }

    @Test
    func aFalseStartBeforeTheGunListensForNothing() async {
        let player = FakeSignalPlayer()
        player.hearing = .heard(heardGun)
        let (engine, detector, config) = makeEngine(holdTime: 10, player: player)

        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }

        detector.emitMovement(at: CACurrentMediaTime())
        await waitUntil { !engine.isRunning }

        #expect(player.hearRequests.isEmpty)
        #expect(!kinds(engine).contains(.gunHeard(heardGun)))
    }

    @Test
    func aCompletedRunWaitsForTheMicrophone() async {
        let clock = ManualClock()
        let player = FakeSignalPlayer()
        player.gunDuration = 0.2
        player.hearing = .heard(heardGun)
        player.hearingDelay = 0.5
        let (engine, _, config) = makeEngine(holdTime: 0.1, player: player, clock: clock)

        engine.start(config: config)
        await waitUntil { player.pendingSchedule != nil }

        // The gun's sound is over, the microphone isn't done yet.
        await clock.advance(by: 0.4)
        #expect(engine.isRunning)

        await clock.advance(by: 0.3)
        #expect(!engine.isRunning)
        #expect(kinds(engine).contains(.gunHeard(heardGun)))
        #expect(engine.lastSession?.outcome == .completed)
    }

    @Test
    func aHearingStillPendingWhenTheRunIsAbortedIsDropped() async {
        let clock = ManualClock()
        let player = FakeSignalPlayer()
        player.gunDuration = 0.2
        player.hearing = .heard(heardGun)
        player.hearingDelay = 0.5
        let (engine, _, config) = makeEngine(holdTime: 0.1, player: player, clock: clock)

        engine.start(config: config)
        await waitUntil { player.pendingSchedule != nil }
        await clock.advance(by: 0.15)
        #expect(player.hearRequests.count == 1)

        engine.abort()
        await clock.advance(by: 1)

        #expect(!kinds(engine).contains(.gunHeard(heardGun)))
    }
}

/// Runs against the real audio session, so inside the serialized
/// `AudioControllerTests`: a suite of its own would share the one system
/// session with them in parallel.
extension AudioControllerTests {
    private nonisolated static var listeningMicrophoneGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Opt-in: plays the gun at full session volume.
    private nonisolated static var audibleRequested: Bool {
        ProcessInfo.processInfo.environment["RUN_CALIBRATION"] == "1"
    }

    private func listeningNow() -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: CACurrentMediaTime())
    }

    @Test
    func startsOnAutomaticOutputDoNotListen() async throws {
        let controller = AudioController(theme: .eng1)

        let preflight = try await controller.prepareForStart()

        let hearing = await controller.hear(gunAt100())
        #expect(preflight.microphone == nil)
        #expect(hearing == .notListening)

        await controller.deactivateSession()
    }

    @Test(.enabled(if: listeningMicrophoneGranted))
    func aStartOnTheSpeakerListensFromItsPreflight() async throws {
        let controller = AudioController(theme: .eng1)
        controller.output = .iPhoneSpeaker

        let began = listeningNow()
        let preflight = try await controller.prepareForStart()
        let took = listeningNow().seconds - began.seconds

        let microphone = try #require(preflight.microphone)
        Attachment.record(
            """
            preflight with listening: \(took * 1000) ms
            input: \(microphone.name), \(microphone.sampleRate) Hz, latency \(microphone.inputLatency * 1000) ms
            playback engine running afterwards: \(controller.engine.isRunning)
            """,
            named: "Listening"
        )
        #expect(microphone.sampleRate > 0)
        #expect(controller.engine.isRunning, "starting the microphone left the playback engine stopped")

        // A second start on the kept session listens on.
        let again = try await controller.prepareForStart()
        #expect(again.microphone == microphone)

        await controller.deactivateSession()
        let afterwards = await controller.hear(gunAt100())
        #expect(afterwards == .notListening)
    }

    /// Opt-in, plays the gun four times: what the microphone hears of guns
    /// scheduled as at a start, against the model.
    @Test(.enabled(if: listeningMicrophoneGranted && audibleRequested))
    func theGunIsHeardWhereTheModelSaysIt() async throws {
        let controller = AudioController(theme: .eng1)
        controller.output = .iPhoneSpeaker
        _ = try await controller.prepareForStart()

        var lines: [String] = []
        var checks: [ModelCheck] = []

        for _ in 0..<4 {
            let gun = try #require(controller.schedule(.go, at: MonotonicTimestamp(seconds: listeningNow().seconds + 0.5)))
            let hearing = await controller.hear(gun)

            switch hearing {
            case .heard(let heard):
                let delay = try #require(heard.heardAfterModel)
                checks.append(heard.check)
                lines.append(
                    String(
                        format: "heard %+.2f ms after the model (%+.2f to %+.2f), %@, peak/noise %.0f",
                        delay.best * 1000, delay.earliest * 1000, delay.latest * 1000,
                        String(describing: heard.check), heard.peakLevel / max(heard.noiseLevel, 1e-9)
                    )
                )
            default:
                lines.append(String(describing: hearing))
            }

            try await Task.sleep(for: .seconds(0.6))
        }

        let route = controller.currentOutput()?.name ?? "none"
        Attachment.record("route: \(route)\n" + lines.joined(separator: "\n"), named: "Gun heard against the model")
        await controller.deactivateSession()

        #expect(checks.count == 4, "not every gun was heard")
        #if !targetEnvironment(simulator)
        #expect(checks.allSatisfy { $0 == .agrees })
        #endif
    }

    /// Opt-in, plays one standing start: the start records what the
    /// microphone heard of its gun.
    @Test(.enabled(if: listeningMicrophoneGranted && audibleRequested))
    func aStartOnTheSpeakerRecordsItsHeardGun() async throws {
        let controller = AudioController(theme: .eng1)
        controller.output = .iPhoneSpeaker
        let engine = StarterEngine(player: controller, movementDetector: FakeMovementDetector())

        var config = StartConfig.instant
        config.startType = .standing
        config.standingTimeToReady = 0
        config.standingTimeToStartMin = 1
        config.standingTimeToStartMax = 1

        engine.start(config: config)
        await waitUntil(timeout: .seconds(15)) { !engine.isRunning }
        await controller.deactivateSession()

        let session = try #require(engine.lastSession)
        let hearing = ReplayTimeline.gunHearing(in: session)
        Attachment.record(String(describing: hearing), named: "Heard at a start")

        #expect(session.outcome == .completed)
        guard case .heard = hearing else {
            Issue.record("the start did not hear its gun: \(String(describing: hearing))")
            return
        }
    }
}
