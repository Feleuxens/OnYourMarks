//
//  AthleteTrackingTests.swift
//  OnYourMarksTests
//

import Foundation
import Testing
import Vision
@testable import OnYourMarks

/// A standing body around the given x position, about 0.4 high.
private func pose(at x: CGFloat, confidence: Float = 0.9, shiftedBy offset: CGFloat = 0) -> DetectedPose {
    DetectedPose(
        joints: [
            .neck: CGPoint(x: x + offset, y: 0.7),
            .root: CGPoint(x: x + offset, y: 0.5),
            .leftShoulder: CGPoint(x: x - 0.03 + offset, y: 0.68),
            .rightShoulder: CGPoint(x: x + 0.03 + offset, y: 0.68),
            .leftHip: CGPoint(x: x - 0.02 + offset, y: 0.5),
            .rightHip: CGPoint(x: x + 0.02 + offset, y: 0.5),
            .leftKnee: CGPoint(x: x - 0.02 + offset, y: 0.4),
            .rightKnee: CGPoint(x: x + 0.02 + offset, y: 0.4),
            .leftAnkle: CGPoint(x: x - 0.02 + offset, y: 0.3),
            .rightAnkle: CGPoint(x: x + 0.02 + offset, y: 0.3)
        ],
        confidence: confidence
    )
}

private func time(_ seconds: TimeInterval) -> MonotonicTimestamp {
    MonotonicTimestamp(seconds: seconds)
}

/// Frame interval of the precision rate.
private let frame: TimeInterval = 1.0 / 120

/// Feeds the same poses for a number of frames and returns the last result.
private func run(
    _ tracker: inout AthleteTracker,
    poses: [DetectedPose],
    from start: TimeInterval,
    frames: Int
) -> [TrackedAthlete] {
    var athletes: [TrackedAthlete] = []
    for index in 0..<frames {
        athletes = tracker.update(with: poses, at: time(start + Double(index) * frame))
    }
    return athletes
}

struct DetectedPoseTests {
    @Test
    func centerIsTheMiddleOfTheTorso() {
        let center = pose(at: 0.3).center

        #expect(abs(center.x - 0.3) < 0.001)
        #expect(center.y > 0.5 && center.y < 0.7)
    }

    @Test
    func centerFallsBackToAllJointsWithoutATorso() {
        let legs = DetectedPose(
            joints: [.leftAnkle: CGPoint(x: 0.2, y: 0.1), .rightAnkle: CGPoint(x: 0.4, y: 0.3)],
            confidence: 0.9
        )

        #expect(abs(legs.center.x - 0.3) < 0.001)
        #expect(abs(legs.center.y - 0.2) < 0.001)
    }

    @Test
    func bodyScaleFallsBackFromTorsoToShoulderAndHipToAllJoints() {
        let torso: DetectedPose.Joints = [.neck: CGPoint(x: 0.5, y: 0.8), .root: CGPoint(x: 0.5, y: 0.5)]
        let side: DetectedPose.Joints = [.rightShoulder: CGPoint(x: 0.5, y: 0.7), .rightHip: CGPoint(x: 0.5, y: 0.5)]
        let legs: DetectedPose.Joints = [.leftKnee: CGPoint(x: 0.5, y: 0.4), .leftAnkle: CGPoint(x: 0.5, y: 0.3)]
        let single: DetectedPose.Joints = [.neck: CGPoint(x: 0.5, y: 0.8)]

        #expect(abs(DetectedPose.bodyScale(of: torso, aspectRatio: 1) - 0.3) < 0.001)
        #expect(abs(DetectedPose.bodyScale(of: side, aspectRatio: 1) - 0.2) < 0.001)
        #expect(abs(DetectedPose.bodyScale(of: legs, aspectRatio: 1) - 0.1) < 0.001)
        #expect(DetectedPose.bodyScale(of: single, aspectRatio: 1) == DetectedPose.minimumBodyScale)
        #expect(abs(pose(at: 0.5).bodyScale - 0.2) < 0.001)
    }

    @Test
    func lengthsCountTheSameInEveryDirectionOfAPortraitPicture() {
        let aspectRatio: CGFloat = 9.0 / 16.0
        let origin = CGPoint(x: 0.5, y: 0.5)

        // The same length covers a larger share of the narrow side.
        let sideways = DetectedPose.distance(origin, CGPoint(x: 0.5 + 0.1 / aspectRatio, y: 0.5), aspectRatio: aspectRatio)
        let upwards = DetectedPose.distance(origin, CGPoint(x: 0.5, y: 0.6), aspectRatio: aspectRatio)

        #expect(abs(sideways - upwards) < 0.000_001)
    }

    @Test
    func distanceIsTheMeanOverSharedJoints() {
        #expect(abs(pose(at: 0.3).distance(to: pose(at: 0.3, shiftedBy: 0.05)) - 0.05) < 0.001)
    }

    @Test
    func distanceUsesCentresWithoutSharedJoints() {
        let upper = DetectedPose(joints: [.neck: CGPoint(x: 0.2, y: 0.5)], confidence: 0.9)
        let lower = DetectedPose(joints: [.leftAnkle: CGPoint(x: 0.5, y: 0.5)], confidence: 0.9)

        #expect(abs(upper.distance(to: lower) - 0.3) < 0.001)
    }

    @Test
    func unconfidentAndUninterestingJointsAreDropped() throws {
        let points: [VNHumanBodyPoseObservation.JointName: (location: CGPoint, confidence: Float)] = [
            .neck: (CGPoint(x: 0.5, y: 0.7), 0.8),
            .root: (CGPoint(x: 0.5, y: 0.5), 0.4),
            .leftKnee: (CGPoint(x: 0.5, y: 0.3), PoseTracker.minimumConfidence / 2),
            .nose: (CGPoint(x: 0.5, y: 0.8), 0.9)
        ]

        let detected = try #require(PoseTracker.pose(from: points))

        #expect(Set(detected.joints.keys) == [.neck, .root])
        #expect(abs(detected.confidence - 0.6) < 0.001)
    }

    @Test
    func aBodyWithoutConfidentJointsIsNoPose() {
        #expect(PoseTracker.pose(from: [.neck: (CGPoint(x: 0.5, y: 0.7), 0.1)]) == nil)
    }
}

struct AthleteAssociationTests {
    @Test
    func pairsEachTrackWithTheNearestPose() {
        let tracks = [pose(at: 0.2), pose(at: 0.5), pose(at: 0.8)]
        // The poses arrive in another order and slightly moved.
        let poses = [pose(at: 0.81), pose(at: 0.19), pose(at: 0.52)]

        let pairings = AthleteAssociation.pair(tracks: tracks, with: poses)

        #expect(Set(pairings.map { [$0.track, $0.pose] }) == [[0, 1], [1, 2], [2, 0]])
    }

    @Test
    func aPoseBeyondTheGateStaysUnpaired() {
        let pairings = AthleteAssociation.pair(tracks: [pose(at: 0.2)], with: [pose(at: 0.6)])

        #expect(pairings.isEmpty)
    }

    @Test
    func aTrackTakesOnlyOnePose() {
        let pairings = AthleteAssociation.pair(tracks: [pose(at: 0.5)], with: [pose(at: 0.53), pose(at: 0.51)])

        #expect(pairings == [AthleteAssociation.Pairing(track: 0, pose: 1)])
    }

    @Test
    func theCloserTrackWinsAContestedPose() {
        let pairings = AthleteAssociation.pair(tracks: [pose(at: 0.40), pose(at: 0.50)], with: [pose(at: 0.48)])

        #expect(pairings == [AthleteAssociation.Pairing(track: 1, pose: 0)])
    }
}

struct AthleteTrackerTests {
    @Test
    func aNewBodyIsTentativeUntilConfirmed() {
        var tracker = AthleteTracker()

        for index in 0..<(AthleteTracker.confirmationFrames - 1) {
            let athletes = tracker.update(with: [pose(at: 0.5)], at: time(Double(index) * frame))
            #expect(athletes.map { $0.state } == [.tentative])
        }

        let athletes = tracker.update(with: [pose(at: 0.5)], at: time(1))
        #expect(athletes.map { $0.state } == [.tracked])
    }

    @Test
    func identitiesSurviveMovementAndReordering() throws {
        var tracker = AthleteTracker()
        let first = run(&tracker, poses: [pose(at: 0.2), pose(at: 0.5), pose(at: 0.8)], from: 0, frames: 5)
        try #require(first.count == 3)

        // Everyone drifts a little and Vision reports them in another order.
        var athletes: [TrackedAthlete] = []
        for step in 1...20 {
            let drift = CGFloat(step) * 0.002
            athletes = tracker.update(
                with: [pose(at: 0.8 - drift), pose(at: 0.2 + drift), pose(at: 0.5 + drift)],
                at: time(1 + Double(step) * frame)
            )
        }

        #expect(athletes.map { $0.id } == first.map { $0.id })
        #expect(athletes.allSatisfy { $0.state == .tracked && $0.isVisible })
    }

    @Test
    func athletesAreOrderedFromLeftToRight() {
        var tracker = AthleteTracker()
        let athletes = run(&tracker, poses: [pose(at: 0.8), pose(at: 0.2), pose(at: 0.5)], from: 0, frames: 3)

        #expect(athletes.map { $0.pose.center.x } == athletes.map { $0.pose.center.x }.sorted())
    }

    @Test
    func aSpuriousDetectionIsForgotten() {
        var tracker = AthleteTracker()
        _ = tracker.update(with: [pose(at: 0.5)], at: time(0))

        var athletes = tracker.update(with: [], at: time(frame))
        #expect(athletes.map { $0.state } == [.tentative])

        athletes = tracker.update(with: [], at: time(AthleteTracker.occlusionDelay + 2 * frame))
        #expect(athletes.isEmpty)
    }

    @Test
    func aMissedFrameIsNotAnOcclusion() {
        var tracker = AthleteTracker()
        _ = run(&tracker, poses: [pose(at: 0.5)], from: 0, frames: 5)

        let athletes = tracker.update(with: [], at: time(5 * frame))

        #expect(athletes.map { $0.state } == [.tracked])
        #expect(athletes.first?.isVisible == false)
    }

    @Test
    func aHiddenAthleteIsOccludedAndReturnsUnderTheSameID() throws {
        var tracker = AthleteTracker()
        let id = try #require(run(&tracker, poses: [pose(at: 0.5)], from: 0, frames: 5).first?.id)

        var athletes = tracker.update(with: [], at: time(0.3))
        #expect(athletes.map { $0.state } == [.occluded])
        #expect(athletes.map { $0.id } == [id])

        athletes = tracker.update(with: [pose(at: 0.51)], at: time(0.5))
        #expect(athletes.map { $0.state } == [.tracked])
        #expect(athletes.map { $0.id } == [id])
    }

    @Test
    func aLostAthleteIsReportedOnceAndTheNextBodyIsSomeoneNew() throws {
        var tracker = AthleteTracker()
        let id = try #require(run(&tracker, poses: [pose(at: 0.5)], from: 0, frames: 5).first?.id)

        var athletes = tracker.update(with: [], at: time(AthleteTracker.lostDelay + 0.5))
        #expect(athletes.map { $0.state } == [.lost])

        athletes = tracker.update(with: [], at: time(AthleteTracker.lostDelay + 0.6))
        #expect(athletes.isEmpty)

        athletes = tracker.update(with: [pose(at: 0.5)], at: time(AthleteTracker.lostDelay + 0.7))
        #expect(athletes.count == 1)
        #expect(athletes.first?.id != id)
    }

    @Test
    func aRetainedAthleteReturnsUnderTheSameIDAfterBeingLost() throws {
        var tracker = AthleteTracker()
        let id = try #require(run(&tracker, poses: [pose(at: 0.5)], from: 0, frames: 5).first?.id)
        tracker.retained = [id]

        var athletes = tracker.update(with: [], at: time(3))
        athletes = tracker.update(with: [], at: time(4))
        #expect(athletes.map { $0.state } == [.lost])

        athletes = tracker.update(with: [pose(at: 0.5)], at: time(5))
        #expect(athletes.map { $0.id } == [id])
        #expect(athletes.map { $0.state } == [.tracked])
    }

    @Test
    func aNewcomerNextToAnOccludedAthleteGetsAnotherID() throws {
        var tracker = AthleteTracker()
        let id = try #require(run(&tracker, poses: [pose(at: 0.3)], from: 0, frames: 5).first?.id)

        let athletes = tracker.update(with: [pose(at: 0.7)], at: time(0.3))

        #expect(athletes.count == 2)
        #expect(athletes.first { $0.id == id }?.state == .occluded)
        #expect(athletes.first { $0.id != id }?.state == .tentative)
    }

    @Test
    func resetForgetsEveryone() throws {
        var tracker = AthleteTracker()
        let id = try #require(run(&tracker, poses: [pose(at: 0.5)], from: 0, frames: 5).first?.id)
        tracker.retained = [id]

        tracker.reset()
        let athletes = tracker.update(with: [pose(at: 0.5)], at: time(0.1))

        #expect(athletes.count == 1)
        #expect(athletes.first?.id != id)
        #expect(tracker.retained.isEmpty)
    }
}

struct TrackingQualityTests {
    private func quality(
        state: AthleteTrackState = .tracked,
        jointCoverage: Double = 1,
        confidence: Double = 0.9,
        continuity: Double = 1
    ) -> TrackingQuality {
        TrackingQuality(state: state, jointCoverage: jointCoverage, confidence: confidence, continuity: continuity)
    }

    @Test
    func aSteadyWellSeenTrackIsGood() {
        #expect(quality().level == .good)
    }

    @Test(arguments: [AthleteTrackState.tentative, .occluded, .lost])
    func anythingButTrackedIsPoor(state: AthleteTrackState) {
        #expect(quality(state: state).level == .poor)
    }

    @Test
    func fewJointsOrLowContinuityArePoor() {
        #expect(quality(jointCoverage: 3.0 / 14).level == .poor)
        #expect(quality(continuity: TrackingQuality.poorContinuity - 0.01).level == .poor)
    }

    @Test
    func shortfallsBelowGoodAreReduced() {
        #expect(quality(jointCoverage: 5.0 / 14).level == .reduced)
        #expect(quality(confidence: 0.4).level == .reduced)
        #expect(quality(continuity: 0.7).level == .reduced)
    }

    @Test
    func trackerReportsWhatItSaw() throws {
        var tracker = AthleteTracker()
        let athlete = try #require(run(&tracker, poses: [pose(at: 0.5, confidence: 0.8)], from: 0, frames: 10).first)

        #expect(athlete.quality.state == .tracked)
        #expect(abs(athlete.quality.jointCoverage - 10.0 / 14) < 0.001)
        #expect(abs(athlete.quality.confidence - 0.8) < 0.001)
        #expect(athlete.quality.continuity == 1)
        #expect(athlete.quality.level == .good)
    }

    @Test
    func continuityFallsWhileHiddenAndRecoversAfterTheWindow() throws {
        var tracker = AthleteTracker()
        _ = run(&tracker, poses: [pose(at: 0.5)], from: 0, frames: 30)

        // Hidden for 0.3 s, then back.
        _ = run(&tracker, poses: [], from: 30 * frame, frames: 36)
        var athlete = try #require(tracker.update(with: [pose(at: 0.5)], at: time(66 * frame)).first)

        #expect(athlete.state == .tracked)
        #expect(athlete.quality.continuity < TrackingQuality.poorContinuity)
        #expect(athlete.quality.level == .poor)

        athlete = try #require(
            run(&tracker, poses: [pose(at: 0.5)], from: 67 * frame, frames: Int(AthleteTracker.continuityWindow / frame) + 2).first
        )
        #expect(athlete.quality.continuity == 1)
        #expect(athlete.quality.level == .good)
    }
}

struct AthleteMotionMonitorTests {
    /// A tracker and a monitor fed frame by frame at the precision rate.
    private struct Scene {
        var tracker = AthleteTracker()
        var monitor = AthleteMotionMonitor()
        var now: TimeInterval = 0
        /// Whether the monitor is ready, as its updates reported it.
        var reportedReadiness: [Bool] = []

        @discardableResult
        mutating func track(_ poses: [DetectedPose], frames: Int = 1) -> [TrackedAthlete] {
            var athletes: [TrackedAthlete] = []
            for _ in 0..<frames {
                now += frame
                athletes = tracker.update(with: poses, at: time(now))
            }
            return athletes
        }

        @discardableResult
        mutating func step(_ poses: [DetectedPose], cameraOffset: CGPoint = .zero) -> [DetectorEvent] {
            now += frame
            let update = monitor.process(
                tracker.update(with: poses, at: time(now)), cameraOffset: cameraOffset, at: time(now)
            )
            if let readiness = update.readiness {
                reportedReadiness.append(readiness)
            }
            return update
        }

        /// Everyone stands still for long enough to become stable.
        mutating func settle(_ poses: [DetectedPose]) {
            for _ in 0..<(Int(MotionProfile.block.settleDuration / frame) + 3) {
                let update = step(poses)
                #expect(update.movements.isEmpty)
            }
        }

        /// Confirms one athlete per position and fixes them as the roster.
        mutating func begin(_ positions: [CGFloat]) -> [TrackedAthlete] {
            let athletes = track(positions.map { pose(at: $0) }, frames: 5)
            let roster = monitor.begin(with: athletes, profile: .block)
            tracker.retained = Set(roster.entries.map { $0.id })
            return athletes
        }
    }

    @Test
    func rosterHoldsTrackedAndOccludedAthletesNumberedFromTheLeft() throws {
        var tracker = AthleteTracker()
        _ = run(&tracker, poses: [pose(at: 0.2), pose(at: 0.6)], from: 0, frames: 5)
        // The left athlete is hidden and someone new has just appeared.
        let athletes = tracker.update(with: [pose(at: 0.6), pose(at: 0.9)], at: time(0.3))
        try #require(athletes.map { $0.state } == [.occluded, .tracked, .tentative])

        var monitor = AthleteMotionMonitor()
        let roster = monitor.begin(with: athletes, profile: .block)

        #expect(roster.entries.map { $0.id } == [athletes[0].id, athletes[1].id])
        #expect(roster.entries.map { $0.position } == [1, 2])
        #expect(roster.position(of: athletes[1].id) == 2)
        #expect(roster.position(of: athletes[2].id) == nil)
        #expect(roster.entries.map { $0.quality.level } == [.poor, .good])
        #expect(monitor.roster == roster)
    }

    @Test
    func readyOnceEveryoneHoldsStill() {
        var scene = Scene()
        let athletes = scene.begin([0.2, 0.6])
        #expect(!scene.monitor.isReady)

        // The right athlete keeps shifting about.
        for step in 0..<80 {
            scene.step([pose(at: 0.2), pose(at: 0.6, shiftedBy: step % 20 < 10 ? 0 : 0.05)])
        }
        #expect(scene.monitor.phases[athletes[0].id] == .stable)
        #expect(scene.monitor.phases[athletes[1].id] != .stable)
        #expect(!scene.monitor.isReady)
        #expect(scene.reportedReadiness.isEmpty)

        scene.settle([pose(at: 0.2), pose(at: 0.6)])

        #expect(scene.monitor.isReady)
        #expect(scene.reportedReadiness == [true])
    }

    @Test
    func anEmptyRosterIsReadyAndNoRosterIsNot() {
        var monitor = AthleteMotionMonitor()
        #expect(!monitor.isReady)

        _ = monitor.begin(with: [], profile: .block)
        #expect(monitor.isReady)
    }

    @Test
    func aHiddenAthleteDoesNotHoldUpTheStart() {
        var scene = Scene()
        _ = scene.begin([0.2, 0.6])

        // The right athlete disappears behind someone before ever being still.
        scene.settle([pose(at: 0.2)])

        #expect(scene.monitor.isReady)
    }

    @Test
    func gettingIntoPositionIsNotAMovement() {
        var scene = Scene()
        _ = scene.begin([0.3])

        // Rising into the set position: far more than the threshold.
        for step in 0..<40 {
            let update = scene.step([pose(at: 0.3, shiftedBy: CGFloat(step) * 0.005)])
            #expect(update.movements.isEmpty)
            #expect(update.unsteady.isEmpty)
        }
        #expect(!scene.monitor.isReady)
    }

    @Test
    func eachAthletesMovementIsReportedOnceWithTheirID() {
        var scene = Scene()
        let athletes = scene.begin([0.2, 0.6])
        scene.settle([pose(at: 0.2), pose(at: 0.6)])

        // Only the right athlete moves.
        var update = scene.step([pose(at: 0.2), pose(at: 0.6, shiftedBy: 0.08)])
        #expect(update.movements.map { $0.athleteID } == [athletes[1].id])
        #expect(update.movements.first?.time == time(scene.now))
        #expect(update.movements.first?.quality?.level == .good)

        // The right one keeps moving, now the left one starts as well.
        update = scene.step([pose(at: 0.2, shiftedBy: 0.08), pose(at: 0.6, shiftedBy: 0.1)])
        #expect(update.movements.map { $0.athleteID } == [athletes[0].id])

        update = scene.step([pose(at: 0.2, shiftedBy: 0.1), pose(at: 0.6, shiftedBy: 0.12)])
        #expect(update.movements.isEmpty)
    }

    @Test
    func someoneOutsideTheRosterIsNotWatched() {
        var scene = Scene()
        _ = scene.begin([0.2])
        scene.settle([pose(at: 0.2)])

        // A second person walks in and moves about.
        for step in 0..<30 {
            let update = scene.step([pose(at: 0.2), pose(at: 0.7, shiftedBy: CGFloat(step) * 0.01)])
            #expect(update.movements.isEmpty)
            #expect(update.unsteady.isEmpty)
            #expect(update.trackingChanges.isEmpty)
        }
        #expect(scene.monitor.isReady)
    }

    @Test
    func anUnsteadyAthleteIsReportedAndHasToSettleAgain() {
        var scene = Scene()
        let athletes = scene.begin([0.2, 0.6])
        scene.settle([pose(at: 0.2), pose(at: 0.6)])

        // The left athlete sags by a fifth of a torso and stays there.
        var unsteady: [MovementObservation] = []
        for _ in 0..<(Int(MotionProfile.block.unsteadyDelay / frame) + 3) {
            let update = scene.step([pose(at: 0.2, shiftedBy: 0.04), pose(at: 0.6)])
            #expect(update.movements.isEmpty)
            unsteady += update.unsteady
        }
        #expect(unsteady.map { $0.athleteID } == [athletes[0].id])

        scene.monitor.resettle(athletes[0].id)
        #expect(!scene.monitor.isReady)
        #expect(scene.monitor.phases[athletes[0].id] == .moving)
        #expect(scene.monitor.phases[athletes[1].id] == .stable)

        // Still again in the new place: that is the new resting pose.
        scene.settle([pose(at: 0.2, shiftedBy: 0.04), pose(at: 0.6)])
        #expect(scene.monitor.isReady)
        #expect(scene.reportedReadiness == [true, true])
    }

    @Test
    func aMovingCameraIsTakenOutOfTheAthletes() {
        var scene = Scene()
        _ = scene.begin([0.2, 0.6])
        scene.settle([pose(at: 0.2), pose(at: 0.6)])

        // The whole picture shifts as far as a start would move a body.
        let shaken = [pose(at: 0.2, shiftedBy: 0.08), pose(at: 0.6, shiftedBy: 0.08)]

        var compensated = scene
        let update = compensated.step(shaken, cameraOffset: CGPoint(x: 0.08, y: 0))
        #expect(update.movements.isEmpty)

        #expect(scene.step(shaken).movements.count == 2)
    }

    @Test
    func occlusionAndReturnAreReportedAndTheReturnIsPoorlyTracked() {
        var scene = Scene()
        let id = scene.begin([0.2])[0].id
        scene.settle([pose(at: 0.2)])

        var changes: [AthleteTrackState] = []
        var movements: [MovementObservation] = []

        // Hidden for 0.4 s: no movement comes from the stale pose.
        for _ in 0..<48 {
            let update = scene.step([])
            changes += update.trackingChanges.map { $0.state }
            movements += update.movements
        }
        #expect(changes == [.occluded])
        #expect(movements.isEmpty)

        // Back, but displaced: a movement, on a track that can't be trusted yet.
        let update = scene.step([pose(at: 0.2, shiftedBy: 0.08)])

        #expect(update.trackingChanges == [AthleteTrackingChange(athleteID: id, state: .tracked, time: time(scene.now))])
        #expect(update.movements.map { $0.athleteID } == [id])
        #expect(update.movements.first?.quality?.level == .poor)
    }

    @Test
    func nothingIsReportedAfterTheEnd() {
        var scene = Scene()
        _ = scene.begin([0.2])
        scene.settle([pose(at: 0.2)])

        scene.monitor.end()

        #expect(scene.step([pose(at: 0.2, shiftedBy: 0.08)]).isEmpty)
        #expect(scene.monitor.roster == nil)
        #expect(!scene.monitor.isReady)
    }

    @Test
    func stableAthletesHaveARegionToWatchAndMovementsCarryTheirBeginning() throws {
        var scene = Scene()
        let athletes = scene.begin([0.2, 0.6])
        #expect(scene.monitor.regions.isEmpty)

        scene.settle([pose(at: 0.2), pose(at: 0.6)])

        let region = try #require(scene.monitor.regions[athletes[0].id])
        #expect(region.contains(CGPoint(x: 0.2, y: 0.5)))
        #expect(!region.contains(CGPoint(x: 0.6, y: 0.5)))
        #expect(scene.monitor.regions.count == 2)

        let lastStill = scene.now
        let movement = try #require(scene.step([pose(at: 0.2, shiftedBy: 0.08), pose(at: 0.6)]).movements.first)

        #expect(movement.onset.earliest == time(lastStill))
        #expect(movement.onset.latest == movement.time)

        // Settling again means a new place to watch.
        scene.monitor.resettle(athletes[1].id)
        #expect(scene.monitor.regions[athletes[1].id] == nil)
    }
}
