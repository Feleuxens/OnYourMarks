//
//  NodeTests.swift
//  OnYourMarks
//
//  Phones talking to each other: over a simulated network with clocks
//  whose truth is known, over the real network stack in one process, and
//  (opt-in) between two devices.
//

import Foundation
import Testing
@testable import OnYourMarks

/// Collects what a link reports, on the main actor.
@MainActor
final class LinkEventLog {
    private(set) var found: [NodeAnnouncement] = []
    private(set) var samples: [(node: NodeID, sample: SyncSample)] = []
    private(set) var incompatible: [Int] = []
    private(set) var hellos = 0
    private var task: Task<Void, Never>?

    init(_ link: NodeLink) {
        task = Task { [weak self] in
            for await event in link.events {
                self?.take(event)
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }

    private func take(_ event: NodeLinkEvent) {
        switch event {
        case .found(let announcement):
            found.append(announcement)
        case .synchronized(let node, let sample):
            samples.append((node, sample))
        case .incompatible(_, let version):
            incompatible.append(version)
        case .received(_, .hello, _):
            hellos += 1
        default:
            break
        }
    }
}

private let fixedEpoch = ClockEpoch(bootSession: "test", sleptAtLeast: 0, sleptAtMost: 0)

private func link(_ transport: SimulatedTransport, on network: SimulatedNetwork, id: NodeID = NodeID(), role: NodeRole = .camera) -> NodeLink {
    NodeLink(
        announcement: NodeAnnouncement(id: id, name: transport.name, role: role),
        transport: transport,
        now: network.clock(of: transport.name),
        epoch: { fixedEpoch }
    )
}

@MainActor
struct NodeLinkTests {
    @Test
    func twoPhonesFindEachOtherAndHoldTheTrueOffset() async throws {
        let network = SimulatedNetwork()
        // One way fast, the other slow: the midpoint would be 14 ms off.
        network.setDelays(outbound: 0.001, inbound: 0.029)
        let a = link(network.addPhone("a"), on: network)
        let b = link(network.addPhone("b", offset: 1234.5678, rate: 80e-6), on: network)
        let log = LinkEventLog(a)

        a.start()
        b.start()
        await waitUntil { log.found.contains { $0.id == b.announcement.id } }

        var estimator = ClockSyncEstimator()
        for round in 1...50 {
            let requested = a.requestSync(with: b.announcement.id)
            #expect(requested)
            network.run(for: 0.1)
            await waitUntil { log.samples.count == round }

            if let sample = log.samples.last?.sample {
                let violation = estimator.add(sample.exchange)
                #expect(violation == nil)
            }
        }

        let offset = try #require(estimator.offset(at: network.reading(of: "a")))
        #expect(offset.contains(network.offset(of: "b", from: "a")))
        #expect(offset.width > 0.028)
        #expect(a.counts(for: b.announcement.id) == SyncCounts(sent: 50, lost: 0, unmatched: 0, interrupted: 0))
    }

    @Test
    func aPhoneIsGreetedWhenFound() async {
        let network = SimulatedNetwork()
        let a = link(network.addPhone("a"), on: network)
        let b = link(network.addPhone("b"), on: network)
        let log = LinkEventLog(b)

        a.start()
        b.start()
        network.run(for: 0.1)

        await waitUntil { log.hellos >= 1 }
        #expect(log.found.map { $0.name } == ["a"])
    }

    @Test
    func anotherVersionIsReportedAndNotAnswered() async throws {
        let network = SimulatedNetwork()
        let a = link(network.addPhone("a"), on: network)
        let log = LinkEventLog(a)
        a.start()

        let future = NodeEnvelope(sender: NodeID(), epoch: fixedEpoch, message: .syncRequest(SyncRequest(nonce: 1)), version: NodeProtocol.version + 1)
        a.handle(.received(ReceivedDatagram(data: try future.encoded(), from: PeerAddress(rawValue: "x"), receivedAt: MonotonicTimestamp(seconds: 1), kernelReceivedAt: nil)))
        a.handle(.received(ReceivedDatagram(data: Data("not a message".utf8), from: PeerAddress(rawValue: "x"), receivedAt: MonotonicTimestamp(seconds: 1), kernelReceivedAt: nil)))

        await waitUntil { log.incompatible == [NodeProtocol.version + 1] }
        #expect(log.samples.isEmpty)
    }

    @Test
    func aPhoneDoesNotFindItself() {
        let network = SimulatedNetwork()
        let transport = network.addPhone("a")
        let a = link(transport, on: network)
        a.start()

        a.handle(.peerFound(PeerAddress(rawValue: "a"), txtRecord: a.announcement.txtRecord))

        let requested = a.requestSync(with: a.announcement.id)
        #expect(!requested)
    }

    @Test
    func announcementsSurviveTheBonjourRecord() {
        let announcement = NodeAnnouncement(id: NodeID(), name: "Start line", role: .speaker)

        #expect(NodeAnnouncement(txtRecord: announcement.txtRecord) == announcement)
        #expect(NodeAnnouncement(txtRecord: ["name": "no id"]) == nil)
        #expect(announcement.id.shortCode.count == 4)
    }
}

@MainActor
struct NodeSessionTests {
    private func session(on network: SimulatedNetwork, named name: String, clock: ManualClock, defaults: UserDefaults) -> NodeSession {
        let transport = network.addPhone(name)
        return NodeSession(
            store: NodeStore(defaults: defaults),
            clock: clock,
            defaultName: name,
            makeTransport: { transport },
            linkClock: network.clock(of: name),
            epoch: { fixedEpoch }
        )
    }

    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "NodeSessionTests-\(UUID().uuidString)"))
    }

    /// Runs the session's clock and the network side by side.
    private func run(_ seconds: TimeInterval, clock: ManualClock, network: SimulatedNetwork) async {
        for _ in 0..<Int((seconds / NodeSession.syncInterval).rounded()) {
            await clock.advance(by: NodeSession.syncInterval)
            network.run(for: NodeSession.syncInterval)
        }
    }

    @Test
    func aPairedPhoneIsSynchronizedAndAnUnpairedOneIsNot() async throws {
        let network = SimulatedNetwork()
        let clock = ManualClock()
        let controller = session(on: network, named: "a", clock: clock, defaults: try scratchDefaults())
        let speaker = link(network.addPhone("b", offset: -42.25, rate: -120e-6), on: network, role: .speaker)

        controller.start()
        speaker.start()
        let id = speaker.announcement.id
        await waitUntil { controller.peers[id]?.isReachable == true }
        #expect(controller.peers[id]?.role == .speaker)

        await run(1, clock: clock, network: network)
        #expect(controller.peers[id]?.counts.sent == 0)
        #expect(controller.mapping(for: id) == nil)

        controller.pair(id)
        await run(3, clock: clock, network: network)
        await waitUntil { controller.mapping(for: id) != nil }

        let offset = try #require(controller.offset(for: id))
        #expect(offset.contains(network.offset(of: "b", from: "a")))
        #expect((controller.peers[id]?.roundTrips.count ?? 0) > 20)
    }

    @Test
    func aJumpingClockIsReportedAndDistrustedForAWhile() async throws {
        let network = SimulatedNetwork()
        let clock = ManualClock()
        let controller = session(on: network, named: "a", clock: clock, defaults: try scratchDefaults())
        let camera = link(network.addPhone("b", offset: 7), on: network)

        controller.start()
        camera.start()
        let id = camera.announcement.id
        await waitUntil { controller.peers[id]?.isReachable == true }
        controller.pair(id)
        await run(2, clock: clock, network: network)
        await waitUntil { controller.mapping(for: id) != nil }

        network.shiftClock(of: "b", by: 0.05)
        await run(1, clock: clock, network: network)
        await waitUntil { controller.peers[id]?.violationCount == 1 }
        #expect(controller.mapping(for: id) == nil)

        await run(NodeSession.quarantine + 1, clock: clock, network: network)
        await waitUntil { controller.mapping(for: id) != nil }

        let offset = try #require(controller.offset(for: id))
        #expect(offset.contains(network.offset(of: "b", from: "a")))
        #expect(controller.peers[id]?.violationCount == 1)
    }

    @Test
    func pairingAndIdentityAreKept() async throws {
        let defaults = try scratchDefaults()
        let network = SimulatedNetwork()
        let clock = ManualClock()
        let first = session(on: network, named: "a", clock: clock, defaults: defaults)
        let other = link(network.addPhone("b"), on: network)

        first.start()
        other.start()
        let id = other.announcement.id
        await waitUntil { first.peers[id]?.isReachable == true }
        first.pair(id)
        first.update(name: "Finish", role: .camera)
        first.stop()

        let second = NodeSession(store: NodeStore(defaults: defaults), clock: clock, defaultName: "ignored", makeTransport: { network.addPhone("c") })
        #expect(second.identity == first.identity)
        #expect(second.identity.name == "Finish")
        #expect(second.peers[id]?.isPaired == true)
        #expect(second.peers[id]?.isReachable == false)

        second.unpair(id)
        #expect(second.peers[id] == nil)
        #expect(NodeStore(defaults: defaults).loadPaired().isEmpty)
    }
}

/// The real network stack: two transports in one process, so both read
/// the same host clock and the true offset is exactly 0.
@MainActor
struct NetworkTransportTests {
    @Test
    func twoTransportsInOneProcessSynchronizeToZero() async throws {
        let a = NodeLink(
            announcement: NodeAnnouncement(id: NodeID(), name: "Loopback A", role: .controller),
            transport: NetworkNodeTransport(),
            now: NodeSession.hostClock
        )
        let b = NodeLink(
            announcement: NodeAnnouncement(id: NodeID(), name: "Loopback B", role: .camera),
            transport: NetworkNodeTransport(),
            now: NodeSession.hostClock
        )
        let log = LinkEventLog(a)
        defer {
            a.stop()
            b.stop()
        }

        a.start()
        b.start()
        await waitUntil(timeout: .seconds(20)) { log.found.contains { $0.id == b.announcement.id } }

        var estimator = ClockSyncEstimator()
        var round = 0
        while round < 30, estimator.violation == nil {
            let requested = a.requestSync(with: b.announcement.id)
            #expect(requested)
            // A lost request is not waited for.
            let expected = log.samples.count + 1
            await waitUntil(timeout: .seconds(5)) { log.samples.count >= expected }
            if let sample = log.samples.last?.sample {
                estimator.add(sample.exchange)
            }
            round += 1
        }

        #expect(estimator.violation == nil)
        #expect(log.samples.count >= 25)

        let offset = try #require(estimator.offset(at: NodeSession.hostClock()))
        #expect(offset.contains(0))
        Attachment.record(
            "width \(offset.width * 1_000) ms, round trips \(log.samples.map { ($0.sample.exchange.roundTrip * 1_000_000).rounded() / 1_000 }) ms, kernel leads \(log.samples.compactMap { $0.sample.replyKernelLead.map { ($0 * 1_000_000).rounded() } }) µs",
            named: "Loopback synchronization"
        )
    }
}

/// Run on two devices (or a device and a simulator) on the same network at
/// the same time, with `TEST_RUNNER_RUN_SYNC_PEER=1`. Each pairs with the
/// first phone it finds that runs this test and synchronizes for a minute.
@MainActor
struct TwoPhoneSyncTests {
    private nonisolated static var peerRequested: Bool {
        ProcessInfo.processInfo.environment["RUN_SYNC_PEER"] == "1"
    }

    /// How long the measurement runs.
    private static let duration: TimeInterval = 60
    private static let testName = "Sync test"

    @Test(.enabled(if: peerRequested))
    func twoPhonesSynchronize() async throws {
        let defaults = try #require(UserDefaults(suiteName: "TwoPhoneSyncTests"))
        let session = NodeSession(store: NodeStore(defaults: defaults), defaultName: Self.testName)
        session.update(name: Self.testName, role: .camera)
        session.start()
        defer { session.stop() }

        await waitUntil(timeout: .seconds(120)) { session.peers.values.contains { $0.name == Self.testName && $0.isReachable } }
        let peer = try #require(session.peers.values.first { $0.name == Self.testName && $0.isReachable })
        session.pair(peer.id)

        // The measurement itself takes this long; nothing is waited for.
        var widths: [TimeInterval] = []
        for _ in 0..<Int(Self.duration) {
            try await Task.sleep(for: .seconds(1))
            if let offset = session.offset(for: peer.id) {
                widths.append(offset.width)
            }
        }

        let result = try #require(session.peers[peer.id])
        let trips = result.roundTrips.sorted()
        let sortedWidths = widths.sorted()
        func ms(_ value: TimeInterval?) -> String { value.map { String(format: "%.3f ms", $0 * 1_000) } ?? "–" }
        func percentile(_ values: [TimeInterval], _ share: Double) -> TimeInterval? {
            values.isEmpty ? nil : values[min(values.count - 1, Int(Double(values.count) * share))]
        }
        let rate = result.estimator.rate

        let report = """
        peer \(peer.name) \(peer.id.shortCode), \(Self.duration) s
        exchanges sent \(result.counts.sent), lost \(result.counts.lost), unmatched \(result.counts.unmatched), interrupted \(result.counts.interrupted)
        round trip (last \(trips.count)): min \(ms(trips.first)), median \(ms(percentile(trips, 0.5))), p95 \(ms(percentile(trips, 0.95)))
        interval width right after an exchange (last \(result.widths.count)): median \(ms(percentile(result.widths.sorted(), 0.5))), max \(ms(result.widths.max()))
        interval width once a second (\(widths.count) readings): median \(ms(percentile(sortedWidths, 0.5))), p95 \(ms(percentile(sortedWidths, 0.95))), max \(ms(sortedWidths.last))
        rate \(rate.map { String(format: "%+.2f ppm (%+.2f … %+.2f) over %.0f s", $0.best * 1e6, $0.lower * 1e6, $0.upper * 1e6, $0.span) } ?? "–")
        kernel lead median \(ms(percentile(result.kernelLeads.sorted(), 0.5)))
        violations \(result.violationCount)\(result.lastViolation.map { ", last \($0)" } ?? ""), clock restarts \(result.restartCount)
        """
        Attachment.record(report, named: "sync-peer.txt")

        #expect(result.violationCount == 0)
        #expect(session.mapping(for: peer.id) != nil)
    }
}
