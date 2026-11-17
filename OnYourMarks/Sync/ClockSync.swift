//
//  ClockSync.swift
//  OnYourMarks
//
//  The offset between this phone's host clock and another's, as an interval
//  that contains it whenever the stated assumptions hold. The argument is in
//  Docs/ClockSync.md; the comments here name its steps.
//

import Foundation

/// One round trip of the synchronization, stamped on both host clocks.
///
/// Every stamp is taken in the app, not at the radio: a send stamp before
/// the message is handed to the network, a receive stamp after it was
/// handed up. Time spent between the radio and the stamp only makes the
/// interval wider, never wrong.
nonisolated struct SyncExchange: Equatable, Codable, Sendable {
    /// t1, local clock: before the request was handed to the network.
    let requestSent: MonotonicTimestamp
    /// t2, remote clock: after the request arrived.
    let requestReceived: MonotonicTimestamp
    /// t3, remote clock: before the reply was handed to the network.
    let replySent: MonotonicTimestamp
    /// t4, local clock: after the reply arrived.
    let replyReceived: MonotonicTimestamp

    var roundTrip: TimeInterval {
        replyReceived.seconds - requestSent.seconds
    }

    /// How long the remote held the request, on its own clock.
    var remoteHold: TimeInterval {
        replySent.seconds - requestReceived.seconds
    }

    var midpoint: MonotonicTimestamp {
        MonotonicTimestamp(seconds: (requestSent.seconds + replyReceived.seconds) / 2)
    }

    /// What causality alone says (theorem 1): at some local instant in
    /// t1...t4 the offset was at most t2 − t1, and at some (other) instant
    /// in t1...t4 at least t3 − t4. No assumption about how the delay is
    /// split between the two directions.
    var causalOffset: (lower: TimeInterval, upper: TimeInterval) {
        (replySent.seconds - replyReceived.seconds, requestReceived.seconds - requestSent.seconds)
    }
}

/// The offset of the remote host clock from the local one, remote − local,
/// as an interval. A remote reading r was taken at local time r − offset.
nonisolated struct ClockOffset: Equatable, Codable, Sendable {
    let lower: TimeInterval
    let upper: TimeInterval

    var best: TimeInterval {
        (lower + upper) / 2
    }

    var width: TimeInterval {
        upper - lower
    }

    func contains(_ offset: TimeInterval) -> Bool {
        lower <= offset && offset <= upper
    }
}

/// An offset interval that holds at one local instant.
nonisolated struct OffsetBound: Equatable, Codable, Sendable {
    let at: MonotonicTimestamp
    let offset: ClockOffset

    /// The interval at another local instant: the offset can have moved
    /// by at most the rate bound times the distance (theorem 2).
    func aged(to time: MonotonicTimestamp, maximumRate: Double) -> ClockOffset {
        let spread = maximumRate * abs(time.seconds - at.seconds)
        return ClockOffset(lower: offset.lower - spread, upper: offset.upper + spread)
    }
}

/// What the synchronization assumes beyond causality. Both are named so
/// that a proof can point at them and a measurement can check them.
nonisolated struct ClockSyncAssumptions: Equatable, Codable, Sendable {
    /// The most the two host clocks can run apart: |d(remote − local) / d(local)|.
    ///
    /// The host clock counts the SoC's crystal-driven timebase (24 MHz) and
    /// is never slewed. Phone crystals are specified around ±10 to ±20 ppm
    /// at room temperature, another ±10 to ±30 ppm over the temperature
    /// range and a few ppm of ageing a year, so ±50 ppm for one phone and
    /// 100 ppm between two. Apple publishes no figure for the iPhone, so the
    /// bound is twice that. `RateEstimate` measures the real rate from the
    /// exchanges, so the bound is checked against every pair of phones.
    var maximumRelativeRate: Double = 200e-6

    /// Added to every bound: the host clock's resolution (one tick of the
    /// 24 MHz timebase, 42 ns, per reading) and the rounding of host times
    /// in seconds as `Double` (under 2 ns per operation for an uptime under
    /// 2^24 s, 194 days). A dozen of each stays far below 1 µs.
    var resolutionAllowance: TimeInterval = 1e-6

    static let standard = ClockSyncAssumptions()
}

/// The real relative rate of the two clocks, remote against local, measured
/// between two exchanges without using the rate bound.
///
/// Each limit holds for the mean rate over some stretch between the two
/// exchanges, whatever the rate does in between (theorem 3), so a limit
/// beyond `maximumRelativeRate` proves the assumption wrong. If the rate
/// is steady, both hold for the same stretch and `best` is the estimate.
nonisolated struct RateEstimate: Equatable, Codable, Sendable {
    let best: Double
    let lower: Double
    let upper: Double
    /// Local time between the two exchanges.
    let span: TimeInterval

    /// Nil if the exchanges overlap in time.
    static func between(_ earlier: SyncExchange, _ later: SyncExchange, resolutionAllowance: TimeInterval) -> RateEstimate? {
        let shortest = later.requestSent.seconds - earlier.replyReceived.seconds
        let longest = later.replyReceived.seconds - earlier.requestSent.seconds
        guard shortest > 0 else { return nil }

        let first = earlier.causalOffset
        let second = later.causalOffset
        let slack = 2 * resolutionAllowance

        // The offset rose at least this much from where the earlier one
        // was at most to where the later one was at least; a rise is
        // slowest over the longest stretch, a fall fastest over the shortest.
        let leastRise = second.lower - first.upper - slack
        let mostRise = second.upper - first.lower + slack
        let lower = leastRise >= 0 ? leastRise / longest : leastRise / shortest
        let upper = mostRise >= 0 ? mostRise / shortest : mostRise / longest

        let middles = (second.lower + second.upper) / 2 - (first.lower + first.upper) / 2
        let best = min(max(middles / (later.midpoint.seconds - earlier.midpoint.seconds), lower), upper)

        return RateEstimate(best: best, lower: lower, upper: upper, span: shortest)
    }
}

/// Why the exchanges and the assumptions can't all be true. Once one is
/// found, no offset is given out until the estimator is reset.
nonisolated enum SyncViolation: Equatable, Codable, Sendable {
    /// t4 before t1: the local clock went back.
    case localClockWentBack
    /// t3 before t2: the remote clock went back.
    case remoteClockWentBack
    /// The remote held the request longer than the round trip took, by more
    /// than the rate bound allows.
    case holdLongerThanRoundTrip
    /// No offset that moves within the rate bound fits every exchange; the
    /// exchanges around this local time contradict the earlier ones.
    case boundsDisagree(at: MonotonicTimestamp)
    /// The clocks ran apart faster than the rate bound.
    case rateBeyondAssumption(RateEstimate)
}

/// Collects exchanges with one remote clock and keeps the interval that
/// every one of them, aged by the rate bound, allows.
///
/// Sound: if the assumptions hold, `offset(at:)` contains the true offset
/// at every local instant (theorems 1 and 2). Complete in what it can tell:
/// if no offset trajectory within the rate bound fits all kept exchanges,
/// `violation` says so (theorem 4).
nonisolated struct ClockSyncEstimator: Sendable {
    let assumptions: ClockSyncAssumptions

    /// Exchanges are kept for this long. Aged by the rate bound, an older
    /// one is 2 × 200 ppm × 120 s = 48 ms wide and can't narrow anything.
    static let retention: TimeInterval = 120

    /// At 10 exchanges a second, the retention.
    static let maximumExchanges = 1200

    /// The rate is measured from the narrowest exchange of this first
    /// stretch to the narrowest of the last one: the longer the span, the
    /// finer the rate.
    static let rateAnchorStretch: TimeInterval = 10

    /// Sorted by midpoint.
    private(set) var exchanges: [SyncExchange] = []
    private(set) var bounds: [OffsetBound] = []
    private(set) var violation: SyncViolation?
    private(set) var rateAnchor: SyncExchange?
    private var anchorStretchEnd: MonotonicTimestamp?

    init(assumptions: ClockSyncAssumptions = .standard) {
        self.assumptions = assumptions
    }

    var isEmpty: Bool {
        exchanges.isEmpty
    }

    /// The interval one exchange gives for the offset at its midpoint:
    /// causality, then the rate bound over half the round trip, then the
    /// resolution allowance.
    func bound(for exchange: SyncExchange) -> OffsetBound {
        let causal = exchange.causalOffset
        let spread = assumptions.maximumRelativeRate * exchange.roundTrip / 2 + assumptions.resolutionAllowance

        return OffsetBound(
            at: exchange.midpoint,
            offset: ClockOffset(lower: causal.lower - spread, upper: causal.upper + spread)
        )
    }

    /// Takes an exchange in. Returns the violation it reveals, if any.
    @discardableResult
    mutating func add(_ exchange: SyncExchange) -> SyncViolation? {
        guard violation == nil else { return violation }

        if let found = Self.check(exchange, against: self) {
            violation = found
            return found
        }

        let bound = bound(for: exchange)
        let index = bounds.firstIndex { $0.at > bound.at } ?? bounds.endIndex
        bounds.insert(bound, at: index)
        exchanges.insert(exchange, at: index)

        updateRateAnchor(with: exchange)
        prune()

        if let disagreement = firstDisagreement() {
            violation = .boundsDisagree(at: disagreement)
        } else if let rate, rate.lower > assumptions.maximumRelativeRate || rate.upper < -assumptions.maximumRelativeRate {
            violation = .rateBeyondAssumption(rate)
        }

        return violation
    }

    /// Forgets everything, e.g. after a violation or when a clock was
    /// restarted (a reboot, or a sleep that stopped the host clock).
    mutating func reset() {
        exchanges = []
        bounds = []
        violation = nil
        rateAnchor = nil
        anchorStretchEnd = nil
    }

    /// The offset at a local instant. Nil before the first exchange and
    /// after a violation.
    func offset(at time: MonotonicTimestamp) -> ClockOffset? {
        mapping?.offset(at: time)
    }

    /// The conversion as it stands now, to be handed on. Nil before the
    /// first exchange and after a violation.
    var mapping: ClockMapping? {
        guard violation == nil, !bounds.isEmpty else { return nil }

        return ClockMapping(assumptions: assumptions, bounds: bounds)
    }

    /// The measured relative rate, once two exchanges are apart in time.
    var rate: RateEstimate? {
        guard let rateAnchor, let latest = narrowest(in: recentStretch) else { return nil }

        return RateEstimate.between(rateAnchor, latest, resolutionAllowance: assumptions.resolutionAllowance)
    }

    // MARK: - Checks

    private static func check(_ exchange: SyncExchange, against estimator: ClockSyncEstimator) -> SyncViolation? {
        if exchange.replyReceived < exchange.requestSent {
            return .localClockWentBack
        }
        if exchange.replySent < exchange.requestReceived {
            return .remoteClockWentBack
        }

        let offset = estimator.bound(for: exchange).offset
        if offset.lower > offset.upper {
            return .holdLongerThanRoundTrip
        }

        return nil
    }

    /// The forward pass of theorem 4: the offsets that fit every exchange
    /// up to one, carried to the next by the rate bound. Empty means no
    /// trajectory fits; returns the midpoint where it became empty.
    private func firstDisagreement() -> MonotonicTimestamp? {
        guard var feasible = bounds.first.map({ $0.offset }) else { return nil }
        var at = bounds[0].at

        for bound in bounds.dropFirst() {
            let carried = OffsetBound(at: at, offset: feasible).aged(to: bound.at, maximumRate: assumptions.maximumRelativeRate)
            let lower = max(carried.lower, bound.offset.lower)
            let upper = min(carried.upper, bound.offset.upper)

            guard lower <= upper else { return bound.at }

            feasible = ClockOffset(lower: lower, upper: upper)
            at = bound.at
        }

        return nil
    }

    // MARK: - Keeping

    private var recentStretch: ArraySlice<SyncExchange> {
        guard let newest = exchanges.last?.midpoint else { return [] }

        let start = exchanges.firstIndex { $0.midpoint.seconds >= newest.seconds - Self.rateAnchorStretch } ?? exchanges.endIndex
        return exchanges[start...]
    }

    private func narrowest(in exchanges: ArraySlice<SyncExchange>) -> SyncExchange? {
        exchanges.min { width(of: $0) < width(of: $1) }
    }

    private func width(of exchange: SyncExchange) -> TimeInterval {
        exchange.roundTrip - exchange.remoteHold
    }

    private mutating func updateRateAnchor(with exchange: SyncExchange) {
        if anchorStretchEnd == nil {
            anchorStretchEnd = MonotonicTimestamp(seconds: exchange.midpoint.seconds + Self.rateAnchorStretch)
        }

        guard let anchorStretchEnd, exchange.midpoint <= anchorStretchEnd else { return }

        if rateAnchor.map({ width(of: exchange) < width(of: $0) }) ?? true {
            rateAnchor = exchange
        }
    }

    private mutating func prune() {
        guard let newest = bounds.last?.at else { return }

        let oldestKept = newest.seconds - Self.retention
        let tooOld = bounds.prefix { $0.at.seconds < oldestKept }.count
        let tooMany = max(0, bounds.count - Self.maximumExchanges)
        let drop = max(tooOld, tooMany)

        guard drop > 0 else { return }

        bounds.removeFirst(drop)
        exchanges.removeFirst(drop)
    }
}

/// Converts times between the two clocks as one snapshot of the
/// synchronization. Every result is widened by exactly the bound, so
/// whoever uses it carries the synchronization's error without knowing
/// about it.
nonisolated struct ClockMapping: Equatable, Codable, Sendable {
    let assumptions: ClockSyncAssumptions
    /// Sorted by local time, never empty.
    let bounds: [OffsetBound]

    /// Remote − local at a local instant: every bound aged to it,
    /// intersected (theorem 2).
    func offset(at time: MonotonicTimestamp) -> ClockOffset {
        var lower = -Double.infinity
        var upper = Double.infinity

        for bound in bounds {
            let aged = bound.aged(to: time, maximumRate: assumptions.maximumRelativeRate)
            lower = max(lower, aged.lower)
            upper = min(upper, aged.upper)
        }

        // Only if the bounds contradict each other, which the estimator
        // rules out before it hands a mapping on.
        if lower > upper {
            let middle = (lower + upper) / 2
            return ClockOffset(lower: middle, upper: middle)
        }

        return ClockOffset(lower: lower, upper: upper)
    }

    /// Where the newest exchange was taken, on the local clock.
    var newest: MonotonicTimestamp {
        bounds[bounds.count - 1].at
    }

    /// The local time at which the remote clock read `remote`.
    ///
    /// The offset is wanted at that local time, which is what is being
    /// computed. Taken at a first guess instead, it can be off by the rate
    /// bound times the distance to the answer, which is at most the
    /// interval's width over (1 − rate): that much more is added.
    func localTime(forRemote remote: MonotonicTimestamp) -> TimeEstimate {
        let rate = assumptions.maximumRelativeRate
        let firstGuess = MonotonicTimestamp(seconds: remote.seconds - offset(at: newest).best)
        let estimate = offset(at: firstGuess)
        let guess = MonotonicTimestamp(seconds: remote.seconds - estimate.best)
        let offset = offset(at: guess)

        let distance = max(abs(guess.seconds - (remote.seconds - offset.upper)), abs(guess.seconds - (remote.seconds - offset.lower))) / (1 - rate)
        let spread = rate * distance + assumptions.resolutionAllowance

        let earliest = remote.seconds - offset.upper - spread
        let latest = remote.seconds - offset.lower + spread
        let best = min(max(remote.seconds - offset.best, earliest), latest)

        return TimeEstimate(
            best: MonotonicTimestamp(seconds: best),
            earliest: MonotonicTimestamp(seconds: earliest),
            latest: MonotonicTimestamp(seconds: latest)
        )
    }

    /// A time the remote measured, as an interval on the local clock: the
    /// remote's own uncertainty and the synchronization's, added.
    func localEstimate(forRemote estimate: TimeEstimate) -> TimeEstimate {
        let earliest = localTime(forRemote: estimate.earliest).earliest
        let latest = localTime(forRemote: estimate.latest).latest
        let best = min(max(localTime(forRemote: estimate.best).best, earliest), latest)

        return TimeEstimate(best: best, earliest: earliest, latest: latest)
    }

    /// The remote time at which the local clock reads `local`, for telling
    /// the remote when to do something.
    func remoteTime(forLocal local: MonotonicTimestamp) -> TimeEstimate {
        let offset = offset(at: local)
        let allowance = assumptions.resolutionAllowance

        return TimeEstimate(
            best: MonotonicTimestamp(seconds: local.seconds + offset.best),
            earliest: MonotonicTimestamp(seconds: local.seconds + offset.lower - allowance),
            latest: MonotonicTimestamp(seconds: local.seconds + offset.upper + allowance)
        )
    }

    /// A duration the remote measured on its own clock, on the local one:
    /// the clocks may run apart by the rate bound over it.
    func localDuration(forRemote duration: DurationEstimate) -> DurationEstimate {
        let rate = assumptions.maximumRelativeRate
        let allowance = 2 * assumptions.resolutionAllowance

        func range(_ seconds: TimeInterval) -> (TimeInterval, TimeInterval) {
            let a = seconds / (1 + rate)
            let b = seconds / (1 - rate)
            return (min(a, b), max(a, b))
        }

        let earliest = range(duration.earliest).0 - allowance
        let latest = range(duration.latest).1 + allowance

        return DurationEstimate(best: min(max(duration.best, earliest), latest), earliest: earliest, latest: latest)
    }
}
