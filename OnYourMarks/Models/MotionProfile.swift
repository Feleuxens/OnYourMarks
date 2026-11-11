//
//  MotionProfile.swift
//  OnYourMarks
//

import CoreGraphics
import Foundation
import Vision

/// Parts of the body that move together and matter differently for a start.
nonisolated enum BodyRegion: CaseIterable, Hashable, Sendable {
    case torso
    case arms
    case hands
    case legs

    var joints: [VNHumanBodyPoseObservation.JointName] {
        switch self {
        case .torso: [.neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip]
        case .arms: [.leftElbow, .rightElbow]
        case .hands: [.leftWrist, .rightWrist]
        case .legs: [.leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        }
    }
}

/// How an athlete's stillness and first movement are judged for one kind of
/// start. Lengths are in torso lengths of the athlete.
///
/// All values are reasoned first choices, not measurements; a field test
/// has to confirm them.
nonisolated struct MotionProfile: Equatable, Sendable {
    /// How much a region's movement counts. A region at 1 triggers when it
    /// moves by the threshold, one at 0.5 has to move twice as far.
    let regionWeights: [BodyRegion: CGFloat]

    /// How far the body may wander and still count as still. Has to stay
    /// above the jitter of the pose detection.
    let stillTolerance: CGFloat

    /// How far the body has to move from its resting pose to have started.
    let movementThreshold: CGFloat

    /// How long the athlete has to be still to count as stable.
    let settleDuration: TimeInterval

    /// How long a body may be outside the tolerance without having started
    /// before it is called unsteady. A start reaches the threshold within
    /// this time; swaying or shifting doesn't.
    let unsteadyDelay: TimeInterval

    /// In the blocks the hands leave the ground first and the hips rise;
    /// the legs are often hidden from a camera beside the track.
    static let block = MotionProfile(
        regionWeights: [.torso: 1, .hands: 1, .arms: 0.7, .legs: 0.5],
        stillTolerance: 0.1,
        movementThreshold: 0.3,
        settleDuration: 0.4,
        unsteadyDelay: 0.3
    )

    /// Standing athletes sway and move their arms without starting; the
    /// start shows in the torso and the first step.
    static let standing = MotionProfile(
        regionWeights: [.torso: 1, .legs: 0.8, .arms: 0.4, .hands: 0.3],
        stillTolerance: 0.15,
        movementThreshold: 0.3,
        settleDuration: 0.4,
        unsteadyDelay: 0.3
    )
}
