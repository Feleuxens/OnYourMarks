//
//  Timing.swift
//  OnYourMarks
//
//  Created by Felix on 26.08.26.
//

import Foundation
import QuartzCore

nonisolated struct MonotonicTimestamp: Equatable, Comparable, Hashable, Sendable {
    let seconds: TimeInterval
    
    static func < (lhs: MonotonicTimestamp, rhs: MonotonicTimestamp) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

/// An estimate of when an event happened.
///
/// If it is exact, then earliest == best == latest,
/// if not, it gives an interval.
nonisolated struct TimeEstimate: Equatable, Sendable {
    let best: MonotonicTimestamp
    let earliest: MonotonicTimestamp
    let latest: MonotonicTimestamp
    
    init (
        best: MonotonicTimestamp,
        earliest: MonotonicTimestamp,
        latest: MonotonicTimestamp
    ) {
        precondition(earliest <= best && best <= latest, "best must be in between earliest and latest")
        self.best = best
        self.earliest = earliest
        self.latest = latest
    }
    
    static func exact(_ timestamp: MonotonicTimestamp) -> TimeEstimate {
        TimeEstimate(best: timestamp, earliest: timestamp, latest: timestamp)
    }
    
    func duration(since reference: TimeEstimate) -> DurationEstimate {
        DurationEstimate(
            best: best.seconds - reference.best.seconds,
            earliest: earliest.seconds - reference.earliest.seconds,
            latest: latest.seconds - reference.latest.seconds
        )
    }
}


/// An estimated elapsed duration.
nonisolated struct DurationEstimate: Equatable, Sendable {
    let best: TimeInterval
    let earliest: TimeInterval
    let latest: TimeInterval

    init(
        best: TimeInterval,
        earliest: TimeInterval,
        latest: TimeInterval
    ) {
        precondition(
            earliest <= best && best <= latest,
            "best must lie inside earliest...latest"
        )

        self.best = best
        self.earliest = earliest
        self.latest = latest
    }

    static func exact(
        _ seconds: TimeInterval
    ) -> DurationEstimate {
        DurationEstimate(
            best: seconds,
            earliest: seconds,
            latest: seconds
        )
    }

    var width: TimeInterval {
        latest - earliest
    }
}

protocol MonotonicClock: AnyObject {
    func now() -> MonotonicTimestamp
}

/// Local phone's monotonic clock back by the system's monotonic host clock.
final class SystemMonotonicClock: MonotonicClock {
    func now() -> MonotonicTimestamp {
        .init(seconds: CACurrentMediaTime())
    }
}
