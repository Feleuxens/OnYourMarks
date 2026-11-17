//
//  SyncProtocol.swift
//  OnYourMarks
//

import Darwin
import Foundation

/// Asks the remote for its clock. Its own send time stays at home: the
/// remote is not trusted to echo it.
nonisolated struct SyncRequest: Equatable, Codable, Sendable {
    /// Random, so that a reply can only belong to this request.
    let nonce: UInt64
}

nonisolated struct SyncReply: Equatable, Codable, Sendable {
    let nonce: UInt64
    /// t2 on the replying clock.
    let requestReceived: MonotonicTimestamp
    /// t3 on the replying clock.
    let replySent: MonotonicTimestamp
}

/// The asking side of the exchange for one remote: remembers when each
/// request left and pairs replies with them.
///
/// Losses, duplicates and reordering need no special care for the bound:
/// whichever copy of a reply comes first was sent after its request was,
/// and a reply nobody asked for (an unknown or used nonce) is dropped.
nonisolated struct SyncInitiator: Sendable {
    /// A reply later than this is not waited for: its interval would be
    /// more than a second wide, a thousand times a usual one.
    static let replyTimeout: TimeInterval = 1

    private var pending: [UInt64: (sent: MonotonicTimestamp, epoch: ClockEpoch)] = [:]
    private(set) var sentCount = 0
    private(set) var lostCount = 0
    /// Replies to no pending request: duplicates, or late after a timeout.
    private(set) var unmatchedCount = 0
    /// Exchanges dropped because the local clock stopped during them.
    private(set) var interruptedCount = 0

    /// To be called before the request is handed to the network, with a
    /// time stamped then. A stamp taken earlier only widens the bound.
    mutating func register(_ request: SyncRequest, sentAt time: MonotonicTimestamp, epoch: ClockEpoch) {
        pending[request.nonce] = (time, epoch)
        sentCount += 1
    }

    /// Pairs a reply with its request.
    ///
    /// - Parameters:
    ///   - time: stamped after the reply arrived.
    ///   - epoch: the local clock's epoch read then; if it changed since
    ///     the request left, the clock stood still in between and the
    ///     exchange says nothing.
    mutating func complete(_ reply: SyncReply, receivedAt time: MonotonicTimestamp, epoch: ClockEpoch) -> SyncExchange? {
        guard let request = pending.removeValue(forKey: reply.nonce) else {
            unmatchedCount += 1
            return nil
        }

        guard request.epoch.isSameClock(as: epoch) else {
            interruptedCount += 1
            return nil
        }

        return SyncExchange(
            requestSent: request.sent,
            requestReceived: reply.requestReceived,
            replySent: reply.replySent,
            replyReceived: time
        )
    }

    /// Gives up on requests older than the timeout.
    mutating func expire(now: MonotonicTimestamp) {
        let expired = pending.filter { now.seconds - $0.value.sent.seconds > Self.replyTimeout }.keys

        for nonce in expired {
            pending.removeValue(forKey: nonce)
        }

        lostCount += expired.count
    }
}

/// Which run of a host clock a reading belongs to.
///
/// The host clock (`mach_absolute_time`, `CACurrentMediaTime`) starts at
/// zero when the phone boots and stands still while it sleeps. Readings
/// from different runs can't be compared by an offset and a rate; when
/// either side's epoch changes, the synchronization starts over.
nonisolated struct ClockEpoch: Equatable, Codable, Sendable {
    /// Changes with every boot.
    let bootSession: String

    /// How long the system slept since it booted, from the difference of
    /// the continuous clock (which counts sleep) and the host clock (which
    /// doesn't). It is constant while the system is awake; the read
    /// brackets it.
    let sleptAtLeast: TimeInterval
    let sleptAtMost: TimeInterval

    /// Different if the brackets don't overlap. A pause shorter than the
    /// brackets' width (a few hundred nanoseconds) would go unseen; no
    /// sleep is that short, and the resolution allowance covers it.
    func isSameClock(as other: ClockEpoch) -> Bool {
        bootSession == other.bootSession && sleptAtLeast <= other.sleptAtMost && other.sleptAtLeast <= sleptAtMost
    }

    /// Reads that took longer than this are tried again: preempted.
    private static let widestRead: TimeInterval = 1e-6
    private static let readAttempts = 8

    static func current() -> ClockEpoch {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9

        var best: (lower: Double, upper: Double)?

        for _ in 0..<readAttempts {
            let before = mach_absolute_time()
            let continuous = mach_continuous_time()
            let after = mach_absolute_time()

            let lower = Double(Int64(bitPattern: continuous &- after)) * secondsPerTick
            let upper = Double(Int64(bitPattern: continuous &- before)) * secondsPerTick

            if best.map({ upper - lower < $0.upper - $0.lower }) ?? true {
                best = (lower, upper)
            }
            if upper - lower <= widestRead {
                break
            }
        }

        return ClockEpoch(bootSession: bootSessionID, sleptAtLeast: best?.lower ?? 0, sleptAtMost: best?.upper ?? 0)
    }

    private static let bootSessionID: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }

        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}
