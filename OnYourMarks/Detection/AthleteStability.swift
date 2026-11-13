//
//  AthleteStability.swift
//  OnYourMarks
//

import CoreGraphics
import Foundation
import Vision

/// Follows one athlete from moving into position to holding still, and
/// from there tells a start from unsteadiness.
///
/// The resting pose every movement is measured against is the average of
/// the stretch in which the athlete was found still, however long they
/// took to get there.
nonisolated struct AthleteStability: Sendable {
    typealias Joints = [VNHumanBodyPoseObservation.JointName: CGPoint]

    enum Phase: Equatable, Codable, Sendable {
        case moving
        /// Still, but not for long enough yet.
        case settling
        case stable
    }

    enum Event: Equatable, Sendable {
        case becameStable
        /// Left the resting pose without starting.
        case unsteady
        /// Moved from the resting pose by the threshold. Reported once.
        case started
    }

    let profile: MotionProfile

    private(set) var phase: Phase = .moving

    /// The pose that began the current still stretch, and when.
    private var anchor: Joints?
    private var anchorTime: MonotonicTimestamp?
    /// Sum and count of each joint's positions in the still stretch.
    private var sums: [VNHumanBodyPoseObservation.JointName: (sum: CGPoint, count: Int)] = [:]

    /// The resting pose, once stable.
    private var reference: Joints?
    /// Since when the body has been outside the tolerance.
    private var departedAt: MonotonicTimestamp?
    private var unsteadyReported = false
    private var hasStarted = false

    /// How far the body was from the resting pose in the latest frames,
    /// back to `unsteadyDelay` before the last of them: a start takes no
    /// longer than that. An athlete who was hidden has only that last one.
    private var recent: [(time: MonotonicTimestamp, movement: CGFloat)] = []

    /// When the movement began, as far as poses can tell; set with `.started`.
    ///
    /// It began after the last frame that showed the athlete at rest and
    /// had certainly begun in the frame that crossed the threshold. The
    /// best guess is the first frame after rest. A movement still inside
    /// the tolerance can't be told from rest, so the true beginning may lie
    /// a little before the interval.
    ///
    /// Rest is where the athlete was just before, not only the resting
    /// pose: one who has swayed or leaned out of the tolerance and starts
    /// from there began to start there, not when they left the tolerance.
    private(set) var onset: TimeEstimate?

    /// The resting pose, once stable.
    var restingPose: Joints? {
        reference
    }

    init(profile: MotionProfile) {
        self.profile = profile
    }

    /// Forgets the resting pose; the athlete has to become still again.
    mutating func resettle() {
        self = AthleteStability(profile: profile)
    }

    mutating func process(
        _ joints: Joints,
        aspectRatio: CGFloat = 1,
        at time: MonotonicTimestamp
    ) -> Event? {
        guard !hasStarted, !joints.isEmpty else { return nil }

        if let reference {
            return watch(joints, against: reference, aspectRatio: aspectRatio, at: time)
        }
        return settle(joints, aspectRatio: aspectRatio, at: time)
    }

    private mutating func settle(_ joints: Joints, aspectRatio: CGFloat, at time: MonotonicTimestamp) -> Event? {
        guard let anchor, let anchorTime,
              Self.movement(of: joints, from: anchor, weights: profile.regionWeights, aspectRatio: aspectRatio)
                <= profile.stillTolerance else {
            // Moved: the still stretch begins again here.
            self.anchor = joints
            anchorTime = time
            sums = [:]
            accumulate(joints)
            phase = .moving
            return nil
        }

        accumulate(joints)
        phase = .settling

        guard time.seconds - anchorTime.seconds >= profile.settleDuration else { return nil }

        reference = sums.mapValues {
            CGPoint(x: $0.sum.x / CGFloat($0.count), y: $0.sum.y / CGFloat($0.count))
        }
        phase = .stable
        recent = [(time, 0)]
        return .becameStable
    }

    private mutating func watch(
        _ joints: Joints,
        against reference: Joints,
        aspectRatio: CGFloat,
        at time: MonotonicTimestamp
    ) -> Event? {
        let movement = Self.movement(of: joints, from: reference, weights: profile.regionWeights, aspectRatio: aspectRatio)

        if movement > profile.movementThreshold {
            hasStarted = true
            onset = beginning(ofCrossingAt: time)
            return .started
        }

        recent.removeAll { time.seconds - $0.time.seconds > profile.unsteadyDelay }
        recent.append((time, movement))

        guard movement > profile.stillTolerance else {
            departedAt = nil
            return nil
        }

        guard let departedAt else {
            self.departedAt = time
            return nil
        }

        if !unsteadyReported, time.seconds - departedAt.seconds > profile.unsteadyDelay {
            unsteadyReported = true
            return .unsteady
        }
        return nil
    }

    /// Where the rise that crossed the threshold began: after the last of
    /// the recent frames that was no further out than the athlete had been
    /// at rest in them.
    private func beginning(ofCrossingAt time: MonotonicTimestamp) -> TimeEstimate {
        guard let lowest = recent.map({ $0.movement }).min() else { return .exact(time) }

        // Half the tolerance above the lowest: the jitter of the pose
        // detection, which the tolerance has to stay above.
        let rest = max(profile.stillTolerance, lowest + profile.stillTolerance / 2)

        guard let still = recent.lastIndex(where: { $0.movement <= rest }) else { return .exact(time) }

        return TimeEstimate(
            best: still + 1 < recent.count ? recent[still + 1].time : time,
            earliest: recent[still].time,
            latest: time
        )
    }

    private mutating func accumulate(_ joints: Joints) {
        for (joint, position) in joints {
            let existing = sums[joint] ?? (.zero, 0)
            sums[joint] = (CGPoint(x: existing.sum.x + position.x, y: existing.sum.y + position.y), existing.count + 1)
        }
    }

    // MARK: - Measures

    /// How far the body has moved from a pose, in torso lengths: the mean
    /// displacement of each region's joints, weighted, and of those the largest.
    ///
    /// Measuring in the athlete's own size makes the same real movement
    /// count the same near the camera and further away.
    static func movement(
        of joints: Joints,
        from reference: Joints,
        weights: [BodyRegion: CGFloat],
        aspectRatio: CGFloat
    ) -> CGFloat {
        let scale = DetectedPose.bodyScale(of: reference, aspectRatio: aspectRatio)
        var largest: CGFloat = 0

        for (region, weight) in weights where weight > 0 {
            var sum: CGFloat = 0
            var count = 0

            for joint in region.joints {
                if let position = joints[joint], let base = reference[joint] {
                    sum += DetectedPose.distance(position, base, aspectRatio: aspectRatio)
                    count += 1
                }
            }

            if count > 0 {
                largest = max(largest, weight * sum / CGFloat(count) / scale)
            }
        }
        return largest
    }
}
