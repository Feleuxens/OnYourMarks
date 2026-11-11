//
//  PoseMotionDetector.swift
//  OnYourMarks
//

import Foundation
import Synchronization
import Vision

/// Follows the athletes in the camera's frames and detects each one's
/// first movement.
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

    /// Shared between the capture queue and the main actor.
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
        isReady = false
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

    /// Runs on the capture queue.
    private nonisolated func process(_ frame: CameraFrame) {
        let poses = poseTracker.poses(in: frame)

        let (compensates, needsReference) = tracking.withLock {
            defer { $0.needsCameraReference = false }
            return ($0.compensatesCameraMotion && $0.monitor.roster != nil, $0.needsCameraReference)
        }

        if needsReference || !compensates {
            cameraMotion.reset()
        }
        let cameraOffset = compensates ? cameraMotion.offset(in: frame) : .zero

        let (athletes, phases, events) = tracking.withLock {
            let athletes = $0.tracker.update(with: poses, at: frame.timestamp)
            $0.athletes = athletes
            let events = $0.monitor.process(athletes, cameraOffset: cameraOffset, at: frame.timestamp)
            return (athletes, $0.monitor.phases, events)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            onAthletes?(athletes, phases)

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
}
