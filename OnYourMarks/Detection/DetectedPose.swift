//
//  DetectedPose.swift
//  OnYourMarks
//

import CoreGraphics
import Vision

/// One body found in one frame, in Vision's normalized image coordinates.
nonisolated struct DetectedPose: Equatable, Sendable {
    typealias Joints = [VNHumanBodyPoseObservation.JointName: CGPoint]

    /// Joints the torso centre is taken from. They stay nearly still while
    /// arms and legs move, and are the last to be hidden.
    static let torsoJoints: [VNHumanBodyPoseObservation.JointName] = [
        .neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip
    ]

    /// Smallest body size distances are normalized by. A pose of only one
    /// or two joints would otherwise have a size near zero.
    static let minimumExtent: CGFloat = 0.05

    /// The confidently detected joints.
    let joints: Joints

    /// Mean confidence of those joints.
    let confidence: Float

    /// Width of the picture divided by its height. The normalized
    /// coordinates stretch the shorter side, so lengths have to be
    /// corrected by this before they are compared across directions.
    let aspectRatio: CGFloat

    init(joints: Joints, confidence: Float, aspectRatio: CGFloat = 1) {
        self.joints = joints
        self.confidence = confidence
        self.aspectRatio = aspectRatio
    }

    /// The middle of the torso, or of all joints if no torso joint was found.
    var center: CGPoint {
        let torso = Self.torsoJoints.compactMap { joints[$0] }
        return Self.mean(of: torso.isEmpty ? Array(joints.values) : torso)
    }

    /// The diagonal of the box around the joints.
    var extent: CGFloat {
        guard let first = joints.values.first else { return Self.minimumExtent }

        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in joints.values {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return max(hypot(maxX - minX, maxY - minY), Self.minimumExtent)
    }

    /// Share of the joints of interest that were found.
    var jointCoverage: Double {
        Double(joints.count) / Double(PoseTracker.jointsOfInterest.count)
    }

    /// How far apart two poses are: the mean distance of the joints both
    /// have. With fewer than two shared joints, the distance of the centres.
    func distance(to other: DetectedPose) -> CGFloat {
        var sum: CGFloat = 0
        var shared = 0

        for (joint, position) in joints {
            if let otherPosition = other.joints[joint] {
                sum += hypot(position.x - otherPosition.x, position.y - otherPosition.y)
                shared += 1
            }
        }

        guard shared >= 2 else {
            let a = center, b = other.center
            return hypot(a.x - b.x, a.y - b.y)
        }
        return sum / CGFloat(shared)
    }

    private static func mean(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }

        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
