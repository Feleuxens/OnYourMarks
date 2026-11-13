//
//  TrackingFrame.swift
//  OnYourMarks
//

import CoreGraphics
import Foundation

/// What pose detection knew after one analysed frame: every athlete, where
/// their joints were and how still they held. Kept with a recording, so the
/// skeletons can be drawn over the video later and a start can be analysed again.
nonisolated struct TrackingFrame: Equatable, Codable, Sendable {
    /// Capture time of the analysed frame, on the host clock.
    let time: MonotonicTimestamp

    /// Every athlete the tracker knows, in Vision's normalized upright picture.
    let athletes: [TrackedAthlete]

    /// How still the roster athletes are; empty outside of monitoring.
    let phases: [AthleteID: AthleteStability.Phase]

    /// How far the picture had shifted because the camera moved, as it was
    /// taken out of the joints for the decision. Nil on a tripod, and in a
    /// handheld frame whose shift could not be measured. Stored to judge
    /// the handheld compensation against the video.
    let cameraOffset: CGPoint?

    init(
        time: MonotonicTimestamp,
        athletes: [TrackedAthlete],
        phases: [AthleteID: AthleteStability.Phase] = [:],
        cameraOffset: CGPoint? = nil
    ) {
        self.time = time
        self.athletes = athletes
        self.phases = phases
        self.cameraOffset = cameraOffset
    }
}
