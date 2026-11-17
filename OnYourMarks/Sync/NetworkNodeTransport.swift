//
//  NetworkNodeTransport.swift
//  OnYourMarks
//
//  UDP over Bonjour with the Network framework's Swift connections,
//  peer-to-peer included, so phones on a track find each other without an
//  access point.
//

import Foundation
import Network
import OSLog
import QuartzCore
import Synchronization

/// Why UDP: the bound is as tight as the fastest round trips, so what
/// matters is that each datagram goes out at once and on its own. A lost
/// one costs one exchange of ten a second; on a stream (TCP, QUIC streams)
/// a lost segment would hold back every message behind it. Why Bonjour
/// with peer-to-peer: it needs no access point (Apple Wireless Direct Link
/// between phones), no pairing UI and no entitlement, and works in the
/// simulator. Wi-Fi Aware could take its place behind `DatagramTransport`.
nonisolated final class NetworkNodeTransport: DatagramTransport {
    private let state = Mutex(State())

    private struct State {
        var run: Task<Void, Never>?
        var links: [PeerAddress: Link] = [:]
        var browsed: [String: PeerAddress] = [:]
    }

    /// One connection with the task that writes its outbox.
    private struct Link {
        let outbox: AsyncStream<Data>.Continuation
        let tasks: [Task<Void, Never>]

        func close() {
            outbox.finish()
            tasks.forEach { $0.cancel() }
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks", category: "Sync")

    init() {}

    deinit {
        stop()
    }

    func start(announcing announcement: NodeAnnouncement, handler: @escaping @Sendable (TransportEvent) -> Void) {
        let run = Task { [weak self] in
            guard let self else { return }
            await self.run(announcing: announcement, handler: handler)
        }

        state.withLock { state in
            state.run?.cancel()
            state.run = run
        }
    }

    func stop() {
        let links = state.withLock { state in
            state.run?.cancel()
            state.run = nil
            state.browsed = [:]
            defer { state.links = [:] }
            return Array(state.links.values)
        }

        links.forEach { $0.close() }
    }

    func send(_ data: Data, to peer: PeerAddress) {
        _ = state.withLock { $0.links[peer] }?.outbox.yield(data)
    }

    // MARK: - Running

    private func run(announcing announcement: NodeAnnouncement, handler: @escaping @Sendable (TransportEvent) -> Void) async {
        handler(.stateChanged(.starting))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.listen(announcing: announcement, handler: handler) }
            group.addTask { await self.browse(ignoring: announcement.id, handler: handler) }
        }

        handler(.stateChanged(.stopped))
    }

    /// The stack of every connection: UDP, with the kernel's receive time.
    private static func parameters() -> NWParametersBuilder<UDP> {
        NWParametersBuilder.parameters {
            UDP {
                IP().receiveTimeCalculated(true)
            }
        }
        .peerToPeerIncluded(true)
    }

    private func listen(announcing announcement: NodeAnnouncement, handler: @escaping @Sendable (TransportEvent) -> Void) async {
        do {
            let listener = try NetworkListener(
                for: .bonjour(
                    name: announcement.id.rawValue.uuidString,
                    type: NodeProtocol.serviceType,
                    txtRecord: NWTXTRecord(announcement.txtRecord)
                ),
                using: Self.parameters()
            )
            .onStateUpdate { _, state in
                switch state {
                case .ready:
                    handler(.stateChanged(.ready))
                case .failed(let error), .waiting(let error):
                    handler(.stateChanged(.failed(error.localizedDescription)))
                default:
                    break
                }
            }

            try await listener.run { [weak self] connection in
                guard let self else { return }

                let address = PeerAddress(rawValue: "in:\(connection.id)")
                await self.serve(connection, at: address, handler: handler)
            }
        } catch {
            if !Task.isCancelled {
                Self.logger.error("Listener ended: \(error.localizedDescription, privacy: .public)")
                handler(.stateChanged(.failed(error.localizedDescription)))
            }
        }
    }

    private func browse(ignoring own: NodeID, handler: @escaping @Sendable (TransportEvent) -> Void) async {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true

        let browser = NetworkBrowser(for: .bonjour(NodeProtocol.serviceType, includeTxtRecord: true), using: parameters)

        do {
            try await browser.run { [weak self] endpoints in
                self?.update(endpoints.filter { $0.txtRecord.dictionary["id"] != own.rawValue.uuidString }, handler: handler)
            }
        } catch {
            if !Task.isCancelled {
                Self.logger.error("Browser ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func update(_ endpoints: [Bonjour.Endpoint], handler: @escaping @Sendable (TransportEvent) -> Void) {
        let current = Set(endpoints.map(\.id))

        let gone = state.withLock { state in
            let gone = state.browsed.filter { !current.contains($0.key) }
            for (id, address) in gone {
                state.browsed.removeValue(forKey: id)
                state.links.removeValue(forKey: address)?.close()
            }
            return Array(gone.values)
        }

        for address in gone {
            handler(.peerLost(address))
        }

        for endpoint in endpoints {
            let address = PeerAddress(rawValue: "out:\(endpoint.id)")
            let isNew = state.withLock { state in
                guard state.browsed[endpoint.id] == nil else { return false }
                state.browsed[endpoint.id] = address
                return true
            }

            if isNew {
                let connection = NetworkConnection(to: endpoint, using: Self.parameters())
                open(connection, at: address, handler: handler)
            }

            // Again for a known one: its record may have changed.
            handler(.peerFound(address, txtRecord: endpoint.txtRecord.dictionary))
        }
    }

    // MARK: - Connections

    /// An inbound connection lives as long as the listener's call for it.
    private func serve(_ connection: NetworkConnection<UDP>, at address: PeerAddress, handler: @escaping @Sendable (TransportEvent) -> Void) async {
        let (outbox, continuation) = AsyncStream<Data>.makeStream()
        let writer = Task { await Self.write(outbox, to: connection) }

        state.withLock { $0.links[address] = Link(outbox: continuation, tasks: [writer]) }

        await Self.read(connection, from: address, handler: handler)

        state.withLock { $0.links.removeValue(forKey: address) }?.close()
    }

    private func open(_ connection: NetworkConnection<UDP>, at address: PeerAddress, handler: @escaping @Sendable (TransportEvent) -> Void) {
        let (outbox, continuation) = AsyncStream<Data>.makeStream()
        let writer = Task { await Self.write(outbox, to: connection) }
        let reader = Task { await Self.read(connection, from: address, handler: handler) }

        state.withLock { $0.links[address] = Link(outbox: continuation, tasks: [writer, reader]) }
    }

    private static func write(_ outbox: AsyncStream<Data>, to connection: NetworkConnection<UDP>) async {
        for await data in outbox {
            do {
                try await connection.send(data)
            } catch {
                logger.debug("Send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func read(_ connection: NetworkConnection<UDP>, from address: PeerAddress, handler: @escaping @Sendable (TransportEvent) -> Void) async {
        do {
            for try await message in connection.messages {
                // As soon as the datagram is up here: the receive stamp of
                // the exchange.
                let receivedAt = MonotonicTimestamp(seconds: CACurrentMediaTime())

                handler(
                    .received(
                        ReceivedDatagram(
                            data: message.content,
                            from: address,
                            receivedAt: receivedAt,
                            kernelReceivedAt: kernelReceiveTime(message.metadata)
                        )
                    )
                )
            }
        } catch {
            if !Task.isCancelled {
                logger.debug("Connection \(address.rawValue, privacy: .public) ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The kernel's receive time counts on the clock that runs through
    /// sleep (CLOCK_MONOTONIC_RAW); the host clock doesn't, so the time
    /// slept is taken off.
    private static func kernelReceiveTime(_ metadata: UDP.Metadata) -> MonotonicTimestamp? {
        guard
            let ip = metadata.other.lazy.compactMap({ $0 as? NWProtocolIP.Metadata }).first,
            ip.receiveTime > 0
        else { return nil }

        let epoch = ClockEpoch.current()
        let slept = (epoch.sleptAtLeast + epoch.sleptAtMost) / 2

        return MonotonicTimestamp(seconds: Double(ip.receiveTime) / Double(NSEC_PER_SEC) - slept)
    }
}
