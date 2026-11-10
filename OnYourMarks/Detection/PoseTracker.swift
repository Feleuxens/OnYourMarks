//
//  PoseTracker.swift
//  OnYourMarks
//

import Vision

/// Finds the bodies in a frame and their joints.
///
/// Not thread-safe: use it from one queue only, here the capture queue.
nonisolated final class PoseTracker: @unchecked Sendable {
    static let jointsOfInterest: [VNHumanBodyPoseObservation.JointName] = [
        .root, .neck,
        .leftHip, .rightHip,
        .leftWrist, .rightWrist,
        .leftElbow, .rightElbow,
        .leftShoulder, .rightShoulder,
        .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle
    ]

    static let minimumConfidence: Float = 0.3

    private let request = VNDetectHumanBodyPoseRequest()

    /// Every body with at least one confidently detected joint.
    /// Empty if none was found.
    func poses(in frame: CameraFrame) -> [DetectedPose] {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .right)

        guard (try? handler.perform([request])) != nil, let observations = request.results else {
            return []
        }

        return observations.compactMap { observation in
            guard let points = try? observation.recognizedPoints(.all) else { return nil }
            return Self.pose(from: points.mapValues { (location: $0.location, confidence: $0.confidence) })
        }
    }

    /// Keeps the joints of interest that are confident enough.
    /// Nil if none is left.
    static func pose(
        from points: [VNHumanBodyPoseObservation.JointName: (location: CGPoint, confidence: Float)]
    ) -> DetectedPose? {
        var joints: DetectedPose.Joints = [:]
        var confidenceSum: Float = 0

        for joint in jointsOfInterest {
            if let point = points[joint], point.confidence >= minimumConfidence {
                joints[joint] = point.location
                confidenceSum += point.confidence
            }
        }

        guard !joints.isEmpty else { return nil }

        return DetectedPose(joints: joints, confidence: confidenceSum / Float(joints.count))
    }
}
