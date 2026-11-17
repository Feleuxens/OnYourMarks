//
//  SecondPass.swift
//  OnYourMarks
//

import CoreGraphics
import CoreVideo
import Foundation

/// The second pass over a recorded start: every frame of the video, a pose
/// on each, and each roster athlete's part of the picture sampled from
/// their last rest to the end. Live, pose detection gets to about three
/// quarters of the frames at 120 fps, the rest is learned from at most 2 s,
/// and nothing after the confirming frame can be looked at; here all of it can.
///
/// Who is who, where each athlete was sampled and when their last rest
/// began come from the live record, replayed (`StartReplay.poses(of:)`):
/// the second pass measures the same athletes again, it doesn't find others.
///
/// Its result never recalls and never changes the live decision.
nonisolated enum SecondPass {
    /// How far past the frame in which the poses confirmed a movement the
    /// pictures are looked at. A start that crossed the pose threshold is
    /// under way and doesn't stop within a tenth of a second, so the change
    /// stays high up to there, and the peak a beginning is measured by is
    /// more complete. Reasoned, not measured.
    static let followUp: TimeInterval = 0.1

    /// What the second pass looks for, worked out from the live record
    /// before the video is read.
    struct Plan: Equatable, Sendable {
        struct Athlete: Equatable, Sendable {
            let id: AthleteID
            let position: Int

            /// Where the athlete was sampled live, or would have been: the
            /// region around the resting pose.
            let region: CGRect?

            /// The live frame that began the athlete's last still stretch;
            /// the second pass watches the poses from there.
            let stillSince: MonotonicTimestamp?

            /// The live frame that made the athlete stable in it. Rest is
            /// learned from there.
            let stableSince: MonotonicTimestamp?

            /// The frame in which the live poses confirmed the movement.
            let liveConfirmation: MonotonicTimestamp?

            /// How well the athlete was tracked then.
            let quality: TrackingQuality?
        }

        let athletes: [Athlete]
        let gun: StartReplay.Gun?
        let profile: StartProfile

        /// The live tracker's athletes, to recognise them by in the
        /// second pass's own tracks.
        let tracking: [TrackingFrame]

        /// The regions to sample in every frame.
        var regions: [AthleteID: CGRect] {
            Dictionary(uniqueKeysWithValues: athletes.compactMap { athlete in athlete.region.map { (athlete.id, $0) } })
        }
    }

    /// Nil for a start without a roster or without monitored frames: there
    /// is nobody to look for. A handheld start has no plan either: its
    /// camera moved every pixel, which the onset analysis can't take out.
    static func plan(for start: RecordedStart) -> Plan? {
        let session = start.recording.session
        let isHandheld = start.tracking.contains { $0.cameraOffset != nil }

        guard let roster = session.roster, !roster.isEmpty, !isHandheld else { return nil }

        let replay = StartReplay.poses(of: start)
        guard !replay.athletes.isEmpty else { return nil }

        return Plan(
            athletes: replay.athletes.map { athlete in
                Plan.Athlete(
                    id: athlete.id,
                    position: athlete.position,
                    // Exactly where the live analysis sampled, if it did.
                    region: start.motion.first { $0.athleteID == athlete.id }?.region ?? athlete.region,
                    stillSince: athlete.stillSince,
                    stableSince: athlete.stableSince,
                    liveConfirmation: athlete.storedMovement?.latest,
                    quality: athlete.quality
                )
            },
            gun: StartReplay.gun(in: session),
            profile: session.profile,
            tracking: start.tracking
        )
    }

    /// One decoded frame, as the second pass keeps it.
    struct Frame: Sendable {
        let time: MonotonicTimestamp
        let poses: [DetectedPose]
        /// Each planned athlete's region, scaled to the motion grid.
        let cells: [AthleteID: [UInt8]]
    }

    /// Reduces a decoded frame to what the analysis needs, so that the
    /// buffer can go at once.
    static func frame(
        _ buffer: CVPixelBuffer,
        at time: MonotonicTimestamp,
        index: Int,
        regions: [AthleteID: CGRect],
        poses detector: any PoseDetecting
    ) -> Frame {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        return Frame(
            time: time,
            poses: detector.poses(in: CameraFrame(pixelBuffer: buffer, timestamp: time, index: index)),
            cells: regions.compactMapValues {
                MotionSampler.cells(
                    of: buffer,
                    in: MotionSampler.bufferRegion(for: $0, bufferWidth: width, bufferHeight: height)
                )
            }
        )
    }

    /// Analyses the frames of a whole recording.
    static func analyse(
        _ frames: [Frame],
        plan: Plan,
        recordingID: UUID,
        video: RecordedVideoReader.Summary,
        duration: TimeInterval
    ) -> RecordingAnalysis {
        let tracks = track(frames)

        var events: [StartEvent] = []
        var athletes: [RecordingAnalysis.Athlete] = []

        for athlete in plan.athletes {
            let result = analyse(athlete, in: frames, tracks: tracks, plan: plan)
            athletes.append(result)

            guard let movement = result.movement else { continue }

            events.append(
                StartEvent(
                    kind: .movementAnalysed(
                        OnsetRefinement(athleteID: athlete.id, onset: movement, droppedFrames: result.onset?.droppedFrames ?? 0)
                    ),
                    time: movement,
                    source: .recordedVideo,
                    athleteID: athlete.id
                )
            )
            if let reaction = result.reaction {
                events.append(StartEvent(kind: .reactionAnalysed(reaction), time: movement, source: .recordedVideo, athleteID: athlete.id))
            }
        }

        return RecordingAnalysis(
            version: RecordingAnalysis.currentVersion,
            recordingID: recordingID,
            date: .now,
            events: events,
            athletes: athletes,
            frames: RecordingAnalysis.FrameCounts(
                decoded: video.decoded,
                unmatched: video.unmatched,
                withPose: frames.count { !$0.poses.isEmpty }
            ),
            duration: duration
        )
    }

    // MARK: - Athletes

    /// The athletes after every frame, by the app's own tracker. A lost
    /// track is kept: the athletes on the roster keep theirs live too.
    private static func track(_ frames: [Frame]) -> [[TrackedAthlete]] {
        var tracker = AthleteTracker()
        var seen: Set<AthleteID> = []

        return frames.map { frame in
            tracker.retained = seen
            let athletes = tracker.update(with: frame.poses, at: frame.time)
            seen.formUnion(athletes.map { $0.id })
            return athletes
        }
    }

    /// Which of the second pass's tracks is the live athlete: the one whose
    /// poses lay nearest to the live ones, in the frames both have, most
    /// often while the athlete was watched.
    private static func trackID(
        of athlete: Plan.Athlete,
        in frames: [Frame],
        tracks: [[TrackedAthlete]],
        plan: Plan,
        until end: MonotonicTimestamp
    ) -> AthleteID? {
        let indices = Dictionary(frames.enumerated().map { ($1.time, $0) }, uniquingKeysWith: { first, _ in first })
        let begin = athlete.stillSince ?? athlete.stableSince ?? .init(seconds: -.greatestFiniteMagnitude)
        var votes: [AthleteID: Int] = [:]

        for live in plan.tracking where live.time >= begin && live.time <= end {
            guard let pose = live.athletes.first(where: { $0.id == athlete.id && $0.isVisible })?.pose,
                  let index = indices[live.time] else { continue }

            let nearest = tracks[index]
                .filter { $0.isVisible }
                .map { (id: $0.id, distance: pose.distance(to: $0.pose) / pose.bodyScale) }
                .filter { $0.distance <= AthleteAssociation.maximumDistance }
                .min { $0.distance < $1.distance }

            if let nearest {
                votes[nearest.id, default: 0] += 1
            }
        }
        return votes.max { $0.value < $1.value }?.key
    }

    private static func analyse(
        _ athlete: Plan.Athlete,
        in frames: [Frame],
        tracks: [[TrackedAthlete]],
        plan: Plan
    ) -> RecordingAnalysis.Athlete {
        let end = frames.last?.time ?? .init(seconds: 0)
        let watchedUntil = athlete.liveConfirmation.map { MonotonicTimestamp(seconds: $0.seconds + followUp) } ?? end
        let id = trackID(of: athlete, in: frames, tracks: tracks, plan: plan, until: watchedUntil)

        // The poses of every frame from the beginning of the last rest.
        var stability = AthleteStability(profile: plan.profile.motion)
        var poseMovement: TimeEstimate?
        var confirmation: MonotonicTimestamp?
        var posedFrames = 0

        if let id, let begin = athlete.stillSince ?? athlete.stableSince {
            for (frame, athletes) in zip(frames, tracks) where frame.time >= begin {
                guard let tracked = athletes.first(where: { $0.id == id && $0.isVisible }) else { continue }
                posedFrames += 1

                if confirmation == nil,
                   stability.process(tracked.pose.joints, aspectRatio: tracked.pose.aspectRatio, at: frame.time) == .started {
                    confirmation = frame.time
                    poseMovement = stability.onset
                }
            }
        }

        let looked = lookForOnset(of: athlete, in: frames, confirmedAt: confirmation ?? athlete.liveConfirmation)
        let movement = looked.onset?.interval ?? poseMovement
        let reaction = plan.gun.flatMap { gun in movement.map { $0.duration(since: gun.heard) } }

        let engine = DecisionEngine()
        let decision: StartDecision? = if let movement, let reaction, let gun = plan.gun {
            engine.judge(
                reaction,
                movement: movement,
                quality: athlete.quality,
                profile: plan.profile,
                gunTimeIsTrusted: gun.isTrusted,
                renderStart: gun.renderStart
            )
        } else if movement != nil {
            engine.evaluateMovementBeforeGun(trackingQuality: athlete.quality)
        } else {
            nil
        }

        return RecordingAnalysis.Athlete(
            athleteID: athlete.id,
            position: athlete.position,
            poseMovement: poseMovement,
            onset: looked.onset.map {
                OnsetRefinement(athleteID: athlete.id, onset: $0.interval, droppedFrames: $0.droppedFrames)
            },
            reaction: reaction,
            decision: decision,
            change: looked.change,
            parameters: looked.parameters,
            posedFrames: posedFrames
        )
    }

    // MARK: - Pictures

    /// The onset analysis's constants for a second pass that confirmed a
    /// movement at `confirmation` and learns rest from `restSince` on: it
    /// looks `followUp` past the confirmation and learns from all of the
    /// rest, however long it was. Rest still ends where it ends live,
    /// `lookback` before the confirmation.
    static func parameters(
        confirmedAt confirmation: MonotonicTimestamp,
        restSince: MonotonicTimestamp,
        lookingUntil end: MonotonicTimestamp
    ) -> MotionOnsetAnalyzer.Parameters {
        var parameters = MotionOnsetAnalyzer.Parameters.live
        let restEnd = confirmation.seconds - parameters.lookback

        parameters.lookback = end.seconds - restEnd
        parameters.restDuration = max(parameters.restDuration, restEnd - restSince.seconds)
        return parameters
    }

    private static func lookForOnset(
        of athlete: Plan.Athlete,
        in frames: [Frame],
        confirmedAt confirmation: MonotonicTimestamp?
    ) -> (onset: MotionOnsetAnalyzer.Onset?, change: MotionOnsetAnalyzer.ChangeSeries?, parameters: MotionOnsetAnalyzer.Parameters?) {
        guard let confirmation, let restSince = athlete.stableSince else { return (nil, nil, nil) }

        let samples = frames
            .filter { $0.time >= restSince }
            .compactMap { frame in frame.cells[athlete.id].map { MotionSample(time: frame.time, cells: $0) } }

        let lookUntil = MonotonicTimestamp(seconds: confirmation.seconds + followUp)
        let parameters = parameters(confirmedAt: confirmation, restSince: restSince, lookingUntil: lookUntil)
        let onset = MotionOnsetAnalyzer.onset(in: samples, confirmedAt: lookUntil, parameters: parameters)

        // The curve goes on for as long as the frames came at the same rate.
        let curveEnd = steadyEnd(of: samples, from: confirmation)
        let change = MotionOnsetAnalyzer.series(
            in: samples,
            until: curveEnd,
            parameters: Self.parameters(confirmedAt: confirmation, restSince: restSince, lookingUntil: curveEnd)
        )

        return (onset, change, parameters)
    }

    /// The last frame after a moment that came at the rate of the frames
    /// around that moment: up to the first gap the onset analysis wouldn't
    /// look across.
    static func steadyEnd(of samples: [MotionSample], from moment: MonotonicTimestamp) -> MonotonicTimestamp {
        let around = samples.filter { abs($0.time.seconds - moment.seconds) <= MotionOnsetAnalyzer.lookback }
        let gaps = zip(around.dropFirst(), around).map { $0.time.seconds - $1.time.seconds }.sorted()

        guard !gaps.isEmpty, var index = samples.lastIndex(where: { $0.time <= moment }) else { return moment }

        let usual = gaps[gaps.count / 2]
        while index + 1 < samples.count,
              samples[index + 1].time.seconds - samples[index].time.seconds <= MotionOnsetAnalyzer.largestGap * usual {
            index += 1
        }
        return samples[index].time
    }
}

/// Finds the bodies in a frame. `PoseTracker` does it with Vision; tests
/// hand in poses of their own.
nonisolated protocol PoseDetecting {
    func poses(in frame: CameraFrame) -> [DetectedPose]
}

nonisolated extension PoseTracker: PoseDetecting {}

/// Runs the second pass over a recorded start.
nonisolated protocol RecordingAnalyser: Sendable {
    /// Nil if there is nothing to analyse, e.g. no athletes. Off the main
    /// actor, at the caller's priority; throws `CancellationError` once
    /// the task is cancelled.
    @concurrent
    func analyse(_ start: RecordedStart) async throws -> RecordingAnalysis?
}

/// The second pass with Vision's pose detection on the decoded video.
nonisolated struct SecondPassAnalyser: RecordingAnalyser {
    private let makeDetector: @Sendable () -> any PoseDetecting

    init(makeDetector: @escaping @Sendable () -> any PoseDetecting = { PoseTracker() }) {
        self.makeDetector = makeDetector
    }

    @concurrent
    func analyse(_ start: RecordedStart) async throws -> RecordingAnalysis? {
        guard let plan = SecondPass.plan(for: start) else { return nil }

        let clock = ContinuousClock()
        let began = clock.now
        let detector = makeDetector()
        let regions = plan.regions
        var frames: [SecondPass.Frame] = []

        let video = try await RecordedVideoReader.read(start.videoURL, frameTimes: start.recording.frameTimes) { buffer, time in
            frames.append(SecondPass.frame(buffer, at: time, index: frames.count, regions: regions, poses: detector))
        }

        return SecondPass.analyse(
            frames,
            plan: plan,
            recordingID: start.recording.id,
            video: video,
            duration: (clock.now - began) / .seconds(1)
        )
    }
}
