//
//  TrackingQuality.swift
//  OnYourMarks
//

import Foundation

/// Where an athlete's track stands.
nonisolated enum AthleteTrackState: Equatable, Sendable {
    /// Seen, but not often enough yet to rule out a spurious detection.
    case tentative
    case tracked
    /// Not found in the recent frames; expected back at the same place.
    case occluded
    /// Gone for so long that a body appearing now may be someone else.
    case lost
}

/// How far an athlete's track can be trusted at one moment.
///
/// A movement is measured against the athlete's earlier pose, so it is only
/// as good as the certainty that both poses belong to the same, well-seen body.
nonisolated struct TrackingQuality: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case good
        case reduced
        /// Not enough to hold a movement against the athlete.
        case poor
    }

    // The thresholds are first values chosen by reasoning, not from
    // measurements; a field test with several athletes has to confirm them.

    /// Below this share of recent frames with the athlete in them, the track
    /// has just been picked up again and its identity is not settled.
    static let poorContinuity = 0.5
    /// A few missed frames are normal: pose detection skips some at 120 fps.
    static let goodContinuity = 0.9
    /// Four of the 14 joints: less than a torso, too little to tell a
    /// movement from a changing set of joints.
    static let poorJointCoverage = 4.0 / 14.0
    /// Half the body, e.g. everything the camera sees of a crouched athlete.
    static let goodJointCoverage = 0.5
    /// Clearly above the 0.3 a single joint needs to be used at all.
    static let goodConfidence = 0.5

    let state: AthleteTrackState

    /// Share of the joints of interest in the last pose.
    let jointCoverage: Double

    /// Mean joint confidence of the last pose.
    let confidence: Double

    /// Share of the recently analysed frames that showed the athlete.
    let continuity: Double

    var level: Level {
        guard state == .tracked,
              continuity >= Self.poorContinuity,
              jointCoverage >= Self.poorJointCoverage else {
            return .poor
        }

        guard continuity >= Self.goodContinuity,
              jointCoverage >= Self.goodJointCoverage,
              confidence >= Self.goodConfidence else {
            return .reduced
        }
        return .good
    }
}
