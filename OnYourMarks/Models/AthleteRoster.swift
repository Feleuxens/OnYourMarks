//
//  AthleteRoster.swift
//  OnYourMarks
//

import Foundation

/// The athletes taking part in one start, fixed when monitoring begins.
///
/// Only they can be charged with a false start. Whoever enters the picture
/// later (a coach, a passer-by) is tracked but not judged.
nonisolated struct AthleteRoster: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: AthleteID
        /// Counted from the left of the picture when the roster was fixed,
        /// starting at 1. It is how a person can tell the athletes apart:
        /// with the camera beside the track and not square to the start
        /// line, the order in the picture is the order of the lanes.
        let position: Int
        /// How well the athlete was tracked when the roster was fixed.
        let quality: TrackingQuality
    }

    /// From left to right in the picture.
    let entries: [Entry]

    static let empty = AthleteRoster(entries: [])

    var isEmpty: Bool {
        entries.isEmpty
    }

    func contains(_ id: AthleteID) -> Bool {
        entries.contains { $0.id == id }
    }

    func position(of id: AthleteID) -> Int? {
        entries.first { $0.id == id }?.position
    }
}

/// A movement one detector saw.
nonisolated struct MovementObservation: Equatable, Sendable {
    /// Capture time of the frame that showed the movement, on the host clock.
    let time: MonotonicTimestamp

    /// Nil from a detector that doesn't tell athletes apart.
    let athleteID: AthleteID?

    /// How well the athlete was tracked in that frame, if the detector knows.
    let quality: TrackingQuality?

    init(time: MonotonicTimestamp, athleteID: AthleteID? = nil, quality: TrackingQuality? = nil) {
        self.time = time
        self.athleteID = athleteID
        self.quality = quality
    }
}

/// An athlete on the roster was hidden, lost or found again.
nonisolated struct AthleteTrackingChange: Equatable, Sendable {
    let athleteID: AthleteID
    let state: AthleteTrackState
    /// Capture time of the frame that showed the change.
    let time: MonotonicTimestamp
}

/// What one athlete did in a start.
nonisolated struct AthleteStartResult: Equatable, Sendable {
    /// Nil from a detector that doesn't tell athletes apart.
    let athleteID: AthleteID?
    /// The athlete's position on the roster.
    let position: Int?
    /// Nil for a movement before the gun.
    let reaction: DurationEstimate?
    let decision: StartDecision
}
