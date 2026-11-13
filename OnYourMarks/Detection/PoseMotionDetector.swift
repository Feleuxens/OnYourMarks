//
//  PoseMotionDetector.swift
//  OnYourMarks
//

import Foundation
import Synchronization
import Vision

/// Follows the athletes in the camera's frames and detects each one's
/// first movement.
///
/// Two rates: every frame is sampled where the athletes are, which is
/// cheap and keeps the camera's full time resolution. Pose detection, which
/// knows who is who, takes the newest frame whenever it is free.
final class PoseMotionDetector: MovementDetector {
    /// Every athlete after each analysed frame and, while monitoring, how
    /// still the ones on the roster are. For the preview overlay.
    var onAthletes: (([TrackedAthlete], [AthleteID: AthleteStability.Phase]) -> Void)?

    var onEvent: ((DetectorEvent) -> Void)?

    let source = MeasurementSource.cameraLocal

    private(set) var isReady = false

    /// For a camera held in the hand: takes the camera's own movement out
    /// of the athletes'. Costs an image registration per frame, so it stays
    /// off on a tripod.
    var compensatesCameraMotion = false {
        didSet {
            let compensates = compensatesCameraMotion
            tracking.withLock { $0.compensatesCameraMotion = compensates }
        }
    }

    private let camera: CameraController
    private nonisolated let poseTracker = PoseTracker()
    private nonisolated let cameraMotion = CameraMotionEstimator()
    private nonisolated let tracking = Mutex(Tracking())
    private nonisolated let motion = Mutex(MotionTimeline())
    private nonisolated let statistics = Mutex(DetectionStatistics())

    /// Pose detection takes longer than a frame lasts at the precision
    /// rate, so it gets its own queue and must not hold up the sampling.
    private nonisolated let poseQueue = DispatchSerialQueue(label: "detection.pose")
    private nonisolated let poseInbox = Mutex(PoseInbox())

    /// The frame pose detection takes next. Only the newest one waits: an
    /// older one that was not begun is passed over.
    private nonisolated struct PoseInbox {
        var isBusy = false
        var waiting: CameraFrame?
    }

    /// Frames sampled and frames that went through pose detection since
    /// monitoring last began.
    var detectionStatistics: DetectionStatistics {
        statistics.withLock { $0 }
    }

    /// Shared between the pose queue and the main actor.
    private nonisolated struct Tracking {
        var tracker = AthleteTracker()
        var monitor = AthleteMotionMonitor()
        var athletes: [TrackedAthlete] = []
        var compensatesCameraMotion = false
        /// The next frame becomes the picture camera movement is measured against.
        var needsCameraReference = false
    }

    init(camera: CameraController) {
        self.camera = camera

        camera.setFrameHandler { [weak self] frame in
            self?.process(frame)
        }
    }

    @discardableResult
    func startMonitoring(profile: MotionProfile) -> AthleteRoster {
        let (roster, ready) = tracking.withLock {
            let roster = $0.monitor.begin(with: $0.athletes, profile: profile)
            $0.tracker.retained = Set(roster.entries.map { $0.id })
            $0.needsCameraReference = true
            return (roster, $0.monitor.isReady)
        }
        motion.withLock { $0.reset() }
        statistics.withLock { $0 = DetectionStatistics() }

        isReady = ready
        return roster
    }

    func resettle(_ athlete: AthleteID?) {
        isReady = tracking.withLock {
            $0.monitor.resettle(athlete)
            return $0.monitor.isReady
        }
    }

    func stopMonitoring() {
        tracking.withLock {
            $0.monitor.end()
            $0.tracker.retained = []
        }
        let records = motion.withLock { timeline in
            defer { timeline.reset() }
            return timeline.records
        }
        isReady = false

        for record in records {
            onEvent?(.motionSampled(record))
        }
    }

    /// Forgets the athletes; the next ones in view get new IDs.
    func reset() {
        stopMonitoring()
        tracking.withLock {
            $0.tracker.reset()
            $0.athletes = []
        }
    }

    func beginPrecisionWindow() {
        camera.setMode(.precision)
    }

    func endPrecisionWindow() {
        camera.setMode(.idle)
    }

    /// Runs on the capture queue, for every frame.
    private nonisolated func process(_ frame: CameraFrame) {
        sample(frame)

        let isFree = poseInbox.withLock { inbox in
            guard inbox.isBusy else {
                inbox.isBusy = true
                return true
            }

            inbox.waiting = frame
            return false
        }
        guard isFree else { return }

        poseQueue.async { [weak self] in
            var next: CameraFrame? = frame

            while let current = next, let self {
                analyse(current)

                next = poseInbox.withLock { inbox in
                    defer { inbox.waiting = nil }
                    inbox.isBusy = inbox.waiting != nil
                    return inbox.waiting
                }
            }
        }
    }

    /// Keeps what every watched athlete's part of the frame looks like.
    private nonisolated func sample(_ frame: CameraFrame) {
        let regions = motion.withLock { $0.regions }
        guard !regions.isEmpty else { return }

        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)

        let samples = regions.compactMapValues { region in
            MotionSampler.cells(
                of: frame.pixelBuffer,
                in: MotionSampler.bufferRegion(for: region, bufferWidth: width, bufferHeight: height)
            ).map { MotionSample(time: frame.timestamp, cells: $0) }
        }

        motion.withLock { timeline in
            for (athlete, sample) in samples {
                timeline.append(sample, for: athlete)
            }
        }
        statistics.withLock { $0.sampledFrames += 1 }
    }

    /// Runs on the pose queue.
    private nonisolated func analyse(_ frame: CameraFrame) {
        let poses = poseTracker.poses(in: frame)

        let (compensates, needsReference) = tracking.withLock {
            defer { $0.needsCameraReference = false }
            return ($0.compensatesCameraMotion && $0.monitor.roster != nil, $0.needsCameraReference)
        }

        if needsReference || !compensates {
            cameraMotion.reset()
        }
        let cameraShift = compensates ? cameraMotion.shift(in: frame) : .measured(.zero)

        let (athletes, phases, regions, poseEvents) = tracking.withLock {
            let athletes = $0.tracker.update(with: poses, at: frame.timestamp)
            $0.athletes = athletes
            let events = $0.monitor.process(athletes, camera: cameraShift, at: frame.timestamp)
            return (athletes, $0.monitor.phases, $0.monitor.regions, events)
        }

        // A camera that moves changes every pixel. Until its movement is
        // taken out well enough, a handheld start is timed from poses alone.
        motion.withLock { $0.setRegions(compensates ? [:] : regions) }
        statistics.withLock { $0.analysedFrames += 1 }

        let events = poseEvents.flatMap { event -> [DetectorEvent] in
            guard case .movement(let observation) = event,
                  let refinement = refinement(of: observation) else {
                return [event]
            }
            return [event, .onsetRefined(refinement)]
        }

        let trackingFrame = TrackingFrame(
            time: frame.timestamp,
            athletes: athletes,
            phases: phases,
            cameraOffset: compensates ? cameraShift.offset : nil
        )

        Task { @MainActor [weak self] in
            guard let self else { return }

            onAthletes?(athletes, phases)
            onEvent?(.athletesTracked(trackingFrame))

            // A frame analysed before monitoring ended has nothing to say any more.
            guard tracking.withLock({ $0.monitor.roster != nil }) else { return }

            for event in events {
                if case .readinessChanged(let ready) = event {
                    isReady = ready
                }
                onEvent?(event)
            }
        }
    }

    /// Looks up, in the samples of every frame, when a movement that pose
    /// detection has just confirmed began.
    private nonisolated func refinement(of observation: MovementObservation) -> OnsetRefinement? {
        guard let athlete = observation.athleteID else { return nil }

        let samples = motion.withLock { $0.samples(for: athlete) }

        guard let onset = MotionOnsetAnalyzer.onset(in: samples, confirmedAt: observation.time) else { return nil }

        return OnsetRefinement(athleteID: athlete, onset: onset.interval, droppedFrames: onset.droppedFrames)
    }
}

/// How much of the camera's stream the two paths of the detector saw.
nonisolated struct DetectionStatistics: Equatable, Sendable {
    /// Frames whose athlete regions were sampled; with athletes watched,
    /// every frame the camera delivered.
    var sampledFrames = 0
    /// Frames that went through pose detection.
    var analysedFrames = 0
}
