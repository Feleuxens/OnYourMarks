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

    /// Smallest body scale, as a share of the picture's height. Keeps a
    /// pose of one or two joints from turning joint noise into movement.
    static let minimumBodyScale: CGFloat = 0.02

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

    /// The body's size in the picture; see `bodyScale(of:aspectRatio:)`.
    var bodyScale: CGFloat {
        Self.bodyScale(of: joints, aspectRatio: aspectRatio)
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
                sum += Self.distance(position, otherPosition, aspectRatio: aspectRatio)
                shared += 1
            }
        }

        guard shared >= 2 else {
            return Self.distance(center, other.center, aspectRatio: aspectRatio)
        }
        return sum / CGFloat(shared)
    }

    // MARK: - Measures

    /// A body's size in the picture: the length of the torso, the most
    /// rigid part of the body. Without neck and root, a shoulder to its hip;
    /// without those, the box around all joints.
    ///
    /// Lengths measured in it count the same for an athlete near the
    /// camera and one further away.
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
    static func distance(_ a: CGPoint, _ b: CGPoint, aspectRatio: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * aspectRatio, a.y - b.y)
    }

    private static func mean(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }

        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}

/// Stored with a recording. Vision's joint names aren't codable, so the
/// joints are keyed by the names' raw strings.
nonisolated extension DetectedPose: Codable {
    private enum CodingKeys: String, CodingKey {
        case joints, confidence, aspectRatio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let named = try container.decode([String: CGPoint].self, forKey: .joints)

        self.init(
            joints: Dictionary(
                uniqueKeysWithValues: named.map {
                    (VNHumanBodyPoseObservation.JointName(rawValue: VNRecognizedPointKey(rawValue: $0.key)), $0.value)
                }
            ),
            confidence: try container.decode(Float.self, forKey: .confidence),
            aspectRatio: try container.decode(CGFloat.self, forKey: .aspectRatio)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let named = Dictionary(uniqueKeysWithValues: joints.map { ($0.key.rawValue.rawValue, $0.value) })

        try container.encode(named, forKey: .joints)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(aspectRatio, forKey: .aspectRatio)
    }
}
