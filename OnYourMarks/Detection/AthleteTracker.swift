//
//  AthleteTracker.swift
//  OnYourMarks
//

import CoreGraphics
import Foundation

/// An athlete as known after one frame.
nonisolated struct TrackedAthlete: Identifiable, Equatable, Sendable {
    let id: AthleteID
    let state: AthleteTrackState

    /// The pose when the athlete was last seen.
    let pose: DetectedPose
    let lastSeen: MonotonicTimestamp

    /// Whether `pose` comes from the latest frame.
    let isVisible: Bool

    let quality: TrackingQuality
}

/// Pairs the bodies of a new frame with the known tracks.
nonisolated enum AthleteAssociation {
    /// How far a body may have moved between two analysed frames, in torso
    /// lengths. At the idle rate of 15 fps a walking person covers about a
    /// fifth of one per frame; a whole one leaves room for missed frames.
    /// Seen from beside the track, neighbours can stand closer than that in
    /// the picture; then the nearest pose decides.
    static let maximumDistance: CGFloat = 1

    struct Pairing: Equatable {
        let track: Int
        let pose: Int
    }

    /// Closest pairs first, each track and each pose used once.
    ///
    /// Not the optimal assignment in every case, but the same for athletes
    /// that are further apart than they move per frame, which the gate ensures.
    static func pair(tracks: [DetectedPose], with poses: [DetectedPose]) -> [Pairing] {
        var candidates: [(distance: CGFloat, pairing: Pairing)] = []

        for (trackIndex, track) in tracks.enumerated() {
            for (poseIndex, pose) in poses.enumerated() {
                let distance = track.distance(to: pose) / track.bodyScale

                if distance <= maximumDistance {
                    candidates.append((distance, Pairing(track: trackIndex, pose: poseIndex)))
                }
            }
        }

        candidates.sort { $0.distance < $1.distance }

        var usedTracks: Set<Int> = []
        var usedPoses: Set<Int> = []
        var pairings: [Pairing] = []

        for candidate in candidates {
            let pairing = candidate.pairing
            guard !usedTracks.contains(pairing.track), !usedPoses.contains(pairing.pose) else { continue }

            usedTracks.insert(pairing.track)
            usedPoses.insert(pairing.pose)
            pairings.append(pairing)
        }
        return pairings
    }
}

/// Follows the bodies in the picture from frame to frame, so each athlete
/// keeps one `AthleteID` for as long as they stay in view.
nonisolated struct AthleteTracker: Sendable {
    /// Frames a new body has to be found in before it counts as an athlete.
    /// Spurious detections rarely last that long.
    static let confirmationFrames = 3

    /// Unseen for longer than this, an athlete is occluded. Longer than two
    /// frame intervals at 15 fps would hide real occlusions; shorter would
    /// report every frame the pose detection misses at 120 fps.
    static let occlusionDelay: TimeInterval = 0.1

    /// Unseen for longer than this, an athlete is lost: by then a person can
    /// have left and another one taken the place.
    static let lostDelay: TimeInterval = 1

    /// The stretch the continuity of a track is judged over.
    static let continuityWindow: TimeInterval = 0.5

    private struct Track {
        let id: AthleteID
        var state: AthleteTrackState
        var pose: DetectedPose
        var lastSeen: MonotonicTimestamp
        var seenFrames: Int
        /// Whether each recent frame showed the athlete, oldest first.
        var recentFrames: [(time: MonotonicTimestamp, seen: Bool)]
    }

    private var tracks: [Track] = []

    /// Athletes that are kept when lost, so they can return under their ID.
    /// During a start these are the athletes on the roster.
    var retained: Set<AthleteID> = []

    /// The athletes after this frame, ordered from left to right. An athlete
    /// that isn't retained is reported as lost once and then forgotten.
    mutating func update(with poses: [DetectedPose], at time: MonotonicTimestamp) -> [TrackedAthlete] {
        let pairings = AthleteAssociation.pair(tracks: tracks.map { $0.pose }, with: poses)

        var matchedTracks: Set<Int> = []
        var matchedPoses: Set<Int> = []

        for pairing in pairings {
            matchedTracks.insert(pairing.track)
            matchedPoses.insert(pairing.pose)

            tracks[pairing.track].pose = poses[pairing.pose]
            tracks[pairing.track].lastSeen = time
            tracks[pairing.track].seenFrames += 1

            if tracks[pairing.track].state != .tentative
                || tracks[pairing.track].seenFrames >= Self.confirmationFrames {
                tracks[pairing.track].state = .tracked
            }
        }

        var abandoned: Set<Int> = []

        for index in tracks.indices where !matchedTracks.contains(index) {
            let unseen = time.seconds - tracks[index].lastSeen.seconds

            switch tracks[index].state {
            case .tentative:
                if unseen > Self.occlusionDelay {
                    abandoned.insert(index)
                }
            case .tracked, .occluded:
                if unseen > Self.lostDelay {
                    tracks[index].state = .lost
                } else if unseen > Self.occlusionDelay {
                    tracks[index].state = .occluded
                }
            case .lost:
                break
            }
        }

        for index in tracks.indices {
            tracks[index].recentFrames.append((time, matchedTracks.contains(index)))
            tracks[index].recentFrames.removeAll { time.seconds - $0.time.seconds > Self.continuityWindow }
        }

        for (index, pose) in poses.enumerated() where !matchedPoses.contains(index) {
            tracks.append(
                Track(
                    id: AthleteID(),
                    state: Self.confirmationFrames <= 1 ? .tracked : .tentative,
                    pose: pose,
                    lastSeen: time,
                    seenFrames: 1,
                    recentFrames: [(time, true)]
                )
            )
        }

        let athletes = tracks.enumerated()
            .filter { !abandoned.contains($0.offset) }
            .map { Self.athlete(from: $0.element, at: time) }
            .sorted { $0.pose.center.x < $1.pose.center.x }

        let retained = retained
        tracks = tracks.enumerated()
            .filter { !abandoned.contains($0.offset) && ($0.element.state != .lost || retained.contains($0.element.id)) }
            .map { $0.element }

        return athletes
    }

    /// Forgets everyone, e.g. when the camera stops.
    mutating func reset() {
        tracks.removeAll()
        retained.removeAll()
    }

    private static func athlete(from track: Track, at time: MonotonicTimestamp) -> TrackedAthlete {
        let seen = track.recentFrames.count { $0.seen }

        return TrackedAthlete(
            id: track.id,
            state: track.state,
            pose: track.pose,
            lastSeen: track.lastSeen,
            isVisible: track.lastSeen == time,
            quality: TrackingQuality(
                state: track.state,
                jointCoverage: track.pose.jointCoverage,
                confidence: Double(track.pose.confidence),
                continuity: Double(seen) / Double(max(track.recentFrames.count, 1))
            )
        )
    }
}
