//
//  NodeLink.swift
//  OnYourMarks
//
//  Between the network and the rest of the app: decodes what arrives,
//  answers clock requests on the spot and pairs replies with requests.
//

import Foundation
import Synchronization

/// Where a datagram came from or goes to, as the transport names it.
nonisolated struct PeerAddress: Hashable, Sendable {
    let rawValue: String
}

nonisolated enum TransportState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)
}

nonisolated struct ReceivedDatagram: Sendable {
    let data: Data
    let from: PeerAddress
    /// Host clock, stamped in the app after the datagram was handed up.
    let receivedAt: MonotonicTimestamp
    /// Host clock, from the kernel's receive timestamp if the transport has
    /// one. Not used for the bound; it shows how much later the app's own
    /// stamp is.
    let kernelReceivedAt: MonotonicTimestamp?
}

nonisolated enum TransportEvent: Sendable {
    case stateChanged(TransportState)
    /// A phone advertising the service, with its Bonjour record.
    case peerFound(PeerAddress, txtRecord: [String: String])
    case peerLost(PeerAddress)
    case received(ReceivedDatagram)
}

/// Datagrams between phones nearby. Hardware, so it is injected: the app
/// uses `NetworkNodeTransport`, tests a simulated network.
nonisolated protocol DatagramTransport: AnyObject, Sendable {
    /// Starts advertising this phone and looking for others. The handler is
    /// called on the transport's own threads, possibly concurrently.
    func start(announcing announcement: NodeAnnouncement, handler: @escaping @Sendable (TransportEvent) -> Void)
    func stop()
    /// Hands a datagram to the network and returns at once.
    func send(_ data: Data, to peer: PeerAddress)
}

/// One completed exchange with what is needed to judge it.
nonisolated struct SyncSample: Equatable, Sendable {
    let exchange: SyncExchange
    /// The local clock's epoch at the end of the exchange (unchanged since
    /// its beginning, or the exchange would have been dropped).
    let localEpoch: ClockEpoch
    /// The remote clock's epoch when it replied.
    let remoteEpoch: ClockEpoch
    /// How much earlier the kernel saw the reply than the app stamped it.
    let replyKernelLead: TimeInterval?
}

nonisolated struct SyncCounts: Equatable, Sendable {
    var sent = 0
    var lost = 0
    var unmatched = 0
    var interrupted = 0
}

nonisolated enum NodeLinkEvent: Sendable {
    case transportChanged(TransportState)
    /// A phone was found, through Bonjour or its hello.
    case found(NodeAnnouncement)
    case lost(NodeID)
    case synchronized(NodeID, SyncSample)
    case received(NodeID, NodeMessage, at: MonotonicTimestamp)
    /// A phone that speaks another protocol version.
    case incompatible(PeerAddress, version: Int)
}

/// Lives on the transport's threads, so that a clock request is answered
/// without waiting for the main actor. The remote's hold is left out of the
/// bound anyway; what counts is that the stamps are taken here, next to the
/// network, and not after a wait for a main actor that audio calls hold up
/// to 0.16 s.
nonisolated final class NodeLink: Sendable {
    let announcement: NodeAnnouncement
    let events: AsyncStream<NodeLinkEvent>

    private let continuation: AsyncStream<NodeLinkEvent>.Continuation
    private let transport: any DatagramTransport
    private let now: @Sendable () -> MonotonicTimestamp
    private let epoch: @Sendable () -> ClockEpoch
    private let nonce: @Sendable () -> UInt64
    private let state = Mutex(State())

    private struct State {
        var initiators: [NodeID: SyncInitiator] = [:]
        /// Where requests to a phone go: its advertised service if found,
        /// otherwise where it last wrote from.
        var addresses: [NodeID: PeerAddress] = [:]
        var advertised: [PeerAddress: NodeID] = [:]
        var known: Set<NodeID> = []
        var isRunning = false
    }

    init(
        announcement: NodeAnnouncement,
        transport: any DatagramTransport,
        now: @escaping @Sendable () -> MonotonicTimestamp,
        epoch: @escaping @Sendable () -> ClockEpoch = { ClockEpoch.current() },
        nonce: @escaping @Sendable () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) {
        self.announcement = announcement
        self.transport = transport
        self.now = now
        self.epoch = epoch
        self.nonce = nonce
        (events, continuation) = AsyncStream.makeStream()
    }

    deinit {
        continuation.finish()
    }

    func start() {
        let wasRunning = state.withLock { state in
            defer { state.isRunning = true }
            return state.isRunning
        }
        guard !wasRunning else { return }

        transport.start(announcing: announcement, handler: Self.makeHandler(for: self))
    }

    func stop() {
        state.withLock { $0 = State() }
        transport.stop()
    }

    /// Built here, outside any actor: the transport calls it on its threads.
    private static func makeHandler(for link: NodeLink) -> @Sendable (TransportEvent) -> Void {
        { [weak link] event in link?.handle(event) }
    }

    /// Asks a phone for its clock. False if there is no way to reach it.
    @discardableResult
    func requestSync(with node: NodeID) -> Bool {
        let request = SyncRequest(nonce: nonce())
        let epoch = epoch()

        guard let data = encode(.syncRequest(request), epoch: epoch) else { return false }

        // Stamped after encoding and before sending: as late as possible
        // while still before the request leaves.
        let sent = now()

        let address = state.withLock { state -> PeerAddress? in
            guard let address = state.addresses[node] else { return nil }

            state.initiators[node, default: SyncInitiator()].expire(now: sent)
            state.initiators[node, default: SyncInitiator()].register(request, sentAt: sent, epoch: epoch)
            return address
        }

        guard let address else { return false }

        transport.send(data, to: address)
        return true
    }

    func send(_ message: NodeMessage, to node: NodeID) {
        guard
            let address = state.withLock({ $0.addresses[node] }),
            let data = encode(message, epoch: epoch())
        else { return }

        transport.send(data, to: address)
    }

    func counts(for node: NodeID) -> SyncCounts {
        state.withLock { state in
            guard let initiator = state.initiators[node] else { return SyncCounts() }

            return SyncCounts(
                sent: initiator.sentCount,
                lost: initiator.lostCount,
                unmatched: initiator.unmatchedCount,
                interrupted: initiator.interruptedCount
            )
        }
    }

    // MARK: - Arriving

    func handle(_ event: TransportEvent) {
        switch event {
        case .stateChanged(let transportState):
            continuation.yield(.transportChanged(transportState))

        case .peerFound(let address, let txtRecord):
            guard let found = NodeAnnouncement(txtRecord: txtRecord), found.id != announcement.id else { return }

            guard found.protocolVersion == NodeProtocol.version else {
                continuation.yield(.incompatible(address, version: found.protocolVersion))
                return
            }

            state.withLock { state in
                state.advertised[address] = found.id
                state.addresses[found.id] = address
                state.known.insert(found.id)
            }
            continuation.yield(.found(found))

            if let hello = encode(.hello(announcement), epoch: epoch()) {
                transport.send(hello, to: address)
            }

        case .peerLost(let address):
            let lost = state.withLock { state -> NodeID? in
                guard let id = state.advertised.removeValue(forKey: address) else { return nil }

                if state.addresses[id] == address {
                    state.addresses.removeValue(forKey: id)
                }
                state.known.remove(id)
                return id
            }

            if let lost {
                continuation.yield(.lost(lost))
            }

        case .received(let datagram):
            receive(datagram)
        }
    }

    private func receive(_ datagram: ReceivedDatagram) {
        let envelope: NodeEnvelope

        switch NodeEnvelope.decode(datagram.data) {
        case .success(let decoded):
            envelope = decoded
        case .failure(.otherVersion(let version)):
            continuation.yield(.incompatible(datagram.from, version: version))
            return
        case .failure(.unreadable):
            return
        }

        guard envelope.sender != announcement.id else { return }

        switch envelope.message {
        case .syncRequest(let request):
            // Answered first and from here: every step before t3 is the
            // remote's hold, which the bound leaves out.
            let reply = SyncReply(nonce: request.nonce, requestReceived: datagram.receivedAt, replySent: now())

            if let data = encode(.syncReply(reply), epoch: epoch()) {
                transport.send(data, to: datagram.from)
            }
            remember(envelope.sender, at: datagram.from)

        case .syncReply(let reply):
            let localEpoch = epoch()
            let exchange = state.withLock {
                $0.initiators[envelope.sender]?.complete(reply, receivedAt: datagram.receivedAt, epoch: localEpoch)
            }

            guard let exchange else { return }

            let lead = datagram.kernelReceivedAt.map { datagram.receivedAt.seconds - $0.seconds }.flatMap { $0 >= 0 ? $0 : nil }
            let sample = SyncSample(exchange: exchange, localEpoch: localEpoch, remoteEpoch: envelope.epoch, replyKernelLead: lead)
            continuation.yield(.synchronized(envelope.sender, sample))

        case .hello(let hello):
            guard hello.id == envelope.sender else { return }

            let isNew = remember(envelope.sender, at: datagram.from)
            if isNew {
                continuation.yield(.found(hello))
            }
            continuation.yield(.received(envelope.sender, envelope.message, at: datagram.receivedAt))
        }
    }

    /// A phone that writes to us can be written back to, also if its
    /// Bonjour record was never seen. True if it wasn't known.
    @discardableResult
    private func remember(_ node: NodeID, at address: PeerAddress) -> Bool {
        state.withLock { state in
            if state.addresses[node] == nil {
                state.addresses[node] = address
            }
            return state.known.insert(node).inserted
        }
    }

    private func encode(_ message: NodeMessage, epoch: ClockEpoch) -> Data? {
        let envelope = NodeEnvelope(sender: announcement.id, epoch: epoch, message: message)

        guard let data = try? envelope.encoded(), data.count <= NodeProtocol.maximumDatagramSize else { return nil }
        return data
    }
}
