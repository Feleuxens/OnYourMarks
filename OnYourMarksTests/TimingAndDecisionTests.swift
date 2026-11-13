//
//  TimingAndDecisionTests.swift
//  OnYourMarks
//
//  Created by Felix on 28.08.26.
//

import Testing
@testable import OnYourMarks

struct TimingAndDecisionTests {
    @Test
        func exactTimeDifference() {
            let gun = TimeEstimate.exact(
                MonotonicTimestamp(seconds: 10.000)
            )

            let movement = TimeEstimate.exact(
                MonotonicTimestamp(seconds: 10.143)
            )

            let reaction = movement.duration(
                since: gun
            )

            #expect(
                abs(reaction.best - 0.143) < 0.000_001
            )

            #expect(
                abs(reaction.earliest - 0.143) < 0.000_001
            )

            #expect(
                abs(reaction.latest - 0.143) < 0.000_001
            )
        }

        @Test
        func uncertaintyPropagatesConservatively() {
            let gun = TimeEstimate(
                best: MonotonicTimestamp(seconds: 10.002),
                earliest: MonotonicTimestamp(seconds: 10.000),
                latest: MonotonicTimestamp(seconds: 10.005)
            )

            let movement = TimeEstimate(
                best: MonotonicTimestamp(seconds: 10.092),
                earliest: MonotonicTimestamp(seconds: 10.090),
                latest: MonotonicTimestamp(seconds: 10.095)
            )

            let reaction = movement.duration(
                since: gun
            )

            #expect(
                abs(reaction.best - 0.090) < 0.000_001
            )

            // earliest movement - latest gun
            #expect(
                abs(reaction.earliest - 0.085) < 0.000_001
            )

            // latest movement - earliest gun
            #expect(
                abs(reaction.latest - 0.095) < 0.000_001
            )
        }

        @Test
        func definiteFalseStartRequiresEntireIntervalBelowThreshold() {
            let engine = DecisionEngine()

            let reaction = DurationEstimate(
                best: 0.090,
                earliest: 0.082,
                latest: 0.097
            )

            let result = engine.evaluateReaction(
                reaction,
                profile: .block
            )

            #expect(
                result == .definiteFalseStart
            )
        }

        @Test
        func intervalCrossingThresholdIsUncertain() {
            let engine = DecisionEngine()

            let reaction = DurationEstimate(
                best: 0.094,
                earliest: 0.086,
                latest: 0.104
            )

            let result = engine.evaluateReaction(
                reaction,
                profile: .block
            )

            #expect(
                result == .uncertain
            )
        }

        @Test
        func exactlyOneHundredMillisecondsIsLegal() {
            let engine = DecisionEngine()

            let reaction = DurationEstimate.exact(
                0.100
            )

            let result = engine.evaluateReaction(
                reaction,
                profile: .block
            )

            #expect(
                result == .legal
            )
        }

        @Test
        func clearlyLegalReactionIsLegal() {
            let engine = DecisionEngine()

            let reaction = DurationEstimate(
                best: 0.120,
                earliest: 0.110,
                latest: 0.130
            )

            let result = engine.evaluateReaction(
                reaction,
                profile: .block
            )

            #expect(
                result == .legal
            )
        }

        /// A standing start is false when the movement was certain before
        /// the gun, not within the 100 ms of a block start.
        @Test
        func standingStartIsJudgedAgainstTheGunItself() {
            let engine = DecisionEngine()

            #expect(engine.evaluateReaction(.exact(0.050), profile: .standing) == .legal)
            #expect(engine.evaluateReaction(.exact(0.050), profile: .block) == .definiteFalseStart)

            // As recorded on the device: certain 26 ms before the gun.
            let early = DurationEstimate(best: -0.060, earliest: -0.093, latest: -0.026)
            #expect(engine.evaluateReaction(early, profile: .standing) == .definiteFalseStart)

            // A slow beginning that reaches across the gun.
            let across = DurationEstimate(best: -0.020, earliest: -0.050, latest: 0.010)
            #expect(engine.evaluateReaction(across, profile: .standing) == .uncertain)
        }

        @Test
        func aStartWithoutAThresholdIsNotJudgedByItsReaction() {
            let profile = StartProfile(
                startType: .standing, usesSetCommand: false, automaticReactionThreshold: nil, motion: .standing
            )

            #expect(DecisionEngine().evaluateReaction(.exact(-0.5), profile: profile) == .notApplicable)
        }

        @Test
        func sessionRecordsEventsAndOutcome() {
            var session = StartSession(
                startType: .block,
                profile: .block,
                createdAt: MonotonicTimestamp(
                    seconds: 100
                )
            )

            session.record(
                .stateChanged(.onYourMarks),
                at: .exact(
                    MonotonicTimestamp(seconds: 101)
                ),
                source: .system
            )

            session.finish(
                .completed,
                at: .exact(
                    MonotonicTimestamp(seconds: 105)
                )
            )

            #expect(session.events.count == 3)
            #expect(session.outcome == .completed)

            #expect(
                session.events.first?.kind ==
                    .sessionStarted
            )

            #expect(
                session.events.last?.kind ==
                    .sessionEnded(.completed)
            )
        }

        @Test
        func anAssumedGunTimeConvictsNoOne() {
            let engine = DecisionEngine()

            #expect(engine.qualify(.definiteFalseStart, gunTimeIsTrusted: false, movedBeforeRender: false) == .uncertain)
            #expect(engine.qualify(.definiteFalseStart, gunTimeIsTrusted: true, movedBeforeRender: false) == .definiteFalseStart)

            // Over before any output could have played the gun.
            #expect(engine.qualify(.definiteFalseStart, gunTimeIsTrusted: false, movedBeforeRender: true) == .definiteFalseStart)

            #expect(engine.qualify(.legal, gunTimeIsTrusted: false, movedBeforeRender: false) == .legal)
            #expect(engine.qualify(.notApplicable, gunTimeIsTrusted: false, movedBeforeRender: false) == .notApplicable)
        }
}
