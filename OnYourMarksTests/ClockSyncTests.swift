//
//  ClockSyncTests.swift
//  OnYourMarks
//
//  The clock synchronization against simulated clocks and networks whose
//  truth is known: the true offset must lie inside every interval the
//  estimator gives while the assumptions hold, and a broken assumption
//  must be reported.
//

import Foundation
import Testing
@testable import OnYourMarks

/// Deterministic, so a failing seed can be run again.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A remote clock against the local one. The local clock is the
/// reference: local time is true time here, which loses nothing because
/// only the relation between the two clocks matters.
nonisolated struct SimulatedClockPair: Sendable {
    /// remote − local at local time `start`.
    let initialOffset: TimeInterval
    /// The steady part of d(remote − local)/d(local).
    let rate: Double
    /// A wobble of the rate on top: amplitude of the offset and its
    /// angular frequency, so the rate wanders by amplitude × frequency.
    let wobble: TimeInterval
    let wobbleFrequency: Double
    /// Added to the remote clock from this local time on, to simulate a
    /// clock that jumps.
    var jump: (at: TimeInterval, by: TimeInterval)?

    static let start: TimeInterval = 5_000

    /// The largest |d offset / d local|.
    var maximumRate: Double {
        abs(rate) + wobble * wobbleFrequency
    }

    func offset(at local: TimeInterval) -> TimeInterval {
        var offset = initialOffset + rate * (local - Self.start) + wobble * sin(wobbleFrequency * (local - Self.start))
        if let jump, local >= jump.at {
            offset += jump.by
        }
        return offset
    }

    func remote(at local: TimeInterval) -> TimeInterval {
        local + offset(at: local)
    }
}

/// How the network treats datagrams, by direction.
nonisolated enum DelayModel: CaseIterable, Sendable, CustomStringConvertible {
    /// Mostly a few milliseconds, a long tail, sometimes very fast.
    case typical
    /// The way out is always fast, the way back always slow: the case a
    /// symmetric estimate gets wrong by half the difference.
    case asymmetric
    /// Like asymmetric, but the slow direction flips every few seconds.
    case flippingAsymmetry
    /// Calm with bursts of delay spikes of up to 200 ms.
    case spiky

    var description: String {
        switch self {
        case .typical: "typical"
        case .asymmetric: "asymmetric"
        case .flippingAsymmetry: "flippingAsymmetry"
        case .spiky: "spiky"
        }
    }

    func delay(outbound: Bool, at time: TimeInterval, using random: inout SeededGenerator) -> TimeInterval {
        switch self {
        case .typical:
            if Double.random(in: 0..<1, using: &random) < 0.1 {
                return Double.random(in: 0.000_2...0.000_5, using: &random)
            }
            return 0.001 - 0.004 * log(Double.random(in: 0.000_1..<1, using: &random))
        case .asymmetric:
            return outbound
                ? Double.random(in: 0.000_1...0.000_3, using: &random)
                : Double.random(in: 0.030...0.045, using: &random)
        case .flippingAsymmetry:
            let slowOut = Int((time - SimulatedClockPair.start) / 3).isMultiple(of: 2)
            return outbound == slowOut
                ? Double.random(in: 0.020...0.060, using: &random)
                : Double.random(in: 0.000_1...0.001, using: &random)
        case .spiky:
            if Double.random(in: 0..<1, using: &random) < 0.05 {
                return Double.random(in: 0.050...0.200, using: &random)
            }
            return Double.random(in: 0.000_5...0.003, using: &random)
        }
    }
}

/// Request and reply flowing through a lossy, duplicating, reordering
/// network between two clocks, with stamps taken late in the app as on a
/// phone. Uses the app's own initiator and estimator.
nonisolated struct SyncSimulation {
    var clocks: SimulatedClockPair
    var delays: DelayModel
    var lossRate = 0.1
    var duplicationRate = 0.05
    var assumptions = ClockSyncAssumptions.standard

    var estimator: ClockSyncEstimator
    var initiator = SyncInitiator()
    var random: SeededGenerator
    var exchanges: [SyncExchange] = []
    var violation: SyncViolation?
    /// Local time of the first violation.
    var violationTime: TimeInterval?

    private let epoch = ClockEpoch(bootSession: "simulated", sleptAtLeast: 0, sleptAtMost: 0)

    init(clocks: SimulatedClockPair, delays: DelayModel, seed: UInt64) {
        self.clocks = clocks
        self.delays = delays
        self.random = SeededGenerator(seed: seed)
        self.estimator = ClockSyncEstimator(assumptions: assumptions)
    }

    private enum Arrival {
        case request(nonce: UInt64)
        case reply(SyncReply)
    }

    /// A stamp taken in the app comes this much after the network event
    /// (or, for a send, this much before): scheduling, the debugger.
    private mutating func appLag() -> TimeInterval {
        Double.random(in: 0..<1, using: &random) < 0.02
            ? Double.random(in: 0.01...0.3, using: &random)
            : Double.random(in: 0...0.000_3, using: &random)
    }

    /// Runs `duration` seconds of local time with a request every
    /// `interval`; `check` is called after every exchange taken in.
    mutating func run(for duration: TimeInterval, interval: TimeInterval = 0.1, check: (inout SyncSimulation, SyncExchange) -> Void = { _, _ in }) {
        var queue: [(time: TimeInterval, arrival: Arrival)] = []
        var nextRequest = SimulatedClockPair.start
        let end = SimulatedClockPair.start + duration

        func schedule(_ arrival: Arrival, at time: TimeInterval, outbound: Bool, in simulation: inout SyncSimulation) {
            guard Double.random(in: 0..<1, using: &simulation.random) >= simulation.lossRate else { return }

            let first = time + simulation.delays.delay(outbound: outbound, at: time, using: &simulation.random)
            queue.append((first, arrival))

            if Double.random(in: 0..<1, using: &simulation.random) < simulation.duplicationRate {
                queue.append((first + Double.random(in: 0...0.05, using: &simulation.random), arrival))
            }
        }

        while nextRequest < end || !queue.isEmpty {
            let nextArrival = queue.indices.min { queue[$0].time < queue[$1].time }

            if let index = nextArrival, queue[index].time <= nextRequest || nextRequest >= end {
                let (time, arrival) = queue.remove(at: index)

                switch arrival {
                case .request(let nonce):
                    let received = time + appLag()
                    let replied = received + Double.random(in: 0...0.002, using: &random)
                    let departs = replied + appLag()
                    let reply = SyncReply(
                        nonce: nonce,
                        requestReceived: MonotonicTimestamp(seconds: clocks.remote(at: received)),
                        replySent: MonotonicTimestamp(seconds: clocks.remote(at: replied))
                    )
                    schedule(.reply(reply), at: departs, outbound: false, in: &self)

                case .reply(let reply):
                    let stamped = MonotonicTimestamp(seconds: time + appLag())
                    guard let exchange = initiator.complete(reply, receivedAt: stamped, epoch: epoch) else { continue }

                    exchanges.append(exchange)
                    if let found = estimator.add(exchange), violation == nil {
                        violation = found
                        violationTime = stamped.seconds
                    }
                    check(&self, exchange)
                }
            } else {
                let stamped = nextRequest
                let departs = stamped + appLag()
                let request = SyncRequest(nonce: UInt64.random(in: .min ... .max, using: &random))

                initiator.expire(now: MonotonicTimestamp(seconds: stamped))
                initiator.register(request, sentAt: MonotonicTimestamp(seconds: stamped), epoch: epoch)
                schedule(.request(nonce: request.nonce), at: departs, outbound: true, in: &self)

                nextRequest += interval
            }
        }
    }
}

struct ClockSyncTests {
    static let seeds: [UInt64] = Array(1...12)

    private static func clocks(seed: UInt64, rateShare: Double) -> SimulatedClockPair {
        var random = SeededGenerator(seed: seed &* 7919)
        let bound = ClockSyncAssumptions.standard.maximumRelativeRate * rateShare
        let wobbleFrequency = 2 * Double.pi / 20
        let wobble = bound * 0.2 / wobbleFrequency

        return SimulatedClockPair(
            initialOffset: Double.random(in: -2_000...2_000, using: &random),
            rate: Double.random(in: -0.8...0.8, using: &random) * bound,
            wobble: wobble,
            wobbleFrequency: wobbleFrequency
        )
    }

    // MARK: - Soundness

    /// Theorem 1 on its own: one exchange, no rate bound needed.
    @Test
    func oneExchangeHoldsTheOffsetWhateverTheDelays() {
        var random = SeededGenerator(seed: 42)

        for _ in 0..<10_000 {
            let offset = Double.random(in: -1_000...1_000, using: &random)
            let sent = Double.random(in: 1_000...2_000, using: &random)
            let arrives = sent + Double.random(in: 0...0.2, using: &random)
            let replies = arrives + Double.random(in: 0...0.01, using: &random)
            let returns = replies + Double.random(in: 0...0.2, using: &random)

            let exchange = SyncExchange(
                requestSent: MonotonicTimestamp(seconds: sent),
                requestReceived: MonotonicTimestamp(seconds: arrives + offset),
                replySent: MonotonicTimestamp(seconds: replies + offset),
                replyReceived: MonotonicTimestamp(seconds: returns)
            )
            let bound = ClockSyncEstimator().bound(for: exchange).offset

            #expect(bound.contains(offset))
        }
    }

    @Test(arguments: DelayModel.allCases)
    func theTrueOffsetIsAlwaysInside(delays: DelayModel) {
        for seed in Self.seeds {
            let clocks = Self.clocks(seed: seed, rateShare: 1)
            #expect(clocks.maximumRate <= ClockSyncAssumptions.standard.maximumRelativeRate)

            var simulation = SyncSimulation(clocks: clocks, delays: delays, seed: seed)
            var misses = 0

            simulation.run(for: 60) { simulation, exchange in
                guard let mapping = simulation.estimator.mapping else { return }

                // Now, a moment ago, and a little ahead.
                for local in [exchange.replyReceived.seconds, exchange.requestSent.seconds - 0.7, exchange.replyReceived.seconds + 0.3] {
                    let offset = mapping.offset(at: MonotonicTimestamp(seconds: local))
                    if !offset.contains(clocks.offset(at: local)) {
                        misses += 1
                    }
                }
            }

            #expect(simulation.violation == nil, "seed \(seed)")
            #expect(misses == 0, "seed \(seed)")
            #expect(simulation.exchanges.count > 300, "seed \(seed)")
        }
    }

    @Test(arguments: DelayModel.allCases)
    func remoteTimesConvertIntoIntervalsThatHoldTheTruth(delays: DelayModel) {
        for seed in Self.seeds {
            let clocks = Self.clocks(seed: seed, rateShare: 1)
            var simulation = SyncSimulation(clocks: clocks, delays: delays, seed: seed)
            var random = SeededGenerator(seed: seed &+ 99)
            var checked = 0

            simulation.run(for: 30) { simulation, exchange in
                guard let mapping = simulation.estimator.mapping else { return }

                // A remote event from somewhere in the last two seconds,
                // measured on the remote clock with an uncertainty of its own.
                let local = exchange.replyReceived.seconds - Double.random(in: 0...2, using: &random)
                let reading = clocks.remote(at: local)
                let spread = Double.random(in: 0...0.01, using: &random)
                let remote = TimeEstimate(
                    best: MonotonicTimestamp(seconds: reading),
                    earliest: MonotonicTimestamp(seconds: reading - spread),
                    latest: MonotonicTimestamp(seconds: reading + spread)
                )

                let converted = mapping.localEstimate(forRemote: remote)
                #expect(converted.earliest.seconds <= local && local <= converted.latest.seconds, "seed \(seed)")

                let back = mapping.remoteTime(forLocal: MonotonicTimestamp(seconds: local))
                #expect(back.earliest.seconds <= reading && reading <= back.latest.seconds, "seed \(seed)")

                let duration = Double.random(in: 0...5, using: &random)
                let remoteDuration = clocks.remote(at: local + duration) - clocks.remote(at: local)
                let localDuration = mapping.localDuration(forRemote: .exact(remoteDuration))
                #expect(localDuration.earliest <= duration && duration <= localDuration.latest, "seed \(seed)")

                checked += 1
            }

            #expect(checked > 100)
        }
    }

    /// The clocks agree; whatever the network does, the bound is narrower
    /// than the slow direction would make a symmetric estimate wrong.
    @Test
    func asymmetryOnlyWidensTheInterval() throws {
        let clocks = SimulatedClockPair(initialOffset: 12.5, rate: 0, wobble: 0, wobbleFrequency: 0)
        var simulation = SyncSimulation(clocks: clocks, delays: .asymmetric, seed: 7)
        simulation.lossRate = 0
        simulation.duplicationRate = 0
        simulation.run(for: 10)

        let mapping = try #require(simulation.estimator.mapping)
        let offset = mapping.offset(at: mapping.newest)

        #expect(offset.contains(12.5))
        // A symmetric estimate (midpoint of one exchange) is off by half
        // the asymmetry, over 15 ms here; the interval says so instead.
        let exchange = try #require(simulation.exchanges.last)
        let symmetric = (exchange.causalOffset.lower + exchange.causalOffset.upper) / 2
        #expect(abs(symmetric - 12.5) > 0.015)
        #expect(offset.width > abs(symmetric - 12.5))
    }

    // MARK: - Detection

    @Test(arguments: [1.5, 3, 10])
    func aDriftBeyondTheBoundIsDetected(times: Double) {
        for seed in Self.seeds {
            let bound = ClockSyncAssumptions.standard.maximumRelativeRate
            let clocks = SimulatedClockPair(initialOffset: 300, rate: (seed.isMultiple(of: 2) ? 1 : -1) * times * bound, wobble: 0, wobbleFrequency: 0)
            var simulation = SyncSimulation(clocks: clocks, delays: .typical, seed: seed)

            simulation.run(for: 120)

            #expect(simulation.violation != nil, "seed \(seed), \(times) × the bound")
        }
    }

    @Test
    func aClockThatJumpsIsDetected() {
        for seed in Self.seeds {
            var clocks = SimulatedClockPair(initialOffset: -40, rate: 0, wobble: 0, wobbleFrequency: 0)
            clocks.jump = (SimulatedClockPair.start + 20, 0.02)
            var simulation = SyncSimulation(clocks: clocks, delays: .typical, seed: seed)

            simulation.run(for: 40)

            let time = simulation.violationTime ?? .infinity
            #expect(time > SimulatedClockPair.start + 20, "seed \(seed)")
            #expect(time < SimulatedClockPair.start + 25, "seed \(seed)")
        }
    }

    @Test
    func noOffsetIsGivenOutAfterAViolationUntilReset() {
        let clocks = SimulatedClockPair(initialOffset: 1, rate: 0.01, wobble: 0, wobbleFrequency: 0)
        var simulation = SyncSimulation(clocks: clocks, delays: .typical, seed: 3)
        simulation.run(for: 10)

        #expect(simulation.violation != nil)
        #expect(simulation.estimator.mapping == nil)
        #expect(simulation.estimator.offset(at: MonotonicTimestamp(seconds: SimulatedClockPair.start)) == nil)

        simulation.estimator.reset()
        #expect(simulation.estimator.isEmpty)
        #expect(simulation.estimator.violation == nil)
    }

    @Test
    func clocksGoingBackAreViolations() {
        func exchange(_ t1: TimeInterval, _ t2: TimeInterval, _ t3: TimeInterval, _ t4: TimeInterval) -> SyncExchange {
            SyncExchange(
                requestSent: MonotonicTimestamp(seconds: t1),
                requestReceived: MonotonicTimestamp(seconds: t2),
                replySent: MonotonicTimestamp(seconds: t3),
                replyReceived: MonotonicTimestamp(seconds: t4)
            )
        }

        var estimator = ClockSyncEstimator()
        let localBack = estimator.add(exchange(10, 20, 20.001, 9.9))
        #expect(localBack == .localClockWentBack)

        estimator.reset()
        let remoteBack = estimator.add(exchange(10, 20, 19.9, 10.01))
        #expect(remoteBack == .remoteClockWentBack)

        estimator.reset()
        // Held for 50 ms in a round trip of 10 ms.
        let held = estimator.add(exchange(10, 20, 20.05, 10.01))
        #expect(held == .holdLongerThanRoundTrip)
    }

    // MARK: - Rate

    @Test
    func theMeasuredRateHoldsTheTrueOne() throws {
        for seed in Self.seeds {
            let rate = Double(Int(seed) - 6) * 15e-6
            let clocks = SimulatedClockPair(initialOffset: 0.5, rate: rate, wobble: 0, wobbleFrequency: 0)
            var simulation = SyncSimulation(clocks: clocks, delays: .typical, seed: seed)

            simulation.run(for: 100)

            let measured = try #require(simulation.estimator.rate)
            #expect(measured.lower <= rate && rate <= measured.upper, "seed \(seed)")
            // Fine enough to check the assumption with.
            #expect(measured.upper - measured.lower < ClockSyncAssumptions.standard.maximumRelativeRate / 2, "seed \(seed)")
        }
    }

    // MARK: - Intersection

    /// The intersection is never wider than the narrowest exchange of the
    /// last second, aged to now.
    @Test
    func intersectingNarrowsTheInterval() throws {
        let clocks = Self.clocks(seed: 5, rateShare: 1)
        var simulation = SyncSimulation(clocks: clocks, delays: .typical, seed: 5)
        simulation.run(for: 20)

        let mapping = try #require(simulation.estimator.mapping)
        let now = mapping.newest
        let rate = ClockSyncAssumptions.standard.maximumRelativeRate
        let recent = simulation.estimator.bounds.filter { now.seconds - $0.at.seconds <= 1 }
        let narrowest = try #require(recent.map { $0.aged(to: now, maximumRate: rate).width }.min())

        let widths = recent.map(\.offset.width).sorted()
        let median = widths[widths.count / 2]

        #expect(mapping.offset(at: now).width <= narrowest)
        #expect(mapping.offset(at: now).width < median / 2)
    }

    // MARK: - Initiator

    @Test
    func repliesArePairedOnceAndOnlyWithTheirRequest() throws {
        let epoch = ClockEpoch(bootSession: "a", sleptAtLeast: 1, sleptAtMost: 1.000_001)
        var initiator = SyncInitiator()
        initiator.register(SyncRequest(nonce: 7), sentAt: MonotonicTimestamp(seconds: 10), epoch: epoch)

        let reply = SyncReply(nonce: 7, requestReceived: MonotonicTimestamp(seconds: 50), replySent: MonotonicTimestamp(seconds: 50.001))

        let stranger = initiator.complete(SyncReply(nonce: 8, requestReceived: reply.requestReceived, replySent: reply.replySent), receivedAt: MonotonicTimestamp(seconds: 10.01), epoch: epoch)
        #expect(stranger == nil)

        let paired = initiator.complete(reply, receivedAt: MonotonicTimestamp(seconds: 10.01), epoch: epoch)
        let exchange = try #require(paired)
        #expect(exchange.requestSent == MonotonicTimestamp(seconds: 10))
        #expect(exchange.replyReceived == MonotonicTimestamp(seconds: 10.01))

        let duplicate = initiator.complete(reply, receivedAt: MonotonicTimestamp(seconds: 10.02), epoch: epoch)
        #expect(duplicate == nil)
        #expect(initiator.unmatchedCount == 2)
    }

    @Test
    func requestsWithoutReplyAreCountedLost() {
        let epoch = ClockEpoch(bootSession: "a", sleptAtLeast: 1, sleptAtMost: 1)
        var initiator = SyncInitiator()
        initiator.register(SyncRequest(nonce: 1), sentAt: MonotonicTimestamp(seconds: 10), epoch: epoch)
        initiator.register(SyncRequest(nonce: 2), sentAt: MonotonicTimestamp(seconds: 10.5), epoch: epoch)

        initiator.expire(now: MonotonicTimestamp(seconds: 10 + SyncInitiator.replyTimeout + 0.1))

        #expect(initiator.lostCount == 1)
        #expect(initiator.sentCount == 2)
    }

    @Test
    func anExchangeAcrossASleepIsDropped() {
        let before = ClockEpoch(bootSession: "a", sleptAtLeast: 1, sleptAtMost: 1.000_001)
        let after = ClockEpoch(bootSession: "a", sleptAtLeast: 31, sleptAtMost: 31.000_001)
        var initiator = SyncInitiator()
        initiator.register(SyncRequest(nonce: 1), sentAt: MonotonicTimestamp(seconds: 10), epoch: before)

        let reply = SyncReply(nonce: 1, requestReceived: MonotonicTimestamp(seconds: 5), replySent: MonotonicTimestamp(seconds: 5))
        let exchange = initiator.complete(reply, receivedAt: MonotonicTimestamp(seconds: 10.01), epoch: after)
        #expect(exchange == nil)
        #expect(initiator.interruptedCount == 1)
    }

    @Test
    func theEpochOfThisClockStaysWhileAwake() {
        let first = ClockEpoch.current()
        let second = ClockEpoch.current()

        #expect(first.isSameClock(as: second))
        #expect(!first.bootSession.isEmpty)
        #expect(first.sleptAtMost - first.sleptAtLeast < 0.001)
        #expect(!first.isSameClock(as: ClockEpoch(bootSession: first.bootSession, sleptAtLeast: first.sleptAtMost + 0.01, sleptAtMost: first.sleptAtMost + 0.01)))
        #expect(!first.isSameClock(as: ClockEpoch(bootSession: "another boot", sleptAtLeast: first.sleptAtLeast, sleptAtMost: first.sleptAtMost)))
    }
}
