//
//  RecordingTests.swift
//  OnYourMarksTests
//

import AVFoundation
import Foundation
import Testing
import Vision
@testable import OnYourMarks

/// A start as a recording keeps it, with a gun at `gun` if given.
private func recordedSession(
    gun: TimeInterval? = 10,
    outcome: StartSessionOutcome = .completed,
    roster: AthleteRoster = .empty
) -> StartSession {
    var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 0))
    
    session.record(.rosterEstablished(roster), at: .exact(MonotonicTimestamp(seconds: 1)), source: .cameraLocal)
    
    if let gun {
        let heard = TimeEstimate(
            best: MonotonicTimestamp(seconds: gun),
            earliest: MonotonicTimestamp(seconds: gun - 0.002),
            latest: MonotonicTimestamp(seconds: gun + 0.002)
        )
        session.record(.gunScheduled(AudioPreflight.fake().gunTiming), at: heard, source: .audioLocal)
        session.record(.stateChanged(.start), at: .exact(MonotonicTimestamp(seconds: gun)), source: .system)
    }
    
    session.finish(outcome, at: .exact(MonotonicTimestamp(seconds: (gun ?? 10) + 1)))
    return session
}

struct RecordingCodingTests {
    @Test
    func sessionSurvivesStoring() throws {
        let athlete = AthleteID()
        let quality = TrackingQuality(state: .tracked, jointCoverage: 0.8, confidence: 0.7, continuity: 1)
        let roster = AthleteRoster(entries: [.init(id: athlete, position: 1, quality: quality)])
        var session = recordedSession(outcome: .failed("no output"), roster: roster)
        
        let moved = TimeEstimate(
            best: MonotonicTimestamp(seconds: 10.14),
            earliest: MonotonicTimestamp(seconds: 10.136),
            latest: MonotonicTimestamp(seconds: 10.144)
        )
        session.record(.audioPrepared(.fake(calibration: .fake())), at: moved, source: .audioLocal)
        session.record(.movementObserved(quality), at: moved, source: .remoteCamera(UUID()), athleteID: athlete)
        session.record(
            .movementOnsetRefined(OnsetRefinement(athleteID: athlete, onset: moved, droppedFrames: 2)),
            at: moved,
            source: .cameraLocal,
            athleteID: athlete
        )
        session.record(.reactionMeasured(.exact(0.14)), at: moved, source: .externalSensor("pad"))
        session.record(.decisionRevised(.uncertain), at: moved, source: .system, athleteID: athlete)
        session.record(.athleteTrackingChanged(.occluded), at: moved, source: .cameraLocal, athleteID: athlete)
        session.record(.recordingBegan, at: moved, source: .system)
        
        let stored = try JSONEncoder().encode(session)
        
        #expect(try JSONDecoder().decode(StartSession.self, from: stored) == session)
    }
    
    @Test
    func trackingFrameSurvivesStoring() throws {
        let athlete = TrackedAthlete.fake(at: CGPoint(x: 0.25, y: 0.75), time: 3)
        let frame = TrackingFrame(
            time: MonotonicTimestamp(seconds: 3),
            athletes: [athlete],
            phases: [athlete.id: .settling],
            cameraOffset: CGPoint(x: 0.01, y: -0.02)
        )
        
        let stored = try JSONEncoder().encode([frame])
        let restored = try JSONDecoder().decode([TrackingFrame].self, from: stored)
        
        #expect(restored == [frame])
        #expect(restored.first?.athletes.first?.pose.joints[.leftWrist] == CGPoint(x: 0.2, y: 0.75))
    }
}

/// The suites that write video. One after the other: several encoder
/// sessions at once slow each other down, on the phone by seconds.
@Suite(.serialized)
struct VideoRecordingTests {}

extension VideoRecordingTests {
    struct VideoFileWriterTests {
        private func finish(_ writer: VideoFileWriter) async -> VideoFileWriter.Summary {
            await withCheckedContinuation { continuation in
                writer.finish { continuation.resume(returning: $0) }
            }
        }
    
        /// Where the frames of a video sit, in seconds, in the order they are shown.
        private func frameTimes(in url: URL) async throws -> [TimeInterval] {
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            // Decoded, so that there is exactly one sample per picture.
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            )
            let provider = reader.outputProvider(for: output)
        
            try reader.start()
        
            var times: [TimeInterval] = []
            while let sample = try await provider.next() {
                times.append(sample.presentationTimeStamp.seconds)
            }
            return times
        }
    
        @Test
        func everyFrameSitsAtItsCaptureTime() async throws {
            let url = try RecordingStore.scratch().prepare(UUID())
            let writer = VideoFileWriter(url: url)
        
            // Idle rate first, then the precision rate, as around a gun.
            let captured = (0..<4).map { 500 + Double($0) / 15 } + (1...24).map { 500.2 + Double($0) / 240 }
        
            for (index, time) in captured.enumerated() {
                writer.append(try .synthetic(at: time, index: index))
            }
        
            let summary = await finish(writer)
        
            #expect(summary.failure == nil)
            #expect(summary.skippedFrames + summary.frameTimes.count == captured.count)
            #expect(!summary.frameTimes.isEmpty)
        
            let first = try #require(summary.frameTimes.first)
            let expected = summary.frameTimes.map {
                VideoTimeline.presentationTime(of: $0, first: first).seconds
            }
            let stored = try await frameTimes(in: url)
        
            #expect(stored.count == expected.count)
            // Exactly: a seek computed from a capture time has to land on its frame.
            #expect(zip(stored, expected).allSatisfy { $0 == $1 })
        
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            let upright = CGRect(origin: .zero, size: size).applying(transform)
        
            // Turned upright for playback.
            #expect(abs(upright.width) == 360)
            #expect(abs(upright.height) == 640)
        }
    
        @Test
        func framesOutOfOrderAreLeftOut() async throws {
            let writer = VideoFileWriter(url: try RecordingStore.scratch().prepare(UUID()))
        
            for time in [1.0, 1.1, 1.05, 1.1, 1.2] {
                writer.append(try .synthetic(at: time))
            }
        
            let summary = await finish(writer)
        
            #expect(summary.failure == nil)
            // The encoder may have passed on some, but never takes one that goes back.
            let times = summary.frameTimes.map { $0.seconds }
            #expect(times.first == 1.0)
            #expect(times.allSatisfy { [1.0, 1.1, 1.2].contains($0) })
            #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
            #expect(times.count + summary.skippedFrames == 3)
        }
    
        @Test
        func withoutFramesThereIsNoFileAndNoFailure() async throws {
            let url = try RecordingStore.scratch().prepare(UUID())
            let writer = VideoFileWriter(url: url)
        
            let summary = await finish(writer)
        
            #expect(summary == VideoFileWriter.Summary())
            #expect(!FileManager.default.fileExists(atPath: url.path))
        
            // Too late for this file.
            writer.append(try .synthetic(at: 1))
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}

struct RecordingStoreTests {
    private func recording(date: Date = .now) -> StartRecording {
        StartRecording(
            id: UUID(),
            date: date,
            session: recordedSession(),
            results: [],
            frameTimes: [MonotonicTimestamp(seconds: 9), MonotonicTimestamp(seconds: 9.1)],
            skippedFrames: 0
        )
    }
    
    /// Stores a recording as the controller would, with a stand-in for the video.
    private func store(_ recording: StartRecording, in store: RecordingStore) throws {
        try Data("video".utf8).write(to: try store.prepare(recording.id))
        try store.write(recording, tracking: [TrackingFrame(time: MonotonicTimestamp(seconds: 9), athletes: [.fake()])])
    }
    
    @Test
    func aStoredRecordingIsFoundWithItsTracking() throws {
        let store = RecordingStore.scratch()
        let recording = recording()
        
        try self.store(recording, in: store)
        
        #expect(store.recordings(in: .temporary) == [recording])
        #expect(store.recordings(in: .library).isEmpty)
        #expect(try store.tracking(of: recording.id, in: .temporary).count == 1)
        #expect(store.files(of: recording.id, in: .temporary).map { $0.lastPathComponent }
            == [RecordingStore.videoFileName, RecordingStore.recordFileName, RecordingStore.trackingFileName])
    }
    
    @Test
    func whatTheSamplerSawIsStoredBesideTheRest() throws {
        let store = RecordingStore.scratch()
        let recording = recording()
        let motion = MotionRecord(
            athleteID: AthleteID(),
            region: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5),
            samples: [
                MotionSample(time: MonotonicTimestamp(seconds: 9), cells: [0, 17, 255]),
                MotionSample(time: MonotonicTimestamp(seconds: 9.1), cells: [1, 2, 3])
            ]
        )
        
        try Data("video".utf8).write(to: try store.prepare(recording.id))
        try store.write(recording, tracking: [], motion: [motion])
        
        #expect(try store.motion(of: recording.id, in: .temporary) == [motion])
        #expect(store.files(of: recording.id, in: .temporary).map { $0.lastPathComponent }.last == RecordingStore.motionFileName)
    }
    
    @Test
    func aRecordingWithoutSamplesHasNoFileForThem() throws {
        let store = RecordingStore.scratch()
        let recording = recording()
        
        try self.store(recording, in: store)
        
        #expect(try store.motion(of: recording.id, in: .temporary).isEmpty)
    }
    
    @Test
    func aRecordingWithoutItsVideoIsPassedOver() throws {
        let store = RecordingStore.scratch()
        let recording = recording()
        
        try self.store(recording, in: store)
        try FileManager.default.removeItem(at: store.videoURL(of: recording.id, in: .temporary))
        
        #expect(store.recordings(in: .temporary).isEmpty)
    }
    
    @Test
    func savingMovesTheRecordingIntoTheLibrary() throws {
        let store = RecordingStore.scratch()
        let recording = recording()
        
        try self.store(recording, in: store)
        try store.save(recording.id)
        
        #expect(store.recordings(in: .temporary).isEmpty)
        #expect(store.recordings(in: .library) == [recording])
        #expect(try store.tracking(of: recording.id, in: .library).count == 1)
        
        store.delete(recording.id, in: .library)
        #expect(store.recordings(in: .library).isEmpty)
    }
    
    @Test
    func theNextStartClearsTheOnesBefore() throws {
        let store = RecordingStore.scratch()
        let old = recording(date: .now.addingTimeInterval(-60))
        let saved = recording(date: .now.addingTimeInterval(-30))
        let new = recording()
        
        try self.store(old, in: store)
        try self.store(saved, in: store)
        try store.save(saved.id)
        try self.store(new, in: store)
        
        #expect(store.recordings(in: .temporary) == [new, old])
        
        store.keepOnly([new.id])
        
        #expect(store.recordings(in: .temporary) == [new])
        #expect(store.recordings(in: .library) == [saved])
    }
}

extension VideoRecordingTests {
    @MainActor
    struct StartRecordingControllerTests {
        private let source = FakeFrameSource()
        private let store = RecordingStore.scratch()
    
        /// Closing a video takes the simulator's encoder a while when many
        /// tests run beside it.
        private let patience = Duration.seconds(30)
    
        private func makeController() -> StartRecordingController {
            StartRecordingController(source: source, store: store)
        }
    
        /// Records a start of a few frames and ends it with the given outcome.
        private func record(
            with controller: StartRecordingController,
            outcome: StartSessionOutcome = .completed,
            from time: TimeInterval = 9.5,
            tail: TimeInterval = 0
        ) async throws -> StartSession {
            try #require(controller.beginRecording())
        
            for index in 0..<6 {
                try await source.deliver(at: time + Double(index) / 120, index: index)
            }
            controller.record(TrackingFrame(time: MonotonicTimestamp(seconds: time), athletes: [.fake()]))
        
            let session = recordedSession(outcome: outcome)
            controller.endRecording(session: session, results: [], tail: tail)
            return session
        }
    
        @Test
        func nothingIsRecordedWithoutFrames() {
            let controller = makeController()
            source.isDelivering = false
        
            #expect(!controller.beginRecording())
            #expect(source.handler == nil)
        }
    
        @Test
        func aCompletedStartBecomesTheLastRecording() async throws {
            let controller = makeController()
        
            let session = try await record(with: controller)
        
            #expect(source.handler == nil)
            await waitUntil(timeout: patience) { controller.last != nil }
        
            let last = try #require(controller.last)
            #expect(last.session == session)
            #expect(last.frameTimes.count + last.skippedFrames == 6)
            #expect(!controller.isFinishing)
            #expect(FileManager.default.fileExists(atPath: controller.videoURL(of: last).path))
            #expect(await controller.tracking(of: last).count == 1)
            #expect(controller.files(of: last).count == 3)
        }
    
        @Test(arguments: [StartSessionOutcome.aborted, .failed("no output")])
        func aStartThatGotNowhereKeepsTheOneBefore(outcome: StartSessionOutcome) async throws {
            let controller = makeController()
        
            _ = try await record(with: controller)
            await waitUntil(timeout: patience) { controller.last != nil }
            let first = try #require(controller.last)
        
            _ = try await record(with: controller, outcome: outcome, from: 20)
            await waitUntil(timeout: patience) { !controller.isFinishing }
        
            #expect(controller.last == first)
            #expect(store.recordings(in: .temporary) == [first])
        }
    
        @Test
        func theNextStartReplacesTheLast() async throws {
            let controller = makeController()
        
            _ = try await record(with: controller)
            await waitUntil(timeout: patience) { controller.last != nil }
            let first = try #require(controller.last)
        
            _ = try await record(with: controller, outcome: .falseStart, from: 20)
            await waitUntil(timeout: patience) { controller.last != first && !controller.isFinishing }
        
            let second = try #require(controller.last)
            #expect(second.session.outcome == .falseStart)
            #expect(store.recordings(in: .temporary) == [second])
        }
    
        @Test
        func aSavedStartOutlivesTheNext() async throws {
            let controller = makeController()
        
            _ = try await record(with: controller)
            await waitUntil(timeout: patience) { controller.last != nil }
            let first = try #require(controller.last)
        
            try controller.save(first)
        
            #expect(controller.last == nil)
            #expect(controller.saved == [first])
            #expect(controller.isSaved(first))
            #expect(FileManager.default.fileExists(atPath: controller.videoURL(of: first).path))
        
            _ = try await record(with: controller, from: 20)
            await waitUntil(timeout: patience) { controller.last != nil }
        
            // A controller started later finds both again.
            let reopened = makeController()
            #expect(reopened.saved == [first])
            #expect(reopened.last == controller.last)
        
            controller.delete(first)
            #expect(controller.saved.isEmpty)
            #expect(store.recordings(in: .library).isEmpty)
        }
    
        @Test
        func aCompletedStartIsRecordedALittleLonger() async throws {
            let controller = makeController()
        
            _ = try await record(with: controller, tail: 60)
        
            // Still taking frames and tracking data after the run.
            #expect(source.handler != nil)
            try await source.deliver(at: 9.6, index: 6)
            controller.record(TrackingFrame(time: MonotonicTimestamp(seconds: 9.6), athletes: []))
        
            // The camera is about to stop.
            controller.flush()
        
            #expect(source.handler == nil)
            await waitUntil(timeout: patience) { controller.last != nil }
        
            let last = try #require(controller.last)
            #expect(last.frameTimes.count + last.skippedFrames == 7)
            #expect(await controller.tracking(of: last).count == 2)
        }
    
        @Test
        func aStartDuringTheTailEndsIt() async throws {
            let controller = makeController()
        
            let first = try await record(with: controller, tail: 60)
            let second = try await record(with: controller, from: 20, tail: 60)
        
            controller.flush()
            await waitUntil(timeout: patience) { controller.last?.session == second && !controller.isFinishing }
        
            #expect(first != second)
            #expect(store.recordings(in: .temporary).map { $0.session } == [second])
        }
    
        @Test
        func whatAnUnfinishedStartLeftBehindIsClearedWhenTheAppOpens() async throws {
            let controller = makeController()
        
            _ = try await record(with: controller)
            await waitUntil(timeout: patience) { controller.last != nil }
            let last = try #require(controller.last)
        
            // A start whose files were never completed.
            let orphan = UUID()
            _ = try store.prepare(orphan)
        
            let reopened = makeController()
        
            #expect(reopened.last == last)
            #expect(FileManager.default.fileExists(atPath: reopened.videoURL(of: last).path))
            #expect(!FileManager.default.fileExists(atPath: store.directory(of: orphan, in: .temporary).path))
        }
    
        /// The folders of the temporary recordings that hold the given file.
        private func temporaryFolders(holding file: String? = nil) -> [URL] {
            let root = store.directory(of: UUID(), in: .temporary).deletingLastPathComponent()
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        
            return folders.filter { folder in
                file.map { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) } ?? true
            }
        }
    
        @Test
        func aStartBegunWhileTheLastIsStoredKeepsItsFolder() async throws {
            let controller = makeController()
        
            try #require(controller.beginRecording())
            for index in 0..<6 {
                try await source.deliver(at: 9.5 + Double(index) / 120, index: index)
            }
        
            // So much tracking data that storing it takes a while. The
            // start's record is written first.
            for index in 0..<100_000 {
                controller.record(TrackingFrame(time: MonotonicTimestamp(seconds: 9.5 + Double(index) / 1000), athletes: []))
            }
            let first = recordedSession()
            controller.endRecording(session: first, results: [], tail: 0)
        
            await waitUntil(timeout: patience) {
                !temporaryFolders(holding: RecordingStore.recordFileName).isEmpty
            }
            try #require(controller.last == nil)
        
            // The next start reaches its hold while the tracking data is written.
            try #require(controller.beginRecording())
            let folders = temporaryFolders()
            try #require(folders.count == 2)
        
            await waitUntil(timeout: patience) { controller.last?.session == first }
        
            #expect(temporaryFolders().count == 2)
        
            for index in 0..<6 {
                try await source.deliver(at: 20 + Double(index) / 120, index: index)
            }
            let second = recordedSession(outcome: .falseStart)
            controller.endRecording(session: second, results: [], tail: 0)
        
            await waitUntil(timeout: patience) { controller.last?.session == second && !controller.isFinishing }
            #expect(store.recordings(in: .temporary).map { $0.session } == [second])
        }
    
        @Test
        func aFalseStartHasNoTail() async throws {
            let controller = makeController()
        
            _ = try await record(with: controller, outcome: .falseStart, tail: 60)
        
            #expect(source.handler == nil)
            await waitUntil(timeout: patience) { controller.last != nil }
        }
    }
}

struct ReplayTimelineTests {
    private let athlete = AthleteID()
    
    /// Frames at 100 fps from 9.5 s, a gun at 10 s and a movement after it.
    private func timeline(
        session: StartSession? = nil,
        tracking: [TrackingFrame] = []
    ) -> ReplayTimeline {
        let movement = TimeEstimate(
            best: MonotonicTimestamp(seconds: 10.145),
            earliest: MonotonicTimestamp(seconds: 10.14),
            latest: MonotonicTimestamp(seconds: 10.15)
        )
        
        return ReplayTimeline(
            recording: StartRecording(
                id: UUID(),
                date: .now,
                session: session ?? recordedSession(),
                results: [
                    AthleteStartResult(
                        athleteID: nil, position: nil, movement: movement, reaction: nil,
                        decision: .legal, trackingQuality: nil
                    ),
                    AthleteStartResult(
                        athleteID: athlete, position: 1, movement: movement, reaction: nil,
                        decision: .definiteFalseStart, trackingQuality: nil
                    ),
                ],
                frameTimes: (0...100).map { MonotonicTimestamp(seconds: 9.5 + Double($0) / 100) },
                skippedFrames: 0
            ),
            tracking: tracking
        )
    }
    
    @Test
    func aMomentShowsTheLastFrameCapturedBeforeIt() {
        let timeline = timeline()
        
        #expect(timeline.frameCount == 101)
        #expect(abs(timeline.duration - 1) < 1e-9)
        #expect(timeline.frame(at: MonotonicTimestamp(seconds: 9.5)) == 0)
        #expect(timeline.frame(at: MonotonicTimestamp(seconds: 9.7049)) == 20)
        #expect(timeline.frame(at: MonotonicTimestamp(seconds: 9.7151)) == 21)
        // Outside of the video, the nearer end.
        #expect(timeline.frame(at: MonotonicTimestamp(seconds: 1)) == 0)
        #expect(timeline.frame(at: MonotonicTimestamp(seconds: 99)) == 100)
    }
    
    @Test
    func everyFrameIsFoundAgainFromItsPlaceInTheVideo() {
        let timeline = timeline()
        
        for frame in 0..<timeline.frameCount {
            #expect(timeline.frame(atVideoTime: timeline.videoTime(ofFrame: frame).seconds) == frame)
        }
        
        #expect(timeline.frame(atFraction: 0) == 0)
        #expect(timeline.frame(atFraction: 0.505) == 50)
        #expect(timeline.frame(atFraction: 1) == 100)
        #expect(timeline.frame(atFraction: 7) == 100)
    }
    
    @Test
    func framesAreTimedAgainstTheGun() throws {
        let timeline = timeline()
        
        #expect(timeline.gun?.best == MonotonicTimestamp(seconds: 10))
        #expect(abs(try #require(timeline.timeSinceGun(ofFrame: 0)) + 0.5) < 1e-9)
        #expect(abs(try #require(timeline.timeSinceGun(ofFrame: 64)) - 0.14) < 1e-9)
        #expect(abs(timeline.fraction(of: MonotonicTimestamp(seconds: 10)) - 0.5) < 1e-9)
        #expect(timeline.fraction(of: MonotonicTimestamp(seconds: 3)) == 0)
        #expect(timeline.fraction(of: MonotonicTimestamp(seconds: 30)) == 1)
    }
    
    @Test
    func aStartRecalledBeforeTheGunHasNone() {
        var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 0))
        let planned = TimeEstimate.exact(MonotonicTimestamp(seconds: 10))
        
        // Taken back once, scheduled again, then a false start before it was heard.
        session.record(.gunScheduled(AudioPreflight.fake().gunTiming), at: planned, source: .audioLocal)
        session.record(.gunCancelled, at: planned, source: .system)
        session.record(.gunScheduled(AudioPreflight.fake().gunTiming), at: planned, source: .audioLocal)
        session.record(.stateChanged(.falseStart), at: planned, source: .system)
        session.finish(.falseStart, at: planned)
        
        let timeline = timeline(session: session)
        
        #expect(timeline.gun == nil)
        #expect(timeline.timeSinceGun(ofFrame: 10) == nil)
    }
    
    @Test
    func theGunHeardIsTheLastOneScheduled() {
        var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 0))
        let first = TimeEstimate.exact(MonotonicTimestamp(seconds: 9.8))
        let second = TimeEstimate.exact(MonotonicTimestamp(seconds: 10.2))
        
        session.record(.gunScheduled(AudioPreflight.fake().gunTiming), at: first, source: .audioLocal)
        session.record(.gunCancelled, at: first, source: .system)
        session.record(.gunScheduled(AudioPreflight.fake().gunTiming), at: second, source: .audioLocal)
        session.record(.stateChanged(.start), at: second, source: .system)
        
        #expect(ReplayTimeline.gun(in: session) == second)
    }
    
    @Test
    func aGunThatWasOutBeforeARecallIsShown() {
        var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 0))
        let heard = TimeEstimate.exact(MonotonicTimestamp(seconds: 10))
        
        // Recalled between the gun going out and the sequence reaching it.
        session.record(.gunScheduled(AudioPreflight.fake().gunTiming), at: heard, source: .audioLocal)
        session.record(.gunCommitted, at: heard, source: .audioLocal)
        session.record(.stateChanged(.falseStart), at: heard, source: .system)
        
        #expect(ReplayTimeline.gun(in: session) == heard)
    }
    
    @Test
    func aGunOffItsScheduleIsShownAsRevised() {
        var session = StartSession(startType: .block, profile: .block, createdAt: MonotonicTimestamp(seconds: 0))
        let scheduled = TimeEstimate.exact(MonotonicTimestamp(seconds: 10))
        let revised = TimeEstimate(
            best: MonotonicTimestamp(seconds: 10.004),
            earliest: MonotonicTimestamp(seconds: 10),
            latest: MonotonicTimestamp(seconds: 10.004)
        )
        
        session.record(.gunScheduled(AudioPreflight.fake().gunTiming), at: scheduled, source: .audioLocal)
        session.record(.gunCommitted, at: scheduled, source: .audioLocal)
        session.record(.stateChanged(.start), at: scheduled, source: .system)
        session.record(.gunTimeRevised, at: revised, source: .audioLocal)
        
        #expect(ReplayTimeline.gun(in: session) == revised)
    }
    
    @Test
    func aFrameShowsTheNewestTrackingDataThatIsNotStale() {
        let tracking = [9.9, 9.6, 9.61].map {
            TrackingFrame(time: MonotonicTimestamp(seconds: $0), athletes: [.fake(time: $0)])
        }
        let timeline = timeline(tracking: tracking)
        
        // Before any pose was analysed.
        #expect(timeline.tracking(forFrame: 5) == nil)
        #expect(timeline.tracking(forFrame: 10)?.time.seconds == 9.6)
        #expect(timeline.tracking(forFrame: 12)?.time.seconds == 9.61)
        #expect(timeline.tracking(forFrame: 25)?.time.seconds == 9.61)
        // Older than the tracker can vouch for.
        #expect(timeline.tracking(forFrame: 30) == nil)
        #expect(timeline.tracking(forFrame: 41)?.time.seconds == 9.9)
        #expect(timeline.tracking(forFrame: 500) == nil)
    }
    
    @Test
    func resultsAreOrderedByNumberAndFalseStartersNamed() {
        let timeline = timeline()
        
        #expect(timeline.results.map { $0.position } == [1, nil])
        #expect(timeline.falseStarters == [athlete])
    }
}

@MainActor
struct EngineRecordingTests {
    private func makeEngine(
        holdTime: Double = 0
    ) -> (StarterEngine, FakeMovementDetector, FakeStartRecorder, StartConfig) {
        let player = FakeSignalPlayer()
        let detector = FakeMovementDetector()
        let recorder = FakeStartRecorder()
        
        var config = StartConfig.instant
        config.blockTimeToStartMin = holdTime
        config.blockTimeToStartMax = holdTime
        
        return (StarterEngine(player: player, movementDetector: detector, recorder: recorder), detector, recorder, config)
    }
    
    @Test
    func recordingRunsFromTheHoldToTheEndOfTheRun() async throws {
        let (engine, detector, recorder, config) = makeEngine(holdTime: 10)
        
        engine.start(config: config)
        #expect(recorder.beginCount == 0)
        
        await waitUntil { engine.state == .waitForStart }
        #expect(recorder.beginCount == 1)
        
        detector.emitTracking(at: 1)
        detector.emitMovement(at: 2)
        await waitUntil { !engine.isRunning }
        
        let ended = try #require(recorder.ended.first)
        let kinds = ended.session.events.map { $0.kind }
        
        #expect(recorder.ended.count == 1)
        #expect(ended.session == engine.lastSession)
        #expect(ended.session.outcome == .falseStart)
        #expect(ended.results == engine.athleteResults)
        #expect(recorder.tracking.map { $0.time.seconds } == [1])
        
        let began = try #require(kinds.firstIndex(of: .recordingBegan))
        let finished = try #require(kinds.firstIndex(of: .recordingEnded))
        #expect(try #require(kinds.firstIndex(of: .monitoringStarted)) < began)
        #expect(began < finished)
        #expect(kinds.last == .sessionEnded(.falseStart))
    }
    
    @Test
    func aCompletedStartHandsOverItsSession() async throws {
        let (engine, _, recorder, config) = makeEngine()
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        #expect(recorder.ended.map { $0.session.outcome } == [.completed])
    }
    
    /// The first steps are what athletes want to see: the recording and
    /// the precision rate go on after the run, counted from the gun.
    @Test
    func aCompletedStartIsFilmedOnAtThePrecisionRate() async throws {
        let clock = ManualClock()
        let player = FakeSignalPlayer()
        player.gunDuration = 0.4
        player.clock = clock
        let detector = FakeMovementDetector()
        detector.clock = clock
        let recorder = FakeStartRecorder()
        let engine = StarterEngine(
            player: player, movementDetector: detector, recorder: recorder, clock: clock, decisionEngine: DecisionEngine()
        )
        
        var config = StartConfig.instant
        config.blockTimeToStartMin = 0.5
        config.blockTimeToStartMax = 0.5
        config.recordingAfterStart = 2.5
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        // The hold and the gun's sound.
        await clock.advance(by: 0.9)
        #expect(!engine.isRunning)
        
        // 0.4 s of the 2.5 s have passed with the gun's sound.
        let ended = try #require(recorder.ended.first)
        #expect(ended.session.outcome == .completed)
        #expect(abs(ended.tail - 2.1) < 0.000_001)
        #expect(detector.isInPrecisionWindow)
        
        await clock.advance(by: 2.09)
        #expect(detector.isInPrecisionWindow)
        
        await clock.advance(by: 0.02)
        #expect(!detector.isInPrecisionWindow)
        #expect(detector.precisionEndCount == 1)
    }
    
    @Test
    func theNextStartEndsTheFilmingOfTheOneBefore() async throws {
        let (engine, detector, recorder, base) = makeEngine()
        var config = base
        config.recordingAfterStart = 6
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        #expect(detector.isInPrecisionWindow)
        
        config.blockTimeToReady = 10
        engine.start(config: config)
        #expect(!detector.isInPrecisionWindow)
        
        engine.abort()
        #expect(recorder.ended.count == 1)
    }
    
    @Test
    func aFalseStartIsNotFilmedOn() async throws {
        let (engine, detector, recorder, config) = makeEngine(holdTime: 10)
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        detector.emitMovement(at: 2)
        await waitUntil { !engine.isRunning }
        
        #expect(recorder.ended.map { $0.tail } == [0])
        #expect(!detector.isInPrecisionWindow)
    }
    
    @Test
    func whatTheSamplerSawGoesToTheRecorder() async throws {
        let (engine, detector, recorder, config) = makeEngine(holdTime: 10)
        let motion = MotionRecord(athleteID: AthleteID(), region: .zero, samples: [])
        
        engine.start(config: config)
        await waitUntil { engine.state == .waitForStart }
        
        detector.onEvent?(.motionSampled(motion))
        engine.abort()
        
        #expect(recorder.motion == [motion])
    }
    
    @Test
    func nothingIsRecordedWhenSwitchedOff() async {
        let (engine, _, recorder, base) = makeEngine()
        var config = base
        config.recordsVideo = false
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        #expect(recorder.beginCount == 0)
        #expect(recorder.ended.isEmpty)
    }
    
    @Test
    func withoutACameraTheStartRunsUnrecorded() async throws {
        let (engine, _, recorder, config) = makeEngine()
        recorder.canRecord = false
        
        engine.start(config: config)
        await waitUntil { !engine.isRunning }
        
        let kinds = try #require(engine.lastSession).events.map { $0.kind }
        
        #expect(engine.lastSession?.outcome == .completed)
        #expect(!kinds.contains(.recordingBegan))
        #expect(!kinds.contains(.recordingEnded))
        #expect(recorder.ended.isEmpty)
    }
    
    @Test
    func anAbortBeforeTheHoldRecordsNothing() async {
        let (engine, _, recorder, base) = makeEngine()
        var config = base
        config.blockTimeToReady = 10
        
        engine.start(config: config)
        await waitUntil { engine.state == .preparing }
        engine.abort()
        
        #expect(recorder.beginCount == 0)
        #expect(recorder.ended.isEmpty)
    }
}

extension VideoRecordingTests {
    /// Puts a made-up start into the app's library, so the review can be looked
    /// at in the simulator, which has no camera to record one with.
    @MainActor
    struct DemoRecordingTests {
        nonisolated static let seedRequested = ProcessInfo.processInfo.environment["SEED_RECORDING"] == "1"
    
        /// A frame with a bright block where the athlete's torso is.
        private func frame(at time: TimeInterval, index: Int, athletes: [TrackedAthlete]) throws -> CameraFrame {
            let frame = try CameraFrame.synthetic(at: time, index: 0)
            let buffer = frame.pixelBuffer
        
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        
            for athlete in athletes {
                // From the upright picture into the buffer, which lies on its side.
                let centerX = Int((1 - athlete.pose.center.y) * CGFloat(width))
                let centerY = Int((1 - athlete.pose.center.x) * CGFloat(height))
            
                for y in max(0, centerY - 12)..<min(height, centerY + 12) {
                    for x in max(0, centerX - 40)..<min(width, centerX + 40) {
                        base[y * rowBytes + x] = 220
                    }
                }
            }
            return frame
        }
    
        @Test(.enabled(if: seedRequested))
        func seedsAStartIntoTheLibrary() async throws {
            let source = FakeFrameSource()
            let controller = StartRecordingController(source: source)
            let ids = [AthleteID(), AthleteID()]
            let quality = TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1)
            let gun = 100.0
        
            /// The first athlete leaves early, the second in time.
            func athletes(at time: TimeInterval) -> [TrackedAthlete] {
                let lean = [max(0, time - gun - 0.06), max(0, time - gun - 0.15)]
                return ids.enumerated().map { index, id in
                    .fake(id: id, at: CGPoint(x: 0.3 + 0.4 * Double(index) + lean[index] * 0.5, y: 0.45), time: time)
                }
            }
        
            try #require(controller.beginRecording())
        
            // The hold at the idle rate, then the precision window around the gun.
            let times = (0..<8).map { gun - 1.1 + Double($0) / 15 } + (0..<110).map { gun - 0.55 + Double($0) / 120 }
        
            for (index, time) in times.enumerated() {
                let athletes = athletes(at: time)
            
                await source.deliver(try frame(at: time, index: index, athletes: athletes))
                controller.record(
                    TrackingFrame(
                        time: MonotonicTimestamp(seconds: time),
                        athletes: athletes,
                        phases: Dictionary(uniqueKeysWithValues: ids.map { ($0, .stable) })
                    )
                )
                // The simulator's encoder can't take frames as fast as a loop sends them.
                try await Task.sleep(for: .milliseconds(15))
            }
        
            func moved(_ seconds: TimeInterval) -> TimeEstimate {
                TimeEstimate(
                    best: MonotonicTimestamp(seconds: gun + seconds),
                    earliest: MonotonicTimestamp(seconds: gun + seconds - 0.004),
                    latest: MonotonicTimestamp(seconds: gun + seconds + 0.004)
                )
            }
        
            let roster = AthleteRoster(entries: ids.enumerated().map { .init(id: $1, position: $0 + 1, quality: quality) })
            let heard = TimeEstimate(
                best: MonotonicTimestamp(seconds: gun),
                earliest: MonotonicTimestamp(seconds: gun - 0.002),
                latest: MonotonicTimestamp(seconds: gun + 0.002)
            )
        
            controller.endRecording(
                session: recordedSession(gun: gun, outcome: .falseStart, roster: roster),
                results: [
                    AthleteStartResult(
                        athleteID: ids[0], position: 1, movement: moved(0.06),
                        reaction: moved(0.06).duration(since: heard), decision: .definiteFalseStart,
                        trackingQuality: quality, isRefined: true
                    ),
                    AthleteStartResult(
                        athleteID: ids[1], position: 2, movement: moved(0.15),
                        reaction: moved(0.15).duration(since: heard), decision: .legal,
                        trackingQuality: quality, isRefined: true
                    ),
                ],
                tail: 0
            )
        
            await waitUntil(timeout: .seconds(30)) { controller.last != nil }
        
            let last = try #require(controller.last)
            try controller.save(last)
        
            Attachment.record(
                "\(last.frameTimes.count) frames, \(last.skippedFrames) skipped",
                named: "Seeded recording"
            )
        }
    }
}
