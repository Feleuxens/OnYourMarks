//
//  SecondPassTests.swift
//  OnYourMarksTests
//

import CoreVideo
import Foundation
import Testing
@testable import OnYourMarks

struct SecondPassTests {
    private static let gun: TimeInterval = 2.85

    /// What the camera saw of the athlete's region in a frame: rest, and
    /// from the movement on a growing part of it changes.
    private func cells(at seconds: TimeInterval, frame: Int) -> [UInt8] {
        let cellCount = MotionSampler.gridSize * MotionSampler.gridSize
        let moving = seconds >= SimulatedStart.movementBegins
            ? Int(((seconds - SimulatedStart.movementBegins) * SimulatedStart.rate).rounded()) + 1
            : 0

        return (0..<cellCount).map { cell in
            var value = 60 + abs(cell * 37) % 120 + (frame &* 31 &+ cell &* 17) % 3 - 1
            if cell < min(moving * 16, cellCount / 2) {
                value += 50
            }
            return UInt8(clamping: value)
        }
    }

    /// Every frame of the simulated video, with a pose on each.
    private func frames(of simulated: SimulatedStart, athlete: AthleteID) -> [SecondPass.Frame] {
        simulated.recording.frameTimes.enumerated().map { index, time in
            let seconds = time.seconds - SimulatedStart.begin
            return SecondPass.Frame(
                time: time,
                poses: [SimulatedStart.pose(at: seconds)],
                cells: [athlete: cells(at: seconds, frame: index)]
            )
        }
    }

    private func analyse(_ simulated: SimulatedStart) throws -> RecordingAnalysis {
        let plan = try #require(SecondPass.plan(for: simulated.start))
        let athlete = try #require(plan.athletes.first)
        let frames = frames(of: simulated, athlete: athlete.id)

        return SecondPass.analyse(
            frames,
            plan: plan,
            recordingID: simulated.recording.id,
            video: RecordedVideoReader.Summary(decoded: frames.count, unmatched: 0),
            duration: 1
        )
    }

    @Test
    func thePlanTakesTheLiveRestAndRegion() throws {
        let simulated = SimulatedStart(gun: Self.gun)
        let plan = try #require(SecondPass.plan(for: simulated.start))
        let replay = try #require(StartReplay.poses(of: simulated.start).athletes.first)

        let athlete = try #require(plan.athletes.first)
        #expect(plan.athletes.count == 1)
        #expect(athlete.region == simulated.regionAtMovement)
        #expect(athlete.stableSince == replay.stableSince)
        #expect(athlete.stillSince == replay.stillSince)
        #expect(athlete.liveConfirmation == replay.storedMovement?.latest)
        #expect(plan.gun?.heard.best.seconds == SimulatedStart.begin + Self.gun)
        #expect(plan.regions == [athlete.id: try #require(athlete.region)])
    }

    @Test
    func theBeginningIsFoundBetweenTwoFramesAndTimedAgainstTheGun() throws {
        let simulated = SimulatedStart(gun: Self.gun)
        let analysis = try analyse(simulated)
        let times = simulated.recording.frameTimes
        let moving = try #require(times.firstIndex { $0.seconds - SimulatedStart.begin >= SimulatedStart.movementBegins })

        let athlete = try #require(analysis.athletes.first)
        #expect(analysis.athletes.count == 1)
        #expect(athlete.position == 1)

        let onset = try #require(athlete.onset?.onset)
        #expect(onset.earliest == times[moving - 1])
        #expect(onset.latest == times[moving])
        #expect(athlete.movement == onset)

        let heard = try #require(StartReplay.gun(in: simulated.recording.session)?.heard)
        #expect(athlete.reaction == onset.duration(since: heard))
        #expect(athlete.decision == .legal)

        // The poses on every frame confirm it no later than live.
        let observed = simulated.recording.session.events.first { event in
            guard event.athleteID == athlete.athleteID, case .movementObserved = event.kind else { return false }
            return true
        }
        let live = try #require(observed?.time)
        let poses = try #require(athlete.poseMovement)
        #expect(poses.latest <= live.latest)
        #expect(athlete.posedFrames > 0)

        #expect(analysis.frames.withPose == times.count)
        #expect(analysis.version == RecordingAnalysis.currentVersion)
        #expect(analysis.recordingID == simulated.recording.id)
    }

    @Test
    func itsResultIsRecordedAsEventsOfItsOwn() throws {
        let simulated = SimulatedStart(gun: Self.gun)
        let analysis = try analyse(simulated)
        let athlete = try #require(analysis.athletes.first)

        #expect(analysis.events.count == 2)
        #expect(analysis.events.allSatisfy { $0.source == .recordedVideo && $0.athleteID == athlete.athleteID })
        #expect(analysis.events.first?.kind == .movementAnalysed(try #require(athlete.onset)))
        #expect(analysis.events.last?.kind == .reactionAnalysed(try #require(athlete.reaction)))

        // Stored beside the record, and read back the same.
        let stored = try JSONDecoder().decode(RecordingAnalysis.self, from: JSONEncoder().encode(analysis))
        #expect(stored == analysis)
    }

    @Test
    func itLearnsRestFromTheWholeHoldAndLooksPastTheConfirmation() throws {
        let simulated = SimulatedStart(gun: Self.gun)
        let analysis = try analyse(simulated)
        let athlete = try #require(analysis.athletes.first)
        let parameters = try #require(athlete.parameters)
        let poses = try #require(athlete.poseMovement)

        #expect(abs(parameters.lookback - (MotionOnsetAnalyzer.lookback + SecondPass.followUp)) < 0.000_001)
        #expect(parameters.restDuration >= MotionOnsetAnalyzer.restDuration)

        // The curve goes on to the last frame and holds the whole rest.
        let change = try #require(athlete.change)
        #expect(change.times.last == simulated.recording.frameTimes.last)
        #expect(change.restCount > 0)
        let restEnd = poses.latest.seconds - MotionOnsetAnalyzer.lookback
        #expect(change.times[change.restCount - 1].seconds < restEnd)
        #expect(change.times[change.restCount].seconds >= restEnd)
        #expect(change.values.max() ?? 0 > change.levels.certain)
    }

    /// Without the live record's rest the pass has nothing to learn from;
    /// whatever else it says, it never makes up a beginning.
    @Test
    func noOnsetWithoutRestBeforeTheMovement() throws {
        let simulated = SimulatedStart(gun: Self.gun)
        var plan = try #require(SecondPass.plan(for: simulated.start))
        let athlete = try #require(plan.athletes.first)
        plan = SecondPass.Plan(
            athletes: [
                SecondPass.Plan.Athlete(
                    id: athlete.id, position: athlete.position, region: athlete.region,
                    stillSince: athlete.stillSince, stableSince: nil,
                    liveConfirmation: athlete.liveConfirmation, quality: athlete.quality
                )
            ],
            gun: plan.gun, profile: plan.profile, tracking: plan.tracking
        )

        let analysis = SecondPass.analyse(
            frames(of: simulated, athlete: athlete.id), plan: plan, recordingID: UUID(),
            video: RecordedVideoReader.Summary(), duration: 0
        )
        #expect(analysis.athletes.first?.onset == nil)
        #expect(analysis.athletes.first?.change == nil)
        // The poses still found the movement, so it is reported from them.
        #expect(analysis.athletes.first?.movement == analysis.athletes.first?.poseMovement)
    }

    @Test
    func aStartWithoutAthletesOrHeldInTheHandHasNoPlan() {
        var withoutRoster = SimulatedStart()
        withoutRoster.tracking = withoutRoster.tracking.map { TrackingFrame(time: $0.time, athletes: $0.athletes) }
        #expect(SecondPass.plan(for: withoutRoster.start) == nil)

        var handheld = SimulatedStart()
        handheld.tracking = handheld.tracking.map {
            TrackingFrame(time: $0.time, athletes: $0.athletes, phases: $0.phases, cameraOffset: .zero)
        }
        #expect(SecondPass.plan(for: handheld.start) == nil)
    }

    @Test
    func theCurveEndsWhereTheRateChanges() {
        let precise = (0..<100).map { MotionSample(time: MonotonicTimestamp(seconds: 1 + Double($0) / 240), cells: [1]) }
        let idle = (1...5).map { MotionSample(time: MonotonicTimestamp(seconds: precise[99].time.seconds + Double($0) / 15), cells: [1]) }

        #expect(SecondPass.steadyEnd(of: precise + idle, from: precise[50].time) == precise[99].time)
        #expect(SecondPass.steadyEnd(of: precise, from: precise[50].time) == precise[99].time)
    }
}

extension VideoRecordingTests {
    struct RecordedVideoReaderTests {
        private func finish(_ writer: VideoFileWriter) async -> VideoFileWriter.Summary {
            await withCheckedContinuation { continuation in
                writer.finish { continuation.resume(returning: $0) }
            }
        }

        /// A short video whose frames each have a brightness of their own.
        private func video() async throws -> (url: URL, summary: VideoFileWriter.Summary, brightness: [MonotonicTimestamp: Int]) {
            let url = try RecordingStore.scratch().prepare(UUID())
            let writer = VideoFileWriter(url: url)
            var brightness: [MonotonicTimestamp: Int] = [:]

            for index in 0..<20 {
                let frame = try CameraFrame.synthetic(at: 300 + Double(index) / 120, index: index)
                brightness[frame.timestamp] = 40 + index * 7
                writer.append(frame)
                // The simulator's encoder can't take frames as fast as a loop sends them.
                try await Task.sleep(for: .milliseconds(15))
            }
            return (url, await finish(writer), brightness)
        }

        /// The middle of the brightness plane.
        private func brightness(of buffer: CVPixelBuffer) -> Int {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetHeightOfPlane(buffer, 0) / 2
            return Int(base[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + CVPixelBufferGetWidthOfPlane(buffer, 0) / 2])
        }

        @Test
        func everyFrameComesBackWithItsOwnCaptureTime() async throws {
            let (url, summary, written) = try await video()
            try #require(summary.failure == nil)
            try #require(summary.frameTimes.count > 2)

            var read: [(time: MonotonicTimestamp, brightness: Int)] = []
            let result = try await RecordedVideoReader.read(url, frameTimes: summary.frameTimes) { buffer, time in
                read.append((time, brightness(of: buffer)))
            }

            #expect(result.decoded == summary.frameTimes.count)
            #expect(result.unmatched == 0)
            #expect(read.map { $0.time } == summary.frameTimes)
            // The picture is the one captured then, not its neighbour's (7 apart).
            #expect(read.allSatisfy { abs($0.brightness - (written[$0.time] ?? -100)) <= 2 })
        }

        @Test
        func aFrameWithoutAStoredTimeIsLeftOutAndCounted() async throws {
            let (url, summary, _) = try await video()
            try #require(summary.frameTimes.count > 2)

            var times = summary.frameTimes
            let missing = times.remove(at: 1)

            var read: [MonotonicTimestamp] = []
            let result = try await RecordedVideoReader.read(url, frameTimes: times) { _, time in read.append(time) }

            #expect(result.decoded == summary.frameTimes.count)
            #expect(result.unmatched == 1)
            #expect(!read.contains(missing))
            #expect(read == times)
        }
    }
}

extension VideoRecordingTests {
    @MainActor
    struct SecondPassControllerTests {
        private let source = FakeFrameSource()
        private let store = RecordingStore.scratch()
        private let patience = Duration.seconds(30)

        private func record(with controller: StartRecordingController) async throws -> StartRecording {
            try #require(controller.beginRecording())

            for index in 0..<6 {
                try await source.deliver(at: 9.5 + Double(index) / 120, index: index)
            }

            var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 9))
            session.finish(.completed, at: .exact(MonotonicTimestamp(seconds: 10)))
            controller.endRecording(session: session, results: [], tail: 0)

            await waitUntil(timeout: patience) { controller.last?.session == session }
            return try #require(controller.last)
        }

        @Test
        func aKeptRecordingIsAnalysedAndTheResultStoredBesideIt() async throws {
            let analyser = FakeRecordingAnalyser()
            let controller = StartRecordingController(source: source, store: store, analyser: analyser)

            let recording = try await record(with: controller)
            await waitUntil(timeout: patience) { controller.analysis(of: recording) != nil }
            await waitUntil(timeout: patience) { store.analysis(of: recording.id, in: .temporary) != nil }

            #expect(analyser.started == [recording.id])
            #expect(controller.analysing == nil)
            #expect(controller.files(of: recording).count == 4)
            // The live record stays as it was.
            #expect(store.recordings(in: .temporary) == [recording])

            // Opened again later, it is read, not run again.
            let again = FakeRecordingAnalyser()
            let reopened = StartRecordingController(source: source, store: store, analyser: again)
            await reopened.loadAnalysis(of: recording)

            #expect(reopened.analysis(of: recording) == controller.analysis(of: recording))
            #expect(again.started.isEmpty)
        }

        @Test
        func theNextStartCancelsTheSecondPass() async throws {
            let analyser = FakeRecordingAnalyser()
            analyser.holds = true
            let controller = StartRecordingController(source: source, store: store, analyser: analyser)

            let recording = try await record(with: controller)
            await waitUntil(timeout: patience) { analyser.started == [recording.id] }
            #expect(controller.analysing == recording.id)

            try #require(controller.beginRecording())

            #expect(controller.analysing == nil)
            await waitUntil(timeout: patience) { analyser.cancelled == [recording.id] }
            #expect(controller.analysis(of: recording) == nil)
            #expect(store.analysis(of: recording.id, in: .temporary) == nil)

            controller.flush()
        }

        @Test
        func aPassThatNeverFinishedRunsWhenTheStartIsReviewed() async throws {
            let unanalysed = StartRecordingController(source: source, store: store, analyser: nil)
            let recording = try await record(with: unanalysed)
            await waitUntil(timeout: patience) { !unanalysed.isFinishing }

            let analyser = FakeRecordingAnalyser()
            let controller = StartRecordingController(source: source, store: store, analyser: analyser)
            await controller.loadAnalysis(of: recording)

            await waitUntil(timeout: patience) { controller.analysis(of: recording) != nil }
            #expect(analyser.started == [recording.id])
        }

        @Test
        func deletingARecordingEndsItsPass() async throws {
            let analyser = FakeRecordingAnalyser()
            analyser.holds = true
            let controller = StartRecordingController(source: source, store: store, analyser: analyser)

            let recording = try await record(with: controller)
            await waitUntil(timeout: patience) { analyser.started == [recording.id] }

            controller.delete(recording)

            #expect(controller.analysing == nil)
            await waitUntil(timeout: patience) { analyser.cancelled == [recording.id] }
        }
    }
}
