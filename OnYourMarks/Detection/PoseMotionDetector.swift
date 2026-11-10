//
//  PoseMotionDetector.swift
//  OnYourMarks
//

import Foundation
import Synchronization
import Vision

/// Detects the athlete's first movement from the poses in the camera's frames.
final class PoseMotionDetector: MovementDetector {
    /// Every detected pose, for the preview overlay.
    var onJoints: ((PoseTracker.Joints) -> Void)?

    /// Called once per monitoring with the capture time of the frame that
    /// showed the movement, on the host clock.
    var onMovement: ((TimeInterval) -> Void)?

    private(set) var isMonitoring = false

    private let camera: CameraController
    private nonisolated let tracker = PoseTracker()
    private nonisolated let motionState = Mutex(MotionState())

    init(camera: CameraController) {
        self.camera = camera

        camera.setFrameHandler { [weak self] frame in
            self?.process(frame)
        }
    }

    func startMonitoring() {
        motionState.withLock { $0.reset(monitoring: true) }
        isMonitoring = true
    }

    func stopMonitoring() {
        motionState.withLock { $0.reset(monitoring: false) }
        isMonitoring = false
    }

    func beginPrecisionWindow() {
        camera.setMode(.precision)
    }

    func endPrecisionWindow() {
        camera.setMode(.idle)
    }

    /// Runs on the capture queue.
    private nonisolated func process(_ frame: CameraFrame) {
        guard let joints = tracker.joints(in: frame) else { return }

        Task { @MainActor [weak self] in
            self?.onJoints?(joints)
        }

        let movementDetected = motionState.withLock { $0.process(joints) }

        guard movementDetected else { return }

        let frameTime = frame.timestamp.seconds

        Task { @MainActor [weak self] in
            self?.onMovement?(frameTime)
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
