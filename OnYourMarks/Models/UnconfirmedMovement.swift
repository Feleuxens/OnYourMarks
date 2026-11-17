//
//  UnconfirmedMovement.swift
//  OnYourMarks
//

import Foundation

/// A movement that one pose showed and nothing else backed. It was never
/// reported as a start; it is kept so the review can show what was passed over.
nonisolated struct UnconfirmedMovement: Equatable, Codable, Sendable {
    enum Reason: Equatable, Codable, Sendable {
        /// The athlete's next pose was back below the threshold.
        case contradicted
        /// No pose of the athlete could be judged in time: hidden, the
        /// camera's shift not measured, or the camera lost.
        case notSeenAgain
        /// The athlete was made to settle again before a second pose came.
        case resettled
        /// Monitoring ended before a second pose came.
        case monitoringEnded
    }

    let athleteID: AthleteID

    /// Capture time of the frame that crossed the threshold.
    let time: MonotonicTimestamp

    /// When the movement would have begun.
    let onset: TimeEstimate

    let reason: Reason

    /// How well the athlete was tracked in that frame.
    let quality: TrackingQuality?

    init(_ observation: MovementObservation, athleteID: AthleteID, reason: Reason) {
        self.athleteID = athleteID
        time = observation.time
        onset = observation.onset
        self.reason = reason
        quality = observation.quality
    }
}
