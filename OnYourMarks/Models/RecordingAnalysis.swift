//
//  RecordingAnalysis.swift
//  OnYourMarks
//

import CoreGraphics
import Foundation

/// The second pass over a recorded start: what the whole video says about
/// when each athlete's movement began, found after the start with a pose on
/// every frame and the rest learned from the entire hold.
///
/// Stored beside the start's record, never in it: the record says what was
/// decided live and stays as it was. Nothing here recalls a start or
/// changes a live result.
///
/// What its intervals claim: the movement began after the last frame that
/// still looked like rest and had begun by the first in which it was
/// certain, by the frames' capture times on the host clock. Two frames that
/// follow each other are 4.2 ms apart at 240 fps and 8.3 ms at 120 fps; a
/// reaction adds the gun's own interval. Not in them: where within its
/// exposure a frame's capture time lies, how long the exposure and the
/// sensor's readout take, and the compression of the video. Nothing has
/// been checked against a ground truth.
nonisolated struct RecordingAnalysis: Equatable, Codable, Sendable {
    /// Raised when what is stored here changes its meaning. An analysis of
    /// another version is not shown; the pass runs again.
    static let currentVersion = 1

    let version: Int
    let recordingID: UUID

    /// When the pass ran.
    let date: Date

    /// What it found, as events of its own (source `.recordedVideo`): a
    /// `movementAnalysed` and, after a gun, a `reactionAnalysed` for each
    /// athlete it found a movement for.
    let events: [StartEvent]

    /// One for each athlete on the roster, from the left.
    let athletes: [Athlete]

    let frames: FrameCounts

    /// How long the pass took, on the device it ran on.
    let duration: TimeInterval

    struct Athlete: Equatable, Codable, Sendable {
        let athleteID: AthleteID
        let position: Int

        /// From the poses of every frame: after the last frame at rest up to
        /// the one that crossed the movement threshold. Nil if the poses
        /// showed no start from a still position.
        let poseMovement: TimeEstimate?

        /// From the pictures of every frame, looked for back from the
        /// movement the poses confirmed (or, without one, the live
        /// confirmation). Nil if the pictures allowed no statement.
        let onset: OnsetRefinement?

        /// What the second pass says about the movement: the onset from the
        /// pictures, else the one from the poses.
        var movement: TimeEstimate? {
            onset?.onset ?? poseMovement
        }

        /// Against the gun that was heard; nil without a gun or a movement.
        let reaction: DurationEstimate?

        /// How the decision engine would judge that reaction. Shown, never
        /// acted on.
        let decision: StartDecision?

        /// The change the onset analysis thresholded, frame by frame, from
        /// the athlete's rest to the end of the frames at that rate. For a
        /// curve beside the video.
        let change: MotionOnsetAnalyzer.ChangeSeries?

        /// What the onset analysis ran with.
        let parameters: MotionOnsetAnalyzer.Parameters?

        /// Frames in which the athlete had a pose, from the beginning of
        /// their last rest to the end of the video.
        let posedFrames: Int
    }

    struct FrameCounts: Equatable, Codable, Sendable {
        /// Frames the video holds.
        let decoded: Int

        /// Decoded frames whose place in the video matches no stored
        /// capture time; they are left out.
        let unmatched: Int

        /// Frames in which pose detection found at least one body.
        let withPose: Int
    }
}

nonisolated extension RecordingAnalysis {
    /// The athlete's result, if the pass found one.
    func athlete(_ id: AthleteID?) -> Athlete? {
        athletes.first { $0.athleteID == id }
    }
}
