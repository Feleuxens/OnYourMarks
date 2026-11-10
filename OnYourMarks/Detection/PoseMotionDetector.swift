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
    typealias Joints = [VNHumanBodyPoseObservation.JointName: CGPoint]
    
    static let baselineFrameCount = 8
    
    /// How far a joint has to move from its resting place, in torso
    /// lengths. Measuring in the athlete's own size instead of in the
    /// picture makes the same real movement count the same for an athlete
    /// near the camera and one further away. About 15 cm for an adult;
    /// reasoned, not yet confirmed in the field.
    static let movementThreshold: CGFloat = 0.3
    
    /// Smallest body scale, as a share of the picture's height. Keeps a
    /// degenerate baseline from turning joint noise into movement.
    static let minimumBodyScale: CGFloat = 0.02
    
    private var isMonitoring = false
    private var hasTriggered = false
    private var baseline: Joints?
    private var baselineFrames = 0
    
    mutating func reset(monitoring: Bool) {
        isMonitoring = monitoring
        hasTriggered = false
        baseline = nil
        baselineFrames = 0
    }
    
    mutating func process(
        _ joints: Joints,
        aspectRatio: CGFloat = 1
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
        
        let scale = Self.bodyScale(of: baseline, aspectRatio: aspectRatio)
        
        var maxDisplacement: CGFloat = 0
        for (joint, position) in joints {
            if let base = baseline[joint] {
                maxDisplacement = max(maxDisplacement, Self.distance(position, base, aspectRatio: aspectRatio))
            }
        }
        
        guard maxDisplacement / scale > Self.movementThreshold else {
            return false
        }
        
        hasTriggered = true
        return true
    }
    
    /// The athlete's size in the picture: the length of the torso, the most
    /// rigid part of the body. Without neck and root, a shoulder to its hip;
    /// without those, the box around all joints.
    static func bodyScale(of joints: Joints, aspectRatio: CGFloat) -> CGFloat {
        let segments: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.neck, .root), (.leftShoulder, .leftHip), (.rightShoulder, .rightHip)
        ]
        
        for (upper, lower) in segments {
            if let a = joints[upper], let b = joints[lower] {
                return max(distance(a, b, aspectRatio: aspectRatio), minimumBodyScale)
            }
        }
        
        let xs = joints.values.map { $0.x * aspectRatio }
        let ys = joints.values.map { $0.y }
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        return max(hypot(width, height), minimumBodyScale)
    }
    
    /// In picture heights, so that a length counts the same in every direction.
    private static func distance(_ a: CGPoint, _ b: CGPoint, aspectRatio: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * aspectRatio, a.y - b.y)
    }
    
    private mutating func mergeBaseline(
        _ joints: Joints
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
