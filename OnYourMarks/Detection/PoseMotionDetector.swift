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
    /// Every athlete after each analysed frame, for the preview overlay.
    var onAthletes: (([TrackedAthlete]) -> Void)?

    var onMovement: ((MovementObservation) -> Void)?
    var onTrackingChange: ((AthleteTrackingChange) -> Void)?

    private(set) var isMonitoring = false

    private let camera: CameraController
    private nonisolated let poseTracker = PoseTracker()
    private nonisolated let tracking = Mutex(Tracking())

    /// Shared between the capture queue and the main actor.
    private nonisolated struct Tracking {
        var tracker = AthleteTracker()
        var monitor = AthleteMotionMonitor()
        var athletes: [TrackedAthlete] = []
    }

    init(camera: CameraController) {
        self.camera = camera

        camera.setFrameHandler { [weak self] frame in
            self?.process(frame)
        }
    }

    @discardableResult
    func startMonitoring() -> AthleteRoster {
        isMonitoring = true

        return tracking.withLock {
            let roster = $0.monitor.begin(with: $0.athletes)
            $0.tracker.retained = Set(roster.entries.map { $0.id })
            return roster
        }
    }

    func stopMonitoring() {
        tracking.withLock {
            $0.monitor.end()
            $0.tracker.retained = []
        }
        isMonitoring = false
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

        let (athletes, update) = tracking.withLock {
            let athletes = $0.tracker.update(with: poses, at: frame.timestamp)
            $0.athletes = athletes
            return (athletes, $0.monitor.process(athletes, at: frame.timestamp))
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            onAthletes?(athletes)
            update.trackingChanges.forEach { onTrackingChange?($0) }
            update.movements.forEach { onMovement?($0) }
        }
    }
}

nonisolated struct MotionState {
    static let baselineFrameCount = 8
    static let movementThreshold: CGFloat = 0.05
    
    private var isMonitoring = false
    private var hasTriggered = false
    private var baseline: [VNHumanBodyPoseObservation.JointName: CGPoint]?
    private var baselineFrames = 0
    
    mutating func reset(monitoring: Bool) {
        isMonitoring = monitoring
        hasTriggered = false
        baseline = nil
        baselineFrames = 0
    }
    
    mutating func process(
        _ joints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    ) -> Bool {
        guard isMonitoring, !hasTriggered, !joints.isEmpty else {
            return false
        }
        
        if baselineFrames < Self.baselineFrameCount {
            mergeBaseline(joints)
            baselineFrames += 1
            return false
        }
        
        guard let baseline else { return false }
        
        var maxDisplacement: CGFloat = 0
        for (joint, position) in joints {
            if let base = baseline[joint] {
                maxDisplacement = max(maxDisplacement, hypot(position.x - base.x, position.y - base.y))
            }
        }
        
        guard maxDisplacement > Self.movementThreshold else {
            return false
        }
        
        hasTriggered = true
        return true
    }
    
    private mutating func mergeBaseline(
        _ joints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    ) {
        guard baseline != nil else {
            baseline = joints
            return
        }
        
        for (joint, position) in joints {
            if let existing = baseline?[joint] {
                baseline?[joint] = CGPoint(x: (existing.x + position.x) / 2, y: (existing.y + position.y) / 2)
            } else {
                baseline?[joint] = position
            }
        }
    }
}
