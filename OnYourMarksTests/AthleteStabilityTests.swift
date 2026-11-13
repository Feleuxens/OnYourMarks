//
//  AthleteStabilityTests.swift
//  OnYourMarksTests
//

import Foundation
import Testing
import Vision
@testable import OnYourMarks

struct AthleteStabilityTests {
    private typealias Joints = AthleteStability.Joints

    /// Frame interval of the precision rate.
    private let frame: TimeInterval = 1.0 / 120

    /// Where each joint sits, in torso lengths from the root.
    private let layout: [VNHumanBodyPoseObservation.JointName: CGPoint] = [
        .root: CGPoint(x: 0, y: 0), .neck: CGPoint(x: 0, y: 1),
        .leftShoulder: CGPoint(x: -0.2, y: 0.9), .rightShoulder: CGPoint(x: 0.2, y: 0.9),
        .leftHip: CGPoint(x: -0.1, y: 0), .rightHip: CGPoint(x: 0.1, y: 0),
        .leftElbow: CGPoint(x: -0.3, y: 0.3), .rightElbow: CGPoint(x: 0.3, y: 0.3),
        .leftWrist: CGPoint(x: -0.3, y: -0.3), .rightWrist: CGPoint(x: 0.3, y: -0.3),
        .leftKnee: CGPoint(x: -0.15, y: -0.6), .rightKnee: CGPoint(x: 0.15, y: -0.6),
        .leftAnkle: CGPoint(x: -0.15, y: -1.2), .rightAnkle: CGPoint(x: 0.15, y: -1.2)
    ]

    /// A body with the given torso length in the picture. Regions can be
    /// moved, in torso lengths: sideways with `dx`, upwards with `dy`.
    private func body(
        torso: CGFloat = 0.2,
        moving regions: Set<BodyRegion> = [],
        dx: CGFloat = 0,
        dy: CGFloat = 0,
        aspectRatio: CGFloat = 1
    ) -> Joints {
        var joints: Joints = [:]

        for region in BodyRegion.allCases {
            let moved = regions.contains(region)

            for joint in region.joints {
                guard let place = layout[joint] else { continue }
                joints[joint] = CGPoint(
                    x: 0.5 + (place.x + (moved ? dx : 0)) * torso / aspectRatio,
                    y: 0.5 + (place.y + (moved ? dy : 0)) * torso
                )
            }
        }
        return joints
    }

    /// Feeds one pose for a duration and returns the events it caused.
    private func feed(
        _ stability: inout AthleteStability,
        _ joints: Joints,
        for duration: TimeInterval,
        from start: inout TimeInterval,
        aspectRatio: CGFloat = 1
    ) -> [AthleteStability.Event] {
        var events: [AthleteStability.Event] = []

        for _ in 0..<Int((duration / frame).rounded(.up)) {
            start += frame
            if let event = stability.process(joints, aspectRatio: aspectRatio, at: MonotonicTimestamp(seconds: start)) {
                events.append(event)
            }
        }
        return events
    }

    /// An athlete who has become stable in the given pose, and the time after.
    private func stable(
        _ profile: MotionProfile = .block,
        in pose: Joints? = nil,
        aspectRatio: CGFloat = 1
    ) -> (AthleteStability, TimeInterval) {
        var stability = AthleteStability(profile: profile)
        var now: TimeInterval = 0

        let events = feed(
            &stability, pose ?? body(), for: profile.settleDuration + 3 * frame, from: &now, aspectRatio: aspectRatio
        )
        #expect(events == [.becameStable])
        return (stability, now)
    }

    @Test
    func goesFromMovingThroughSettlingToStable() {
        var stability = AthleteStability(profile: .block)
        var now: TimeInterval = 0
        #expect(stability.phase == .moving)

        var events = feed(&stability, body(), for: MotionProfile.block.settleDuration / 2, from: &now)
        #expect(stability.phase == .settling)
        #expect(events.isEmpty)

        events = feed(&stability, body(), for: MotionProfile.block.settleDuration, from: &now)
        #expect(stability.phase == .stable)
        #expect(events == [.becameStable])
    }

    @Test
    func movingWhileSettlingStartsTheWaitAgain() {
        var stability = AthleteStability(profile: .block)
        var now: TimeInterval = 0

        _ = feed(&stability, body(), for: MotionProfile.block.settleDuration * 0.8, from: &now)
        _ = feed(&stability, body(moving: [.torso], dy: 0.5), for: frame, from: &now)
        #expect(stability.phase == .moving)

        var events = feed(&stability, body(moving: [.torso], dy: 0.5), for: MotionProfile.block.settleDuration * 0.8, from: &now)
        #expect(stability.phase == .settling)
        #expect(events.isEmpty)

        events = feed(&stability, body(moving: [.torso], dy: 0.5), for: MotionProfile.block.settleDuration * 0.4, from: &now)
        #expect(events == [.becameStable])
    }

    @Test
    func gettingIntoPositionIsNeitherAStartNorUnsteady() {
        var stability = AthleteStability(profile: .block)
        var now: TimeInterval = 0
        var events: [AthleteStability.Event] = []

        for step in 0..<60 {
            events += feed(&stability, body(moving: Set(BodyRegion.allCases), dy: CGFloat(step) * 0.05), for: frame, from: &now)
        }

        #expect(events.isEmpty)
        #expect(stability.phase == .moving)
    }

    @Test
    func aStartIsReportedOnce() {
        var (stability, now) = stable()

        var events = feed(&stability, body(moving: [.hands], dy: 0.4), for: frame, from: &now)
        #expect(events == [.started])

        events = feed(&stability, body(moving: Set(BodyRegion.allCases), dx: 2), for: 0.5, from: &now)
        #expect(events.isEmpty)
    }

    @Test
    func leavingTheRestingPoseWithoutStartingIsUnsteady() {
        var (stability, now) = stable()
        let sagging = body(moving: [.torso], dy: -0.2)

        var events = feed(&stability, sagging, for: MotionProfile.block.unsteadyDelay - 2 * frame, from: &now)
        #expect(events.isEmpty)

        events = feed(&stability, sagging, for: 0.5, from: &now)
        #expect(events == [.unsteady])
        #expect(stability.phase == .stable)
    }

    @Test
    func aTwitchThatReturnsIsNothing() {
        var (stability, now) = stable()

        var events = feed(&stability, body(moving: [.hands], dy: 0.2), for: MotionProfile.block.unsteadyDelay / 2, from: &now)
        events += feed(&stability, body(), for: 0.1, from: &now)
        events += feed(&stability, body(moving: [.hands], dy: 0.2), for: MotionProfile.block.unsteadyDelay / 2, from: &now)
        events += feed(&stability, body(), for: 0.1, from: &now)

        #expect(events.isEmpty)
    }

    /// After the gun nobody resettles an unsteady athlete; their start still has to be seen.
    @Test
    func aStartIsStillReportedAfterUnsteadiness() {
        var (stability, now) = stable()

        var events = feed(&stability, body(moving: [.torso], dy: 0.2), for: 0.5, from: &now)
        #expect(events == [.unsteady])

        events = feed(&stability, body(moving: [.torso], dy: 0.5), for: frame, from: &now)
        #expect(events == [.started])
    }

    @Test
    func resettlingForgetsTheRestingPose() {
        var (stability, now) = stable()

        stability.resettle()
        #expect(stability.phase == .moving)

        // What would have been a start is now just the new place to settle in.
        let events = feed(&stability, body(moving: [.hands], dy: 0.5), for: MotionProfile.block.settleDuration + 3 * frame, from: &now)
        #expect(events == [.becameStable])
    }

    @Test
    func theRestingPoseIsTheAverageOfTheStillStretch() {
        var stability = AthleteStability(profile: .block)
        var now: TimeInterval = 0

        // The hands jitter by ±0.04 torso lengths around their place.
        for step in 0..<60 {
            _ = feed(&stability, body(moving: [.hands], dy: step.isMultiple(of: 2) ? 0.04 : -0.04), for: frame, from: &now)
        }
        #expect(stability.phase == .stable)

        // Measured from the average, 0.28 is under the threshold and 0.32
        // over it; from either extreme one of the two would be judged wrongly.
        var events = feed(&stability, body(moving: [.hands], dy: 0.28), for: frame, from: &now)
        #expect(events.isEmpty)
        events = feed(&stability, body(moving: [.hands], dy: 0.32), for: frame, from: &now)
        #expect(events == [.started])
    }

    /// The camera stands diagonally, so athletes differ in size in the picture.
    @Test(arguments: [0.05, 0.15, 0.35])
    func theSameMovementCountsTheSameNearAndFar(torso: Double) {
        let torso = CGFloat(torso)
        let threshold = MotionProfile.block.movementThreshold

        var (near, now) = stable(in: body(torso: torso))
        #expect(feed(&near, body(torso: torso, moving: [.hands], dy: threshold * 0.8), for: frame, from: &now).isEmpty)
        #expect(feed(&near, body(torso: torso, moving: [.hands], dy: threshold * 1.2), for: frame, from: &now) == [.started])
    }

    @Test
    func sidewaysAndUpwardMovementsCountTheSameInAPortraitPicture() {
        let aspectRatio: CGFloat = 9.0 / 16.0
        let threshold = MotionProfile.block.movementThreshold
        let still = body(aspectRatio: aspectRatio)

        var (sideways, now) = stable(in: still, aspectRatio: aspectRatio)
        #expect(
            feed(&sideways, body(moving: [.hands], dx: threshold * 0.8, aspectRatio: aspectRatio), for: frame, from: &now, aspectRatio: aspectRatio).isEmpty
        )
        #expect(
            feed(&sideways, body(moving: [.hands], dx: threshold * 1.2, aspectRatio: aspectRatio), for: frame, from: &now, aspectRatio: aspectRatio) == [.started]
        )

        var (upwards, later) = stable(in: still, aspectRatio: aspectRatio)
        #expect(
            feed(&upwards, body(moving: [.hands], dy: threshold * 1.2, aspectRatio: aspectRatio), for: frame, from: &later, aspectRatio: aspectRatio) == [.started]
        )
    }

    @Test
    func aRegionWithLessWeightHasToMoveFurther() {
        // Legs count half in the blocks.
        var (stability, now) = stable()
        #expect(feed(&stability, body(moving: [.legs], dy: 0.5), for: frame, from: &now).isEmpty)
        #expect(feed(&stability, body(moving: [.legs], dy: 0.7), for: frame, from: &now) == [.started])
    }

    @Test
    func oneHandAloneCountsHalf() {
        var (stability, now) = stable()
        var oneHand = body()
        oneHand[.leftWrist]?.y += 0.5 * 0.2

        #expect(feed(&stability, oneHand, for: frame, from: &now).isEmpty)

        oneHand[.leftWrist]?.y += 0.2 * 0.2
        #expect(feed(&stability, oneHand, for: frame, from: &now) == [.started])
    }

    @Test
    func theProfilesJudgeTheSameMovementDifferently() {
        // Swinging the hands starts a block start but not a standing one.
        let hands = body(moving: [.hands], dy: 0.4)

        var (block, now) = stable(.block)
        #expect(feed(&block, hands, for: 0.5, from: &now) == [.started])

        var (standing, later) = stable(.standing)
        #expect(feed(&standing, hands, for: 0.5, from: &later).isEmpty)

        // A step does start a standing start.
        #expect(feed(&standing, body(moving: [.legs], dy: 0.5), for: frame, from: &later) == [.started])
    }

    @Test
    func emptyFramesAreIgnored() {
        var (stability, now) = stable()

        #expect(feed(&stability, [:], for: 0.5, from: &now).isEmpty)
        #expect(stability.phase == .stable)
    }

    @Test
    func theBeginningReachesFromTheLastRestingFrameToTheCrossing() throws {
        var (stability, now) = stable()

        _ = feed(&stability, body(), for: 5 * frame, from: &now)
        let lastStill = now

        // Out of the tolerance for a few frames, then over the threshold.
        _ = feed(&stability, body(moving: [.hands], dy: 0.2), for: 3 * frame, from: &now)
        let departed = lastStill + frame
        #expect(stability.onset == nil)

        #expect(feed(&stability, body(moving: [.hands], dy: 0.4), for: frame, from: &now) == [.started])

        let onset = try #require(stability.onset)
        #expect(abs(onset.earliest.seconds - lastStill) < 0.000_001)
        #expect(abs(onset.best.seconds - departed) < 0.000_001)
        #expect(abs(onset.latest.seconds - now) < 0.000_001)
    }

    @Test
    func aSuddenCrossingBeganAfterThePreviousFrame() throws {
        var (stability, now) = stable()
        let lastStill = now

        #expect(feed(&stability, body(moving: [.hands], dy: 0.5), for: frame, from: &now) == [.started])

        let onset = try #require(stability.onset)
        #expect(abs(onset.earliest.seconds - lastStill) < 0.000_001)
        #expect(abs(onset.latest.seconds - now) < 0.000_001)
        #expect(onset.best == onset.latest)
    }

    /// A standing athlete who has leaned out of the tolerance starts from
    /// there. Leaning out was not the beginning of the start.
    @Test
    func aStartAfterLeaningOutBeginsWithItsRise() throws {
        var (stability, now) = stable(.standing)

        // Outside the tolerance for longer than a start takes.
        _ = feed(&stability, body(moving: [.torso], dy: 0.2), for: 2 * MotionProfile.standing.unsteadyDelay, from: &now)
        let lastLeaning = now

        #expect(feed(&stability, body(moving: [.torso], dy: 0.29), for: frame, from: &now).isEmpty)
        let rising = now
        #expect(feed(&stability, body(moving: [.torso], dy: 0.4), for: frame, from: &now) == [.started])

        let onset = try #require(stability.onset)
        #expect(abs(onset.earliest.seconds - lastLeaning) < 0.000_001)
        #expect(abs(onset.best.seconds - rising) < 0.000_001)
        #expect(abs(onset.latest.seconds - now) < 0.000_001)
    }

    /// Whatever the athlete did while hidden, the movement began after the
    /// last frame that showed them.
    @Test
    func aStartAfterBeingHiddenBeganAfterTheLastFrameSeen() throws {
        var (stability, now) = stable()
        let lastSeen = now

        now += 1
        #expect(feed(&stability, body(moving: [.hands], dy: 0.5), for: frame, from: &now) == [.started])

        let onset = try #require(stability.onset)
        #expect(abs(onset.earliest.seconds - lastSeen) < 0.000_001)
        #expect(onset.best == onset.latest)
    }

    @Test
    func theRestingPoseIsKnownOnceStable() {
        var stability = AthleteStability(profile: .block)
        #expect(stability.restingPose == nil)

        var now: TimeInterval = 0
        _ = feed(&stability, body(), for: MotionProfile.block.settleDuration + 3 * frame, from: &now)
        #expect(stability.restingPose?.count == body().count)

        stability.resettle()
        #expect(stability.restingPose == nil)
    }
}
