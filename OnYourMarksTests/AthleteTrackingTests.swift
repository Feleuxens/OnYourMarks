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
    func extentNeverCollapses() {
        let single = DetectedPose(joints: [.neck: CGPoint(x: 0.5, y: 0.5)], confidence: 0.9)

        #expect(single.extent == DetectedPose.minimumExtent)
        #expect(abs(pose(at: 0.5).extent - hypot(0.06, 0.4)) < 0.001)
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
    /// A tracker that has confirmed one athlete at each position.
    private func tracking(_ positions: [CGFloat]) -> (AthleteTracker, [TrackedAthlete]) {
        var tracker = AthleteTracker()
        let athletes = run(&tracker, poses: positions.map { pose(at: $0) }, from: 0, frames: 5)
        return (tracker, athletes)
    }

    /// Monitors past the baseline with everyone standing still.
    private func settle(
        _ monitor: inout AthleteMotionMonitor,
        _ tracker: inout AthleteTracker,
        positions: [CGFloat]
    ) {
        for index in 0..<MotionState.baselineFrameCount {
            let now = time(1 + Double(index) * frame)
            let update = monitor.process(tracker.update(with: positions.map { pose(at: $0) }, at: now), at: now)
            #expect(update.movements.isEmpty)
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
        let roster = monitor.begin(with: athletes)

        #expect(roster.entries.map { $0.id } == [athletes[0].id, athletes[1].id])
        #expect(roster.entries.map { $0.position } == [1, 2])
        #expect(roster.position(of: athletes[1].id) == 2)
        #expect(roster.position(of: athletes[2].id) == nil)
        #expect(roster.entries.map { $0.quality.level } == [.poor, .good])
        #expect(monitor.roster == roster)
    }

    @Test
    func eachAthletesMovementIsReportedOnceWithTheirID() throws {
        var (tracker, athletes) = tracking([0.2, 0.6])
        var monitor = AthleteMotionMonitor()
        _ = monitor.begin(with: athletes)
        settle(&monitor, &tracker, positions: [0.2, 0.6])

        // Only the right athlete moves.
        var now = time(2)
        var update = monitor.process(
            tracker.update(with: [pose(at: 0.2), pose(at: 0.6, shiftedBy: 0.08)], at: now), at: now
        )
        #expect(update.movements.map { $0.athleteID } == [athletes[1].id])
        #expect(update.movements.first?.time == now)
        #expect(update.movements.first?.quality?.level == .good)

        // The right one keeps moving, now the left one starts as well.
        now = time(2 + frame)
        update = monitor.process(
            tracker.update(with: [pose(at: 0.2, shiftedBy: 0.08), pose(at: 0.6, shiftedBy: 0.1)], at: now), at: now
        )
        #expect(update.movements.map { $0.athleteID } == [athletes[0].id])

        now = time(2 + 2 * frame)
        update = monitor.process(
            tracker.update(with: [pose(at: 0.2, shiftedBy: 0.1), pose(at: 0.6, shiftedBy: 0.12)], at: now), at: now
        )
        #expect(update.movements.isEmpty)
    }

    @Test
    func someoneOutsideTheRosterIsNotWatched() {
        var (tracker, athletes) = tracking([0.2])
        var monitor = AthleteMotionMonitor()
        _ = monitor.begin(with: athletes)
        settle(&monitor, &tracker, positions: [0.2])

        // A second person walks in and moves about.
        for step in 0..<30 {
            let now = time(2 + Double(step) * frame)
            let update = monitor.process(
                tracker.update(with: [pose(at: 0.2), pose(at: 0.7, shiftedBy: CGFloat(step) * 0.01)], at: now),
                at: now
            )
            #expect(update.movements.isEmpty)
            #expect(update.trackingChanges.isEmpty)
        }
    }

    @Test
    func occlusionAndReturnAreReportedAndTheReturnIsPoorlyTracked() throws {
        var (tracker, athletes) = tracking([0.2])
        let id = athletes[0].id
        var monitor = AthleteMotionMonitor()
        _ = monitor.begin(with: athletes)
        tracker.retained = [id]
        settle(&monitor, &tracker, positions: [0.2])

        var changes: [AthleteTrackState] = []
        var movements: [MovementObservation] = []

        // Hidden for 0.4 s: no movement comes from the stale pose.
        let hiddenFrom = 1 + Double(MotionState.baselineFrameCount) * frame
        for step in 0..<48 {
            let now = time(hiddenFrom + Double(step) * frame)
            let update = monitor.process(tracker.update(with: [], at: now), at: now)
            changes += update.trackingChanges.map { $0.state }
            movements += update.movements
        }
        #expect(changes == [.occluded])
        #expect(movements.isEmpty)

        // Back, but displaced: a movement, on a track that can't be trusted yet.
        let now = time(hiddenFrom + 48 * frame)
        let update = monitor.process(tracker.update(with: [pose(at: 0.2, shiftedBy: 0.08)], at: now), at: now)

        #expect(update.trackingChanges == [AthleteTrackingChange(athleteID: id, state: .tracked, time: now)])
        #expect(update.movements.map { $0.athleteID } == [id])
        #expect(update.movements.first?.quality?.level == .poor)
    }

    @Test
    func nothingIsReportedAfterTheEnd() {
        var (tracker, athletes) = tracking([0.2])
        var monitor = AthleteMotionMonitor()
        _ = monitor.begin(with: athletes)
        settle(&monitor, &tracker, positions: [0.2])

        monitor.end()

        let now = time(2)
        let update = monitor.process(tracker.update(with: [pose(at: 0.2, shiftedBy: 0.08)], at: now), at: now)
        #expect(update == AthleteMotionMonitor.Update())
        #expect(monitor.roster == nil)
    }
}
