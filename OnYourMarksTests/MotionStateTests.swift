//
//  MotionStateTests.swift
//  OnYourMarksTests
//

import Testing
import Vision
@testable import OnYourMarks

struct MotionStateTests {
    private typealias Joints = [VNHumanBodyPoseObservation.JointName: CGPoint]

    private let still: Joints = [
        .root: CGPoint(x: 0.5, y: 0.5),
        .neck: CGPoint(x: 0.5, y: 0.8)
    ]

    /// Neck to root of `still`.
    private let torso: CGFloat = 0.3

    /// The root moved sideways by the given number of torso lengths.
    private func moved(by offset: CGFloat) -> Joints {
        var joints = still
        joints[.root] = CGPoint(x: 0.5 + offset * torso, y: 0.5)
        return joints
    }

    /// A body of the given torso length in the picture, standing still, and
    /// the same body with a wrist moved by a share of that torso length.
    private func body(torso: CGFloat, wristMovedBy offset: CGFloat = 0, sideways: Bool = false) -> Joints {
        [
            .root: CGPoint(x: 0.5, y: 0.3),
            .neck: CGPoint(x: 0.5, y: 0.3 + torso),
            .leftWrist: CGPoint(
                x: 0.4 + (sideways ? offset * torso : 0),
                y: 0.3 + (sideways ? 0 : offset * torso)
            )
        ]
    }

    private func triggers(_ still: Joints, then moved: Joints, aspectRatio: CGFloat = 1) -> Bool {
        var state = MotionState()
        state.reset(monitoring: true)

        for _ in 0..<MotionState.baselineFrameCount {
            _ = state.process(still, aspectRatio: aspectRatio)
        }
        return state.process(moved, aspectRatio: aspectRatio)
    }

    /// A monitoring state that has already collected its baseline.
    private func calibrated() -> MotionState {
        var state = MotionState()
        state.reset(monitoring: true)

        for _ in 0..<MotionState.baselineFrameCount {
            let triggered = state.process(still)
            #expect(!triggered)
        }
        return state
    }

    @Test
    func ignoresFramesWhenNotMonitoring() {
        var state = MotionState()

        for _ in 0..<(MotionState.baselineFrameCount + 2) {
            let triggered = state.process(moved(by: 0.3))
            #expect(!triggered)
        }
    }

    @Test
    func baselineFramesNeverTrigger() {
        var state = MotionState()
        state.reset(monitoring: true)

        for index in 0..<MotionState.baselineFrameCount {
            let triggered = state.process(moved(by: CGFloat(index) * 0.1))
            #expect(!triggered)
        }
    }

    @Test
    func movementAboveThresholdTriggersOnce() {
        var state = calibrated()

        var triggered = state.process(moved(by: MotionState.movementThreshold * 2))
        #expect(triggered)
        triggered = state.process(moved(by: MotionState.movementThreshold * 4))
        #expect(!triggered)
    }

    @Test
    func movementBelowThresholdDoesNotTrigger() {
        var state = calibrated()

        let triggered = state.process(moved(by: MotionState.movementThreshold / 2))
        #expect(!triggered)
    }

    @Test
    func emptyFramesAreIgnored() {
        var state = calibrated()

        var triggered = state.process([:])
        #expect(!triggered)
        triggered = state.process(moved(by: MotionState.movementThreshold * 2))
        #expect(triggered)
    }

    @Test
    func jointsMissingFromBaselineAreIgnored() {
        var state = calibrated()

        let triggered = state.process([.leftKnee: CGPoint(x: 0.9, y: 0.9)])
        #expect(!triggered)
    }

    @Test
    func resetStartsANewBaseline() {
        var state = calibrated()
        var triggered = state.process(moved(by: 1))
        #expect(triggered)

        state.reset(monitoring: true)

        // The moved pose becomes the new baseline instead of triggering.
        for _ in 0..<MotionState.baselineFrameCount {
            let triggered = state.process(moved(by: 1))
            #expect(!triggered)
        }
        triggered = state.process(moved(by: 1))
        #expect(!triggered)
        triggered = state.process(still)
        #expect(triggered)
    }

    /// The camera stands diagonally, so athletes differ in size in the picture.
    @Test(arguments: [0.06, 0.15, 0.4])
    func theSameMovementCountsTheSameNearAndFar(torso: Double) {
        let torso = CGFloat(torso)

        #expect(triggers(body(torso: torso), then: body(torso: torso, wristMovedBy: MotionState.movementThreshold * 1.2)))
        #expect(!triggers(body(torso: torso), then: body(torso: torso, wristMovedBy: MotionState.movementThreshold * 0.8)))
    }

    @Test
    func theSameShiftInThePictureOnlyCountsForTheSmallerAthlete() {
        // 0.03 of the picture: half a torso for the far athlete, a tenth for the near one.
        var far = body(torso: 0.06)
        far[.leftWrist]?.y += 0.03
        var near = body(torso: 0.3)
        near[.leftWrist]?.y += 0.03

        #expect(triggers(body(torso: 0.06), then: far))
        #expect(!triggers(body(torso: 0.3), then: near))
    }

    @Test
    func sidewaysAndUpwardMovementsCountTheSameInAPortraitPicture() {
        let aspectRatio: CGFloat = 9.0 / 16.0
        let torso: CGFloat = 0.2

        // Sideways, the same length covers a larger share of the narrow picture.
        let over = MotionState.movementThreshold * 1.2 / aspectRatio
        let under = MotionState.movementThreshold * 0.8 / aspectRatio

        #expect(triggers(body(torso: torso), then: body(torso: torso, wristMovedBy: over, sideways: true), aspectRatio: aspectRatio))
        #expect(!triggers(body(torso: torso), then: body(torso: torso, wristMovedBy: under, sideways: true), aspectRatio: aspectRatio))
        #expect(triggers(body(torso: torso), then: body(torso: torso, wristMovedBy: MotionState.movementThreshold * 1.2), aspectRatio: aspectRatio))
    }

    @Test
    func bodyScaleFallsBackFromTorsoToShoulderAndHipToAllJoints() {
        let torso: MotionState.Joints = [.neck: CGPoint(x: 0.5, y: 0.8), .root: CGPoint(x: 0.5, y: 0.5)]
        let side: MotionState.Joints = [.rightShoulder: CGPoint(x: 0.5, y: 0.7), .rightHip: CGPoint(x: 0.5, y: 0.5)]
        let legs: MotionState.Joints = [.leftKnee: CGPoint(x: 0.5, y: 0.4), .leftAnkle: CGPoint(x: 0.5, y: 0.3)]
        let single: MotionState.Joints = [.neck: CGPoint(x: 0.5, y: 0.8)]

        #expect(abs(MotionState.bodyScale(of: torso, aspectRatio: 1) - 0.3) < 0.001)
        #expect(abs(MotionState.bodyScale(of: side, aspectRatio: 1) - 0.2) < 0.001)
        #expect(abs(MotionState.bodyScale(of: legs, aspectRatio: 1) - 0.1) < 0.001)
        #expect(MotionState.bodyScale(of: single, aspectRatio: 1) == MotionState.minimumBodyScale)
    }
}
