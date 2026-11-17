//
//  NodeSession.swift
//  OnYourMarks
//
//  The other phones: which are around, which are paired, and how well
//  each one's clock is known.
//

import Foundation
import Observation
import OSLog
import QuartzCore
import UIKit

/// Another phone, as far as this one knows it.
struct NodePeer: Identifiable {
    let id: NodeID
    var name: String
    var role: NodeRole?
    var isPaired: Bool
    /// Advertising, or heard from, since the session started.
    var isReachable: Bool

    var estimator = ClockSyncEstimator()
    /// The epochs the estimator's exchanges belong to.
    var epochs: ClockEpochPair?

    /// Newest last, at most `NodeSession.keptSamples`.
    var roundTrips: [TimeInterval] = []
    /// The offset interval's width right after each exchange.
    var widths: [TimeInterval] = []
    /// How much later the app stamped a reply than the kernel saw it.
    var kernelLeads: [TimeInterval] = []
    var counts = SyncCounts()

    var violationCount = 0
    var lastViolation: SyncViolation?
    /// Times a clock was found restarted (reboot or sleep).
    var restartCount = 0
    /// After a violation, no mapping is given out before this.
    var trustedFrom: MonotonicTimestamp?
    var lastExchange: MonotonicTimestamp?
}

struct ClockEpochPair: Equatable {
    let local: ClockEpoch
    let remote: ClockEpoch
}

@Observable
final class NodeSession {
    private(set) var identity: NodeIdentity
    private(set) var peers: [NodeID: NodePeer] = [:]
    private(set) var transportState = TransportState.stopped
    /// Phones that speak another protocol version, by address.
    private(set) var incompatibleCount = 0

    var isRunning: Bool {
        link != nil
    }

    /// Ten exchanges a second: between two of them a bound ages by
    /// 2 × 200 ppm × 0.1 s = 40 µs, and a hundred bytes ten times a second
    /// cost the radio nothing.
    static let syncInterval: TimeInterval = 0.1

    /// Round trips kept for the statistics, ten seconds of them.
    static let keptSamples = 100

    /// After a violation the exchanges have to agree for this long before
    /// the clock counts as known again: whatever broke the assumption may
    /// still be going on.
    static let quarantine: TimeInterval = 10

    private let store: NodeStore
    private let clock: MonotonicClock
    private let makeTransport: () -> any DatagramTransport
    private let linkClock: @Sendable () -> MonotonicTimestamp
    private let epoch: @Sendable () -> ClockEpoch

    private var link: NodeLink?
    private var listening: Task<Void, Never>?
    private var syncing: Task<Void, Never>?

    @ObservationIgnored
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks", category: "Sync")

    init(
        store: NodeStore = NodeStore(),
        clock: MonotonicClock = SystemMonotonicClock(),
        defaultName: String = UIDevice.current.name,
        makeTransport: @escaping () -> any DatagramTransport = { NetworkNodeTransport() },
        linkClock: @escaping @Sendable () -> MonotonicTimestamp = NodeSession.hostClock,
        epoch: @escaping @Sendable () -> ClockEpoch = { ClockEpoch.current() }
    ) {
        self.store = store
        self.clock = clock
        self.makeTransport = makeTransport
        self.linkClock = linkClock
        self.epoch = epoch
        identity = store.loadIdentity(defaultName: defaultName)

        for paired in store.loadPaired() {
            peers[paired.id] = NodePeer(id: paired.id, name: paired.name, isPaired: true, isReachable: false)
        }
    }

    isolated deinit {
        listening?.cancel()
        syncing?.cancel()
        link?.stop()
    }

    /// The host clock, read off the main actor.
    nonisolated static func hostClock() -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: CACurrentMediaTime())
    }

    var announcement: NodeAnnouncement {
        NodeAnnouncement(id: identity.id, name: identity.name, role: identity.role)
    }

    var sortedPeers: [NodePeer] {
        peers.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: - Running

    /// Advertises this phone, looks for others and keeps the paired ones'
    /// clocks synchronized.
    func start() {
        guard link == nil else { return }

        let link = NodeLink(announcement: announcement, transport: makeTransport(), now: linkClock, epoch: epoch)
        self.link = link
        transportState = .starting

        listening = Task { [weak self] in
            for await event in link.events {
                self?.handle(event)
            }
        }

        syncing = Task { [weak self] in
            await self?.runSync()
        }

        link.start()
    }

    func stop() {
        listening?.cancel()
        syncing?.cancel()
        link?.stop()
        listening = nil
        syncing = nil
        link = nil
        transportState = .stopped

        for id in peers.keys {
            peers[id]?.isReachable = false
        }
        peers = peers.filter { $0.value.isPaired }
    }

    /// A new name or role is announced from the next start.
    func update(name: String, role: NodeRole) {
        identity.name = name
        identity.role = role
        store.save(identity)

        if isRunning {
            stop()
            start()
        }
    }

    func pair(_ id: NodeID) {
        peers[id]?.isPaired = true
        savePaired()
    }

    func unpair(_ id: NodeID) {
        guard var peer = peers[id] else { return }

        peer.isPaired = false
        peer.estimator.reset()
        peer.epochs = nil
        peers[id] = peer.isReachable ? peer : nil
        savePaired()
    }

    private func savePaired() {
        store.save(peers.values.filter(\.isPaired).map { PairedNode(id: $0.id, name: $0.name) }.sorted { $0.id < $1.id })
    }

    private func runSync() async {
        var next = clock.now()

        while !Task.isCancelled {
            if let link {
                for peer in peers.values where peer.isPaired && peer.isReachable {
                    link.requestSync(with: peer.id)
                    peers[peer.id]?.counts = link.counts(for: peer.id)
                }
            }

            next = MonotonicTimestamp(seconds: next.seconds + Self.syncInterval)
            await clock.sleep(until: next)
        }
    }

    // MARK: - Events

    private func handle(_ event: NodeLinkEvent) {
        switch event {
        case .transportChanged(let state):
            transportState = state

        case .found(let found):
            var peer = peers[found.id] ?? NodePeer(id: found.id, name: found.name, isPaired: false, isReachable: true)
            peer.name = found.name
            peer.role = found.role
            peer.isReachable = true
            peers[found.id] = peer

            if peer.isPaired {
                savePaired()
            }

        case .lost(let id):
            peers[id]?.isReachable = false

        case .synchronized(let id, let sample):
            take(sample, from: id)

        case .received:
            break

        case .incompatible:
            incompatibleCount += 1
        }
    }

    private func take(_ sample: SyncSample, from id: NodeID) {
        guard var peer = peers[id], peer.isPaired else { return }

        let epochs = ClockEpochPair(local: sample.localEpoch, remote: sample.remoteEpoch)
        if let known = peer.epochs, !(known.local.isSameClock(as: epochs.local) && known.remote.isSameClock(as: epochs.remote)) {
            logger.notice("Clock of \(peer.name, privacy: .public) or this phone restarted; synchronization starts over")
            peer.estimator.reset()
            peer.restartCount += 1
        }
        peer.epochs = epochs

        if let violation = peer.estimator.add(sample.exchange) {
            logger.error("Synchronization with \(peer.name, privacy: .public) violated its assumptions: \(String(describing: violation), privacy: .public)")
            peer.violationCount += 1
            peer.lastViolation = violation
            peer.estimator.reset()
            peer.trustedFrom = MonotonicTimestamp(seconds: sample.exchange.replyReceived.seconds + Self.quarantine)
        }

        peer.roundTrips = Array((peer.roundTrips + [sample.exchange.roundTrip]).suffix(Self.keptSamples))
        if let offset = peer.estimator.offset(at: sample.exchange.replyReceived) {
            peer.widths = Array((peer.widths + [offset.width]).suffix(Self.keptSamples))
        }
        if let lead = sample.replyKernelLead {
            peer.kernelLeads = Array((peer.kernelLeads + [lead]).suffix(Self.keptSamples))
        }
        peer.lastExchange = sample.exchange.replyReceived
        if let link {
            peer.counts = link.counts(for: id)
        }

        peers[id] = peer
    }

    // MARK: - Reading

    /// How to convert the phone's times into this one's, or nil while its
    /// clock is not known (no exchange yet, or within the quarantine after
    /// a violation).
    func mapping(for id: NodeID) -> ClockMapping? {
        guard let peer = peers[id], let mapping = peer.estimator.mapping else { return nil }

        if let trustedFrom = peer.trustedFrom, mapping.newest < trustedFrom {
            return nil
        }
        return mapping
    }

    /// The offset interval now, on the host clock.
    func offset(for id: NodeID) -> ClockOffset? {
        mapping(for: id)?.offset(at: linkClock())
    }
}
