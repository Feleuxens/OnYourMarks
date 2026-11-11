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

    enum Phase: Equatable, Sendable {
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
            return .started
        }

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
