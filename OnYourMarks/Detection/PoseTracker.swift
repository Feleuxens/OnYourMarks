//
//  PoseTracker.swift
//  OnYourMarks
//

import Vision

/// Finds the athlete's joints in a frame.
///
/// Not thread-safe: use it from one queue only, here the capture queue.
nonisolated final class PoseTracker: @unchecked Sendable {
    typealias Joints = [VNHumanBodyPoseObservation.JointName: CGPoint]

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

    /// The confidently detected joints, or nil if no body was found.
    func joints(in frame: CameraFrame) -> Joints? {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .right)

        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else {
            return nil
        }

        var joints: Joints = [:]

        for joint in Self.jointsOfInterest {
            if let point = points[joint], point.confidence >= Self.minimumConfidence {
                joints[joint] = point.location
            }
        }
        return joints
    }
}
