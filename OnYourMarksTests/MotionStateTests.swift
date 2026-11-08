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

    private func moved(by offset: CGFloat) -> Joints {
        var joints = still
        joints[.root] = CGPoint(x: 0.5 + offset, y: 0.5)
        return joints
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
        var triggered = state.process(moved(by: 0.3))
        #expect(triggered)

        state.reset(monitoring: true)

        // The moved pose becomes the new baseline instead of triggering.
        for _ in 0..<MotionState.baselineFrameCount {
            let triggered = state.process(moved(by: 0.3))
            #expect(!triggered)
        }
        triggered = state.process(moved(by: 0.3))
        #expect(!triggered)
        triggered = state.process(still)
        #expect(triggered)
    }
}
